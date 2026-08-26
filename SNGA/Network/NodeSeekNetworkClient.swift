import Foundation

/// NodeSeek 的请求客户端。
///
/// 和 `NGANetworkClient` 分开写而不是共用：两站的鉴权、限流和失败形态都不一样，
/// 硬凑成一个只会让两边都别扭。共用的是 `HTTPTransport` 和 cookie 的存法。
actor NodeSeekNetworkClient {
    private let transport: any HTTPTransport
    private var cookies: [SessionCookie]
    /// `WKWebView` 自报的真实 UA。见类型文档里的第 1 条约束。
    private let userAgent: String
    private let cookieDidChange: @Sendable ([SessionCookie]) async -> Void
    private var lastRequestAt: ContinuousClock.Instant?
    private let clock = ContinuousClock()

    init(
        cookies: [SessionCookie],
        transport: any HTTPTransport,
        userAgent: String,
        cookieDidChange: @escaping @Sendable ([SessionCookie]) async -> Void
    ) {
        self.cookies = cookies
        self.transport = transport
        self.userAgent = userAgent
        self.cookieDidChange = cookieDidChange
    }

    func currentCookies() -> [SessionCookie] { cookies.filter { !$0.isExpired } }

    /// 站点搜索限流 1 次 / 2 秒，其余接口没有实测过 —— 先按和 NGA 相近的节奏发。
    private func throttle() async throws {
        let now = clock.now
        guard let lastRequestAt else { self.lastRequestAt = now; return }
        let reservedAt = lastRequestAt.advanced(by: .milliseconds(320))
        if reservedAt <= now { self.lastRequestAt = now; return }
        self.lastRequestAt = reservedAt
        try await clock.sleep(until: reservedAt)
    }

    /// Cloudflare 把请求拦下来的三种形态。要在看状态码之前判 ——
    /// 「请去验证」和「请去登录」是两条不同的恢复路径。
    static func isChallenge(status: Int, headers: [String: String], body: Data) -> Bool {
        if headers.first(where: { $0.key.caseInsensitiveCompare("cf-mitigated") == .orderedSame })?
            .value.caseInsensitiveCompare("challenge") == .orderedSame {
            return true
        }
        let head = String(data: body.prefix(600), encoding: .utf8) ?? ""
        return head.contains("Just a moment")
            || head.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<!DOCTYPE")
    }

    /// 这几族接口在**未登录**时答 500 而不是 401。照常识把 500 显示成「服务器错误，请重试」，
    /// 会把唯一有用的动作（去登录）藏起来。
    static func isSessionScoped(_ url: URL) -> Bool {
        let path = url.path()
        return path.hasPrefix("/api/notification")
            || path.hasPrefix("/api/statistics")
            || path.hasPrefix("/api/admin")
            || path.hasPrefix("/api/account/find")
    }
}
