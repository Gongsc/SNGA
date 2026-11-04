import Foundation

/// Linux.do 的请求客户端。
///
/// 照 `NodeSeekNetworkClient` 的样子写，少了那边的签名头 —— Discourse 的读接口只要会话 cookie，
/// 写接口要的是一个从 `/session/csrf` 取来的令牌，等接写操作时再加。
///
/// 传输上的两条硬约束和 NodeSeek 一样（`LinuxDoLiveTests` 实测）：
///
/// 1. UA 必须是 `WKWebView` 自报的那个。
/// 2. 带上这个域下**全部** cookie，按域名全收，不挑。
actor LinuxDoNetworkClient {
    private let transport: any HTTPTransport
    private var jar: SessionCookieJar
    private let userAgent: String
    private let cookieDidChange: @Sendable ([SessionCookie]) async -> Void

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

    /// 发一次 GET，拿回 JSON 响应体。这个站只读 JSON，没有要解析的网页。
    func get(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 25
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // 站点自己的前端带这个；Discourse 对带它的请求在出错时也回 JSON 而不是一张错误页。
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.setValue(LinuxDoEndpoint.base.absoluteString + "/", forHTTPHeaderField: "Referer")
        let cookieHeader = jar.header(for: url)
        if !cookieHeader.isEmpty {
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }
        // 只记名字和个数，绝不记值。
        let cookieNames = cookieHeader
            .components(separatedBy: "; ")
            .compactMap { $0.split(separator: "=", maxSplits: 1).first.map(String.init) }
            .filter { !$0.isEmpty }
            .sorted()
        await RuntimeLogger.shared.log(
            category: "network",
            "GET \(RuntimeLogger.sanitizedURL(url))"
                + " cookies=\(cookieNames.count)[\(cookieNames.joined(separator: ","))]"
        )

        let startedAt = ContinuousClock().now
        let (data, response) = try await transport.data(for: request)
        let elapsed = startedAt.duration(to: ContinuousClock().now)
        await RuntimeLogger.shared.log(
            category: "network",
            "GET \(RuntimeLogger.sanitizedURL(url))"
                + " status=\(response.statusCode)"
                + " bytes=\(data.count)"
                + " durationMs=\(elapsed.components.seconds * 1_000 + elapsed.components.attoseconds / 1_000_000_000_000_000)"
        )

        let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, item in
            result[String(describing: item.key)] = String(describing: item.value)
        }
        // Cloudflare 会不定时换发 `cf_clearance`，Discourse 也会续 `_t`。换了就落盘，
        // 否则下次启动带的是旧的。
        if jar.merge(responseHeaders: headers, url: url) {
            await cookieDidChange(jar.cookies)
        }

        // 挑战要在看状态码之前判：「请去验证」和「请去登录」是两条不同的恢复路径。
        // 这个站上会话一失效，话题详情就必被挑战（匿名访问的常态），所以这里那句话
        // 多半意味着会话过期了。
        if CloudflareChallenge.isChallenge(
            status: response.statusCode, headers: headers, body: data, expectedJSON: true
        ) {
            throw ForumServiceError.restricted(
                "需要在浏览器里完成一次人机验证。请重新登录本站账号，验证通过后再试。"
            )
        }
        switch response.statusCode {
        case 200..<300:
            return data
        case 429:
            throw ForumServiceError.rateLimited
        case 403, 404:
            // Discourse 把「没权限看」「不存在」写在 `errors` 里（等级不够、类别受限……），
            // 那句话比状态码有用。没写的 403 当作会话问题，404 当作东西不在。
            if let message = Self.errorMessage(in: data) {
                throw ForumServiceError.restricted(message)
            }
            throw response.statusCode == 403
                ? ForumServiceError.requiresLogin
                : ForumServiceError.topicDeleted
        default:
            throw ForumServiceError.server(response.statusCode)
        }
    }

    /// Discourse 的错误体：`{"errors": ["…"], "error_type": "invalid_access"}`。
    static func errorMessage(in data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let errors = object["errors"] as? [String],
              let first = errors.first?.trimmingCharacters(in: .whitespacesAndNewlines),
              !first.isEmpty else {
            return nil
        }
        return first
    }
}
