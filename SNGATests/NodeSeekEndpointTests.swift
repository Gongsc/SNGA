import Foundation
import XCTest
@testable import SNGA

/// NodeSeek 的地址拼装与站内链接解析。
///
/// 这些形状来自 `Design/SiteProbe-NodeSeek.md`。传输层那部分是实测的；地址形状来自阅读
/// 另一个客户端的源码，接第一个真接口时会被真实响应验证一次。
final class NodeSeekEndpointTests: XCTestCase {

    private let site = ForumSiteDescriptor.nodeseek

    // MARK: - 站点资料

    func testDescriptorMatchesWhatWasMeasured() {
        XCTAssertEqual(site.baseURL.absoluteString, "https://www.nodeseek.com")
        // 邮箱验证登录。密码登录反复尝试会触发风控，而且那一页没有通往这里的入口。
        XCTAssertEqual(site.loginURL.absoluteString, "https://www.nodeseek.com/emailSignIn.html")
        XCTAssertEqual(site.replyMarkup, .markdown)
        XCTAssertEqual(site.sessionCookieNames, ["session"])
        // 编号不在 cookie 里，只在登录后渲染出来的用户卡片上。
        XCTAssertNil(site.uidCookieName)
        guard case let .renderedDOM(script) = site.userIDSource else {
            return XCTFail("NodeSeek 的编号来源应当是渲染后的 DOM")
        }
        XCTAssertTrue(script.contains(".user-card"), "取的是登录后才出现的那张用户卡片")
        // 写死 UA 会触发无限挑战。
        XCTAssertEqual(site.userAgent, .webView)
    }

    func testCapabilitiesLeaveOutWhatTheSiteDoesNotHave() {
        let capabilities = NodeSeekForumService(
            accountID: AccountID(),
            cookies: [],
            userAgent: "probe"
        ).capabilities

        for present in [
            ForumCapabilities.checkIn, .postVote,
            .quotePost, .privateMessages, .userActivities
        ] {
            XCTAssertTrue(capabilities.contains(present))
        }
        for absent in [
            ForumCapabilities.forumFavorites, .subforums,
            .topicRating, .topicFavoriteFolders, .anonymousPosts
        ] {
            XCTAssertFalse(capabilities.contains(absent), "NodeSeek 没有这个功能")
        }
        // 投票单列一条：站点有，但这边还不会从帖子里把它读出来。
        // 能力位回答的是「这里能不能用」，读出来之前不能点亮。
        XCTAssertFalse(capabilities.contains(.poll))
        // 「反对」单列一条：站点有这个功能，但它要花掉用户 2 个鸡腿而且撤不回来。
        // 摆一个一点就扣钱、又不作声的按钮，比没有这个按钮更糟。
        XCTAssertFalse(
            capabilities.contains(.postDownvote),
            "NodeSeek 的反对要花 2 个鸡腿，没有二次确认之前不该摆出按钮"
        )
        // 搜索单列一条：它不是「站点没有这个功能」，而是站点把搜索转交给了 Google。
        // /search?q=X 会 302 到 google.com/search?q=site:www.nodeseek.com&q=X，
        // 没有任何接口能把结果取回来，所以这个位不能点亮。
        XCTAssertFalse(
            capabilities.contains(.globalSearch),
            "NodeSeek 没有自己的站内搜索，点亮这个位等于摆一个必定失败的入口"
        )
    }

    // MARK: - 列表与帖子地址

    func testHomeCategoryPagesWithoutASlug() {
        let home = NodeSeekEndpoint.forumID(key: NodeSeekEndpoint.homeKey)
        XCTAssertEqual(
            NodeSeekEndpoint.topicList(forumID: home, page: 1, sortByPostTime: false)
                .absoluteString,
            "https://www.nodeseek.com/"
        )
        XCTAssertEqual(
            NodeSeekEndpoint.topicList(forumID: home, page: 3, sortByPostTime: false)
                .absoluteString,
            "https://www.nodeseek.com/page-3"
        )
    }

    func testCategoryPagesUnderItsSlug() {
        let daily = NodeSeekEndpoint.forumID(key: "daily")
        XCTAssertEqual(
            NodeSeekEndpoint.topicList(forumID: daily, page: 1, sortByPostTime: false)
                .absoluteString,
            "https://www.nodeseek.com/categories/daily"
        )
        XCTAssertEqual(
            NodeSeekEndpoint.topicList(forumID: daily, page: 2, sortByPostTime: false)
                .absoluteString,
            "https://www.nodeseek.com/categories/daily/page-2"
        )
    }

    /// 默认排序不带参数，这样地址和站点自己的一模一样。
    func testDefaultSortAddsNoParameter() {
        let daily = NodeSeekEndpoint.forumID(key: "daily")
        XCTAssertFalse(
            NodeSeekEndpoint.topicList(forumID: daily, page: 1, sortByPostTime: false)
                .absoluteString.contains("sortBy")
        )
        XCTAssertTrue(
            NodeSeekEndpoint.topicList(forumID: daily, page: 1, sortByPostTime: true)
                .absoluteString.hasSuffix("?sortBy=postTime")
        )
    }

    func testThreadPathCarriesItsPage() {
        XCTAssertEqual(
            NodeSeekEndpoint.thread(topicID: TopicID(rawValue: 857_694), page: 2).absoluteString,
            "https://www.nodeseek.com/post-857694-2"
        )
    }

    /// 站点只给楼层号不给页码，跳转前得自己算。每页 10 层，`#0` 是主楼。
    func testFloorMapsToItsPage() {
        XCTAssertEqual(NodeSeekEndpoint.page(ofFloor: 0), 1)
        XCTAssertEqual(NodeSeekEndpoint.page(ofFloor: 1), 1)
        XCTAssertEqual(NodeSeekEndpoint.page(ofFloor: 10), 1)
        XCTAssertEqual(NodeSeekEndpoint.page(ofFloor: 11), 2)
        XCTAssertEqual(NodeSeekEndpoint.page(ofFloor: 127), 13)
    }

    // MARK: - 站内链接

    func testInternalLinksResolveToNativeDestinations() throws {
        let cases: [(String, NGAInternalDestination)] = [
            ("https://www.nodeseek.com/post-857694-2",
             .topic(topicID: TopicID(rawValue: 857_694), page: 2, postID: nil)),
            ("https://www.nodeseek.com/post-857694",
             .topic(topicID: TopicID(rawValue: 857_694), page: nil, postID: nil)),
            ("https://www.nodeseek.com/space/12345", .user(uid: 12_345)),
            ("https://www.nodeseek.com/categories/daily",
             .forum(NodeSeekEndpoint.forumID(key: "daily")))
        ]
        for (string, expected) in cases {
            let url = try XCTUnwrap(URL(string: string))
            XCTAssertEqual(site.internalDestination(for: url), expected, string)
        }
    }

    /// 楼层锚点给的是楼层号，要换算成页码才能跳。
    func testFloorAnchorBecomesAPageNumber() throws {
        let url = try XCTUnwrap(URL(string: "https://www.nodeseek.com/post-857694#25"))
        XCTAssertEqual(
            site.internalDestination(for: url),
            .topic(topicID: TopicID(rawValue: 857_694), page: 3, postID: nil)
        )
    }

    func testForeignHostsAreNotInternal() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/post-857694-2"))
        XCTAssertNil(site.internalDestination(for: url))
    }

    // MARK: - 反应

    /// 动作名和含义对不上，接错会花掉用户的鸡腿。这条把对应关系钉住。
    func testReactionCostsAreNotWhatTheNamesSuggest() {
        XCTAssertEqual(NodeSeekReaction.upvote.chickenCost, 0, "投喂是免费的")
        XCTAssertTrue(NodeSeekReaction.upvote.isFree)
        XCTAssertEqual(NodeSeekReaction.like.chickenCost, 1, "like 是加鸡腿，要花钱")
        XCTAssertEqual(NodeSeekReaction.dislike.chickenCost, 2, "dislike 是反对，花两个")
        XCTAssertFalse(NodeSeekReaction.like.isFree)
    }

    // MARK: - Cloudflare 判定

    func testChallengeIsRecognizedInAllThreeShapes() {
        XCTAssertTrue(NodeSeekNetworkClient.isChallenge(
            status: 403, headers: ["cf-mitigated": "challenge"], body: Data(), expectedJSON: true))
        XCTAssertTrue(NodeSeekNetworkClient.isChallenge(
            status: 403, headers: [:], body: Data("<!DOCTYPE html><html>".utf8), expectedJSON: true))
        XCTAssertTrue(NodeSeekNetworkClient.isChallenge(
            status: 200, headers: [:], body: Data("<title>Just a moment…</title>".utf8),
            expectedJSON: true))
        XCTAssertFalse(NodeSeekNetworkClient.isChallenge(
            status: 200, headers: [:], body: Data(#"{"success":true}"#.utf8), expectedJSON: true))
    }

    /// 网页请求拿到 HTML 是正常的，不能当成挑战 —— 这样判会把每一次成功都判死。
    func testHTMLIsNotAChallengeWhenHTMLIsWhatWasAskedFor() {
        let page = Data("<!DOCTYPE html><html><body>列表</body></html>".utf8)
        XCTAssertFalse(NodeSeekNetworkClient.isChallenge(
            status: 200, headers: [:], body: page, expectedJSON: false))
        // 但挑战页即使在网页请求上也认得出来。
        XCTAssertTrue(NodeSeekNetworkClient.isChallenge(
            status: 403, headers: [:], body: Data("<html><title>Just a moment…</title>".utf8),
            expectedJSON: false))
    }

    /// 这几族接口未登录时答 500 而不是 401，得认出来才能提示「去登录」而不是「重试」。
    func testSessionScopedFamiliesAreRecognized() throws {
        for path in ["/api/notification/unread-count", "/api/statistics/collection",
                     "/api/admin/ruling/page-1", "/api/account/find/alice"] {
            let url = try XCTUnwrap(URL(string: "https://www.nodeseek.com" + path))
            XCTAssertTrue(NodeSeekNetworkClient.isSessionScoped(url), path)
        }
        // 这个未登录也答，不该被当成会话端点。
        let open = try XCTUnwrap(URL(string: "https://www.nodeseek.com/api/account/getInfo/1"))
        XCTAssertFalse(NodeSeekNetworkClient.isSessionScoped(open))
    }
}

/// 请求路径：头带对没有、失败形态映射对没有。
///
/// 用假 transport，不联网。
final class NodeSeekNetworkClientTests: XCTestCase {

    private func makeClient(_ transport: RecordingTransport) -> NodeSeekNetworkClient {
        NodeSeekNetworkClient(
            cookies: [
                SessionCookie(name: "session", value: "s", domain: "nodeseek.com", path: "/",
                              expiresAt: nil, isSecure: true, isHTTPOnly: true),
                SessionCookie(name: "cf_clearance", value: "c", domain: ".nodeseek.com", path: "/",
                              expiresAt: nil, isSecure: true, isHTTPOnly: true)
            ],
            transport: transport,
            userAgent: "WebViewUA/1.0",
            cookieDidChange: { _ in }
        )
    }

    /// UA 必须是传进来的那个，cookie 必须一个不落。
    func testRequestCarriesTheWebViewAgentAndEveryCookie() async throws {
        let transport = RecordingTransport(body: Data(#"{"ok":true}"#.utf8))
        _ = try await makeClient(transport).get(NodeSeekEndpoint.unreadCount)

        let recorded = await transport.lastRequest
        let request = try XCTUnwrap(recorded)
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "WebViewUA/1.0")
        let cookie = try XCTUnwrap(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertTrue(cookie.contains("session=s"))
        XCTAssertTrue(cookie.contains("cf_clearance=c"), "少带一个就会被挑战")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Requested-With"), "XMLHttpRequest")
    }

    /// 网页请求不该带 XHR 那套头，`Accept` 也不一样。
    func testHTMLRequestsDropTheXHRHeaders() async throws {
        let transport = RecordingTransport(body: Data("<html></html>".utf8))
        let home = NodeSeekEndpoint.forumID(key: NodeSeekEndpoint.homeKey)
        _ = try await makeClient(transport).get(
            NodeSeekEndpoint.topicList(forumID: home, page: 1, sortByPostTime: false),
            asJSON: false
        )

        let recorded = await transport.lastRequest
        let request = try XCTUnwrap(recorded)
        XCTAssertNil(request.value(forHTTPHeaderField: "X-Requested-With"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), ForumSiteDescriptor.htmlAccept)
    }

    /// 被挑战时不能说成「服务器错误」—— 用户要做的是回去过验证。
    func testChallengeAsksForVerificationRatherThanRetry() async {
        let transport = RecordingTransport(
            body: Data("<!DOCTYPE html><title>Just a moment…</title>".utf8),
            status: 403,
            headers: ["cf-mitigated": "challenge"]
        )
        do {
            _ = try await makeClient(transport).get(NodeSeekEndpoint.unreadCount)
            XCTFail("挑战应当抛错")
        } catch let error as ForumServiceError {
            guard case let .restricted(message) = error else {
                return XCTFail("应当是 restricted，实际是 \(error)")
            }
            XCTAssertTrue(message.contains("人机验证"), message)
        } catch {
            XCTFail("意外的错误：\(error)")
        }
    }

    /// 会话端点的 500 是「没登录」，不是「服务器坏了」。
    func testFiveHundredOnASessionEndpointMeansSignIn() async {
        let transport = RecordingTransport(body: Data(), status: 500)
        do {
            _ = try await makeClient(transport).get(NodeSeekEndpoint.unreadCount)
            XCTFail("应当抛错")
        } catch {
            XCTAssertEqual(error as? ForumServiceError, .requiresLogin)
        }
    }

    /// 但普通端点的 500 仍然是服务器故障，不能一律说成要登录。
    func testFiveHundredElsewhereStaysAServerFault() async {
        let transport = RecordingTransport(body: Data(), status: 500)
        do {
            _ = try await makeClient(transport).get(NodeSeekEndpoint.accountInfo(uid: 1))
            XCTFail("应当抛错")
        } catch {
            XCTAssertEqual(error as? ForumServiceError, .server(500))
        }
    }

    /// 响应里换发的 cookie 要跟上 —— Cloudflare 会不定时换 `cf_clearance`。
    func testRotatedCookiesAreKept() async throws {
        let transport = RecordingTransport(
            body: Data(#"{"ok":true}"#.utf8),
            headers: ["Set-Cookie": "cf_clearance=rotated; Path=/; Domain=.nodeseek.com"]
        )
        let client = makeClient(transport)
        _ = try await client.get(NodeSeekEndpoint.unreadCount)

        let value = await client.currentCookies()
            .first { $0.name == "cf_clearance" }?.value
        XCTAssertEqual(value, "rotated")
    }
}

private actor RecordingTransport: HTTPTransport {
    private(set) var lastRequest: URLRequest?
    private let body: Data
    private let status: Int
    private let headers: [String: String]

    init(body: Data, status: Int = 200, headers: [String: String] = [:]) {
        self.body = body
        self.status = status
        self.headers = headers
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lastRequest = request
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers
        )!
        return (body, response)
    }
}
