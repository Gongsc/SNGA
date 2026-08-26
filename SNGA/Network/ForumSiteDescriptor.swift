import Foundation
import SwiftUI

/// 回复正文用哪种标记语言。
///
/// 不做成两个能力位：站点只会用其中一种，两个位允许出现「都开」和「都关」这两种
/// 没有意义的状态。
enum ReplyMarkup: String, Codable, Sendable {
    case ubb
    case markdown
}

/// 请求该用什么 User-Agent。
///
/// 不是所有站点都能自报家门。NodeSeek 站前的 Cloudflare 会拿请求头里的 UA 去和页面 JS 环境
/// （`navigator.userAgentData`、`Sec-CH-UA`）交叉核对，而后者由 `WKWebView` 按它真实的引擎版本
/// 上报、改不动 —— 两边对不上就再发一次挑战，永远勾不完。这种站只能用 WebView 的真实 UA。
enum SiteUserAgent: Sendable, Hashable {
    /// 自报家门。站点不校验 UA 时用这个。
    case fixed(String)
    /// 从 `WKWebView` 读出它自己的 UA。见 `WebViewUserAgent`。
    case webView
}

/// 一个站点的固定资料：从哪里发请求、去哪里登录、哪些域算它的、登录凭据叫什么。
///
/// 这些值原本散在 `NGAEndpoint`、`NGAInternalLink` 和 `LoginWebView` 里各写一份。
/// 收到这里之后，接第二个站点时要填的东西一眼可数，而不必回去把三处逐个找出来。
struct ForumSiteDescriptor: Sendable {
    let site: ForumSite
    /// 回复用哪种标记。决定编辑器给哪一套工具条。
    let replyMarkup: ReplyMarkup
    /// 所有接口请求的根地址，也是渲染楼层正文时给 `WKWebView` 的 base URL。
    let baseURL: URL
    /// 内嵌登录页。登录流程由站点官方页面完成，应用不碰密码。
    let loginURL: URL
    /// 登录成功后按这些域收 Cookie。写主域即可，子域自动算在内。
    let cookieDomains: [String]
    /// 正文里指向这些域的链接算站内链接，交给原生导航而不是浏览器。
    let linkDomains: [String]
    /// 构成会话的 Cookie。这些都在，才算还登录着。
    ///
    /// 只是**判断登录与否**的依据，不是「要保存哪几个」—— 保存一律按域名全收。
    /// NodeSeek 实测登录后有 6 个 cookie，只带其中两个会被 Cloudflare 挑战。
    ///
    /// 不是「一个 uid + 一个凭据」那种固定两件套 —— 那是 NGA 的形状。NodeSeek 只有一个
    /// `session`，别的站可能更多。
    let sessionCookieNames: [String]
    /// 会话里直接带着用户编号的 Cookie；没有这种 Cookie 的站点为 nil。
    ///
    /// NGA 有，所以本地就能校验「这份 Cookie 是不是这个账号的」。NodeSeek 没有，
    /// 用户编号得另外去问接口。
    let uidCookieName: String?
    /// 请求带哪个 User-Agent。
    let userAgent: SiteUserAgent

    var displayName: String { site.displayName }

    /// 拿不到 WebView 的真实 UA 时退回什么。
    ///
    /// 对 `.webView` 的站点这是个降级：真实 UA 读不出来时，宁可用一个像浏览器的串去试，
    /// 也好过用「SNGA/1.0」—— 后者必然触发挑战。
    func resolvedUserAgent(fallback: String?) -> String {
        switch userAgent {
        case let .fixed(value): value
        case .webView: fallback ?? Self.browserFallbackUserAgent
        }
    }

    /// 日志脱敏和会话校验都要认这些名字。
    var credentialCookieNames: [String] {
        sessionCookieNames + [uidCookieName].compactMap { $0 }
    }

    /// 这个域名是不是本站的。主域本身和它的任意子域都算。
    func owns(host: String) -> Bool {
        Self.matches(host, against: linkDomains)
    }

    /// 这条 Cookie 是不是本站的。`WKWebView` 给出的域名可能带前导点。
    func owns(cookieDomain: String) -> Bool {
        let normalized = cookieDomain.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return Self.matches(normalized, against: cookieDomains)
    }

    /// 把一条站内链接解析成导航目的地；不是本站的链接返回 nil。
    ///
    /// 域名判断在这里统一做，各站只管解析自己的查询参数。
    func internalDestination(for url: URL) -> NGAInternalDestination? {
        guard let host = url.host?.lowercased(), owns(host: host) else { return nil }
        switch site {
        case .nga: return NGAInternalLink.destination(for: url)
        case .nodeseek: return NodeSeekInternalLink.destination(for: url)
        }
    }

    /// 编辑器预览用的正文清洗。
    ///
    /// 同步返回：视图 body 里等不了 actor，而各站的清洗器都是无状态的。
    func sanitizedPreviewHTML(_ source: String) -> String {
        switch site {
        case .nga: NGAParser().sanitizedPostHTML(source)
        // Markdown 站点的预览要先渲染成 HTML。渲染器还没有，所以先把源码原样显示 ——
        // 比给一段假的富文本诚实。跟 Markdown 编辑器一起做。
        case .nodeseek: NodeSeekMarkdown.plainPreviewHTML(source)
        }
    }

    /// 话题在网页版的地址，用于「复制链接」和「在浏览器中打开」。
    func topicWebURL(topicID: TopicID) -> URL {
        switch site {
        case .nga: NGAEndpoint.topicWebURL(topicID: topicID)
        case .nodeseek: NodeSeekEndpoint.thread(topicID: topicID, page: 1)
        }
    }

    /// 只在读不出 WebView 真实 UA 时用。写死这个值当作**主要** UA 正是造成无限挑战的原因，
    /// 所以它只是最后的退路。
    static let browserFallbackUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 " +
        "(KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    /// 请求网页时的 `Accept`。解析用的页面走这个，不是 JSON 那套。
    static let htmlAccept =
        "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8"

    private static func matches(_ host: String, against domains: [String]) -> Bool {
        let host = host.lowercased()
        return domains.contains { domain in
            host == domain || host.hasSuffix(".\(domain)")
        }
    }
}

extension ForumSiteDescriptor {
    static let nga = ForumSiteDescriptor(
        site: .nga,
        replyMarkup: .ubb,
        baseURL: URL(string: "https://bbs.nga.cn")!,
        loginURL: URL(string: "https://bbs.nga.cn/nuke.php?__lib=login&__act=account&login")!,
        cookieDomains: ["nga.cn"],
        // nga.178.com 原本是 isForumHost 里单写的一个特例，规则和其余三个域一样，
        // 所以直接并进列表。
        linkDomains: ["nga.cn", "ngacn.cc", "ngabbs.com", "nga.178.com"],
        sessionCookieNames: ["ngaPassportCid"],
        uidCookieName: "ngaPassportUid",
        userAgent: .fixed("SNGA/1.0 (macOS; native client)")
    )
}

extension ForumSiteDescriptor {
    static let nodeseek = ForumSiteDescriptor(
        site: .nodeseek,
        replyMarkup: .markdown,
        baseURL: URL(string: "https://www.nodeseek.com")!,
        loginURL: URL(string: "https://www.nodeseek.com/signIn.html")!,
        cookieDomains: ["nodeseek.com"],
        linkDomains: ["nodeseek.com"],
        // 登录后站点会下发 6 个 cookie，判断登录与否只看这一个；保存一律按域名全收，
        // 只带其中几个会被 Cloudflare 挑战（实测）。
        sessionCookieNames: ["session"],
        // 用户编号不在 cookie 里，登录后要问 `currentUserID()`。
        uidCookieName: nil,
        // 必须用 WebView 的真实 UA。写死会和页面 JS 环境对不上，触发无限挑战。
        userAgent: .webView
    )
}

extension EnvironmentValues {
    /// 当前账号所属站点的资料。
    ///
    /// 正文渲染埋在 `ThreadPageContentView` → `PostContentView` → `PostWebView` 这一串
    /// 里面，逐层加参数会把一整条签名链都改一遍，所以走环境。
    ///
    /// 默认值是 NGA：目前只有这一个站，缺注入时的表现与从前一致。
    @Entry var forumSiteDescriptor: ForumSiteDescriptor = .nga
}
