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

    /// `x-dynamic-sign` 的值。
    ///
    /// 站点只校验这个头存在，不校验内容 —— 试过填 `1` 就能通。真正的网页版会算一个
    /// 签名放进来，我们算不出，也不需要算。哪天站点开始验内容，投票会退回 403，
    /// 而那时错误里带着 403 和 `{"success":false}`，就是这里该改的信号。
    private static let dynamicSignHeaderValue = "1"

    /// `x-csrf-challenge` 的值。抄自站点自己的 JS，是个写死的字符串。
    private static let csrfChallengeValue = "simple-token"

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
            // 有的接口只认这个头**在不在**，不看值。投票就是一个：不带它一律 403
            // `{"success":false}`，带上（值随便）立刻 200。实测过它对本来就能用的
            // 接口没有影响 —— 页面、帖子、用户资料带不带都一样。
            request.setValue(Self.dynamicSignHeaderValue, forHTTPHeaderField: "x-dynamic-sign")
            request.setValue("empty", forHTTPHeaderField: "Sec-Fetch-Dest")
            request.setValue("cors", forHTTPHeaderField: "Sec-Fetch-Mode")
            request.setValue("same-origin", forHTTPHeaderField: "Sec-Fetch-Site")
        }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            // 写请求要过 CSRF 检查。少了它站点答「csrf check error」，回复发不出去。
            //
            // 值是个字面常量，不是真的令牌 —— 站点自己的 JS 里就这么写死的：
            // `headers:{"x-csrf-challenge":"simple-token","content-type":"application/json"}`。
            // 所以没有「去哪儿取令牌」这一步。哪天站点改成验真令牌，
            // 写操作会退回同一句 csrf 报错，那就是这里该改的信号。
            request.setValue(Self.csrfChallengeValue, forHTTPHeaderField: "x-csrf-challenge")
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
        if Self.isChallenge(
            status: response.statusCode,
            headers: headers,
            body: data,
            expectedJSON: asJSON
        ) {
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
            // 看不了的帖子答 404，真正的原因写在正文里（等级不够、要先注册）。
            // 报成「服务暂时不可用」既不对也没用 —— 站点没坏，是不让看，
            // 而它那句话里写着该怎么办。
            if !asJSON,
               let html = String(data: data, encoding: .utf8),
               let reason = NodeSeekParser.accessDeniedReason(inHTML: html) {
                throw ForumServiceError.restricted(reason)
            }
            throw ForumServiceError.server(response.statusCode)
        }
    }

    /// Cloudflare 把请求拦下来的形态。要在看状态码之前判 ——
    /// 「请去验证」和「请去登录」是两条不同的恢复路径。
    ///
    /// `expectedJSON` 是承重的：「响应体是 HTML」只有在**问 JSON 的时候**才说明被拦截了。
    /// 网页请求本来就该拿到以 `<!DOCTYPE` 开头的东西，拿这条去判网页会把每一次成功
    /// 都当成挑战 —— 列表页正是这样被自己判死过一次。
    static func isChallenge(
        status: Int,
        headers: [String: String],
        body: Data,
        expectedJSON: Bool
    ) -> Bool {
        if headers.first(where: { $0.key.caseInsensitiveCompare("cf-mitigated") == .orderedSame })?
            .value.caseInsensitiveCompare("challenge") == .orderedSame {
            return true
        }
        let head = String(data: body.prefix(600), encoding: .utf8) ?? ""
        // 挑战页本身的特征，网页和 JSON 都算。
        if head.contains("Just a moment") { return true }
        guard expectedJSON else { return false }
        return head.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<")
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
