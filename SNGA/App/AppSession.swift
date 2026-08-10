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

    var checkingInAccountIDs: Set<AccountID> = []
    var checkInFailures: [AccountID: String] = [:]
    private(set) var activeAccountCheckInStatus: DailyCheckInStatus = .failed(
        message: "尚未登录"
    )

    @ObservationIgnored let context: ModelContext
    @ObservationIgnored let sessionStore: any SessionStore
    @ObservationIgnored let notificationService: NotificationService
    @ObservationIgnored private var services: [AccountID: any NGAForumService] = [:]
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

    var activeService: (any NGAForumService)? {
        guard let activeAccountID else { return nil }
        return services[activeAccountID]
    }

    func service(for accountID: AccountID) -> (any NGAForumService)? {
        services[accountID]
    }

    func onError(_ observer: @escaping (Error) -> Void) {
        errorObservers.append(observer)
    }

    // MARK: - 账号与服务

    func makeService(
        accountID: AccountID,
        cookies: [SessionCookie]
    ) -> any NGAForumService {
        LiveNGAForumService(accountID: accountID, cookies: cookies) { [sessionStore] cookies in
            try? await sessionStore.save(cookies: cookies, for: accountID)
        }
    }

    func setService(_ service: (any NGAForumService)?, for accountID: AccountID) {
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
            refreshActiveAccountCheckInStatus(records: records)
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

        guard let serviceError = error as? NGAServiceError,
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

    func checkInAllAccounts(force: Bool = false) async {
        await checkInAccounts(force: force, limitedTo: nil)
    }

    func checkInActiveAccount() async {
        guard let activeAccountID else { return }
        let records = (try? context.fetch(FetchDescriptor<AccountRecord>())) ?? []
        refreshActiveAccountCheckInStatus(records: records)
        guard activeAccountCheckInStatus.canCheckIn else { return }
        await checkInAccounts(force: true, limitedTo: [activeAccountID])
    }

    private func checkInAccounts(
        force: Bool,
        limitedTo accountIDs: Set<AccountID>?
    ) async {
        let records = (try? context.fetch(FetchDescriptor<AccountRecord>())) ?? []
        refreshActiveAccountCheckInStatus(records: records)
        var results: [String] = []
        var hasFailure = false
        for record in records where record.sessionState == .valid {
            let accountID = record.accountID
            guard accountIDs?.contains(accountID) ?? true else { continue }
            guard force || CheckInPolicy.shouldCheckIn(
                lastSuccessfulDay: record.lastCheckInDay
            ) else { continue }
            guard let service = services[accountID] else { continue }
            checkingInAccountIDs.insert(accountID)
            checkInFailures[accountID] = nil
            refreshActiveAccountCheckInStatus(records: records)
            do {
                let result = try await service.checkIn()
                record.lastCheckInDay = CheckInPolicy.dayKey(for: Date())
                switch result {
                case let .success(message), let .alreadyCheckedIn(message):
                    let displayMessage = CheckInPolicy.userFacingSuccessMessage(from: message)
                    record.lastCheckInMessage = displayMessage
                    results.append("\(record.displayName)：\(displayMessage)")
                }
            } catch {
                hasFailure = true
                let message = checkInFailureMessage(error)
                checkInFailures[accountID] = message
                results.append("\(record.displayName)：\(message)")
            }
            checkingInAccountIDs.remove(accountID)
            refreshActiveAccountCheckInStatus(records: records)
        }
        try? context.save()
        refreshActiveAccountCheckInStatus(records: records)
        if !results.isEmpty {
            statusMessage = results.joined(separator: "\n")
            statusMessageIsError = hasFailure
        }
    }

    private func checkInFailureMessage(_ error: Error) -> String {
        if error.localizedDescription.localizedCaseInsensitiveContains("client error") {
            return "签到请求被 NGA 拒绝，请稍后重试"
        }
        return error.localizedDescription
    }

    func refreshActiveAccountCheckInStatus(
        records suppliedRecords: [AccountRecord]? = nil
    ) {
        guard let activeAccountID else {
            activeAccountCheckInStatus = .failed(message: "尚未登录")
            return
        }
        if checkingInAccountIDs.contains(activeAccountID) {
            activeAccountCheckInStatus = .checkingIn
            return
        }
        if let failure = checkInFailures[activeAccountID] {
            activeAccountCheckInStatus = .failed(message: failure)
            return
        }
        let records = suppliedRecords
            ?? ((try? context.fetch(FetchDescriptor<AccountRecord>())) ?? [])
        guard let record = records.first(where: { $0.accountID == activeAccountID }) else {
            activeAccountCheckInStatus = .failed(message: "无法读取签到状态")
            return
        }
        if record.lastCheckInDay == CheckInPolicy.dayKey(for: .now) {
            activeAccountCheckInStatus = .checkedIn(
                message: CheckInPolicy.userFacingSuccessMessage(
                    from: record.lastCheckInMessage
                )
            )
        } else {
            activeAccountCheckInStatus = .notCheckedIn
        }
    }
}
