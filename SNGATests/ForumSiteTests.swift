import Foundation
import SwiftData
import XCTest
@testable import SNGA

/// 站点资料收进 `ForumSiteDescriptor` 之后，域名判断的结果必须和原先逐处写死时一致。
///
/// 尤其是 `nga.178.com`：它原本是 `isForumHost` 里单独写的一个特例，现在并进了
/// `linkDomains`。这里把并进去之后的行为钉住。
final class ForumSiteTests: XCTestCase {

    private let nga = ForumSiteDescriptor.nga

    // MARK: - 站内链接的域名

    func testKnownForumHostsAreRecognized() {
        for host in [
            "nga.cn",
            "bbs.nga.cn",
            "ngacn.cc",
            "bbs.ngacn.cc",
            "ngabbs.com",
            "nga.178.com",
            "bbs.nga.178.com"
        ] {
            XCTAssertTrue(nga.owns(host: host), "应认作站内域名：\(host)")
        }
    }

    func testHostMatchingIsCaseInsensitive() {
        XCTAssertTrue(nga.owns(host: "BBS.NGA.CN"))
    }

    /// 只补足一个点号就能骗过后缀判断的域名，必须挡住。
    func testLookalikeHostsAreRejected() {
        for host in [
            "evilnga.cn",
            "nga.cn.example.com",
            "ngacn.cc.example.com",
            "example.com",
            ""
        ] {
            XCTAssertFalse(nga.owns(host: host), "不该认作站内域名：\(host)")
        }
    }

    // MARK: - Cookie 的域名

    func testCookieDomainsToleratateALeadingDot() {
        XCTAssertTrue(nga.owns(cookieDomain: "nga.cn"))
        XCTAssertTrue(nga.owns(cookieDomain: ".nga.cn"))
        XCTAssertTrue(nga.owns(cookieDomain: "bbs.nga.cn"))
    }

    /// Cookie 的域比站内链接的域窄：镜像域上的 Cookie 不收。
    /// 这一条和登录时那次过滤是同一个判断，别把两份域名列表当成一份。
    func testCookieDomainsAreNarrowerThanLinkDomains() {
        XCTAssertTrue(nga.owns(host: "ngabbs.com"))
        XCTAssertFalse(nga.owns(cookieDomain: "ngabbs.com"))
        XCTAssertFalse(nga.owns(cookieDomain: "nga.178.com"))
    }

    // MARK: - 站内链接的解析

    func testInternalDestinationParsesAForumLinkOnAKnownHost() throws {
        let url = try XCTUnwrap(URL(string: "https://bbs.nga.cn/read.php?tid=42&page=3"))

        XCTAssertEqual(
            nga.internalDestination(for: url),
            .topic(topicID: TopicID(rawValue: 42), page: 3, postID: nil)
        )
    }

    func testInternalDestinationIgnoresForeignHosts() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/read.php?tid=42"))

        XCTAssertNil(nga.internalDestination(for: url))
    }

    // MARK: - 站点表

    func testEverySiteHasAConsistentDescriptor() {
        for site in ForumSite.allCases {
            let descriptor = site.descriptor
            XCTAssertEqual(descriptor.site, site)
            XCTAssertEqual(descriptor.displayName, site.displayName)
            XCTAssertFalse(site.displayName.isEmpty)
            XCTAssertFalse(descriptor.cookieDomains.isEmpty)
            XCTAssertFalse(descriptor.linkDomains.isEmpty)
            XCTAssertFalse(descriptor.sessionCookieNames.isEmpty, "会话总得由某个 Cookie 构成")
            XCTAssertFalse(descriptor.sessionCookieNames.contains(where: \.isEmpty))
            // 编号的来源可以不是 Cookie —— NodeSeek 就在渲染后的 DOM 里。
            switch descriptor.userIDSource {
            case let .cookie(name): XCTAssertFalse(name.isEmpty)
            case let .renderedDOM(script): XCTAssertFalse(script.isEmpty)
            }
            XCTAssertTrue(descriptor.loginURL.absoluteString.hasPrefix("https://"))
            XCTAssertTrue(descriptor.baseURL.absoluteString.hasPrefix("https://"))
            // 每个站都得挑定一种回复标记 —— 编辑器按它给工具条。
            XCTAssertTrue([.ubb, .markdown].contains(descriptor.replyMarkup))
        }
    }

    // MARK: - User-Agent

    /// NGA 不校验 UA，自报家门即可 —— 保持原样。
    func testNGAKeepsItsOwnUserAgent() {
        XCTAssertEqual(nga.userAgent, .fixed("SNGA/1.0 (macOS; native client)"))
        XCTAssertEqual(nga.resolvedUserAgent(fallback: nil), "SNGA/1.0 (macOS; native client)")
    }

    /// 要求用 WebView 真实 UA 的站点，在读不出来的时候也**绝不能**退回自报家门 ——
    /// 那正是无限挑战的成因。退路必须是一个像浏览器的串。
    func testWebViewUserAgentNeverFallsBackToTheAppsOwnName() {
        let probe = ForumSiteDescriptor(
            site: .nga,
            replyMarkup: .markdown,
            baseURL: nga.baseURL,
            loginMethods: nga.loginMethods,
            cookieDomains: nga.cookieDomains,
            linkDomains: nga.linkDomains,
            sessionCookieNames: ["session"],
            userIDSource: .renderedDOM(javaScript: "0"),
            userAgent: .webView
        )

        let resolved = probe.resolvedUserAgent(fallback: nil)
        XCTAssertFalse(resolved.contains("SNGA"), "退路里不能出现应用自己的名字：\(resolved)")
        XCTAssertTrue(resolved.contains("Mozilla/5.0"), resolved)
        // 真读出来了就用真的。
        XCTAssertEqual(probe.resolvedUserAgent(fallback: "Real/1.0"), "Real/1.0")
    }

    /// 没有 uid Cookie 的站点，凭据集合就只有会话那几个，脱敏名单也照样覆盖。
    func testCredentialNamesCoverSitesWithoutAUidCookie() {
        let probe = ForumSiteDescriptor(
            site: .nga,
            replyMarkup: .markdown,
            baseURL: nga.baseURL,
            loginMethods: nga.loginMethods,
            cookieDomains: nga.cookieDomains,
            linkDomains: nga.linkDomains,
            sessionCookieNames: ["session"],
            userIDSource: .renderedDOM(javaScript: "0"),
            userAgent: .webView
        )

        XCTAssertEqual(probe.credentialCookieNames, ["session"])
        XCTAssertEqual(nga.credentialCookieNames, ["ngaPassportCid", "ngaPassportUid"])
    }

    /// 每种登录方式都得能用：有标题、有说明、地址在自己站内。
    func testEveryLoginMethodIsUsable() {
        for site in ForumSite.allCases {
            let descriptor = site.descriptor
            XCTAssertFalse(descriptor.loginMethods.isEmpty, "\(site.rawValue) 一种登录方式都没有")
            XCTAssertEqual(
                Set(descriptor.loginMethods.map(\.id)).count,
                descriptor.loginMethods.count,
                "登录方式的 id 撞了，列表会画错"
            )
            for method in descriptor.loginMethods {
                XCTAssertFalse(method.title.isEmpty)
                XCTAssertFalse(method.detail.isEmpty, "得说清楚什么时候用它")
                XCTAssertTrue(method.url.absoluteString.hasPrefix("https://"))
                XCTAssertTrue(
                    descriptor.owns(host: method.url.host()?.lowercased() ?? ""),
                    "\(site.rawValue) 的 \(method.id) 登录页不在自己站内"
                )
            }
        }
    }

    /// NodeSeek 给两条路，邮箱验证排在前面 —— 密码登录会被风控挡。
    func testNodeSeekOffersEmailSignInFirst() {
        let methods = ForumSiteDescriptor.nodeseek.loginMethods
        XCTAssertEqual(methods.count, 2)
        XCTAssertEqual(methods.first?.id, "email")
        XCTAssertEqual(methods.last?.id, "password")
    }

    /// 登录页之间的来回切换是站内导航。写死一个站的域名会把别的站的站内链接
    /// 当成外链踢到浏览器 —— NodeSeek 的「切换到密码登录」正是这种。
    func testEverySiteOwnsItsOwnLoginHost() {
        for site in ForumSite.allCases {
            let descriptor = site.descriptor
            let host = descriptor.loginURL.host()?.lowercased() ?? ""
            XCTAssertTrue(
                descriptor.owns(host: host),
                "\(site.rawValue) 的登录页域名 \(host) 不在它自己的域名表里"
            )
        }
    }

    // MARK: - 错误文案里的站名

    /// 站名不在 `ForumServiceError` 里，是展示时冠上去的。多个站点并存时，
    /// 用户得知道刚才是哪个站出的错。
    @MainActor
    func testPresentedErrorsCarryTheSiteName() throws {
        let session = try Self.makeSession(withServiceFor: AccountID())

        session.present(ForumServiceError.invalidURL)

        XCTAssertEqual(session.errorMessage, "NGA：论坛地址无效")
    }

    /// 不是 `ForumServiceError` 的错误也一样冠名 —— 用户关心的是哪个站坏了，
    /// 而不是错误来自哪一层。
    @MainActor
    func testPresentedForeignErrorsAlsoCarryTheSiteName() throws {
        let session = try Self.makeSession(withServiceFor: AccountID())

        session.present(URLError(.timedOut))

        let message = try XCTUnwrap(session.errorMessage)
        XCTAssertTrue(message.hasPrefix("NGA："), message)
    }

    /// 适配器自己造的文案不该再写站名，否则展示时会冠出「NGA：NGA 暂时拒绝了…」。
    /// 这条盯的就是那个重复。
    @MainActor
    func testPresentedErrorsNameTheSiteExactlyOnce() throws {
        let session = try Self.makeSession(withServiceFor: AccountID())

        session.present(
            ForumServiceError.restricted("暂时拒绝了本次访问（HTTP 403），请稍后重试")
        )

        let message = try XCTUnwrap(session.errorMessage)
        XCTAssertEqual(
            message.components(separatedBy: "NGA").count - 1,
            1,
            "站名出现了不止一次：\(message)"
        )
    }

    /// 一个账号都没有时没有「哪个站」可言，就别硬冠一个。
    @MainActor
    func testPresentedErrorsAreNotQualifiedWithoutAnActiveService() throws {
        let session = try Self.makeSession(withServiceFor: nil)

        session.present(ForumServiceError.invalidURL)

        XCTAssertEqual(session.errorMessage, "论坛地址无效")
    }

    /// 日志脱敏名单从站点资料里推导，新加的站点不该漏出会话 Cookie。
    func testRuntimeLoggerRedactsEverySiteCredentialCookie() {
        for site in ForumSite.allCases {
            let descriptor = site.descriptor
            for name in descriptor.credentialCookieNames {
                XCTAssertEqual(
                    RuntimeLogger.redacted("Cookie: \(name)=very-secret"),
                    "Cookie: <redacted>",
                    "\(site.rawValue) 的 \(name) 没有被脱敏"
                )
                let url = URL(string: "https://example.com/x?\(name)=very-secret")!
                XCTAssertFalse(
                    RuntimeLogger.sanitizedURL(url).contains("very-secret"),
                    "\(site.rawValue) 的 \(name) 在 URL 里没有被脱敏"
                )
            }
        }
    }

    // MARK: - 能力集

    /// 加了新能力却忘了并进 `.all`，NGA 会悄悄少掉一个功能。
    /// 这里按位盯住：`.all` 必须是所有已声明位的全集。
    func testAllContainsEveryDeclaredCapability() {
        let declared: [ForumCapabilities] = [
            .checkIn, .postVote, .postDownvote, .quotePost, .topicRating, .poll,
            .subforums, .forumFavorites, .topicFavoriteFolders, .privateMessages,
            .globalSearch, .userActivities, .anonymousPosts
        ]
        for capability in declared {
            XCTAssertTrue(ForumCapabilities.all.contains(capability))
        }
        XCTAssertEqual(
            ForumCapabilities.all.rawValue,
            (1 << declared.count) - 1,
            "有位没并进 .all，或者 .all 里多了没声明的位"
        )
    }

    /// 阶段 1 的验收标准：NGA 声明全集，所以门控不该让界面少任何东西。
    @MainActor
    func testNGADeclaresEveryCapabilitySoNothingGetsHidden() throws {
        let session = try Self.makeSession(withServiceFor: AccountID())

        XCTAssertEqual(session.activeCapabilities, .all)
        for capability in [
            ForumCapabilities.checkIn, .postVote, .privateMessages,
            .globalSearch, .forumFavorites, .quotePost
        ] {
            XCTAssertTrue(session.supports(capability))
        }
    }

    /// 没有账号就没有能力，对应的控件一律不画。
    @MainActor
    func testNoAccountMeansNoCapabilities() throws {
        let session = try Self.makeSession(withServiceFor: nil)

        XCTAssertEqual(session.activeCapabilities, [])
        XCTAssertFalse(session.supports(.checkIn))
    }

    /// 版面收藏是主动去拉的，所以门控必须挡在调用层。NodeSeek 没有这个功能，
    /// 光把侧栏那一块藏起来的话，它一登录就会在启动时弹「不支持收藏版面」。
    @MainActor
    func testRefreshFavoritesDoesNotCallASiteThatCannotDoIt() async throws {
        let accountID = AccountID()
        let model = try Self.makeModel(
            withServiceFor: accountID,
            capabilities: ForumCapabilities.all.subtracting(.forumFavorites)
        )

        await model.favorite.refreshFavorites()

        XCTAssertFalse(model.session.supports(.forumFavorites))
        XCTAssertTrue(model.favorite.favorites.isEmpty)
        XCTAssertNil(model.session.errorMessage, "不该因为拉不支持的数据而报错")
    }

    /// 反过来：能力在的时候照拉不误，否则上面那条用例可能只是因为什么都没发生。
    @MainActor
    func testRefreshFavoritesStillRunsWhenTheSiteSupportsIt() async throws {
        let accountID = AccountID()
        let model = try Self.makeModel(withServiceFor: accountID)

        await model.favorite.refreshFavorites()

        XCTAssertTrue(model.session.supports(.forumFavorites))
        XCTAssertFalse(model.favorite.favorites.isEmpty, "调试服务本来会给出一个收藏版面")
    }

    // MARK: -

    @MainActor
    private static func makeSession(
        withServiceFor accountID: AccountID?,
        capabilities: ForumCapabilities = .all
    ) throws -> AppSession {
        try makeModel(withServiceFor: accountID, capabilities: capabilities).session
    }

    @MainActor
    private static func makeModel(
        withServiceFor accountID: AccountID?,
        capabilities: ForumCapabilities = .all
    ) throws -> AppModel {
        let schema = Schema([
            AccountRecord.self,
            FavoriteRecord.self,
            DraftRecord.self,
            SubforumPreferenceRecord.self,
            RecentForumRecord.self,
            AIProfileSummaryRecord.self
        ])
        let container = try ModelContainer(
            for: schema,
            configurations: [
                ModelConfiguration(
                    "ForumSiteTests.\(UUID().uuidString)",
                    schema: schema,
                    isStoredInMemoryOnly: true
                )
            ]
        )
        let model = AppModel(container: container)
        if let accountID {
            model.session.activeAccountID = accountID
            model.session.setService(
                DebugForumService(accountID: accountID, capabilities: capabilities),
                for: accountID
            )
        }
        return model
    }
}
