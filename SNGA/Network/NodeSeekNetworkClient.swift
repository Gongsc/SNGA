import Foundation

/// NodeSeek 的请求客户端。
///
/// 和 `NGANetworkClient` 分开写而不是共用：两站的鉴权、限流和失败形态都不一样，
/// 硬凑成一个只会让两边都别扭。共用的是 `HTTPTransport` 和 cookie 的存法。
actor NodeSeekNetworkClient {
    private let transport: any HTTPTransport
    private var jar: SessionCookieJar
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
        self.jar = SessionCookieJar(cookies)
        self.transport = transport
        self.userAgent = userAgent
        self.cookieDidChange = cookieDidChange
    }

    func currentCookies() -> [SessionCookie] { jar.unexpired }

    /// 站点搜索限流 1 次 / 2 秒，其余接口没有实测过 —— 先按和 NGA 相近的节奏发。
    private func throttle() async throws {
        let now = clock.now
        guard let lastRequestAt else { self.lastRequestAt = now; return }
        let reservedAt = lastRequestAt.advanced(by: .milliseconds(320))
        if reservedAt <= now { self.lastRequestAt = now; return }
        self.lastRequestAt = reservedAt
        try await clock.sleep(until: reservedAt)
    }

    /// 发一次 GET，拿回原始响应体。
    ///
    /// `asJSON` 决定带不带站点自身 XHR 的那几个头 —— 少了它们，有些接口会回 HTML。
    func get(_ url: URL, asJSON: Bool = true, referer: URL? = nil) async throws -> Data {
        try await send(url, method: "GET", body: nil, asJSON: asJSON, referer: referer)
    }

    /// 发一次 JSON POST。
    ///
    /// 写请求只发一次，不重试：这个站的写接口在非 2xx 上也带着有意义的响应体
    /// （重复签到是 HTTP 500，正文里正是要显示给用户的那句话），重试会造成重复提交。
    func postJSON(_ url: URL, body: [String: Any], referer: URL? = nil) async throws -> Data {
        let data = try JSONSerialization.data(withJSONObject: body)
        return try await send(url, method: "POST", body: data, asJSON: true, referer: referer)
    }

    private func send(
        _ url: URL,
        method: String,
        body: Data?,
        asJSON: Bool,
        referer: URL?
    ) async throws -> Data {
        try await throttle()

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = body == nil ? 25 : 40
        // 必须是 WebView 自报的那个串。写死会和页面 JS 环境对不上，触发无限挑战。
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue(
            asJSON ? "application/json, text/plain, */*" : ForumSiteDescriptor.htmlAccept,
            forHTTPHeaderField: "Accept"
        )
        request.setValue(
            (referer ?? ForumSiteDescriptor.nodeseek.baseURL).absoluteString,
            forHTTPHeaderField: "Referer"
        )
        if asJSON {
            // 站点自身的 XHR 带这几个；少了其中的 X-Requested-With，有些接口会回 HTML。
            request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
            request.setValue("empty", forHTTPHeaderField: "Sec-Fetch-Dest")
            request.setValue("cors", forHTTPHeaderField: "Sec-Fetch-Mode")
            request.setValue("same-origin", forHTTPHeaderField: "Sec-Fetch-Site")
        }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            // 浏览器只在写请求上带 Origin。
            request.setValue(
                ForumSiteDescriptor.nodeseek.baseURL.absoluteString,
                forHTTPHeaderField: "Origin"
            )
        }
        // 全部 cookie 一个不落。只带认识的那几个会被 Cloudflare 挑战（实测）。
        let cookieHeader = jar.header(for: url)
        if !cookieHeader.isEmpty {
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }

        await RuntimeLogger.shared.log(
            category: "network",
            "\(method) \(RuntimeLogger.sanitizedURL(url))"
        )
        let (data, response) = try await transport.data(for: request)
        let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, item in
            result[String(describing: item.key)] = String(describing: item.value)
        }
        if jar.merge(responseHeaders: headers, url: url) {
            await cookieDidChange(jar.cookies)
        }

        // 挑战要在看状态码之前判：「请去验证」和「请去登录」是两条不同的恢复路径。
        if Self.isChallenge(status: response.statusCode, headers: headers, body: data) {
            throw ForumServiceError.restricted(
                "需要在浏览器里完成一次人机验证。请重新登录本站账号，验证通过后再试。"
            )
        }
        switch response.statusCode {
        case 200..<300:
            return data
        case 401, 403:
            throw ForumServiceError.requiresLogin
        case 429:
            throw ForumServiceError.rateLimited
        case 500 where Self.isSessionScoped(url):
            // 这几族接口未登录时答 500 而不是 401。当成「服务器错误，请重试」会把
            // 唯一有用的动作藏起来。
            throw ForumServiceError.requiresLogin
        default:
            // 写接口在非 2xx 上也带有意义的正文，交给调用方读。
            if body != nil { return data }
            throw ForumServiceError.server(response.statusCode)
        }
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
