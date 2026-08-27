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
    /// 正在给哪个站点加账号，以及用哪种方式登录。
    var loginSite: ForumSite = .nga
    var loginMethod: SiteLoginMethod = ForumSiteDescriptor.nga.loginMethods[0]
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

    /// 当前账号所在站点支持的功能。没有账号时是空集，对应的控件一律不画。
    var activeCapabilities: ForumCapabilities {
        activeService?.capabilities ?? []
    }

    func supports(_ capability: ForumCapabilities) -> Bool {
        activeCapabilities.contains(capability)
    }

    /// 取当前账号的服务；没有就说明原因，而不是当作什么都没发生。
    ///
    /// 会话不完整的账号建不出服务（见 `reloadAccountsAndServices`）。原先各处一律
    /// `guard let ... else { return }` 静默退出：点版面没反应、点话题没反应、
    /// 也没有任何提示 —— 从用户那边看就是应用卡住了。边栏上虽然给那个账号标了
    /// 「需要重新登录」，但正在看列表的人不会盯着边栏找解释。
    func requireService(_ what: String) -> (any ForumService)? {
        if let activeService { return activeService }
        statusMessage = activeAccount == nil
            ? "还没有账号，先添加一个再\(what)"
            : "当前账号需要重新登录，暂时无法\(what)"
        statusMessageIsError = true
        return nil
    }

    func service(for accountID: AccountID) -> (any ForumService)? {
        services[accountID]
    }

    func onError(_ observer: @escaping (Error) -> Void) {
        errorObservers.append(observer)
    }

    // MARK: - 账号与服务

    /// 按站点造服务。现在只有一个分支 —— 加站点时编译器会要求补上。
    ///
    /// `userAgent` 由调用方解析后传入：要求用 WebView 真实 UA 的站点得先去问一次 WebView，
    /// 而那是 `@MainActor` 上的异步动作，不能塞进这里。
    func makeService(
        site: ForumSite,
        accountID: AccountID,
        cookies: [SessionCookie],
        userAgent: String? = nil
    ) -> any ForumService {
        let persist: @Sendable ([SessionCookie]) async -> Void = { [sessionStore] cookies in
            try? await sessionStore.save(cookies: cookies, for: accountID)
        }
        switch site {
        case .nodeseek:
            return NodeSeekForumService(
                accountID: accountID,
                cookies: cookies,
                userAgent: userAgent ?? site.descriptor.resolvedUserAgent(fallback: nil),
                cookieDidChange: persist
            )
        case .nga:
            return NGAForumService(
                accountID: accountID,
                cookies: cookies,
                userAgent: userAgent ?? site.descriptor.resolvedUserAgent(fallback: nil),
                cookieDidChange: persist
            )
        }
    }

    /// 解析出该站点要用的 UA。要求用 WebView 真实 UA 的站点在这里去问一次。
    func resolvedUserAgent(for site: ForumSite) async -> String {
        switch site.descriptor.userAgent {
        case let .fixed(value):
            return value
        case .webView:
            return await WebViewUserAgent.resolve()
                ?? site.descriptor.resolvedUserAgent(fallback: nil)
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
                let descriptor = record.site.descriptor
                // 会话 Cookie 必须一个不缺，且都不能是空值。
                let hasSession = descriptor.sessionCookieNames.allSatisfy { name in
                    cookies.contains {
                        $0.name.caseInsensitiveCompare(name) == .orderedSame && !$0.value.isEmpty
                    }
                }
                // 有 uid Cookie 的站点顺便核对这份 Cookie 是不是这个账号的；没有的站点跳过 ——
                // 那种站的用户编号不在 Cookie 里，本地无从校验。
                let matchesAccount = descriptor.uidCookieName.map { name in
                    cookies.contains {
                        $0.name.caseInsensitiveCompare(name) == .orderedSame &&
                            Int64($0.value) == record.siteUserID
                    }
                } ?? true
                if !hasSession || !matchesAccount {
                    record.sessionState = .requiresLogin
                } else {
                    // 本地凭据仍完整时先恢复为有效。单个接口的偶发鉴权失败
                    // 不应在下次启动后继续污染整个账号状态。
                    record.sessionState = .valid
                    services[record.accountID] = makeService(
                        site: record.site,
                        accountID: record.accountID,
                        cookies: cookies,
                        userAgent: await resolvedUserAgent(for: record.site)
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
            errorMessage = siteQualified(error.localizedDescription)
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
            statusMessage = siteQualified("暂时未验证本次请求，已保留当前登录状态，请重试")
            statusMessageIsError = true
            return
        }

        errorMessage = siteQualified(error.localizedDescription)
        markSessionRequiresLogin(accountID: activeAccountID)
    }

    /// 给一条要展示的消息冠上站名。
    ///
    /// 站名不放进 `ForumServiceError`：错误值会跨账号传递和比较，为了文案给每一处
    /// 构造都加一个参数不划算。展示的时候本来就知道当前是哪个账号，从这里补最省。
    /// 一个账号都没有时不冠 —— 那种情况下也没有「哪个站」可言。
    private func siteQualified(_ message: String) -> String {
        guard let site = activeService?.site else { return message }
        return "\(site.displayName)：\(message)"
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
            let message = checkInFailureMessage(error, site: service.site)
            checkInStatuses[activeAccountID] = .failed(message: message)
            statusMessage = message
            statusMessageIsError = true
        }
        updateActiveAccountCheckInStatus()
    }

    /// 签到的失败提示走的是 `statusMessage`，不经过 `present(_:)`，所以站名在这里冠。
    private func checkInFailureMessage(_ error: Error, site: ForumSite) -> String {
        let detail = error.localizedDescription
            .localizedCaseInsensitiveContains("client error")
            ? "签到请求被拒绝，请稍后重试"
            : error.localizedDescription
        return "\(site.displayName)：\(detail)"
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
