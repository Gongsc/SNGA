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

/// 一种登录方式。
///
/// 同一个站点可能给好几条路。NodeSeek 的密码登录反复尝试会触发风控，邮箱验证登录不会，
/// 但后者要收验证码 —— 哪个方便得看当时的情况，所以交给用户选，而不是替他定死。
struct SiteLoginMethod: Sendable, Hashable, Identifiable {
    let id: String
    let title: String
    let systemImage: String
    let url: URL
    /// 一句话说明什么时候该用它。选择列表上显示。
    let detail: String
}

/// 登录之后从哪里得知「我是谁」。
///
/// 两种站点都存在，而且差别不小：
///
/// - NGA 把编号写在 Cookie 里，登录抓取当场就能读到，还能反过来校验「这份 Cookie 是不是
///   这个账号的」。
/// - NodeSeek 哪儿都没写：没有 who-am-I 接口（六个候选路径全 404）、`pjwt` 不是 JWT、
///   服务端 HTML 不含身份、会话接口的响应里也没有。它的用户卡片是**客户端渲染**的，
///   所以编号只在浏览器渲染完的 DOM 里 —— 只有登录用的 `WKWebView` 看得见，
///   `URLSession` 抓多少次都没有。
enum SiteUserIDSource: Sendable, Hashable {
    /// 从这个名字的 Cookie 里读。
    case cookie(name: String)
    /// 在登录页渲染完的 DOM 上跑这段脚本，取回编号字符串。取不到就返回空串。
    case renderedDOM(javaScript: String)
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
    /// 站点提供的登录方式。至少一种；多于一种时由用户选。
    let loginMethods: [SiteLoginMethod]
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
    /// 登录之后从哪里得知用户编号。
    let userIDSource: SiteUserIDSource
    /// 请求带哪个 User-Agent。
    let userAgent: SiteUserAgent

    var displayName: String { site.displayName }

    /// 默认落地的登录页。
    var loginURL: URL { loginMethods[0].url }

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

    /// 编号写在 Cookie 里的站点，那个 Cookie 的名字。
    var uidCookieName: String? {
        if case let .cookie(name) = userIDSource { return name }
        return nil
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
        case .nodeseek: MarkdownRenderer.previewHTML(source)
        }
    }

    /// 资料页要不要「声望」那一段（威望、声望、N 币）。
    ///
    /// 这是 NGA 一家的东西。按「有没有数」来判断会出错：NodeSeek 的鸡腿也走
    /// `Profile.money`，于是那一段照样冒出来，还把鸡腿标成「N 币」，
    /// 另外两行是「—」—— 三件事全是错的。所以按站点问。
    var showsReputationSection: Bool {
        switch site {
        case .nga: true
        case .nodeseek: false
        }
    }

    /// 用户资料的「基础信息」里显示哪几行。
    ///
    /// 用户编号和用户名两站都有，由界面固定显示；这里给的是站点自己那部分。
    /// 叫法按站点的说法走 —— NodeSeek 管用户组叫「等级」，管货币叫「鸡腿」，
    /// 照搬 NGA 的词会让人对不上号。
    func profileFields(for profile: Profile) -> [ProfileStat] {
        func number(_ title: String, _ value: Int?) -> ProfileStat? {
            value.map { ProfileStat(title: title, value: String($0)) }
        }
        switch site {
        case .nga:
            return [
                ProfileStat(title: "用户组", value: profile.userGroup ?? "—"),
                ProfileStat(title: "发帖数", value: profile.postCount.map(String.init) ?? "—"),
                ProfileStat(title: "注册时间", value: Self.formatted(profile.registeredAt)),
                ProfileStat(title: "IP 属地", value: profile.location ?? "—"),
                profile.honor.flatMap { $0.isEmpty ? nil : ProfileStat(title: "头衔", value: $0) },
                number("被关注", profile.followerCount)
            ].compactMap { $0 }
        case .nodeseek:
            return [
                // 站点自己的资料页显示的就是「加入天数」，不是注册日期。
                profile.registeredAt.map {
                    ProfileStat(title: "加入天数", value: String(Self.daysSince($0)))
                },
                profile.userGroup.map { ProfileStat(title: "等级", value: $0) },
                number("鸡腿数目", profile.money),
                number("主题帖数", profile.postCount),
                number("评论数目", profile.commentCount),
                number("关注", profile.followingCount),
                number("被关注", profile.followerCount)
            ].compactMap { $0 }
        }
    }

    /// 注册到今天有多少天。不足一天算一天 —— 站点显示的就是这个意思。
    private static func daysSince(_ date: Date, now: Date = .now) -> Int {
        max(0, Calendar.current.dateComponents([.day], from: date, to: now).day ?? 0)
    }

    static func formatted(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(
            .dateTime.year().month(.twoDigits).day(.twoDigits)
                .hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)
        )
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
        loginMethods: [
            SiteLoginMethod(
                id: "password",
                title: "账号密码登录",
                systemImage: "person.badge.key",
                url: URL(string: "https://bbs.nga.cn/nuke.php?__lib=login&__act=account&login")!,
                detail: "在 NGA 官方页面完成，SNGA 不读取或保存密码"
            )
        ],
        cookieDomains: ["nga.cn"],
        // nga.178.com 原本是 isForumHost 里单写的一个特例，规则和其余三个域一样，
        // 所以直接并进列表。
        linkDomains: ["nga.cn", "ngacn.cc", "ngabbs.com", "nga.178.com"],
        sessionCookieNames: ["ngaPassportCid"],
        userIDSource: .cookie(name: "ngaPassportUid"),
        userAgent: .fixed("SNGA/1.0 (macOS; native client)")
    )
}

extension ForumSiteDescriptor {
    static let nodeseek = ForumSiteDescriptor(
        site: .nodeseek,
        replyMarkup: .markdown,
        baseURL: URL(string: "https://www.nodeseek.com")!,
        // 邮箱验证排在前面：密码登录反复尝试会触发站点风控。
        loginMethods: [
            SiteLoginMethod(
                id: "email",
                title: "邮箱验证登录",
                systemImage: "envelope.badge.shield.half.filled",
                url: URL(string: "https://www.nodeseek.com/emailSignIn.html")!,
                detail: "收一封验证码邮件。密码登录被风控挡住时用这个"
            ),
            SiteLoginMethod(
                id: "password",
                title: "账号密码登录",
                systemImage: "person.badge.key",
                url: URL(string: "https://www.nodeseek.com/signIn.html")!,
                detail: "需要通过人机验证；短时间内多试几次会触发风控"
            )
        ],
        cookieDomains: ["nodeseek.com"],
        linkDomains: ["nodeseek.com"],
        // 登录后站点会下发 6 个 cookie，判断登录与否只看这一个；保存一律按域名全收，
        // 只带其中几个会被 Cloudflare 挑战（实测）。
        sessionCookieNames: ["session"],
        // 编号只在渲染后的用户卡片里。`.user-card` 是登录后才出现的那块，
        // 里面的头像和用户名都指向 `/space/{uid}`。
        userIDSource: .renderedDOM(javaScript: """
        (() => {
          const link = document.querySelector(
            '.user-card a.Username, .user-card .user-head a[href^="/space/"]'
          );
          const match = link && link.getAttribute('href').match(/\\/space\\/(\\d+)/);
          return match ? match[1] : '';
        })()
        """),
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
