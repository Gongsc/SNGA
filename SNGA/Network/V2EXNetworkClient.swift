import Foundation

/// V2EX 的请求客户端。
///
/// 比 NodeSeek 那套简单得多：站点不校验 UA，写请求也没有要现算的签名头 ——
/// 它只认一个一次性令牌 `once`，而那个令牌是当查询参数发的，不是请求头。
/// 所以这里只剩三件事：带上 cookie、把语言钉成中文、失败翻译成领域错误。
///
/// 和 `NGANetworkClient` / `NodeSeekNetworkClient` 分开写而不是共用：三站的鉴权、
/// 限流和失败形态都不一样。共用的是 `HTTPTransport` 和 cookie 的存法。
actor V2EXNetworkClient {
    private let transport: any HTTPTransport
    private var jar: SessionCookieJar
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

    /// 站点没有公布限流阈值，按和另外两站相近的节奏发。
    private func throttle() async throws {
        let now = clock.now
        guard let lastRequestAt else { self.lastRequestAt = now; return }
        let reservedAt = lastRequestAt.advanced(by: .milliseconds(320))
        if reservedAt <= now { self.lastRequestAt = now; return }
        self.lastRequestAt = reservedAt
        try await clock.sleep(until: reservedAt)
    }

    /// 取一张网页或一份 JSON。
    func get(_ url: URL, asJSON: Bool = false, referer: URL? = nil) async throws -> Data {
        try await send(url, method: "GET", form: nil, asJSON: asJSON, referer: referer)
    }

    /// 发一次表单 POST。
    ///
    /// 站点的写操作全是表单，没有 JSON 接口：回复是 `content` + `once` 提交到主题页
    /// 自己的地址，感谢是空 body 加 `?once=`。
    ///
    /// **只发一次，不重试。** 写请求重试等于替用户多发一遍。
    func postForm(
        _ url: URL,
        fields: [String: String] = [:],
        referer: URL? = nil
    ) async throws -> Data {
        try await send(url, method: "POST", form: fields, asJSON: false, referer: referer)
    }

    /// 向**站外**发一次 GET。
    ///
    /// 主题搜索走的是第三方的 SoV2EX（V2EX 自己没有主题搜索）。那台服务器和这个站
    /// 没有关系，所以这条路**一个 cookie 都不带**，也不带 Referer 和 Origin ——
    /// 会话是用户的，没有理由让它离开 v2ex.com。
    ///
    /// 单独开一个方法而不是在 `send` 里判域名：判域名是一句可以被后来的人删掉的
    /// 条件，而这里是「这条路本来就不碰 jar」。限流仍然共用，两边都不该被打太快。
    func getThirdParty(_ url: URL) async throws -> Data {
        try await throttle()

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 25
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")

        await RuntimeLogger.shared.log(
            category: "network",
            "GET \(RuntimeLogger.sanitizedURL(url))（站外）"
        )
        let (data, response) = try await transport.data(for: request)
        switch response.statusCode {
        case 200..<300: return data
        case 429: throw ForumServiceError.rateLimited
        default: throw ForumServiceError.server(response.statusCode)
        }
    }

    /// 现取一个一次性令牌。
    ///
    /// 响应体就是一串数字，别的什么都没有。站点自己在本地缓存 10 秒，我们不缓存 ——
    /// 省下的那一次请求，不值得赌一个过期的令牌换来一次失败的提交。
    func freshOnce() async throws -> String {
        let data = try await get(V2EXEndpoint.pollOnce)
        let token = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !token.isEmpty, token.allSatisfy(\.isNumber) else {
            throw ForumServiceError.unexpectedPage("取不到提交用的一次性令牌")
        }
        return token
    }

    private func send(
        _ url: URL,
        method: String,
        form: [String: String]?,
        asJSON: Bool,
        referer: URL?
    ) async throws -> Data {
        try await throttle()

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = form == nil ? 25 : 40
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue(
            asJSON ? "application/json, text/plain, */*" : ForumSiteDescriptor.htmlAccept,
            forHTTPHeaderField: "Accept"
        )
        request.setValue(
            (referer ?? V2EXEndpoint.descriptor.baseURL).absoluteString,
            forHTTPHeaderField: "Referer"
        )
        if let form {
            request.httpBody = Data(Self.formEncoded(form).utf8)
            request.setValue(
                "application/x-www-form-urlencoded",
                forHTTPHeaderField: "Content-Type"
            )
            // 浏览器只在写请求上带 Origin。
            request.setValue(
                V2EXEndpoint.descriptor.baseURL.absoluteString,
                forHTTPHeaderField: "Origin"
            )
        }
        request.setValue(Self.cookieHeader(jar: jar, url: url), forHTTPHeaderField: "Cookie")

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

        switch response.statusCode {
        case 200..<300:
            // 会话过期的形态是 **302 到登录页**，不是 401 —— `URLSession` 跟着跳，
            // 于是拿回来的是一张 200 的登录页。不认这一条，解析器会去那张页面上
            // 找主题列表，报出来的是「论坛页面结构已变化」，把「去登录」这条唯一
            // 有用的路藏起来。
            if Self.isSignInPage(finalURL: response.url, requested: url) {
                throw ForumServiceError.requiresLogin
            }
            return data
        case 401, 403:
            throw ForumServiceError.requiresLogin
        case 404:
            throw ForumServiceError.topicDeleted
        case 429:
            throw ForumServiceError.rateLimited
        default:
            // 写请求在非 2xx 上也可能带着有意义的正文，交给调用方读。
            if form != nil { return data }
            throw ForumServiceError.server(response.statusCode)
        }
    }

    /// 跟完跳转之后落在登录页上了。
    ///
    /// 只看落点，不看来路：请求登录页本身不算（那是用户主动去的），
    /// 请求别的地址却落在登录页上才算。
    static func isSignInPage(finalURL: URL?, requested: URL) -> Bool {
        guard let path = finalURL?.path(), path.hasPrefix("/signin") else { return false }
        return !requested.path().hasPrefix("/signin")
    }

    /// Cookie 头。
    ///
    /// 除了会话本身，还固定钉一条 `V2EX_LANG=zhcn`：站点对没登录、没设过语言的
    /// 访客默认发英文页（`LANG = 'enus'`），那样「最后回复来自」会变成
    /// 「Lastly replied by」。解析基本靠结构和 `title` 属性，不靠这些字，
    /// 但页面里确实有几处只有文字可认，而且日志里读到中文也省事。
    static func cookieHeader(jar: SessionCookieJar, url: URL) -> String {
        let existing = jar.header(for: url)
        guard !existing.contains("V2EX_LANG=") else { return existing }
        return existing.isEmpty ? "V2EX_LANG=zhcn" : existing + "; V2EX_LANG=zhcn"
    }

    static func formEncoded(_ fields: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields
            // 字段顺序固定下来，好让测试能逐字对比请求体。
            .sorted { $0.key < $1.key }
            .map { key, value in
                let escape = { (text: String) in
                    text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
                }
                return "\(escape(key))=\(escape(value))"
            }
            .joined(separator: "&")
    }
}
