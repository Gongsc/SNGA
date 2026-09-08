import Foundation
import XCTest
@testable import SNGA

/// V2EX 的站点资料、地址拼装和站内链接解析。
///
/// 这些形状全是 2026-09-08 从公开页面和站点自己的 `combo.js` 上实测来的，
/// 记在 `Design/SiteProbe-V2EX.md`。
final class V2EXEndpointTests: XCTestCase {

    private let site = ForumSiteDescriptor.v2ex

    // MARK: - 站点资料

    func testDescriptorMatchesWhatWasMeasured() {
        XCTAssertEqual(site.baseURL.absoluteString, "https://www.v2ex.com")
        XCTAssertEqual(site.loginURL.absoluteString, "https://www.v2ex.com/signin")
        // 说的是回复。主题正文走 Markdown，回复不走 —— 而应用只提交回复。
        XCTAssertEqual(site.replyMarkup, .plain)
        XCTAssertEqual(site.sessionCookieNames, ["A2"])
        // 编号不在 cookie 里。`A2` 是签名过的会话串，`PB3_SESSION` 编的是来访 IP。
        XCTAssertNil(site.uidCookieName)
        guard case let .renderedDOM(script) = site.userIDSource else {
            return XCTFail("V2EX 的编号来源应当是登录后的页面")
        }
        XCTAssertTrue(script.contains("memberId"), "第一条路是站点自己写的那个全局")
        XCTAssertTrue(script.contains("data-uid"), "用 gravatar 的会员只剩这一条路")
        // 站点不校验 UA：拿应用自己的名字请求节点页、主题页和节点接口都是 200。
        XCTAssertEqual(site.userAgent, .fixed("SNGA/1.0 (macOS; native client)"))
    }

    /// 站点没有主题全文搜索，只有节点搜索。
    ///
    /// 这个结论不是从「匿名访问 `/search` 被转走」推出来的 —— 那是 NodeSeek 上踩过
    /// 两次的坑。判据是站点自己的 `combo.js`：搜索框给的四档是节点、用户、
    /// 谷歌 `site:v2ex.com/t`、第三方 SoV2EX。
    func testSearchOffersNodesOnly() {
        XCTAssertEqual(site.searchKinds, [.forum])
        XCTAssertEqual(site.searchKindTitle(.forum), "节点")
        XCTAssertTrue(site.searchSummary.contains("节点"))
        // 节点搜索缩不进某一个节点里，所以版面内搜索一档都没有。
        XCTAssertTrue(site.currentForumSearchKinds.isEmpty)
    }

    func testCapabilitiesLeaveOutWhatTheSiteDoesNotHave() {
        let capabilities = V2EXForumService(
            accountID: AccountID(),
            cookies: [],
            userAgent: "probe"
        ).capabilities

        XCTAssertTrue(capabilities.contains(.globalSearch))
        XCTAssertTrue(capabilities.contains(.userActivities))
        // 站点的节点是平的，没有真正的子版面；这一位说的是**首页分类底下那第二排
        // 节点** —— 界面上就是子版面那个形状：一格里列出几个版面，能点进去，
        // 也能筛掉几个不看。
        XCTAssertTrue(capabilities.contains(.subforums))
        for absent in [
            // 「感谢」花钱又撤不回来，所以它走带确认的表态那条路，不是赞踩。
            ForumCapabilities.postVote, .postDownvote,
            // 收藏、提醒、每日奖励都要登录才看得见标记，还没接。
            .topicFavorites, .topicFavoriteFolders, .forumFavorites, .checkIn,
            // 站点本来就没有的。
            .privateMessages, .poll, .topicRating, .quotePost, .anonymousPosts
        ] {
            XCTAssertFalse(capabilities.contains(absent), "不该声明 \(absent)")
        }
    }

    /// 没有签到的站点不该显示「个人简介」之外的 NGA 词汇。
    func testProfileFieldsUseTheSitesOwnWording() {
        let profile = Profile(
            uid: 1,
            displayName: "Livid",
            avatarURL: nil,
            userGroup: "PRO",
            title: "Remember the bigger green",
            registeredAt: Date(timeIntervalSince1970: 1_272_203_146),
            location: "Chiang Mai"
        )
        let titles = site.profileFields(for: profile).map(\.title)

        XCTAssertEqual(titles, ["加入时间", "所在地", "一句话介绍", "会员类型"])
        // 网页上才有的那两行，有数才画。
        var richer = profile
        richer.dailyRank = 497
        richer.affiliation = "V2EX / Builder"
        XCTAssertEqual(
            site.profileFields(for: richer).map(\.title),
            ["加入时间", "所在地", "一句话介绍", "会员类型", "今日活跃度排名", "公司 / 职位"]
        )
        XCTAssertFalse(site.showsReputationSection, "铜币只对本人下发，别人的资料里全是「—」")
        XCTAssertEqual(site.profileSignatureTitle, "个人简介")
    }

    /// 站点没有表情面板 —— 正文里的表情就是 Unicode emoji，直接打。
    func testNoEmoticonPacks() {
        XCTAssertTrue(site.emoticonPacks.isEmpty)
    }

    // MARK: - 地址

    func testTopicListURLs() {
        let recent = V2EXEndpoint.forumID(key: V2EXEndpoint.recentKey)
        XCTAssertEqual(
            V2EXEndpoint.topicList(forumID: recent, page: 1).absoluteString,
            "https://www.v2ex.com/recent"
        )
        XCTAssertEqual(
            V2EXEndpoint.topicList(forumID: recent, page: 3).absoluteString,
            "https://www.v2ex.com/recent?p=3"
        )
        XCTAssertEqual(
            V2EXEndpoint.topicList(forumID: V2EXEndpoint.forumID(key: "qna"), page: 1)
                .absoluteString,
            "https://www.v2ex.com/go/qna"
        )
        XCTAssertEqual(
            V2EXEndpoint.topicList(forumID: V2EXEndpoint.forumID(key: "qna"), page: 2)
                .absoluteString,
            "https://www.v2ex.com/go/qna?p=2"
        )
    }

    // MARK: - 首页分类

    /// 站点有一个叫 `qna` 的**分类**，也有一个叫 `qna` 的**节点**，两份列表并不一样。
    /// 键不加前缀，收藏、最近访问、子版面偏好这些按 `ForumID` 做主键的东西全会串号。
    func testTabKeysDoNotCollideWithNodeKeys() {
        let tab = V2EXEndpoint.tabForumID(key: "qna")
        let node = V2EXEndpoint.forumID(key: "qna")

        XCTAssertNotEqual(tab, node)
        XCTAssertEqual(V2EXEndpoint.tabKey(of: tab), "qna")
        XCTAssertNil(V2EXEndpoint.tabKey(of: node), "节点不该被当成分类")
        XCTAssertEqual(V2EXEndpoint.tabName(of: tab), "问与答")
        XCTAssertNil(V2EXEndpoint.tabName(of: node))
    }

    /// 首页分类没有分页条，站点就是不给翻页 —— 地址里不该冒出一个 `p`。
    func testTabURLsIgnorePaging() {
        let tab = V2EXEndpoint.tabForumID(key: "tech")

        XCTAssertEqual(
            V2EXEndpoint.topicList(forumID: tab, page: 1).absoluteString,
            "https://www.v2ex.com/?tab=tech"
        )
        XCTAssertEqual(
            V2EXEndpoint.topicList(forumID: tab, page: 5).absoluteString,
            "https://www.v2ex.com/?tab=tech"
        )
    }

    /// 侧栏上钉的那一栏。只有 V2EX 有这种东西。
    func testPinnedForumsAreTheHomepageTabs() {
        let pinned = site.pinnedForums

        XCTAssertEqual(site.pinnedForumsTitle, "首页分类")
        XCTAssertEqual(pinned.map(\.name).prefix(4), ["技术", "创意", "好玩", "Apple"])
        XCTAssertEqual(pinned.count, V2EXEndpoint.tabs.count)
        // 每一条都得是分类的键，不是节点的键。
        XCTAssertTrue(pinned.allSatisfy { V2EXEndpoint.tabKey(of: $0.id) != nil })
        // 目录里按分类名归组，和侧栏那一栏同名。
        XCTAssertTrue(pinned.allSatisfy { $0.category == "首页分类" })

        for other in [ForumSiteDescriptor.nga, .nodeseek] {
            XCTAssertTrue(other.pinnedForums.isEmpty, "\(other.displayName) 不该钉版面")
        }
    }

    /// 分类页翻页翻不动，所以服务层就该只取第一页 —— 收下大页码只会把同一屏
    /// 再取一遍，还让界面以为「还有下一页」。
    func testTabRequestsOnlyEverFetchTheFirstPage() async throws {
        let transport = RecordingHTTPTransport(
            responding: try fixture("v2ex-home-tab")
        )
        let service = V2EXForumService(
            accountID: AccountID(),
            cookies: [],
            transport: transport,
            userAgent: "probe"
        )

        let page = try await service.topics(
            forumID: V2EXEndpoint.tabForumID(key: "tech"),
            page: 3,
            sortOrder: .latestReply,
            featuredOnly: false
        )

        XCTAssertEqual(
            transport.requests.first?.url?.absoluteString,
            "https://www.v2ex.com/?tab=tech"
        )
        XCTAssertEqual(page.page, 1)
        XCTAssertFalse(page.hasMore)
        // 分类页上没有节点抬头，名字得自己补，否则列表顶上空着一格。
        XCTAssertEqual(page.forum?.name, "技术")
        XCTAssertEqual(page.forum?.subtitle?.hasPrefix("程序员 · Python"), true)
    }

    private func fixture(_ name: String) throws -> String {
        let url = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: name, withExtension: "html"),
            "测试包里没有夹具 \(name).html"
        )
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testTopicAndMemberURLs() {
        XCTAssertEqual(
            V2EXEndpoint.topic(topicID: TopicID(rawValue: 1_240_288), page: 2).absoluteString,
            "https://www.v2ex.com/t/1240288?p=2"
        )
        XCTAssertEqual(
            V2EXEndpoint.member(uid: 1).absoluteString,
            "https://www.v2ex.com/api/members/show.json?id=1"
        )
        XCTAssertEqual(
            V2EXEndpoint.memberTopics(username: "Livid", page: 2).absoluteString,
            "https://www.v2ex.com/member/Livid/topics?p=2"
        )
        XCTAssertEqual(
            V2EXEndpoint.memberReplies(username: "Livid", page: 1).absoluteString,
            "https://www.v2ex.com/member/Livid/replies?p=1"
        )
    }

    /// 一次性令牌当查询参数发，不是请求头。抄自站点自己的 `thankReply`。
    func testThankURLsCarryTheOnceToken() {
        XCTAssertEqual(
            V2EXEndpoint.thankReply(postID: PostID(rawValue: 18_060_707), once: "35953")
                .absoluteString,
            "https://www.v2ex.com/thank/reply/18060707?once=35953"
        )
        XCTAssertEqual(
            V2EXEndpoint.thankTopic(topicID: TopicID(rawValue: 1_240_288), once: "35953")
                .absoluteString,
            "https://www.v2ex.com/thank/topic/1240288?once=35953"
        )
        XCTAssertEqual(
            V2EXEndpoint.pollOnce.absoluteString,
            "https://www.v2ex.com/poll_once"
        )
    }

    /// 每页 100 层。锚点给的是楼层号，得自己算在第几页。
    func testFloorToPage() {
        XCTAssertEqual(V2EXEndpoint.repliesPerPage, 100)
        XCTAssertEqual(V2EXEndpoint.page(ofFloor: 0), 1)
        XCTAssertEqual(V2EXEndpoint.page(ofFloor: 1), 1)
        XCTAssertEqual(V2EXEndpoint.page(ofFloor: 100), 1)
        XCTAssertEqual(V2EXEndpoint.page(ofFloor: 101), 2)
        XCTAssertEqual(V2EXEndpoint.page(ofFloor: 250), 3)
    }

    // MARK: - 站内链接

    func testInternalDestinations() throws {
        let cases: [(String, NGAInternalDestination?)] = [
            ("https://www.v2ex.com/t/1240288",
             .topic(topicID: TopicID(rawValue: 1_240_288), page: nil, postID: nil)),
            ("https://www.v2ex.com/t/1240288?p=2",
             .topic(topicID: TopicID(rawValue: 1_240_288), page: 2, postID: nil)),
            // 锚点是楼层号不是页码，每页 100 层。
            ("https://www.v2ex.com/t/1240288#reply150",
             .topic(topicID: TopicID(rawValue: 1_240_288), page: 2, postID: nil)),
            ("https://www.v2ex.com/go/qna", .forum(V2EXEndpoint.forumID(key: "qna"))),
            ("https://v2ex.com/recent",
             .forum(V2EXEndpoint.forumID(key: V2EXEndpoint.recentKey))),
            ("https://www.v2ex.com/",
             .forum(V2EXEndpoint.forumID(key: V2EXEndpoint.recentKey))),
            // 用户地址里是用户名，翻译成编号要发一次请求，这个函数是同步的 ——
            // 所以交给浏览器，而不是猜一个编号。
            ("https://www.v2ex.com/member/Livid", nil),
            ("https://www.v2ex.com/u/Livid", nil)
        ]
        for (raw, expected) in cases {
            let url = try XCTUnwrap(URL(string: raw))
            XCTAssertEqual(site.internalDestination(for: url), expected, raw)
        }
    }

    func testForeignHostsAreNotInternal() throws {
        for raw in [
            "https://v2ex.com.example.com/t/1",
            "https://notv2ex.com/t/1",
            "https://example.com/go/qna"
        ] {
            let url = try XCTUnwrap(URL(string: raw))
            XCTAssertNil(site.internalDestination(for: url), raw)
        }
    }

    // MARK: - 传输

    /// 站点对没登录、没设过语言的访客默认发英文页。固定钉一条语言 cookie。
    func testCookieHeaderAlwaysPinsChinese() throws {
        let url = try XCTUnwrap(URL(string: "https://www.v2ex.com/go/qna"))
        let empty = V2EXNetworkClient.cookieHeader(jar: SessionCookieJar([]), url: url)
        XCTAssertEqual(empty, "V2EX_LANG=zhcn")

        let jar = SessionCookieJar([
            SessionCookie(
                name: "A2", value: "secret", domain: ".v2ex.com", path: "/",
                expiresAt: nil, isSecure: true, isHTTPOnly: true
            )
        ])
        let header = V2EXNetworkClient.cookieHeader(jar: jar, url: url)
        XCTAssertTrue(header.contains("A2=secret"), header)
        XCTAssertTrue(header.contains("V2EX_LANG=zhcn"), header)
    }

    /// 已经带了语言的会话不重复添加 —— 用户在网页上换过语言时那条是他自己的选择。
    func testCookieHeaderKeepsAnExistingLanguageChoice() throws {
        let url = try XCTUnwrap(URL(string: "https://www.v2ex.com/go/qna"))
        let jar = SessionCookieJar([
            SessionCookie(
                name: "V2EX_LANG", value: "enus", domain: ".v2ex.com", path: "/",
                expiresAt: nil, isSecure: false, isHTTPOnly: false
            )
        ])

        XCTAssertEqual(V2EXNetworkClient.cookieHeader(jar: jar, url: url), "V2EX_LANG=enus")
    }

    /// 会话过期的形态是 302 到登录页，不是 401。`URLSession` 跟着跳，
    /// 于是拿回来的是一张 200 的登录页 —— 不认这一条，报出去的会是「页面结构变了」。
    func testSignInRedirectIsDetected() throws {
        let requested = try XCTUnwrap(URL(string: "https://www.v2ex.com/my/topics"))
        let landed = try XCTUnwrap(URL(string: "https://www.v2ex.com/signin"))
        XCTAssertTrue(V2EXNetworkClient.isSignInPage(finalURL: landed, requested: requested))

        // 主动去登录页不算被踢。
        XCTAssertFalse(V2EXNetworkClient.isSignInPage(finalURL: landed, requested: landed))
        XCTAssertFalse(V2EXNetworkClient.isSignInPage(finalURL: requested, requested: requested))
        XCTAssertFalse(V2EXNetworkClient.isSignInPage(finalURL: nil, requested: requested))
    }

    /// 表单编码：字段按名字排序（好让请求体逐字可对），值按 RFC 3986 转义。
    func testFormEncoding() {
        XCTAssertEqual(
            V2EXNetworkClient.formEncoded(["once": "35953", "content": "你好 world&"]),
            "content=%E4%BD%A0%E5%A5%BD%20world%26&once=35953"
        )
        XCTAssertEqual(V2EXNetworkClient.formEncoded([:]), "")
    }
}
