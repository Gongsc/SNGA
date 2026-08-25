import Foundation
import Observation
import SwiftData

/// 与 NGA 的会话：账号、每账号的服务实例，以及各领域共用的错误呈现与加载计数。
///
/// 论坛、话题、消息等领域各自持有状态，但都需要「当前账号的服务」「出错了怎么提示」
/// 「请求期间显示加载指示」这三件事。把它们收在这里，各领域就只依赖本类型，
/// 而不必反手持有 `AppModel` —— 那样只是代码搬家，并没有解耦。
@MainActor
@Observable
final class AppSession {
    var accounts: [AccountSummary] = []
    var activeAccountID: AccountID?

    var isLoading = false
    var showsLogin = false
    var errorMessage: String?
    var statusMessage: String?
    var statusMessageIsError = false

    private(set) var checkInStatuses: [AccountID: DailyCheckInStatus] = [:]
    private(set) var queryingCheckInAccountIDs: Set<AccountID> = []
    private(set) var activeAccountCheckInStatus: DailyCheckInStatus = .failed(
        message: "尚未登录"
    )

    @ObservationIgnored let context: ModelContext
    @ObservationIgnored let sessionStore: any SessionStore
    @ObservationIgnored let notificationService: NotificationService
    @ObservationIgnored private var services: [AccountID: any ForumService] = [:]
    @ObservationIgnored private var foregroundLoginFailureDates: [AccountID: Date] = [:]
    @ObservationIgnored private var loadingRequestCount = 0

    /// 各领域对错误的附加反应（例如话题被锁时把当前话题标记为锁定）。
    /// `present(_:)` 本身不认识任何领域概念，具体反应由领域自己登记。
    @ObservationIgnored private var errorObservers: [(Error) -> Void] = []

    init(
        container: ModelContainer,
        sessionStore: any SessionStore,
        notificationService: NotificationService
    ) {
        self.context = ModelContext(container)
        self.sessionStore = sessionStore
        self.notificationService = notificationService
        context.autosaveEnabled = true
    }

    var activeAccount: AccountSummary? {
        accounts.first { $0.id == activeAccountID }
    }

    var activeService: (any ForumService)? {
        guard let activeAccountID else { return nil }
        return services[activeAccountID]
    }

    func service(for accountID: AccountID) -> (any ForumService)? {
        services[accountID]
    }

    func onError(_ observer: @escaping (Error) -> Void) {
        errorObservers.append(observer)
    }

    // MARK: - 账号与服务

    func makeService(
        accountID: AccountID,
        cookies: [SessionCookie]
    ) -> any ForumService {
        NGAForumService(accountID: accountID, cookies: cookies) { [sessionStore] cookies in
            try? await sessionStore.save(cookies: cookies, for: accountID)
        }
    }

    func setService(_ service: (any ForumService)?, for accountID: AccountID) {
        services[accountID] = service
    }

    func reloadAccountsAndServices() async {
        do {
            let records = try context.fetch(
                FetchDescriptor<AccountRecord>(sortBy: [SortDescriptor(\.createdAt)])
            )
            if !records.isEmpty, !records.contains(where: \.isCurrent) {
                records[0].isCurrent = true
            }
            services.removeAll()
            for record in records {
                let cookies = try await sessionStore.cookies(for: record.accountID)
                let hasUID = cookies.contains {
                    $0.name.caseInsensitiveCompare("ngaPassportUid") == .orderedSame &&
                        Int64($0.value) == record.ngaUID
                }
                let hasCredential = cookies.contains {
                    $0.name.caseInsensitiveCompare("ngaPassportCid") == .orderedSame &&
                        !$0.value.isEmpty
                }
                if !hasUID || !hasCredential {
                    record.sessionState = .requiresLogin
                } else {
                    // 本地凭据仍完整时先恢复为有效。单个 NGA 接口的偶发鉴权失败
                    // 不应在下次启动后继续污染整个账号状态。
                    record.sessionState = .valid
                    services[record.accountID] = makeService(
                        accountID: record.accountID,
                        cookies: cookies
                    )
                }
            }
            try context.save()
            accounts = records.map { $0.summary() }
            activeAccountID = records.first(where: \.isCurrent)?.accountID
                ?? records.first?.accountID
            let accountIDs = Set(records.map(\.accountID))
            checkInStatuses = checkInStatuses.filter { accountIDs.contains($0.key) }
            for record in records where record.sessionState == .valid {
                checkInStatuses[record.accountID] = checkInStatuses[record.accountID] ?? .loading
            }
            updateActiveAccountCheckInStatus()
        } catch {
            present(error)
        }
    }

    func markSessionRequiresLogin(accountID: AccountID) {
        if let record = ((try? context.fetch(FetchDescriptor<AccountRecord>())) ?? [])
            .first(where: { $0.accountID == accountID }) {
            record.sessionState = .requiresLogin
            try? context.save()
        }
        if let index = accounts.firstIndex(where: { $0.id == accountID }) {
            accounts[index].sessionState = .requiresLogin
        }
        checkInStatuses[accountID] = .failed(message: "登录状态已失效")
        updateActiveAccountCheckInStatus()
    }

    // MARK: - 加载与错误

    func beginLoading() {
        loadingRequestCount += 1
        isLoading = true
    }

    func endLoading() {
        loadingRequestCount = max(0, loadingRequestCount - 1)
        isLoading = loadingRequestCount > 0
    }

    /// 包裹一次请求：维护加载指示，并在失败时统一呈现。
    ///
    /// `isCurrent` 用来判断结果是否仍然有效（配合 `RequestSlot`）；账号在请求期间
    /// 被切换时同样不再写回，避免把上一个账号的错误弹给当前账号。
    func withLoading(
        showsIndicator: Bool = true,
        isCurrent: () -> Bool = { true },
        _ operation: () async throws -> Void
    ) async {
        let requestAccountID = activeAccountID
        if showsIndicator { beginLoading() }
        defer {
            if showsIndicator { endLoading() }
        }
        do {
            try await operation()
            if let requestAccountID,
               requestAccountID == activeAccountID,
               isCurrent() {
                foregroundLoginFailureDates[requestAccountID] = nil
            }
        } catch {
            guard requestAccountID == activeAccountID, isCurrent() else { return }
            present(error)
        }
    }

    func present(_ error: Error) {
        Task {
            await RuntimeLogger.shared.log(
                .error,
                category: "app",
                error.localizedDescription
            )
        }
        for observe in errorObservers { observe(error) }

        guard let serviceError = error as? ForumServiceError,
              serviceError == .requiresLogin,
              let activeAccountID else {
            errorMessage = error.localizedDescription
            return
        }

        let now = Date()
        let previousFailure = foregroundLoginFailureDates[activeAccountID]
        let isConsecutiveFailure = previousFailure.map {
            now.timeIntervalSince($0) <= 120
        } ?? false
        foregroundLoginFailureDates[activeAccountID] = now

        if !isConsecutiveFailure,
           accounts.first(where: { $0.id == activeAccountID })?.sessionState != .requiresLogin {
            statusMessage = "NGA 暂时未验证本次请求，已保留当前登录状态，请重试"
            statusMessageIsError = true
            return
        }

        errorMessage = error.localizedDescription
        markSessionRequiresLogin(accountID: activeAccountID)
    }

    func clearError() { errorMessage = nil }

    // MARK: - 签到

    /// 查询账号的签到状态。这里只调用只读的 `get_stat`，不会执行签到。
    func refreshCheckInStatuses(limitedTo accountIDs: Set<AccountID>? = nil) async {
        let records = (try? context.fetch(FetchDescriptor<AccountRecord>())) ?? []
        for record in records where record.sessionState == .valid {
            let accountID = record.accountID
            guard accountIDs?.contains(accountID) ?? true else { continue }
            guard let service = services[accountID] else {
                checkInStatuses[accountID] = .failed(message: "无法创建签到状态查询服务")
                continue
            }
            if case .checkingIn = checkInStatuses[accountID] { continue }
            guard queryingCheckInAccountIDs.insert(accountID).inserted else { continue }
            checkInStatuses[accountID] = .loading
            updateActiveAccountCheckInStatus()

            do {
                let statistics = try await service.checkInStatus()
                checkInStatuses[accountID] = dailyCheckInStatus(from: statistics)
                if statistics.isCheckedInToday {
                    record.lastCheckInDay = CheckInPolicy.dayKey(for: Date())
                    record.lastCheckInMessage = "今日已签到"
                }
            } catch {
                checkInStatuses[accountID] = .failed(
                    message: "签到状态查询失败：\(error.localizedDescription)"
                )
            }

            queryingCheckInAccountIDs.remove(accountID)
            updateActiveAccountCheckInStatus()
        }
        try? context.save()
        updateActiveAccountCheckInStatus()
    }

    func queryActiveAccountCheckInStatus() async {
        guard let activeAccountID else { return }
        await refreshCheckInStatuses(limitedTo: [activeAccountID])
    }

    func checkInActiveAccount() async {
        guard let activeAccountID,
              let service = services[activeAccountID] else { return }
        guard activeAccountCheckInStatus.canCheckIn else { return }
        let records = (try? context.fetch(FetchDescriptor<AccountRecord>())) ?? []
        guard let record = records.first(where: { $0.accountID == activeAccountID }) else {
            checkInStatuses[activeAccountID] = .failed(message: "无法读取签到账号")
            updateActiveAccountCheckInStatus()
            return
        }

        checkInStatuses[activeAccountID] = .checkingIn
        updateActiveAccountCheckInStatus()
        do {
            let result = try await service.checkIn()
            let resultMessage: String
            switch result {
            case let .success(message), let .alreadyCheckedIn(message):
                resultMessage = CheckInPolicy.userFacingSuccessMessage(from: message)
            }
            record.lastCheckInDay = CheckInPolicy.dayKey(for: Date())
            record.lastCheckInMessage = resultMessage
            try? context.save()

            do {
                var statistics = try await service.checkInStatus()
                // 写入接口已经明确成功时，即使只读接口同步稍有延迟，
                // 今天的状态也以本次签到结果为准。
                statistics.isCheckedInToday = true
                checkInStatuses[activeAccountID] = .checkedIn(
                    statistics: statistics,
                    message: resultMessage
                )
                statusMessage = resultMessage
                statusMessageIsError = false
            } catch {
                checkInStatuses[activeAccountID] = .failed(
                    message: "签到已完成，但统计信息刷新失败：\(error.localizedDescription)"
                )
                statusMessage = "\(resultMessage)，签到统计暂时无法读取"
                statusMessageIsError = false
            }
        } catch {
            let message = checkInFailureMessage(error)
            checkInStatuses[activeAccountID] = .failed(message: message)
            statusMessage = message
            statusMessageIsError = true
        }
        updateActiveAccountCheckInStatus()
    }

    private func checkInFailureMessage(_ error: Error) -> String {
        if error.localizedDescription.localizedCaseInsensitiveContains("client error") {
            return "签到请求被 NGA 拒绝，请稍后重试"
        }
        return error.localizedDescription
    }

    func updateActiveAccountCheckInStatus() {
        guard let activeAccountID else {
            activeAccountCheckInStatus = .failed(message: "尚未登录")
            return
        }
        activeAccountCheckInStatus = checkInStatuses[activeAccountID] ?? .loading
    }

    private func dailyCheckInStatus(from statistics: CheckInStatistics) -> DailyCheckInStatus {
        if statistics.isCheckedInToday {
            return .checkedIn(statistics: statistics, message: "今日已签到")
        }
        return .notCheckedIn(statistics: statistics)
    }
}
