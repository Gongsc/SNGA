import CoreFoundation
import Foundation

struct NGAHTTPResponse: Sendable {
    var data: Data
    var statusCode: Int
    var headers: [String: String]
    var url: URL

    func decodedString() throws -> String {
        if let contentType = headers.first(where: { $0.key.caseInsensitiveCompare("Content-Type") == .orderedSame })?.value.lowercased() {
            if contentType.contains("utf-8"), let value = String(data: data, encoding: .utf8) {
                return value
            }
            if contentType.contains("gbk") || contentType.contains("gb18030") || contentType.contains("gb2312") {
                let raw = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
                if let value = String(data: data, encoding: String.Encoding(rawValue: raw)) {
                    return value
                }
            }
        }
        if let value = String(data: data, encoding: .utf8) { return value }
        let raw = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        if let value = String(data: data, encoding: String.Encoding(rawValue: raw)) { return value }
        throw NGAServiceError.invalidResponse
    }
}

actor NGANetworkClient {
    private let transport: any HTTPTransport
    private var cookies: [SessionCookie]
    private let cookieDidChange: @Sendable ([SessionCookie]) async -> Void
    private var lastRequestAt: ContinuousClock.Instant?
    private let clock = ContinuousClock()

    init(
        cookies: [SessionCookie],
        transport: any HTTPTransport = URLSessionTransport(),
        cookieDidChange: @escaping @Sendable ([SessionCookie]) async -> Void = { _ in }
    ) {
        self.cookies = cookies
        self.transport = transport
        self.cookieDidChange = cookieDidChange
    }

    func currentCookies() -> [SessionCookie] {
        cookies.filter { !$0.isExpired }
    }

    func request(_ endpoint: NGAEndpoint) async throws -> NGAHTTPResponse {
        let maximumAttempts = endpoint.isWrite ? 1 : 2
        var lastError: Error?

        for attempt in 1...maximumAttempts {
            let startedAt = Date()
            do {
                try await throttle()
                var request = URLRequest(url: endpoint.url)
                request.httpMethod = endpoint.method.rawValue
                request.timeoutInterval = endpoint.isWrite ? 40 : 25
                let userAgent = endpoint.userAgentOverride ?? "SNGA/1.0 (macOS; native client)"
                request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
                if endpoint.url.lastPathComponent == "app_api.php" ||
                    endpoint.userAgentOverride != nil {
                    request.setValue(userAgent, forHTTPHeaderField: "X-User-Agent")
                }
                if endpoint.queryItems.contains(where: {
                    $0.name == "__lib" && $0.value == "check_in"
                }) {
                    // 签到接口会校验 NGA 客户端标识；缺少此请求头时会返回 CLIENT ERROR。
                    request.setValue("Nga_Official", forHTTPHeaderField: "X-User-Agent")
                }
                request.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
                request.setValue("text/html,application/json;q=0.9,*/*;q=0.7", forHTTPHeaderField: "Accept")
                if let referer = endpoint.referer {
                    request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
                }
                let cookieHeader = makeCookieHeader(for: endpoint.url)
                if !cookieHeader.isEmpty {
                    request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
                }
                if endpoint.method == .post {
                    request.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
                    var form = endpoint.form
                    if endpoint.url.lastPathComponent == "app_api.php" ||
                        endpoint.url.lastPathComponent == "post.php" ||
                        endpoint.queryItems.contains(where: { $0.name == "__output" }) {
                        // NGA 的结构化接口不只校验 Cookie，还可能要求同一账号的凭据随表单提交。
                        // 这些值只在各自 actor 内存中使用，不进入日志或共享 Cookie 容器。
                        form["access_uid"] = form["access_uid"] ?? cookieValue(named: "ngaPassportUid")
                        form["access_token"] = form["access_token"] ?? cookieValue(named: "ngaPassportCid")
                    }
                    request.httpBody = formEncoded(form)
                }

                await RuntimeLogger.shared.log(
                    category: "network",
                    "\(request.httpMethod ?? "GET") \(RuntimeLogger.sanitizedURL(endpoint.url)) attempt=\(attempt)"
                )
                let (data, response) = try await transport.data(for: request)
                let elapsedMilliseconds = Int(Date().timeIntervalSince(startedAt) * 1_000)
                await RuntimeLogger.shared.log(
                    category: "network",
                    "\(request.httpMethod ?? "GET") \(RuntimeLogger.sanitizedURL(endpoint.url)) status=\(response.statusCode) bytes=\(data.count) durationMs=\(elapsedMilliseconds)"
                )
                let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, item in
                    result[String(describing: item.key)] = String(describing: item.value)
                }
                await mergeResponseCookies(headers: headers, url: endpoint.url)
                let payload = NGAHTTPResponse(data: data, statusCode: response.statusCode, headers: headers, url: endpoint.url)
                try validate(payload)
                return payload
            } catch {
                if error is CancellationError ||
                    (error as? URLError)?.code == .cancelled {
                    throw CancellationError()
                }
                lastError = error
                await RuntimeLogger.shared.log(
                    .warning,
                    category: "network",
                    "\(endpoint.method.rawValue) \(RuntimeLogger.sanitizedURL(endpoint.url)) attempt=\(attempt) failed=\(error.localizedDescription)"
                )
                guard attempt < maximumAttempts, isRetryable(error) else { break }
                try await Task.sleep(for: .milliseconds(450 * attempt))
            }
        }

        if endpoint.isWrite, !(lastError is NGAServiceError) {
            throw NGAServiceError.ambiguousWrite
        }
        throw lastError ?? NGAServiceError.invalidResponse
    }

    private func throttle() async throws {
        if let lastRequestAt {
            let elapsed = lastRequestAt.duration(to: clock.now)
            if elapsed < .milliseconds(280) {
                try await Task.sleep(for: .milliseconds(280) - elapsed)
            }
        }
        lastRequestAt = clock.now
    }

    private func validate(_ response: NGAHTTPResponse) throws {
        let explicitlyRequiresLogin = responseExplicitlyRequiresLogin(response)
        switch response.statusCode {
        case 200..<300:
            break
        case 401:
            throw NGAServiceError.requiresLogin
        case 403:
            if explicitlyRequiresLogin {
                throw NGAServiceError.requiresLogin
            }
            if responseIndicatesLockedTopic(response) {
                throw NGAServiceError.topicLocked
            }
            if responseIndicatesDeletedTopic(response) {
                throw NGAServiceError.topicDeleted
            }
            throw NGAServiceError.restricted("NGA 暂时拒绝了本次访问（HTTP 403），请稍后重试")
        case 429:
            throw NGAServiceError.rateLimited
        case 500...599:
            throw NGAServiceError.server(response.statusCode)
        default:
            throw NGAServiceError.server(response.statusCode)
        }

        if explicitlyRequiresLogin {
            throw NGAServiceError.requiresLogin
        }
    }

    private func responseExplicitlyRequiresLogin(_ response: NGAHTTPResponse) -> Bool {
        guard let text = try? response.decodedString() else { return false }
        let hasLoginRoute = text.contains("__lib=login") ||
            text.contains("__act=account&login")
        guard hasLoginRoute else { return false }
        return text.contains("未登录") ||
            text.contains("你必须先登录论坛") ||
            text.contains("你必须登录") ||
            text.contains("必须登录后") ||
            text.contains("请先登录")
    }

    private func responseIndicatesDeletedTopic(_ response: NGAHTTPResponse) -> Bool {
        guard response.url.lastPathComponent == "read.php",
              let searchableText = searchableText(in: response) else {
            return false
        }
        return [
            "帖子被删除",
            "帖子已被删除",
            "帖子不存在",
            "主题被删除",
            "主题已被删除",
            "主题不存在",
            "找不到该主题",
            "找不到主题"
        ].contains { searchableText.contains($0) }
    }

    private func responseIndicatesLockedTopic(_ response: NGAHTTPResponse) -> Bool {
        guard let searchableText = searchableText(in: response) else {
            return false
        }
        return [
            "此帖子被锁定",
            "帖子被锁定",
            "帖子已锁定",
            "此主题被锁定",
            "主题被锁定",
            "主题已锁定"
        ].contains { searchableText.contains($0) }
    }

    private func searchableText(in response: NGAHTTPResponse) -> String? {
        guard var text = try? response.decodedString() else { return nil }
        if let payload = try? JSONSerialization.jsonObject(
            with: response.data,
            options: [.fragmentsAllowed]
        ) {
            // NGA 的结构化错误通常使用 Unicode 转义；反序列化后再匹配中文错误语义。
            text += responseStrings(in: payload).joined(separator: " ")
        }
        return text
    }

    private func responseStrings(in value: Any) -> [String] {
        if let value = value as? String {
            return [value]
        }
        if let value = value as? [String: Any] {
            return value.values.flatMap(responseStrings(in:))
        }
        if let value = value as? [Any] {
            return value.flatMap(responseStrings(in:))
        }
        return []
    }

    private func isRetryable(_ error: Error) -> Bool {
        if let error = error as? NGAServiceError {
            switch error {
            case .server, .rateLimited: true
            default: false
            }
        } else {
            true
        }
    }

    private func makeCookieHeader(for url: URL) -> String {
        let host = url.host?.lowercased() ?? ""
        let requestPath = url.path.isEmpty ? "/" : url.path
        return cookies
            .filter { cookie in
                guard !cookie.isExpired else { return false }
                let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
                return (host == domain || host.hasSuffix(".\(domain)")) && requestPath.hasPrefix(cookie.path)
            }
            .sorted { $0.name < $1.name }
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
    }

    private func cookieValue(named name: String) -> String {
        cookies.first {
            !$0.isExpired && $0.name.caseInsensitiveCompare(name) == .orderedSame
        }?.value ?? ""
    }

    private func formEncoded(_ fields: [String: String]) -> Data {
        var components = URLComponents()
        components.queryItems = fields.sorted(by: { $0.key < $1.key }).map(URLQueryItem.init)
        return Data((components.percentEncodedQuery ?? "").utf8)
    }

    private func mergeResponseCookies(headers: [String: String], url: URL) async {
        let normalized = headers.reduce(into: [String: String]()) { result, item in
            if item.key.caseInsensitiveCompare("Set-Cookie") == .orderedSame {
                result["Set-Cookie"] = item.value
            }
        }
        guard !normalized.isEmpty else { return }
        let newCookies = HTTPCookie.cookies(withResponseHeaderFields: normalized, for: url).map(SessionCookie.init)
        guard !newCookies.isEmpty else { return }
        for cookie in newCookies {
            cookies.removeAll { $0.name == cookie.name && $0.domain == cookie.domain && $0.path == cookie.path }
            if !cookie.isExpired { cookies.append(cookie) }
        }
        await cookieDidChange(cookies)
    }
}

extension SessionCookie {
    init(_ cookie: HTTPCookie) {
        name = cookie.name
        value = cookie.value
        domain = cookie.domain
        path = cookie.path
        expiresAt = cookie.expiresDate
        isSecure = cookie.isSecure
        isHTTPOnly = cookie.isHTTPOnly
    }
}
