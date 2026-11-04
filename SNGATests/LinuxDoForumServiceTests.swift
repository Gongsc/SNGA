import Foundation
import XCTest
@testable import SNGA

/// Linux.do 适配器：发出去的请求对不对、切页对不对、站点地址和站内链接。
///
/// 网络一律走 `RecordingHTTPTransport`，夹具见 `LinuxDoParserTests`。
final class LinuxDoForumServiceTests: XCTestCase {

    private func fixture(_ name: String) throws -> String {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func makeService(_ transport: RecordingHTTPTransport) -> LinuxDoForumService {
        LinuxDoForumService(
            accountID: AccountID(),
            cookies: [
                SessionCookie(
                    name: "_t", value: "token", domain: "linux.do", path: "/",
                    expiresAt: nil, isSecure: true, isHTTPOnly: true
                ),
                SessionCookie(
                    name: "cf_clearance", value: "clear", domain: ".linux.do", path: "/",
                    expiresAt: nil, isSecure: true, isHTTPOnly: true
                )
            ],
            transport: transport,
            userAgent: "WebViewUA"
        )
    }

    // MARK: - 站点资料

    func testDescriptorMatchesWhatWasMeasured() {
        let site = ForumSiteDescriptor.linuxdo
        XCTAssertEqual(site.baseURL.absoluteString, "https://linux.do")
        XCTAssertEqual(site.loginURL.absoluteString, "https://linux.do/login")
        XCTAssertEqual(site.replyMarkup, .markdown)
        XCTAssertEqual(site.sessionCookieNames, ["_t"])
        // 编号 cookie 和页面里都没有，只能登录后问。
        XCTAssertEqual(site.userIDSource, .sessionQuery)
        XCTAssertNil(site.uidCookieName)
        // Cloudflare 会拿 UA 和页面 JS 环境对，必须用 WebView 自报的那个。
        XCTAssertEqual(site.userAgent, .webView)
        XCTAssertTrue(site.owns(cookieDomain: ".linux.do"))
        XCTAssertFalse(site.owns(cookieDomain: "notlinux.do"))
    }

    /// 能力位一条条写，现在只点亮了真接上的那一位。
    func testOnlyImplementedCapabilitiesAreLit() {
        let service = makeService(RecordingHTTPTransport(responding: "{}"))
        XCTAssertEqual(
            service.capabilities,
            [.subforums, .userActivities, .globalSearch, .privateMessages, .notifications, .postVote, .quotePost]
        )
    }

    // MARK: - 请求

    func testRequestsCarryEveryCookieAndTheWebViewUserAgent() async throws {
        let transport = RecordingHTTPTransport(responding: #"{"current_user":{"id":800001}}"#)
        let uid = try await makeService(transport).currentUserID()

        XCTAssertEqual(uid, 800_001)
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://linux.do/session/current.json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "WebViewUA")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        let cookie = try XCTUnwrap(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertTrue(cookie.contains("_t=token"))
        XCTAssertTrue(cookie.contains("cf_clearance=clear"), "少带一个就可能被挑战")
    }

    func testCategoryListUsesTheSlugPathAndAttachesSubcategories() async throws {
        let transport = RecordingHTTPTransport(
            responding: "{}",
            byPath: [
                "/categories.json": try fixture("linuxdo-categories"),
                "/c/": try fixture("linuxdo-category-latest")
            ]
        )
        let service = makeService(transport)
        let page = try await service.topics(
            forumID: LinuxDoEndpoint.forumID(categoryID: 14),
            page: 2,
            sortOrder: .latestTopic,
            featuredOnly: false
        )

        let list = try XCTUnwrap(transport.requests.last?.url)
        // 有 slug 就带上，省一次 302；页码从 0 数；「最新话题」是 order=created。
        XCTAssertEqual(list.path, "/c/resource/14/l/latest.json")
        let query = URLComponents(url: list, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertTrue(query.contains(URLQueryItem(name: "page", value: "1")))
        XCTAssertTrue(query.contains(URLQueryItem(name: "order", value: "created")))
        XCTAssertEqual(page.forum?.name, "资源荟萃")
        XCTAssertEqual(page.subforums.map(\.name), ["网盘资源"])

        // 类别表只取一次。
        _ = try await service.topics(
            forumID: LinuxDoEndpoint.forumID(categoryID: 4), page: 1, sortOrder: .latestReply, featuredOnly: false
        )
        XCTAssertEqual(transport.requests.filter { $0.url?.path == "/categories.json" }.count, 1)
    }

    /// 版面表只列顶层类别。子类别平铺出来，登录后会把每个类别的 Lv1 分区各列一遍，
    /// 看起来就是一份重复的列表（用户在应用里实际看到的）。
    func testForumListShowsOnlyTopLevelCategories() async throws {
        let transport = RecordingHTTPTransport(
            responding: "{}",
            byPath: ["/categories.json": try fixture("linuxdo-categories")]
        )
        let forums = try await makeService(transport).forums()
        XCTAssertEqual(forums.map(\.name), ["话题", "开发调优", "资源荟萃", "搞七捻三"])
        XCTAssertFalse(forums.contains { $0.isSubforum })
    }

    /// 侧边栏标签的形状（2026-11-04 实测 `current_user.sidebar_tags`，名字和编号是站点公开的标签）。
    static let sessionWithSidebarTags = """
    {"current_user":{"id":800001,"username":"user1","sidebar_tags":[
      {"id":1436,"name":"快问快答","slug":"1436-tag","description":null,"pm_only":false},
      {"id":444,"name":"人工智能","slug":"444-tag","description":null,"pm_only":false},
      {"id":10,"name":"抽奖","slug":"lottery","description":"","pm_only":false},
      {"id":1531,"name":"原创","slug":"1531-tag","description":"高质量原创帖子可用。","pm_only":false},
      {"id":31,"name":"公告","slug":"31-tag","description":"","pm_only":false},
      {"id":1435,"name":"精华神帖","slug":"1435-tag","description":"","pm_only":false},
      {"id":1534,"name":"集中帖","slug":"1534-tag","description":"专题集中帖。<br>集中讨论。","pm_only":false},
      {"id":9,"name":"私信专用","slug":"pm","description":null,"pm_only":true}
    ]}}
    """

    /// 和网页侧边栏同一个结构：社区里的「话题」、类别、标签；标签按拼音排，私信专用的不列。
    func testForumListMirrorsTheWebSidebar() async throws {
        let transport = RecordingHTTPTransport(
            responding: "{}",
            byPath: [
                "/categories.json": try fixture("linuxdo-categories"),
                "/session/current.json": Self.sessionWithSidebarTags
            ]
        )
        let forums = try await makeService(transport).forums()
        XCTAssertEqual(forums.first?.name, "话题")
        XCTAssertEqual(forums.first?.category, "社区")
        let tags = forums.filter { $0.category == "标签" }
        XCTAssertEqual(tags.map(\.name), ["抽奖", "公告", "集中帖", "精华神帖", "快问快答", "人工智能", "原创"])
        XCTAssertEqual(tags.first?.id, LinuxDoEndpoint.forumID(tagID: 10))
        XCTAssertEqual(tags.first { $0.name == "集中帖" }?.subtitle, "专题集中帖。 集中讨论。")
        // 用户自己设了侧边栏标签，就不必再去问站点的热门标签。
        XCTAssertFalse(transport.requests.contains { $0.url?.path == "/site.json" })
    }

    /// 用户没在侧边栏放过标签时，退到站点的热门标签 —— 网页侧边栏也这么退。
    func testTagsFallBackToTheSiteTopTags() async throws {
        let transport = RecordingHTTPTransport(
            responding: "{}",
            byPath: [
                "/categories.json": try fixture("linuxdo-categories"),
                "/session/current.json": #"{"current_user":{"id":800001,"sidebar_tags":[]}}"#,
                "/site.json": #"{"navigation_menu_site_top_tags":[{"id":1461,"name":"纯水","slug":"1461-tag","pm_only":false}]}"#
            ]
        )
        let forums = try await makeService(transport).forums()
        XCTAssertEqual(forums.filter { $0.category == "标签" }.map(\.name), ["纯水"])
    }

    /// 标签的列表地址带 slug；话题形状和类别列表一样。
    func testTagListUsesTheTagSlug() async throws {
        let transport = RecordingHTTPTransport(
            responding: "{}",
            byPath: [
                "/session/current.json": Self.sessionWithSidebarTags,
                "/tag/": try fixture("linuxdo-category-latest")
            ]
        )
        let page = try await makeService(transport).topics(
            forumID: LinuxDoEndpoint.forumID(tagID: 1435), page: 2, sortOrder: .latestReply, featuredOnly: false
        )
        let url = try XCTUnwrap(transport.requests.last?.url)
        XCTAssertEqual(url.path, "/tag/1435-tag/1435/l/latest.json")
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems, [URLQueryItem(name: "page", value: "1")])
        XCTAssertEqual(page.forum?.name, "精华神帖")
        XCTAssertFalse(page.topics.isEmpty)
        // 标签和类别的编号是两套：标签不该被当成类别去要子类别。
        XCTAssertFalse(transport.requests.contains { $0.url?.path == "/categories.json" })
    }

    func testLatestDoesNotNeedTheCategoryTable() async throws {
        let transport = RecordingHTTPTransport(responding: try fixture("linuxdo-category-latest"))
        let page = try await makeService(transport).topics(
            forumID: LinuxDoEndpoint.forumID(key: LinuxDoEndpoint.latestKey),
            page: 1,
            sortOrder: .latestReply,
            featuredOnly: false
        )
        XCTAssertEqual(transport.requests.map { $0.url?.absoluteString }, ["https://linux.do/latest.json"])
        XCTAssertEqual(page.forum?.name, "话题")
    }

    /// 站点不分页，适配器按 20 楼一页自己切：第一页走详情，第二页按编号批量取那 20 楼。
    func testThreadPagesAreCutFromThePostStream() async throws {
        let transport = RecordingHTTPTransport(
            responding: "{}",
            byPath: [
                "/t/3103315.json": try fixture("linuxdo-topic"),
                "/t/3103315/": try fixture("linuxdo-topic-posts")
            ]
        )
        let service = makeService(transport)
        let topicID = TopicID(rawValue: 3_103_315)

        let first = try await service.threadPage(topicID: topicID, page: 1, authorUID: nil)
        XCTAssertEqual(first.totalPages, 4, "65 楼，每页 20")
        XCTAssertTrue(first.hasMore)
        XCTAssertEqual(first.posts.first?.floor, 0)
        // 只取这一页缺的那些楼，不多取。
        let firstBatch = try XCTUnwrap(transport.requests.last?.url)
        XCTAssertEqual(firstBatch.path, "/t/3103315/posts.json")
        XCTAssertEqual(postIDs(in: firstBatch).count, 19, "详情已经带回了主楼")

        transport.reset()
        let second = try await service.threadPage(topicID: topicID, page: 2, authorUID: nil)
        // 编号流记着，第二页不必再取详情。
        XCTAssertEqual(transport.requests.count, 1)
        let batch = try XCTUnwrap(transport.requests.first?.url)
        XCTAssertEqual(postIDs(in: batch).count, 20)
        XCTAssertEqual(postIDs(in: batch).first, "24263769", "第二页从编号流的第 21 个开始")
        XCTAssertEqual(second.posts.map(\.floor), [20, 21])
        XCTAssertEqual(second.page, 2)
        XCTAssertEqual(second.topic.id, topicID)
    }

    func testChallengeIsReportedAsVerificationNotLogin() async throws {
        let transport = RecordingHTTPTransport(
            responding: "<html><head><title>Just a moment...</title></head></html>",
            status: 403
        )
        do {
            _ = try await makeService(transport).currentUserID()
            XCTFail("挑战页不该被当成正常响应")
        } catch let error as ForumServiceError {
            guard case let .restricted(message) = error else {
                return XCTFail("应当提示去完成人机验证，实际是 \(error)")
            }
            XCTAssertTrue(message.contains("人机验证"))
        }
    }

    func testDiscourseErrorMessageIsShownAsIs() async throws {
        let transport = RecordingHTTPTransport(
            responding: #"{"errors":["您没有权限查看请求的资源。"],"error_type":"invalid_access"}"#,
            status: 403
        )
        do {
            _ = try await makeService(transport).threadPage(topicID: TopicID(rawValue: 1), page: 1, authorUID: nil)
            XCTFail("403 应当抛错")
        } catch let error as ForumServiceError {
            XCTAssertEqual(error, .restricted("您没有权限查看请求的资源。"))
        }
    }

    // MARK: - 资料

    /// 卡片接口只用来把编号换成用户名，完整资料从 `/u/{用户名}.json` 取。
    func testProfileResolvesTheUsernameThenLoadsTheFullProfile() async throws {
        let transport = RecordingHTTPTransport(
            responding: "{}",
            byPath: [
                "/user-cards.json": try fixture("linuxdo-user-card"),
                "/u/": LinuxDoParserTests.fullProfileJSON
            ]
        )
        let profile = try await makeService(transport).profile(uid: 800_030)

        XCTAssertEqual(transport.requests.map { $0.url?.path }, ["/user-cards.json", "/u/user31.json"])
        XCTAssertEqual(profile.profileViewCount, 392_093)
        XCTAssertNotNil(profile.registeredAt)
    }

    /// 完整资料取不到时退回卡片那份，而不是让整页资料打不开。
    func testProfileFallsBackToTheCardWhenTheFullProfileFails() async throws {
        let transport = RecordingHTTPTransport(
            responding: "{}",
            byPath: [
                "/user-cards.json": try fixture("linuxdo-user-card"),
                // 不是 JSON 对象里的 `user`，解析会失败。
                "/u/": #"{"errors":["示例"]}"#
            ]
        )
        let profile = try await makeService(transport).profile(uid: 800_030)
        XCTAssertEqual(profile.uid, 800_030)
        XCTAssertEqual(profile.level, 4)
        XCTAssertNil(profile.profileViewCount)
    }

    // MARK: - 用户动态与搜索

    /// 地址要用户名：先拿卡片换一次，之后记着，不再换。
    func testUserActivitiesResolveTheUsernameOnce() async throws {
        let transport = RecordingHTTPTransport(
            responding: "{}",
            byPath: [
                "/user-cards.json": try fixture("linuxdo-user-card"),
                "/user_actions.json": try fixture("linuxdo-user-replies")
            ]
        )
        let service = makeService(transport)
        _ = try await service.userActivities(uid: 800_030, kind: .replies, page: 2)
        _ = try await service.userActivities(uid: 800_030, kind: .topics, page: 1)

        XCTAssertEqual(transport.requests.filter { $0.url?.path == "/user-cards.json" }.count, 1)
        let actions = transport.requests.filter { $0.url?.path == "/user_actions.json" }.compactMap(\.url)
        let first = URLComponents(url: try XCTUnwrap(actions.first), resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertTrue(first.contains(URLQueryItem(name: "username", value: "user31")))
        XCTAssertTrue(first.contains(URLQueryItem(name: "filter", value: "5")), "回复是 5")
        XCTAssertTrue(first.contains(URLQueryItem(name: "offset", value: "30")), "第二页从第 30 条起")
        let second = URLComponents(url: try XCTUnwrap(actions.last), resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertTrue(second.contains(URLQueryItem(name: "filter", value: "4")), "话题是 4")
    }

    /// 条件全写进 `q`：仅标题、类别、作者、日期。
    func testSearchPutsEveryConditionIntoTheQuery() async throws {
        let transport = RecordingHTTPTransport(
            responding: "{}",
            byPath: [
                "/categories.json": try fixture("linuxdo-categories"),
                "/search.json": try fixture("linuxdo-search")
            ]
        )
        var filters = ForumSearchFilters()
        filters.author = " user5 "
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        filters.postedAfter = calendar.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 12))
        let request = try XCTUnwrap(ForumSearchRequest(
            query: "docker",
            kind: .topicSubject,
            forumID: LinuxDoEndpoint.forumID(categoryID: 94),
            filters: filters
        ))
        let page = try await makeService(transport).search(request, page: 2)

        let url = try XCTUnwrap(transport.requests.last?.url)
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(query.first { $0.name == "q" }?.value, "docker in:title #resource:cloud-asset @user5 after:2026-10-01")
        XCTAssertEqual(query.first { $0.name == "page" }?.value, "2")
        XCTAssertFalse(page.topics.isEmpty)
    }

    /// 标签和「话题」那一栏缩不进去，界面不画，服务也不假装能搜。
    func testSearchRefusesScopesItCannotHonour() async throws {
        let site = ForumSiteDescriptor.linuxdo
        XCTAssertTrue(site.supportsSearch(in: LinuxDoEndpoint.forumID(categoryID: 4)))
        XCTAssertFalse(site.supportsSearch(in: LinuxDoEndpoint.forumID(tagID: 10)))
        XCTAssertFalse(site.supportsSearch(in: LinuxDoEndpoint.forumID(key: LinuxDoEndpoint.latestKey)))
        XCTAssertEqual(site.searchFilters(for: .topicContent), [.author, .dateRange])

        let transport = RecordingHTTPTransport(responding: "{}")
        let request = try XCTUnwrap(ForumSearchRequest(
            query: "x", kind: .topicContent, forumID: LinuxDoEndpoint.forumID(tagID: 10)
        ))
        do {
            _ = try await makeService(transport).search(request, page: 1)
            XCTFail("标签里搜不了，不该悄悄变成全站搜索")
        } catch let error as ForumServiceError {
            guard case .unsupported = error else { return XCTFail("应当是不支持，实际是 \(error)") }
        }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    // MARK: - 站内链接

    func testInternalLinks() {
        let site = ForumSiteDescriptor.linuxdo
        func destination(_ string: String) -> NGAInternalDestination? {
            site.internalDestination(for: URL(string: string)!)
        }
        XCTAssertEqual(
            destination("https://linux.do/t/topic/3103315"),
            .topic(topicID: TopicID(rawValue: 3_103_315), page: nil, postID: nil)
        )
        // 第 45 楼在第 3 页（每页 20 楼）。楼层号和编号流的位置在有删帖时会差几楼，
        // 落到相邻一页也比打开浏览器强。
        XCTAssertEqual(
            destination("https://linux.do/t/some-slug/3103315/45"),
            .topic(topicID: TopicID(rawValue: 3_103_315), page: 3, postID: nil)
        )
        XCTAssertEqual(destination("https://linux.do/c/develop/4"), .forum(LinuxDoEndpoint.forumID(categoryID: 4)))
        XCTAssertEqual(
            destination("https://linux.do/c/resource/cloud-asset/94/l/latest"),
            .forum(LinuxDoEndpoint.forumID(categoryID: 94))
        )
        XCTAssertEqual(destination("https://linux.do/latest"), .forum(LinuxDoEndpoint.forumID(key: "latest")))
        XCTAssertEqual(destination("https://linux.do/tag/lottery/10"), .forum(LinuxDoEndpoint.forumID(tagID: 10)))
        XCTAssertEqual(destination("https://linux.do/tag/1435-tag/1435"), .forum(LinuxDoEndpoint.forumID(tagID: 1435)))
        // 用户地址里是名字，同步路径上翻译不了，交给浏览器。
        XCTAssertNil(destination("https://linux.do/u/user1"))
        XCTAssertNil(destination("https://example.com/t/topic/1"))
    }

    private func postIDs(in url: URL) -> [String] {
        (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .filter { $0.name == "post_ids[]" }
            .compactMap(\.value)
    }
}
