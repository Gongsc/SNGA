import Foundation

/// Linux.do 的请求客户端。
///
/// 照 `NodeSeekNetworkClient` 的样子写，少了那边的签名头 —— Discourse 的读接口只要会话 cookie，
/// 写接口再多要一个从 `/session/csrf` 取来的令牌。
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
    /// 写请求要的令牌。一个会话里一直有效，取一次记着；站点答「BAD CSRF」时换新的。
    private var csrfToken: String?

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
        try await perform(makeRequest(url, method: "GET"))
    }

    /// 发一次写请求（POST / PUT / DELETE），表单编码，带 CSRF 令牌。
    ///
    /// **只在一种情况下重发：站点答 403 且正文是 `BAD CSRF`。** 那是令牌过期，请求在动手之前
    /// 就被拒了，换个令牌再发不会重复做任何事。别的失败一律不重试 —— 发帖、点赞这类请求
    /// 答得不明不白时再发一次，就可能发了两次。
    func send(_ method: String, _ url: URL, form: [(String, String)] = []) async throws -> Data {
        for attempt in 0..<2 {
            let token = try await currentCSRFToken(refresh: attempt > 0)
            var request = makeRequest(url, method: method)
            request.timeoutInterval = 40
            request.setValue(token, forHTTPHeaderField: "X-CSRF-Token")
            request.setValue(LinuxDoEndpoint.base.absoluteString, forHTTPHeaderField: "Origin")
            if !form.isEmpty {
                request.setValue(
                    "application/x-www-form-urlencoded; charset=UTF-8",
                    forHTTPHeaderField: "Content-Type"
                )
                request.httpBody = Data(Self.formEncoded(form).utf8)
            }
            do {
                return try await perform(request)
            } catch is BadCSRF {
                // 第一次：令牌过期了，换一个再发。第二次还这样，就不是令牌的问题了 ——
                // 多半是会话本身失效，交给「请重新登录」。
                if attempt == 0 { continue }
                throw ForumServiceError.requiresLogin
            }
        }
        throw ForumServiceError.requiresLogin
    }

    /// `application/x-www-form-urlencoded`：空格写成 `+`，其余保留字符一律转义。
    ///
    /// 不能用 `URLComponents.percentEncodedQuery` 偷懒：它不转义 `+` 和 `&` 以外的一些字符，
    /// 正文里的 `+` 会在服务端变成空格 —— 回复「1+1」就成了「1 1」。
    static func formEncoded(_ form: [(String, String)]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._*")
        func encode(_ value: String) -> String {
            value.addingPercentEncoding(withAllowedCharacters: allowed)?
                .replacingOccurrences(of: "%20", with: "+") ?? ""
        }
        return form.map { "\(encode($0.0))=\(encode($0.1))" }.joined(separator: "&")
    }

    /// 令牌失效的那一种 403。和别的 403（没权限、等级不够）分开，只有它值得重发。
    private struct BadCSRF: Error {}

    private func currentCSRFToken(refresh: Bool) async throws -> String {
        if !refresh, let csrfToken { return csrfToken }
        let data = try await get(LinuxDoEndpoint.csrf)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = object["csrf"] as? String, !token.isEmpty else {
            throw ForumServiceError.requiresLogin
        }
        csrfToken = token
        return token
    }

    private func makeRequest(_ url: URL, method: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
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
        return request
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let url = request.url ?? LinuxDoEndpoint.base
        let method = request.httpMethod ?? "GET"
        // 只记名字和个数，绝不记值；写请求的正文也不记。
        let cookieNames = (request.value(forHTTPHeaderField: "Cookie") ?? "")
            .components(separatedBy: "; ")
            .compactMap { $0.split(separator: "=", maxSplits: 1).first.map(String.init) }
            .filter { !$0.isEmpty }
            .sorted()
        await RuntimeLogger.shared.log(
            category: "network",
            "\(method) \(RuntimeLogger.sanitizedURL(url))"
                + " cookies=\(cookieNames.count)[\(cookieNames.joined(separator: ","))]"
        )

        let startedAt = ContinuousClock().now
        let (data, response) = try await transport.data(for: request)
        let elapsed = startedAt.duration(to: ContinuousClock().now)
        await RuntimeLogger.shared.log(
            category: "network",
            "\(method) \(RuntimeLogger.sanitizedURL(url))"
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
        case 403 where Self.isBadCSRF(data):
            throw BadCSRF()
        case 403, 404, 422:
            // Discourse 把「没权限看」「不存在」「发不出去」写在 `errors` 里（等级不够、
            // 类别受限、回复太短……），那句话比状态码有用。没写的 403 当作会话问题，
            // 404 当作东西不在。
            if let message = Self.errorMessage(in: data) {
                throw ForumServiceError.restricted(message)
            }
            switch response.statusCode {
            case 403: throw ForumServiceError.requiresLogin
            case 404: throw ForumServiceError.topicDeleted
            default: throw ForumServiceError.server(response.statusCode)
            }
        default:
            throw ForumServiceError.server(response.statusCode)
        }
    }

    /// 令牌失效时 Discourse 答 `["BAD CSRF"]`（一个 JSON 数组，或者纯文本）。
    static func isBadCSRF(_ data: Data) -> Bool {
        String(data: data.prefix(200), encoding: .utf8)?.contains("BAD CSRF") ?? false
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
