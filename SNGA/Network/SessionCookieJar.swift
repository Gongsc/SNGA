import Foundation

/// 一个账号的 cookie，以及围绕它的两件小事：拼请求头、合并响应里换发的。
///
/// 从 `NGANetworkClient` 里抽出来给各站共用。域名匹配、路径前缀、过期判断这几处细节抄错了
/// 不会立刻出错，只会在某些请求上悄悄少带一个 cookie —— 所以只留一份。
struct SessionCookieJar: Sendable {
    private(set) var cookies: [SessionCookie]

    init(_ cookies: [SessionCookie] = []) {
        self.cookies = cookies
    }

    var unexpired: [SessionCookie] { cookies.filter { !$0.isExpired } }

    /// 这次请求该带的 `Cookie` 头。域名和路径都要对得上，过期的不带。
    func header(for url: URL) -> String {
        let host = url.host?.lowercased() ?? ""
        let requestPath = url.path.isEmpty ? "/" : url.path
        return cookies
            .filter { cookie in
                guard !cookie.isExpired else { return false }
                let domain = cookie.domain.lowercased()
                    .trimmingCharacters(in: CharacterSet(charactersIn: "."))
                return (host == domain || host.hasSuffix(".\(domain)"))
                    && requestPath.hasPrefix(cookie.path)
            }
            .sorted { $0.name < $1.name }
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
    }

    func value(named name: String) -> String {
        cookies.first {
            !$0.isExpired && $0.name.caseInsensitiveCompare(name) == .orderedSame
        }?.value ?? ""
    }

    /// 把响应里的 `Set-Cookie` 合进来。
    ///
    /// 返回是否真的变了 —— 变了才值得写回磁盘。Cloudflare 会不定时换发 `cf_clearance`，
    /// 跟不上就会在某次请求上突然被挑战。
    @discardableResult
    mutating func merge(responseHeaders headers: [String: String], url: URL) -> Bool {
        var fields: [String: String] = [:]
        for (key, value) in headers where key.caseInsensitiveCompare("Set-Cookie") == .orderedSame {
            fields["Set-Cookie"] = value
        }
        guard !fields.isEmpty else { return false }
        let incoming = HTTPCookie.cookies(withResponseHeaderFields: fields, for: url)
            .map(SessionCookie.init)
        guard !incoming.isEmpty else { return false }
        for cookie in incoming {
            cookies.removeAll {
                $0.name == cookie.name && $0.domain == cookie.domain && $0.path == cookie.path
            }
            if !cookie.isExpired { cookies.append(cookie) }
        }
        return true
    }
}
