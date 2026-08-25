import Foundation
import SwiftUI

/// 一个站点的固定资料：从哪里发请求、去哪里登录、哪些域算它的、登录凭据叫什么。
///
/// 这些值原本散在 `NGAEndpoint`、`NGAInternalLink` 和 `LoginWebView` 里各写一份。
/// 收到这里之后，接第二个站点时要填的东西一眼可数，而不必回去把三处逐个找出来。
struct ForumSiteDescriptor: Sendable {
    let site: ForumSite
    /// 所有接口请求的根地址，也是渲染楼层正文时给 `WKWebView` 的 base URL。
    let baseURL: URL
    /// 内嵌登录页。登录流程由站点官方页面完成，应用不碰密码。
    let loginURL: URL
    /// 登录成功后按这些域收 Cookie。写主域即可，子域自动算在内。
    let cookieDomains: [String]
    /// 正文里指向这些域的链接算站内链接，交给原生导航而不是浏览器。
    let linkDomains: [String]
    /// 会话里标识用户编号的 Cookie。
    let uidCookieName: String
    /// 会话里承载登录凭据的 Cookie。
    let credentialCookieName: String

    var displayName: String { site.displayName }

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
        }
    }

    /// 编辑器预览用的正文清洗。
    ///
    /// 同步返回：视图 body 里等不了 actor，而各站的清洗器都是无状态的。
    func sanitizedPreviewHTML(_ source: String) -> String {
        switch site {
        case .nga: NGAParser().sanitizedPostHTML(source)
        }
    }

    /// 话题在网页版的地址，用于「复制链接」和「在浏览器中打开」。
    func topicWebURL(topicID: TopicID) -> URL {
        switch site {
        case .nga: NGAEndpoint.topicWebURL(topicID: topicID)
        }
    }

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
        baseURL: URL(string: "https://bbs.nga.cn")!,
        loginURL: URL(string: "https://bbs.nga.cn/nuke.php?__lib=login&__act=account&login")!,
        cookieDomains: ["nga.cn"],
        // nga.178.com 原本是 isForumHost 里单写的一个特例，规则和其余三个域一样，
        // 所以直接并进列表。
        linkDomains: ["nga.cn", "ngacn.cc", "ngabbs.com", "nga.178.com"],
        uidCookieName: "ngaPassportUid",
        credentialCookieName: "ngaPassportCid"
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
