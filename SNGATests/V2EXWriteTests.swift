import Foundation
import XCTest
@testable import SNGA

/// 写请求发出去到底长什么样。
///
/// 不往真实论坛发东西 —— 那是替用户发内容。这里用假传输层，按仓库里那条惯例来：
/// 取校验字段 → 提交一次 → 确认结果，三步都对着断言。
///
/// **V2EX 的写请求形状里，只有「一次性令牌」这一半是匿名验证过的**（`/poll_once`
/// 匿名请求就回一串数字，`thank*` 的地址和参数抄自站点自己的 `combo.js`）。
/// 回复那张表单只在登录后的页面上，字段名是照着站点的表单推断的 ——
/// 见 `Design/SiteProbe-V2EX.md`，以及 `Design/probe-v2ex-write.js`。
final class V2EXWriteTests: XCTestCase {

    private let topicID = TopicID(rawValue: 1_240_288)

    private func service(_ transport: RecordingHTTPTransport) -> V2EXForumService {
        V2EXForumService(
            accountID: AccountID(),
            cookies: [],
            transport: transport,
            userAgent: "probe"
        )
    }

    private func html(_ name: String) throws -> String {
        let url = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: name, withExtension: "html"),
            "测试包里没有夹具 \(name).html"
        )
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func body(_ request: URLRequest) -> String {
        String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
    }

    /// 回复：先现取一个令牌，再把它和正文一起表单提交到主题页自己的地址。
    func testReplyTakesAFreshTokenThenPostsOnce() async throws {
        let transport = RecordingHTTPTransport(
            responding: "<html><body><div id=\"Main\"></div></body></html>",
            byPath: ["/poll_once": "43517"]
        )

        _ = try await service(transport).submitReply(
            topicID: topicID,
            submission: ReplySubmission(content: "  你好 V2EX  ", replyTo: nil)
        )

        XCTAssertEqual(transport.requests.count, 2, "取令牌一次，提交一次，不重试")
        XCTAssertEqual(transport.requests[0].url?.path, "/poll_once")
        XCTAssertEqual(transport.requests[0].httpMethod, "GET")

        let post = transport.requests[1]
        XCTAssertEqual(post.httpMethod, "POST")
        XCTAssertEqual(post.url?.absoluteString, "https://www.v2ex.com/t/1240288")
        XCTAssertEqual(
            post.value(forHTTPHeaderField: "Content-Type"),
            "application/x-www-form-urlencoded"
        )
        // 正文两头的空白先去掉再发 —— 站点会把它们原样留在回复里。
        XCTAssertEqual(body(post), "content=%E4%BD%A0%E5%A5%BD%20V2EX&once=43517")
        // 浏览器只在写请求上带 Origin，而 Referer 指着主题页。
        XCTAssertEqual(post.value(forHTTPHeaderField: "Origin"), "https://www.v2ex.com")
        XCTAssertEqual(
            post.value(forHTTPHeaderField: "Referer"),
            "https://www.v2ex.com/t/1240288?p=1"
        )
    }

    /// 空内容一个请求都不该发出去。
    func testEmptyReplySendsNothing() async {
        let transport = RecordingHTTPTransport(responding: "", byPath: ["/poll_once": "1"])

        do {
            _ = try await service(transport).submitReply(
                topicID: topicID,
                submission: ReplySubmission(content: "   \n  ", replyTo: nil)
            )
            XCTFail("空回复应当被拦下")
        } catch {
            XCTAssertEqual(transport.requests.count, 0)
        }
    }

    /// 站点把出错写在返回的页面里（成功时是 302 回主题页）。
    func testReplyFailureFromThePageIsSurfaced() async {
        let transport = RecordingHTTPTransport(
            responding: """
            <html><body><div id="Main"><div class="problem">你上一条回复的时间过近</div></div></body></html>
            """,
            byPath: ["/poll_once": "43517"]
        )

        do {
            _ = try await service(transport).submitReply(
                topicID: topicID,
                submission: ReplySubmission(content: "再来一条", replyTo: nil)
            )
            XCTFail("站点已经说了不行")
        } catch {
            XCTAssertEqual(error as? ForumServiceError, .restricted("你上一条回复的时间过近"))
        }
    }

    /// 感谢一层楼。地址和参数抄自站点自己的 `thankReply`。
    func testThankingAReplyGoesToTheReplyEndpoint() async throws {
        let transport = RecordingHTTPTransport(
            responding: #"{"success": true, "once": 1}"#,
            byPath: ["/poll_once": "43517"]
        )

        _ = try await service(transport).submitPostReaction(
            topicID: topicID,
            postID: PostID(rawValue: 18_060_707),
            reactionID: "thank"
        )

        XCTAssertEqual(transport.requests.count, 2)
        let post = transport.requests[1]
        XCTAssertEqual(post.httpMethod, "POST")
        XCTAssertEqual(
            post.url?.absoluteString,
            "https://www.v2ex.com/thank/reply/18060707?once=43517"
        )
    }

    /// 主楼走的是另一个地址。分辨靠编号：主楼没有自己的回复编号，
    /// 解析器给它填的就是主题编号。
    func testThankingTheOpeningPostGoesToTheTopicEndpoint() async throws {
        let transport = RecordingHTTPTransport(
            responding: #"{"success": true, "once": 1}"#,
            byPath: ["/poll_once": "43517"]
        )

        _ = try await service(transport).submitPostReaction(
            topicID: topicID,
            postID: PostID(rawValue: topicID.rawValue),
            reactionID: "thank"
        )

        XCTAssertEqual(
            transport.requests.last?.url?.absoluteString,
            "https://www.v2ex.com/thank/topic/1240288?once=43517"
        )
    }

    /// 认不出来的表态不发请求。
    func testUnknownReactionSendsNothing() async {
        let transport = RecordingHTTPTransport(responding: "", byPath: ["/poll_once": "1"])

        do {
            _ = try await service(transport).submitPostReaction(
                topicID: topicID,
                postID: PostID(rawValue: 1),
                reactionID: "chicken"
            )
            XCTFail("站点没有这种表态")
        } catch {
            XCTAssertEqual(transport.requests.count, 0)
        }
    }

    /// 赞踩这个站没有，而且不能悄悄替换成感谢 —— 那要花用户的钱。
    func testVotingIsRefusedRatherThanTurnedIntoAThank() async {
        let transport = RecordingHTTPTransport(responding: "")

        do {
            _ = try await service(transport).vote(
                topicID: topicID,
                postID: PostID(rawValue: 1),
                direction: .up,
                isUndo: false
            )
            XCTFail("V2EX 没有赞踩")
        } catch {
            XCTAssertEqual(transport.requests.count, 0)
            XCTAssertTrue(
                error.localizedDescription.contains("铜币"),
                "报错里要说清代价：\(error.localizedDescription)"
            )
        }
    }

    /// 令牌取不回来（响应不是一串数字）就不提交 —— 拿一个假令牌去发，
    /// 换来的是一次必然失败的提交。
    func testAReplyIsNotSentWhenTheTokenLooksWrong() async {
        let transport = RecordingHTTPTransport(
            responding: "",
            byPath: ["/poll_once": "<!DOCTYPE html><html>登录页</html>"]
        )

        do {
            _ = try await service(transport).submitReply(
                topicID: topicID,
                submission: ReplySubmission(content: "内容", replyTo: nil)
            )
            XCTFail("令牌不对就不该提交")
        } catch {
            XCTAssertEqual(transport.requests.count, 1, "只发了取令牌那一次")
        }
    }

    // MARK: - 节点收藏

    /// 站点没有收藏接口，加减收藏是节点页上的一条链接（点了整页跳转）。
    /// 所以这里先取那一页、把链接读出来，再请求它 —— 一次都不用猜。
    func testFavouritingANodeFollowsTheLinkOnThePage() async throws {
        let page = """
        <html><body><div id="Main"><div class="box">
        <a href="/favorite/node/12?once=73510" class="tb">加入收藏</a>
        </div></div></body></html>
        """
        let transport = RecordingHTTPTransport(responding: page)

        try await service(transport).updateFavorite(
            forumID: V2EXEndpoint.forumID(key: "qna"),
            isFavorite: true
        )

        XCTAssertEqual(transport.requests.count, 2, "取一次页面，点一次链接")
        XCTAssertEqual(transport.requests[0].url?.absoluteString, "https://www.v2ex.com/go/qna")
        XCTAssertEqual(
            transport.requests[1].url?.absoluteString,
            "https://www.v2ex.com/favorite/node/12?once=73510",
            "链接要原样用，令牌也在里面"
        )
        XCTAssertEqual(transport.requests[1].httpMethod, "GET", "站点这一下就是个链接跳转")
    }

    /// 已经是想要的状态了就什么都不做 —— 页面上只有反方向那条链接。
    func testFavouritingAnAlreadyFavouritedNodeDoesNothing() async throws {
        let page = """
        <html><body><div id="Main">
        <a href="/unfavorite/node/12?once=73510">取消收藏</a>
        </div></body></html>
        """
        let transport = RecordingHTTPTransport(responding: page)

        try await service(transport).updateFavorite(
            forumID: V2EXEndpoint.forumID(key: "qna"),
            isFavorite: true
        )

        XCTAssertEqual(transport.requests.count, 1, "取了一次页面，没再点什么")
    }

    /// 两条链接都不在，多半是会话过期 —— 站点只把它们画给登录用户。
    func testAnAnonymousNodePageMeansSignInAgain() async throws {
        let transport = RecordingHTTPTransport(
            responding: "<html><body><div id=\"Main\">没有收藏链接</div></body></html>"
        )

        do {
            try await service(transport).updateFavorite(
                forumID: V2EXEndpoint.forumID(key: "qna"),
                isFavorite: true
            )
            XCTFail("读不到链接就不该当作成功")
        } catch {
            XCTAssertEqual(error as? ForumServiceError, .requiresLogin)
        }
    }

    /// 首页分类不是节点，收藏不了 —— 一个请求都不该发。
    func testAHomepageTabCannotBeFavourited() async {
        let transport = RecordingHTTPTransport(responding: "")

        do {
            try await service(transport).updateFavorite(
                forumID: V2EXEndpoint.tabForumID(key: "tech"),
                isFavorite: true
            )
            XCTFail("首页分类不是节点")
        } catch {
            XCTAssertTrue(transport.requests.isEmpty)
        }
    }

    /// 收藏的主题走 `/my/topics`。那一页用的是和 `/recent` 一模一样的
    /// `div.cell.item` 模板（登录态下跑探针确认过），所以这里拿那份夹具当响应 ——
    /// 验的是「同一套模板解析得动」，不是假装抓到了收藏页。
    func testFavoriteTopicsReuseTheSharedListingTemplate() async throws {
        let transport = RecordingHTTPTransport(responding: try html("v2ex-recent-topics"))

        let page = try await service(transport).favoriteTopics(
            folderID: V2EXEndpoint.implicitFavoriteFolderID,
            page: 2
        )

        XCTAssertEqual(
            transport.requests.first?.url?.absoluteString,
            "https://www.v2ex.com/my/topics?p=2"
        )
        XCTAssertEqual(page.topics.count, 3)
        XCTAssertTrue(page.topics.allSatisfy { $0.sourceForumName != nil })
    }

    /// 站点的收藏是平的一个列表，给一个隐含的收藏夹代表它 —— 空数组会让收藏页
    /// 永远是空的。界面上不会多冒出一条：`.topicFavoriteFolders` 关着。
    func testTopicFavouritesHaveOneImplicitFolder() async throws {
        let folders = try await service(RecordingHTTPTransport(responding: ""))
            .favoriteTopicFolders()

        XCTAssertEqual(folders.map(\.id), [V2EXEndpoint.implicitFavoriteFolderID])
        XCTAssertEqual(folders.first?.isDefault, true)
    }

    /// 收藏主题也是读页面上那条链接，而且要挑对 —— 主题页上同时挂着节点那条。
    func testFavouritingATopicFollowsTheTopicLinkNotTheNodeOne() async throws {
        let page = """
        <html><body><div id="Main">
        <a href="/favorite/topic/1240288?once=73510">收藏主题</a>
        </div><div id="Rightbar">
        <a href="/favorite/node/12?once=73510">收藏节点</a>
        </div></body></html>
        """
        let transport = RecordingHTTPTransport(responding: page)

        try await service(transport).updateTopicFavorite(
            topicID: TopicID(rawValue: 1_240_288),
            folderID: V2EXEndpoint.implicitFavoriteFolderID,
            isFavorite: true
        )

        XCTAssertEqual(transport.requests.count, 2)
        XCTAssertEqual(
            transport.requests[0].url?.absoluteString,
            "https://www.v2ex.com/t/1240288?p=1"
        )
        XCTAssertEqual(
            transport.requests[1].url?.absoluteString,
            "https://www.v2ex.com/favorite/topic/1240288?once=73510"
        )
    }

    // MARK: - 搜索

    /// 节点搜索在本地过滤，翻页也在本地做 —— 那份 JSON 是一次给全的。
    func testNodeSearchFiltersLocallyAndOnlyFetchesOnce() async throws {
        let nodes = """
        [{"name":"qna","title":"问与答","topics":1},
         {"name":"swift","title":"Swift","topics":2},
         {"name":"iphone","title":"iPhone","topics":3}]
        """
        let transport = RecordingHTTPTransport(responding: nodes)
        let service = service(transport)
        let request = try XCTUnwrap(ForumSearchRequest(query: "iph", kind: .forum))

        let page = try await service.search(request, page: 1)
        XCTAssertEqual(page.forums.map(\.id.key), ["iphone"])
        XCTAssertTrue(page.topics.isEmpty)

        // 第二次搜索不再拉一遍节点表。
        let again = try await service.search(
            try XCTUnwrap(ForumSearchRequest(query: "swift", kind: .forum)),
            page: 1
        )
        XCTAssertEqual(again.forums.map(\.id.key), ["swift"])
        XCTAssertEqual(transport.requests.count, 1)
    }

    /// 站点没有主题搜索。收下这一档就等于拿一份空结果冒充搜过了。
    func testTopicSearchIsRefusedWithAnExplanation() async {
        let transport = RecordingHTTPTransport(responding: "[]")
        let request = ForumSearchRequest(query: "swift", kind: .topicSubject)

        do {
            _ = try await service(transport).search(try XCTUnwrap(request), page: 1)
            XCTFail("V2EX 没有主题搜索")
        } catch {
            XCTAssertEqual(transport.requests.count, 0)
            XCTAssertTrue(
                error.localizedDescription.contains("节点"),
                error.localizedDescription
            )
        }
    }
}
