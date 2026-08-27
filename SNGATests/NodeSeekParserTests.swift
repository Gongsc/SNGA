import Foundation
import XCTest
@testable import SNGA

/// 解析器对着真实响应的夹具跑。
///
/// `Fixtures/nodeseek-category-daily.html` 是 2026-08-26 从 `/categories/daily` 抓下来的，
/// 只留了三条列表项和分页条。写解析器时先有它，而不是先想象一个结构。
final class NodeSeekParserTests: XCTestCase {

    private let parser = NodeSeekParser()
    private let daily = NodeSeekEndpoint.forumID(key: "daily")

    fileprivate func fixture(_ name: String) throws -> String {
        let url = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: name, withExtension: "html"),
            "测试包里没有夹具 \(name).html"
        )
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testParsesEveryTopicOnTheListPage() throws {
        let page = try parser.topicList(
            html: try fixture("nodeseek-category-daily"), forumID: daily, page: 1
        )

        XCTAssertEqual(page.topics.map(\.id.rawValue), [1033, 895_071, 895_094])
        XCTAssertEqual(page.topics.map(\.subject.isEmpty), [false, false, false])
        XCTAssertEqual(page.page, 1)
    }

    func testReadsAuthorReplyCountAndTime() throws {
        let page = try parser.topicList(
            html: try fixture("nodeseek-category-daily"), forumID: daily, page: 1
        )
        let first = try XCTUnwrap(page.topics.first)

        XCTAssertEqual(first.author, "斯巴达")
        XCTAssertEqual(first.authorUID, 1769)
        XCTAssertEqual(first.replyCount, 2905)
        XCTAssertNotNil(first.lastReplyAt)
    }

    /// 零回复的帖子不能被当成解析失败。
    func testAZeroReplyTopicStillParses() throws {
        let page = try parser.topicList(
            html: try fixture("nodeseek-category-daily"), forumID: daily, page: 1
        )
        let last = try XCTUnwrap(page.topics.last)

        XCTAssertEqual(last.id.rawValue, 895_094)
        XCTAssertEqual(last.replyCount, 0)
        XCTAssertFalse(last.isPinned)
    }

    /// 置顶只以一个图标的 title 出现，没有别的标记。
    func testPinnedTopicIsRecognized() throws {
        let page = try parser.topicList(
            html: try fixture("nodeseek-category-daily"), forumID: daily, page: 1
        )

        XCTAssertEqual(page.topics.map(\.isPinned), [true, false, false])
    }

    /// 每条自带分类 —— 综合首页会混着各分类的帖子，不能一律算成当前列表的。
    func testEachTopicCarriesItsOwnCategory() throws {
        let page = try parser.topicList(
            html: try fixture("nodeseek-category-daily"),
            forumID: NodeSeekEndpoint.forumID(key: NodeSeekEndpoint.homeKey),
            page: 1
        )

        XCTAssertEqual(page.topics.map(\.forumID), [daily, daily, daily])
        XCTAssertEqual(page.topics.first?.sourceForumName, "日常")
    }

    /// 总页数从分页条里最大的页码读。
    ///
    /// **不能**看「下一页」按钮在不在：站点翻过尾页时仍然渲染它，靠它判断会一直往下翻。
    func testTotalPagesComesFromTheHighestPageNumber() throws {
        let page = try parser.topicList(
            html: try fixture("nodeseek-category-daily"), forumID: daily, page: 1
        )

        XCTAssertEqual(page.totalPages, 100, "末页按钮长成「..100」，页码在 href 里")
        XCTAssertTrue(page.hasMore)
    }

    func testLastPageHasNoMore() throws {
        let page = try parser.topicList(
            html: try fixture("nodeseek-category-daily"), forumID: daily, page: 100
        )

        XCTAssertFalse(page.hasMore)
    }

    /// 页面结构变了要报得出来，而不是安静地给一个空列表。
    func testAPageWithoutAnyItemIsAnError() {
        XCTAssertThrowsError(
            try parser.topicList(html: "<html><body></body></html>", forumID: daily, page: 1)
        ) { error in
            guard case .unexpectedPage = error as? ForumServiceError else {
                return XCTFail("应当是 unexpectedPage，实际是 \(error)")
            }
        }
    }

    // MARK: - 路径解析

    func testPathHelpers() {
        XCTAssertEqual(NodeSeekParser.topicID(fromPath: "/post-857694-2")?.rawValue, 857_694)
        XCTAssertEqual(NodeSeekParser.topicID(fromPath: "/post-1033")?.rawValue, 1033)
        XCTAssertNil(NodeSeekParser.topicID(fromPath: "/space/1769"))
        XCTAssertEqual(NodeSeekParser.uid(fromPath: "/space/1769"), 1769)
        XCTAssertEqual(NodeSeekParser.forumID(fromPath: "/categories/daily"), daily)
        XCTAssertEqual(NodeSeekParser.page(fromPath: "/categories/daily/page-100"), 100)
    }
}

/// 帖子页。夹具取自 `/post-857694-1` 的真实响应，留了标题、主楼和两条回复。
extension NodeSeekParserTests {

    private func threadFixture() throws -> ThreadPage {
        try NodeSeekParser().threadPage(
            html: try fixture("nodeseek-post"),
            topicID: TopicID(rawValue: 857_694),
            page: 1
        )
    }

    /// 主楼在 `.nsk-post` 里、回复在 `.comment-container` 里，两块要一起收上来。
    func testOpeningPostAndRepliesArriveTogether() throws {
        let page = try threadFixture()

        XCTAssertEqual(page.posts.count, 3, "主楼 + 两条回复")
        XCTAssertEqual(page.posts.map(\.floor), [0, 1, 2], "主楼是第 0 层")
    }

    func testEachFloorCarriesItsAuthorAndTime() throws {
        let page = try threadFixture()
        let opening = try XCTUnwrap(page.posts.first)

        XCTAssertEqual(opening.author, "Monkeypox")
        XCTAssertEqual(opening.authorUID, 57815)
        XCTAssertEqual(opening.id.rawValue, 11_697_742, "楼层身份是 data-comment-id")
        XCTAssertNotNil(opening.postedAt)
        XCTAssertEqual(opening.avatarURL?.absoluteString,
                       "https://www.nodeseek.com/avatar/57815.png")
    }

    func testTopicTakesItsTitleAndCategoryFromThePage() throws {
        let page = try threadFixture()

        XCTAssertEqual(page.topic.subject, "【投票】大学流量卡哪家好")
        XCTAssertEqual(page.topic.forumID, NodeSeekEndpoint.forumID(key: "daily"))
        XCTAssertEqual(page.topic.sourceForumName, "日常")
        XCTAssertEqual(page.topic.author, "Monkeypox", "楼主取自主楼")
    }

    func testFloorBodyIsKept() throws {
        let page = try threadFixture()
        let reply = try XCTUnwrap(page.posts.first { $0.floor == 1 })

        XCTAssertTrue(reply.html.contains("移动"), reply.html)
    }

    /// 正文是别人写的，要进 WKWebView —— 脚本和事件属性必须清掉。
    func testScriptsAndEventAttributesAreStripped() throws {
        let hostile = """
        <html><body><div class="nsk-post">
        <div id="0" data-comment-id="1" class="content-item">
        <a href="/space/1" class="author-name">恶意</a>
        <article class="post-content">
          <p onclick="steal()">正文</p>
          <script>steal()</script>
          <iframe src="https://example.com"></iframe>
        </article></div></div></body></html>
        """
        let page = try NodeSeekParser().threadPage(
            html: hostile, topicID: TopicID(rawValue: 1), page: 1
        )
        let html = try XCTUnwrap(page.posts.first?.html)

        XCTAssertFalse(html.contains("<script"), html)
        XCTAssertFalse(html.contains("onclick"), html)
        XCTAssertFalse(html.contains("<iframe"), html)
        XCTAssertTrue(html.contains("正文"), "正文本身要留着")
    }

    /// 只有一页时没有分页条，不能因此报错。
    func testASinglePageThreadHasNoMore() throws {
        let page = try threadFixture()

        XCTAssertEqual(page.totalPages, 1)
        XCTAssertFalse(page.hasMore)
    }

    func testAPageWithoutFloorsIsAnError() {
        XCTAssertThrowsError(
            try NodeSeekParser().threadPage(
                html: "<html><body></body></html>", topicID: TopicID(rawValue: 1), page: 1
            )
        ) { error in
            guard case .unexpectedPage = error as? ForumServiceError else {
                return XCTFail("应当是 unexpectedPage，实际是 \(error)")
            }
        }
    }
}

/// 用户资料。夹具是 `/api/account/getInfo/57815?readme=1` 的真实响应。
extension NodeSeekParserTests {

    private func profileFixture() throws -> Profile {
        let url = try XCTUnwrap(
            Bundle(for: NodeSeekParserTests.self)
                .url(forResource: "nodeseek-account-info", withExtension: "json")
        )
        return try NodeSeekParser().profile(json: try Data(contentsOf: url))
    }

    func testProfileReadsIdentityAndCounts() throws {
        let profile = try profileFixture()

        XCTAssertEqual(profile.uid, 57815)
        XCTAssertFalse(profile.displayName.isEmpty)
        XCTAssertEqual(profile.avatarURL?.absoluteString,
                       "https://www.nodeseek.com/avatar/57815.png")
        XCTAssertNotNil(profile.registeredAt)
        XCTAssertNotNil(profile.postCount)
        XCTAssertNotNil(profile.followerCount)
    }

    /// 站点有两种货币，别混。鸡腿（coin）是花出去的，星辰（stardust）是收到的。
    func testTheTwoCurrenciesLandInDifferentFields() throws {
        let profile = try profileFixture()

        XCTAssertNotNil(profile.money, "鸡腿")
        XCTAssertNotNil(profile.fame, "星辰")
    }

    /// 等级是个序号，显示成 Lv.N。
    func testRankBecomesALevelLabel() throws {
        let profile = try profileFixture()

        XCTAssertEqual(profile.userGroup, "Lv.4")
    }

    func testAResponseWithoutDetailIsAnError() {
        XCTAssertThrowsError(
            try NodeSeekParser().profile(json: Data(#"{"success":false}"#.utf8))
        ) { error in
            guard case .unexpectedPage = error as? ForumServiceError else {
                return XCTFail("应当是 unexpectedPage，实际是 \(error)")
            }
        }
    }
}

/// 签到。响应体里的话才是结论，状态码只是附带 —— 重复签到答的是 HTTP 500。
extension NodeSeekParserTests {

    func testSuccessfulCheckInCarriesTheSitesOwnWords() throws {
        let result = try NodeSeekParser().checkInResult(
            json: Data(#"{"success":true,"message":"签到成功，获得 5 个鸡腿"}"#.utf8)
        )

        guard case let .success(message) = result else {
            return XCTFail("应当是成功，实际是 \(result)")
        }
        XCTAssertEqual(message, "签到成功，获得 5 个鸡腿")
    }

    /// 已经签过不是错误 —— 报成错会让界面一直催用户去签。
    func testRepeatCheckInIsNotAFailure() throws {
        let result = try NodeSeekParser().checkInResult(
            json: Data(#"{"success":false,"message":"今天已经签到过了"}"#.utf8)
        )

        guard case let .alreadyCheckedIn(message) = result else {
            return XCTFail("应当是已签到，实际是 \(result)")
        }
        XCTAssertEqual(message, "今天已经签到过了")
    }

    /// 连一句话都没有就真的不知道结果了，这时候才该报错。
    func testAnEmptyAnswerIsAnError() {
        XCTAssertThrowsError(
            try NodeSeekParser().checkInResult(json: Data(#"{"success":false}"#.utf8))
        )
    }

    /// 今天签没签从签到榜的 record 读，签到接口自己不给。
    func testStatisticsComeFromTheBoardRecord() throws {
        let signed = try NodeSeekParser().checkInStatistics(
            json: Data(#"{"success":true,"record":{"continuous":7,"total":123}}"#.utf8)
        )
        XCTAssertTrue(signed.isCheckedInToday)
        XCTAssertEqual(signed.consecutiveDays, 7)
        XCTAssertEqual(signed.totalDays, 123)

        let unsigned = try NodeSeekParser().checkInStatistics(
            json: Data(#"{"success":true}"#.utf8)
        )
        XCTAssertFalse(unsigned.isCheckedInToday, "榜上没有今天这条就是还没签")
    }
}

/// 页面内嵌的那段 base64 初始状态。
///
/// 它比抓 HTML 全：反应计数、我反应过没有、总页数、锁帖、已收藏，HTML 里一个都没有。
/// 先前一路搜 `member_id` 都搜不到身份，正是因为整段被 base64 编过。
extension NodeSeekParserTests {

    func testEmbeddedStateIsPreferredOverScraping() throws {
        let page = try NodeSeekParser().threadPage(
            html: try fixture("nodeseek-post-state"),
            topicID: TopicID(rawValue: 857_694),
            page: 1
        )

        XCTAssertEqual(page.posts.count, 3)
        XCTAssertEqual(page.posts.map(\.floor), [0, 1, 2])
        XCTAssertEqual(page.topic.subject, "【投票】大学流量卡哪家好")
        // 这两样只有内嵌状态里有。
        XCTAssertEqual(page.totalPages, 1)
        XCTAssertFalse(page.topic.isLocked)
    }

    /// 界面上的赞对应免费的「投喂」。加鸡腿和反对都要花读者的钱，不在这里露出来。
    func testReactionCountsComeFromTheFreeOne() throws {
        let page = try NodeSeekParser().threadPage(
            html: try fixture("nodeseek-post-state"),
            topicID: TopicID(rawValue: 857_694),
            page: 1
        )
        let opening = try XCTUnwrap(page.posts.first)

        XCTAssertEqual(opening.upvoteCount, 0)
        XCTAssertNil(opening.userVote, "没投喂过就是没有")
        XCTAssertEqual(opening.downvoteCount, 0, "反对要花两个鸡腿，界面上不给这个入口")
    }

    /// 正文仍然取渲染好的 HTML —— 内嵌状态给的是 Markdown 原文，应用还没有渲染器。
    func testBodiesStillComeFromTheRenderedHTML() throws {
        let page = try NodeSeekParser().threadPage(
            html: try fixture("nodeseek-post-state"),
            topicID: TopicID(rawValue: 857_694),
            page: 1
        )

        XCTAssertFalse(try XCTUnwrap(page.posts.first).html.isEmpty)
    }

    /// 解不开就退回抓 HTML —— `nodeseek-post.html` 是不含内嵌状态的那份。
    func testScrapingStillWorksWhenTheStateIsMissing() throws {
        let page = try NodeSeekParser().threadPage(
            html: try fixture("nodeseek-post"),
            topicID: TopicID(rawValue: 857_694),
            page: 1
        )

        XCTAssertEqual(page.posts.count, 3)
        XCTAssertEqual(page.topic.subject, "【投票】大学流量卡哪家好")
    }

    /// 匿名页面里 `user` 是 null，读不出编号。
    func testAnonymousPageHasNoSignedInUser() throws {
        XCTAssertNil(
            NodeSeekParser.signedInUserID(inHTML: try fixture("nodeseek-post-state"))
        )
    }

    func testSignedInUserIsReadFromTheState() throws {
        // 造一份带 user 的状态，字段名照站点的样子。
        let json = #"{"pageType":"post","user":{"uid":66675,"name":"someone"}}"#
        let encoded = Data(json.utf8).base64EncodedString()
        let html = "<html><body><script>var d = \"\(encoded)\";</script></body></html>"

        XCTAssertEqual(NodeSeekParser.signedInUserID(inHTML: html), 66675)
    }
}

/// 写操作的确认。站点把结论放在响应体里，状态码只是附带。
extension NodeSeekParserTests {

    func testASuccessfulWritePassesQuietly() throws {
        try NodeSeekParser().confirmWrite(
            // 分隔符用两个井号：正文里的 "#3 会把单井号的原始字符串提前收掉。
            json: Data(##"{"success":true,"redirect":"/post-1-1","redirectHash":"#3"}"##.utf8),
            what: "回复"
        )
    }

    /// 失败时把站点自己的话原样抛出去 —— 换成自己编的会把原因盖掉。
    func testAFailedWriteCarriesTheSitesReason() {
        XCTAssertThrowsError(
            try NodeSeekParser().confirmWrite(
                json: Data(#"{"success":false,"message":"评论间隔太短，请稍后再试"}"#.utf8),
                what: "回复"
            )
        ) { error in
            guard case let .restricted(message) = error as? ForumServiceError else {
                return XCTFail("应当是 restricted，实际是 \(error)")
            }
            XCTAssertEqual(message, "评论间隔太短，请稍后再试")
        }
    }

    func testAWriteWithoutAnyReasonStillFails() {
        XCTAssertThrowsError(
            try NodeSeekParser().confirmWrite(json: Data("{}".utf8), what: "回复")
        )
    }
}

/// 用户动态。夹具是 `/api/content/list-discussions` 和 `list-comments` 的真实响应，
/// 各截前三条。
extension NodeSeekParserTests {

    private func activityData(_ name: String) throws -> Data {
        let url = try XCTUnwrap(
            Bundle(for: NodeSeekParserTests.self).url(forResource: name, withExtension: "json"),
            "测试包里没有夹具 \(name).json"
        )
        return try Data(contentsOf: url)
    }

    func testTopicActivitiesCarryTitleAndTopic() throws {
        let page = try NodeSeekParser().userActivities(
            json: try activityData("nodeseek-activities-discussions"),
            kind: .topics,
            page: 1
        )

        XCTAssertEqual(page.kind, .topics)
        XCTAssertEqual(page.activities.count, 3)
        let first = try XCTUnwrap(page.activities.first)
        XCTAssertEqual(first.topicID, TopicID(rawValue: 875_041))
        XCTAssertEqual(first.subject, "听说Gemini Flash 3.7 但效果不错，所以哪里可以低成本的找到Token呢？")
        // 主题接口不给正文，摘要该是空的而不是空串。
        XCTAssertNil(first.excerpt)
    }

    func testCommentActivitiesCarryTheirText() throws {
        let page = try NodeSeekParser().userActivities(
            json: try activityData("nodeseek-activities-comments"),
            kind: .replies,
            page: 1
        )

        XCTAssertEqual(page.activities.count, 3)
        let first = try XCTUnwrap(page.activities.first)
        XCTAssertEqual(first.topicID, TopicID(rawValue: 884_844))
        XCTAssertEqual(first.subject, "gpt的降智已经蔓延到网页版了")
        XCTAssertEqual(first.excerpt, "看看你是不是网页用量超了？网页用量超了就会自动降级为mini模型。")
        // floor_id 是楼层序号不是评论编号，不该被当成 PostID。
        XCTAssertNil(first.postID)
    }

    /// 同一个帖子回了两层，两条动态得是两条，不能因为 post_id 相同就撞成一条。
    func testTwoRepliesInOneTopicStayTwoRows() throws {
        let page = try NodeSeekParser().userActivities(
            json: Data(#"""
            {"success":true,"comments":[
              {"post_id":1,"title":"同一个帖子","floor_id":3,"text":"三楼"},
              {"post_id":1,"title":"同一个帖子","floor_id":9,"text":"九楼"}
            ]}
            """#.utf8),
            kind: .replies,
            page: 1
        )

        XCTAssertEqual(Set(page.activities.map(\.id)).count, 2)
    }

    /// 满页就还有下一页，不满就是最后一页 —— 站点不给总数，只能这么推。
    func testAFullPageMeansThereIsMore() throws {
        func page(ofCount count: Int) throws -> UserActivityPage {
            let items = (1...count)
                .map { #"{"post_id":\#($0),"title":"第 \#($0) 条"}"# }
                .joined(separator: ",")
            return try NodeSeekParser().userActivities(
                json: Data(#"{"success":true,"discussions":[\#(items)]}"#.utf8),
                kind: .topics,
                page: 2
            )
        }

        let full = try page(ofCount: NodeSeekEndpoint.activitiesPerPage)
        XCTAssertTrue(full.hasMore)
        XCTAssertEqual(full.totalPages, 3)

        let partial = try page(ofCount: NodeSeekEndpoint.activitiesPerPage - 1)
        XCTAssertFalse(partial.hasMore)
        XCTAssertEqual(partial.totalPages, 2)
    }

    /// 站点挡下批量抓取时会回一句像是参数错了的话。当成空列表就会把「拿不到」
    /// 显示成「没有动态」，所以必须抛出来。
    func testTheSitesAntiScrapingDecoyBecomesAnError() throws {
        XCTAssertThrowsError(
            try NodeSeekParser().userActivities(
                json: try activityData("nodeseek-gated-decoy"),
                kind: .topics,
                page: 1
            )
        ) { error in
            guard case let .restricted(message) = error as? ForumServiceError else {
                return XCTFail("应当是 restricted，实际是 \(error)")
            }
            XCTAssertTrue(message.contains("防抓取"), "错误里得说清是被站点挡了：\(message)")
        }
    }

    /// 未登录和被挡是两种毛病，报成同一种会把人引去做没用的事：
    /// 前者重新登录就好，后者登录了也可能还是不行。
    func testNotBeingSignedInIsReportedAsSuchAndNotAsScraping() {
        XCTAssertThrowsError(
            try NodeSeekParser().userActivities(
                json: Data(#"{"message":"USER NOT FOUND","status":404,"success":false}"#.utf8),
                kind: .topics,
                page: 1
            )
        ) { error in
            XCTAssertEqual(error as? ForumServiceError, .requiresLogin)
        }
    }

    /// 认不出来的失败别硬塞进那两类里 —— 冒认成「被挡」会让人白折腾。
    func testAnUnfamiliarFailureIsNotDressedUpAsScraping() {
        XCTAssertThrowsError(
            try NodeSeekParser().userActivities(
                json: Data(#"{"success":false,"message":"服务器开小差了"}"#.utf8),
                kind: .topics,
                page: 1
            )
        ) { error in
            if case let .restricted(message) = error as? ForumServiceError {
                XCTAssertFalse(message.contains("防抓取"), "不该冒认成被挡：\(message)")
            }
        }
    }

    /// 真的是空的时候（翻过了最后一页）不该报错。
    func testAGenuinelyEmptyPageIsNotAnError() throws {
        let page = try NodeSeekParser().userActivities(
            json: Data(#"{"success":true,"discussions":[]}"#.utf8),
            kind: .topics,
            page: 99
        )

        XCTAssertTrue(page.activities.isEmpty)
        XCTAssertFalse(page.hasMore)
    }
}

/// 楼层反应。响应形如 `{success, current, coin, message}`。
extension NodeSeekParserTests {

    func testAReactionReturnsTheSitesNewCount() throws {
        let state = try NodeSeekParser().reactionState(
            json: Data(#"{"success":true,"current":42,"coin":7,"message":"投喂成功"}"#.utf8)
        )

        XCTAssertEqual(state.upvoteCount, 42)
        XCTAssertEqual(state.userVote, .up)
        // 站点没有反方向的计数。
        XCTAssertEqual(state.downvoteCount, 0)
    }

    /// 说成了却不说现在是多少，宁可报错也不要编一个 —— 编出来的数会写进界面上的计数。
    func testASuccessWithoutACountIsAnError() {
        XCTAssertThrowsError(
            try NodeSeekParser().reactionState(json: Data(#"{"success":true}"#.utf8))
        )
    }

    func testAFailedReactionCarriesTheSitesReason() {
        XCTAssertThrowsError(
            try NodeSeekParser().reactionState(
                json: Data(#"{"success":false,"message":"鸡腿不够了"}"#.utf8)
            )
        ) { error in
            XCTAssertEqual(error as? ForumServiceError, .restricted("鸡腿不够了"))
        }
    }
}

/// 反应与收藏的写入路径。这几条守的是「不作声就花掉用户的钱」这件事。
final class NodeSeekWriteGuardTests: XCTestCase {

    private func service() -> NodeSeekForumService {
        NodeSeekForumService(accountID: AccountID(), cookies: [], userAgent: "probe")
    }

    /// 「反对」要花 2 个鸡腿且撤不回来。哪怕有人绕过能力位调到这里，也得拦住 ——
    /// 门控在调用层，不能只在界面上。
    func testDownvotingIsRefusedBecauseItSpendsTheUsersCurrency() async {
        do {
            _ = try await service().vote(
                topicID: TopicID(rawValue: 1),
                postID: PostID(rawValue: 2),
                direction: .down,
                isUndo: false
            )
            XCTFail("反对不该发得出去")
        } catch {
            guard case let .unsupported(message) = error as? ForumServiceError else {
                return XCTFail("应当是 unsupported，实际是 \(error)")
            }
            XCTAssertTrue(message.contains("鸡腿"), "得说清代价：\(message)")
        }
    }

    /// 再点一次已经投喂过的楼层。反应不可撤销，默默再投一次等于把用户的点击
    /// 变成一次他没打算做的操作。
    func testUndoingAnUpvoteIsRefusedRatherThanRepeated() async {
        do {
            _ = try await service().vote(
                topicID: TopicID(rawValue: 1),
                postID: PostID(rawValue: 2),
                direction: .up,
                isUndo: true
            )
            XCTFail("撤销不该被当成再投一次")
        } catch {
            XCTAssertEqual(
                error as? ForumServiceError,
                .unsupported("NodeSeek 的投喂撤不回来")
            )
        }
    }

    /// 界面上不该出现那个会扣钱的按钮。
    func testTheDownvoteButtonIsNotOffered() {
        XCTAssertFalse(service().capabilities.contains(.postDownvote))
        XCTAssertTrue(service().capabilities.contains(.postVote))
    }
}
