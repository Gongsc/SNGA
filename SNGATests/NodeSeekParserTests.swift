import Foundation
import SwiftSoup
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

    /// 站点有两种货币，模型里正好两个位置：鸡腿走 `money`，星辰走 `fame`。
    ///
    /// 先前星辰是留空的 —— 那时「声望」那一段按有没有数据显示，星辰一填就会冒出
    /// 一个这个站没有的声望。那一段现在按站点开关，所以两个数都能带上，
    /// 各自的名字由站点资料给（见 `ProfileFieldsTests`）。
    func testBothCurrenciesAreCarried() throws {
        let profile = try profileFixture()

        XCTAssertNotNil(profile.money, "鸡腿")
        XCTAssertNotNil(profile.fame, "星辰")
        // 威望是 NGA 独有的，这个站没有。
        XCTAssertNil(profile.reputation)
    }

    /// 等级就是个数字。站点的资料页写的是「等级 1」，不是「Lv.1」。
    func testTheLevelIsCarriedAsAPlainNumber() throws {
        let profile = try profileFixture()

        XCTAssertEqual(profile.userGroup, "4")
    }

    /// 站点分开报主题帖和评论，两个都要带出来。
    func testTopicsAndCommentsAreCountedSeparately() throws {
        let profile = try profileFixture()

        XCTAssertNotNil(profile.postCount, "主题帖数")
        XCTAssertNotNil(profile.commentCount, "评论数目")
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
    ///
    /// 这里的 JSON 按真实响应写。先前那份是我照着猜的字段名编的（`continuous`、
    /// `total` 在 record 里），用例因此一直绿着 —— 咬的是一个不存在的东西。
    func testStatisticsComeFromTheBoardRecord() throws {
        let signed = try NodeSeekParser().checkInStatistics(
            json: Data(#"""
            {"list":[],"order":31,"total":1420,
             "record":{"id":5896765,"member_id":17429,"day_id":1420,"gain":14,
                       "created_at":"2026-08-26T01:02:03.000Z"}}
            """#.utf8)
        )
        XCTAssertTrue(signed.isCheckedInToday)
        // 站点不报这两个数。顶层的 order/total 说的是榜单，不是我的天数 ——
        // 拿它们充数会在界面上显示一个错的数字。
        XCTAssertNil(signed.consecutiveDays)
        XCTAssertNil(signed.totalDays)

        let unsigned = try NodeSeekParser().checkInStatistics(
            json: Data(#"{"list":[],"order":0,"total":1420}"#.utf8)
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

    /// 界面上的赞对应免费的「点赞」。加鸡腿和反对都要花读者的鸡腿。
    func testReactionCountsComeFromTheFreeOne() throws {
        let page = try NodeSeekParser().threadPage(
            html: try fixture("nodeseek-post-state"),
            topicID: TopicID(rawValue: 857_694),
            page: 1
        )
        let opening = try XCTUnwrap(page.posts.first)

        XCTAssertEqual(opening.upvoteCount, 0)
        XCTAssertNil(opening.userVote, "没点过赞就是没有")
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
            json: Data(#"{"success":true,"current":42,"coin":7,"message":"点赞成功"}"#.utf8)
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

    /// 再点一次已经点过赞的楼层。表态不可撤销，默默再点一次等于把用户的点击
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
                .unsupported("NodeSeek 的点赞撤不回来")
            )
        }
    }

    /// 界面上不该出现那个会扣钱的按钮。
    func testTheDownvoteButtonIsNotOffered() {
        XCTAssertFalse(service().capabilities.contains(.postDownvote))
        XCTAssertTrue(service().capabilities.contains(.postVote))
    }
}

/// 楼层正文外面那层文档。字体和配色都在这层里 —— 缺了它，NodeSeek 的正文会用
/// WebKit 的默认字体，深色模式下还是白底黑字。
extension NodeSeekParserTests {

    private func firstPostHTML() throws -> String {
        let page = try NodeSeekParser().threadPage(
            html: try fixture("nodeseek-post-state"),
            topicID: TopicID(rawValue: 1),
            page: 1
        )
        return try XCTUnwrap(page.posts.first?.html)
    }

    func testAPostBodyArrivesAsAThemedDocument() throws {
        let html = try firstPostHTML()

        XCTAssertTrue(html.hasPrefix("<!doctype html>"), "正文不是完整文档")
        XCTAssertTrue(html.contains("font:14px -apple-system"), "没有带上正文字体")
        XCTAssertTrue(html.contains("color:CanvasText"), "文字颜色没跟着系统走")
        XCTAssertTrue(html.contains("background:transparent"), "底色该透出宿主视图")
    }

    /// 主题是靠替换 `:root` 里那几个记号字符串实现的。记号不在，换主题会静默失效。
    func testThePostDocumentCarriesTheMarksThemingReplaces() throws {
        let html = try firstPostHTML()

        XCTAssertTrue(html.contains("color-scheme:light dark"))
        XCTAssertTrue(html.contains("--snga-accent:"))
        XCTAssertTrue(html.contains("--snga-quote-rail:"))

        // 真的换一次主题：记号对得上，值就该被换掉。
        let themed = AppTheme.midnight.resolved().applying(to: html)
        XCTAssertNotEqual(themed, html, "主题没能改动这份文档")
    }

    func testTheDocumentKeepsItsContentSecurityPolicy() throws {
        let html = try firstPostHTML()

        XCTAssertTrue(html.contains("default-src 'none'"), "正文是别人写的，默认得全禁")
        XCTAssertFalse(html.contains("script-src"), "不该给脚本开口子")
    }

    func testMarkdownBodiesGetCodeAndHeadingRules() throws {
        let html = try firstPostHTML()

        XCTAssertTrue(html.contains("ui-monospace"), "代码块没有等宽字体")
        XCTAssertTrue(html.contains("h1,h2,h3,h4,h5,h6"), "标题没有样式")
        // UBB 那套是 NGA 专有的，不该跟着进来。
        XCTAssertFalse(html.contains(".ubb-color-red"), "混进了 NGA 的 UBB 样式")
        XCTAssertFalse(html.contains(".nga-game-card"), "混进了 NGA 的游戏卡片样式")
    }
}

/// 私信、通知、收藏列表。夹具按实测的响应字段写。
extension NodeSeekParserTests {

    private func json(_ name: String) throws -> Data {
        try Data(contentsOf: try XCTUnwrap(
            Bundle(for: NodeSeekParserTests.self).url(forResource: name, withExtension: "json"),
            "测试包里没有夹具 \(name).json"
        ))
    }

    /// 列表给的是会话不是单条消息，所以身份必须是**对方**的编号 ——
    /// 打开会话要用它去请求 /message/with/{uid}。
    func testAConversationIsIdentifiedByTheOtherPerson() throws {
        let page = try NodeSeekParser().messages(
            json: try json("nodeseek-messages"), page: 1, currentUserID: 66675
        )

        XCTAssertEqual(page.folder, .privateMessages)
        XCTAssertEqual(page.messages.count, 2)

        // 第一条是别人发给我的：对方是发件人。
        let incoming = try XCTUnwrap(page.messages.first)
        XCTAssertEqual(incoming.id, MessageID(rawValue: 3515))
        XCTAssertEqual(incoming.sender, "Emmmc")
        XCTAssertEqual(incoming.preview, "晚点把配置发你")
        XCTAssertTrue(incoming.isUnread)

        // 第二条是我发出去的：对方是收件人，不能把自己认成对方。
        let outgoing = page.messages[1]
        XCTAssertEqual(outgoing.id, MessageID(rawValue: 63854))
        XCTAssertEqual(outgoing.sender, "someone")
    }

    /// 我自己刚发出去的消息不该显示成未读。
    func testMyOwnMessageIsNeverUnread() throws {
        let page = try NodeSeekParser().messages(
            json: Data(#"""
            {"success":true,"msgArray":[{"max_id":1,"sender_id":66675,"sender_name":"我",
             "receiver_id":3515,"receiver_name":"对方","content":"在吗","viewed":0,
             "created_at":"2026-08-26T11:20:31.000Z"}]}
            """#.utf8),
            page: 1,
            currentUserID: 66675
        )

        XCTAssertFalse(try XCTUnwrap(page.messages.first).isUnread)
    }

    func testReplyNotificationsCarryTopicAndFloor() throws {
        let items = try NodeSeekParser().notifications(
            json: try json("nodeseek-notifications-reply"), kind: .replyToMe, page: 1
        )

        XCTAssertEqual(items.count, 2)
        let first = try XCTUnwrap(items.first)
        XCTAssertEqual(first.kind, .reply)
        XCTAssertEqual(first.topicID, TopicID(rawValue: 884_844))
        XCTAssertEqual(first.subject, "gpt的降智已经蔓延到网页版了")
        XCTAssertTrue(first.preview.contains("回复了你"), first.preview)
        XCTAssertTrue(first.preview.contains("#7"), first.preview)
        XCTAssertTrue(first.isUnread)
        XCTAssertFalse(items[1].isUnread)
    }

    /// 两类通知走同一个解析，但落到不同的类型上 —— 混成一种，界面就分不出
    /// 「有人回你」和「有人 @ 你」。
    func testMentionsAndRepliesStayDifferentKinds() throws {
        let mentions = try NodeSeekParser().notifications(
            json: try json("nodeseek-notifications-atme"), kind: .atMe, page: 1
        )

        XCTAssertEqual(try XCTUnwrap(mentions.first).kind, .mention)
        XCTAssertTrue(try XCTUnwrap(mentions.first).preview.contains("提到了你"))
    }

    /// 通知带的楼层要能换算成正确的页码，否则点开跳到第一页。
    func testANotificationLinksToThePageItsFloorIsOn() throws {
        let items = try NodeSeekParser().notifications(
            json: try json("nodeseek-notifications-atme"), kind: .atMe, page: 1
        )
        let url = try XCTUnwrap(try XCTUnwrap(items.first).replyURL).absoluteString

        // 12 楼、每页 10 层 → 第 2 页。
        XCTAssertTrue(url.hasSuffix("-2"), "楼层没换算成页码：\(url)")
    }

    func testCollectedTopicsComeBackMarkedAsFavorites() throws {
        let page = try NodeSeekParser().favoriteTopics(
            json: try json("nodeseek-collections"), page: 1
        )

        XCTAssertEqual(page.topics.map(\.id), [
            TopicID(rawValue: 884_844), TopicID(rawValue: 875_041)
        ])
        XCTAssertTrue(page.topics.allSatisfy(\.isFavorite), "收藏列表里的话题当然是收藏过的")
    }

    /// 每页多少条没测出来，所以「空了才停」。非空一律再要一页。
    func testCollectionPagingStopsOnlyWhenAPageComesBackEmpty() throws {
        let full = try NodeSeekParser().favoriteTopics(
            json: try json("nodeseek-collections"), page: 1
        )
        XCTAssertTrue(full.hasMore)

        let empty = try NodeSeekParser().favoriteTopics(
            json: Data(#"{"success":true,"collections":[]}"#.utf8), page: 2
        )
        XCTAssertFalse(empty.hasMore)
        XCTAssertTrue(empty.topics.isEmpty)
    }

    /// 这几个列表也在防抓取的范围里，被挡时同样不能当成空列表。
    func testAGatedMessageListIsAnErrorNotAnEmptyInbox() {
        XCTAssertThrowsError(
            try NodeSeekParser().messages(
                json: Data(#"{"success":false,"message":"wrong page"}"#.utf8),
                page: 1,
                currentUserID: 1
            )
        )
    }
}

/// 正文里的 `nsapp://` 内嵌标记。夹具是一个真的带投票的帖子。
extension NodeSeekParserTests {

    private func pollPostBody() throws -> String {
        let page = try NodeSeekParser().threadPage(
            html: try fixture("nodeseek-post-poll"),
            topicID: TopicID(rawValue: 895_695),
            page: 1
        )
        return try XCTUnwrap(page.posts.first?.html)
    }

    /// 清洗会丢掉 data-href 和 javascript: 的 href，只剩锚点文字 ——
    /// 读者于是看到一行 `nsapp://vote?id=3027`。那不该出现在正文里。
    func testTheRawNSAppURLNeverReachesTheReader() throws {
        let html = try pollPostBody()

        XCTAssertFalse(html.contains("nsapp://"), "自定义协议漏到正文里了")
        XCTAssertFalse(html.contains("javascript:"), "伪协议漏到正文里了")
    }

    func testAPollMarkerBecomesAReadableLine() throws {
        let html = try pollPostBody()

        // 整句一起断言。只查「投票」两个字会蒙对 —— 这篇正文本来就有
        // 「根据投票结果」这句，标记就算没换掉也照样能查到。
        XCTAssertTrue(
            html.contains("投票 · 在浏览器中打开本帖参与"),
            "没告诉读者这里有个投票：\(html.prefix(400))"
        )
    }

    /// 正文其余部分不能因为换标记而丢掉。
    func testTheRestOfThePostSurvivesTheReplacement() throws {
        let html = try pollPostBody()

        XCTAssertTrue(html.contains("打开“隐私和安全”"), "正文被换没了")
        XCTAssertTrue(html.contains("cdn.nodeimage.com"), "正文里的图片没了")
    }

    /// 认不出来的内嵌类型也得换掉，但别瞎猜它是什么。
    func testAnUnknownEmbedIsReplacedWithoutGuessingWhatItIs() throws {
        let document = try SwiftSoup.parseBodyFragment(
            #"<article><a href="javascript://void(0)" data-href="nsapp://lottery?id=9">nsapp://lottery?id=9</a></article>"#
        )
        let article = try XCTUnwrap(try document.select("article").first())
        let html = try NodeSeekParser.sanitizedForTesting(article)

        XCTAssertFalse(html.contains("nsapp://"))
        XCTAssertFalse(html.contains("投票"), "认不出来的不该当成投票")
        XCTAssertTrue(html.contains("站点内嵌内容"))
    }
}

/// 投票。夹具按 `/api/vote/info/{id}` 的实测字段写。
extension NodeSeekParserTests {

    private func votePoll() throws -> TopicPoll {
        try NodeSeekParser().poll(
            json: try Data(contentsOf: try XCTUnwrap(
                Bundle(for: NodeSeekParserTests.self)
                    .url(forResource: "nodeseek-vote-info", withExtension: "json")
            )),
            topicID: TopicID(rawValue: 895_695)
        )
    }

    func testAPollCarriesItsOptionsAndCounts() throws {
        let poll = try votePoll()

        XCTAssertEqual(poll.id, TopicID(rawValue: 895_695))
        let group = try XCTUnwrap(poll.groups.first)
        XCTAssertEqual(group.title, "tg账号是否可以通过邮箱登录")
        XCTAssertEqual(group.options.map(\.id), ["13788", "13789", "13790", "13791", "13792"])
        XCTAssertEqual(group.options.map(\.voteCount), [41, 12, 7, 3, 25])
        XCTAssertEqual(poll.totalVoteCount, 88)
    }

    /// 站点报得出「我投的是哪个」，那就得显示出来 —— 否则投过的人会以为自己没投。
    func testTheOptionIAlreadyChoseIsMarked() throws {
        let options = try XCTUnwrap(try votePoll().groups.first).options

        XCTAssertEqual(options.filter(\.isChosen).map(\.id), ["13789"])
    }

    /// `multiple` 是个布尔值，不是「最多选几个」。单选时上限必须是 1，
    /// 放宽了就能一次投出站点不接受的组合。
    func testASingleChoicePollAllowsExactlyOneSelection() throws {
        let poll = try votePoll()

        XCTAssertEqual(poll.maximumSelectionsPerGroup, 1)
        XCTAssertTrue(poll.containsValidSelection(["13788"]))
        XCTAssertFalse(poll.containsValidSelection(["13788", "13789"]))
    }

    func testAMultipleChoicePollAllowsSeveral() throws {
        let poll = try NodeSeekParser().poll(
            json: Data(#"""
            {"success":true,"vote":{"id":1,"uid":2,"title":"多选","isPublic":true,
             "locked":false,"multiple":true,"items":[
               {"vote_item_id":10,"vote_id":1,"text":"甲","count":1,"voted":false},
               {"vote_item_id":11,"vote_id":1,"text":"乙","count":2,"voted":false}]}}
            """#.utf8),
            topicID: TopicID(rawValue: 1)
        )

        XCTAssertTrue(poll.containsValidSelection(["10", "11"]))
    }

    /// 站点给的是 locked 这个布尔值，没有截止时间。硬塞一个过去的日期能骗过判断，
    /// 但界面上就会冒出「截止于 1970 年」。
    func testALockedPollStopsAcceptingWithoutInventingADeadline() throws {
        let poll = try NodeSeekParser().poll(
            json: Data(#"""
            {"success":true,"vote":{"id":1,"uid":2,"title":"关了的","isPublic":true,
             "locked":true,"multiple":false,"items":[
               {"vote_item_id":10,"vote_id":1,"text":"甲","count":1,"voted":false}]}}
            """#.utf8),
            topicID: TopicID(rawValue: 1)
        )

        XCTAssertTrue(poll.isLocked)
        XCTAssertFalse(poll.isAcceptingResponses(at: .now))
        XCTAssertNil(poll.endsAt, "站点没给截止时间，就不该编一个")
    }

    func testAPollWithoutOptionsIsAnError() {
        XCTAssertThrowsError(
            try NodeSeekParser().poll(
                json: Data(#"{"success":true,"vote":{"id":1,"items":[]}}"#.utf8),
                topicID: TopicID(rawValue: 1)
            )
        )
    }

    // MARK: - 正文里的投票编号

    /// 投票编号在正文里，而且和话题编号是两回事。
    func testThePollIDComesFromTheMarkerNotTheTopic() throws {
        XCTAssertEqual(
            NodeSeekParser.pollID(inPageHTML: try fixture("nodeseek-post-poll")),
            3027
        )
    }

    /// **投票编号只能从原始页面里找。**
    ///
    /// 清洗会把标记换成给读者看的一句话，所以 `Post.html` 里根本没有它。先前这个
    /// 函数收的正是 `Post.html`，于是永远返回 nil，投票一次都没显示出来 ——
    /// 而当时的用例喂的是原始页面，跑的输入是生产代码永远不会给的那种，所以一直绿着。
    func testTheMarkerIsAlreadyGoneFromTheSanitizedPostBody() throws {
        let page = try NodeSeekParser().threadPage(
            html: try fixture("nodeseek-post-poll"),
            topicID: TopicID(rawValue: 895_695),
            page: 1
        )
        let openingBody = try XCTUnwrap(page.posts.first { $0.floor == 0 }?.html)

        XCTAssertFalse(
            openingBody.contains("nsapp://"),
            "清洗之后正文里还有标记，那说明替换没生效"
        )
        XCTAssertNil(
            NodeSeekParser.pollID(inPageHTML: openingBody),
            "从清洗过的正文里是找不到投票编号的 —— 这正是当初漏掉的那一步"
        )
    }

    func testAPageWithoutAPollHasNoPollID() {
        XCTAssertNil(NodeSeekParser.pollID(inPageHTML:
            #"<div class="content-item"><article>一篇没有投票的帖子</article></div>"#))
        // 别的 nsapp:// 标记不是投票。
        XCTAssertNil(NodeSeekParser.pollID(inPageHTML:
            #"<div class="content-item"><a data-href="nsapp://lottery?id=9">x</a></div>"#))
    }

    /// 回帖里贴的别人的投票不算这个话题的投票。
    func testOnlyTheOpeningPostsPollCounts() {
        let html = """
        <div class="content-item" id="0"><article>主楼没有投票</article></div>
        <div class="content-item" id="3">
          <article><a data-href="nsapp://vote?id=999">x</a></article>
        </div>
        """

        XCTAssertNil(NodeSeekParser.pollID(inPageHTML: html))
    }

    /// 另一个真帖子里的投票编号，确认认的不是写死的那一个。
    func testAnotherPostYieldsItsOwnPollID() throws {
        XCTAssertEqual(NodeSeekParser.pollID(inPageHTML: try fixture("nodeseek-post")), 2871)
    }
}


/// 投票提交。请求体的形状是这一整件事里唯一靠猜会出错的地方，所以直接断言
/// 发出去的字节。
final class NodeSeekPollSubmissionTests: XCTestCase {

    private func service(responding body: String) -> (NodeSeekForumService, RecordingHTTPTransport) {
        let transport = RecordingHTTPTransport(responding: body)
        return (
            NodeSeekForumService(
                accountID: AccountID(),
                cookies: [],
                transport: transport,
                userAgent: "probe"
            ),
            transport
        )
    }

    private func sentBody(_ transport: RecordingHTTPTransport) throws -> [String: Any] {
        let request = try XCTUnwrap(transport.requests.last)
        let data = try XCTUnwrap(request.httpBody)
        return try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }

    /// 站点要的是 `{"ids":[选项编号]}` —— 只有 ids，没有投票编号。
    func testAVoteIsSentAsAnArrayOfItemIDs() async throws {
        let (service, transport) = service(responding: #"{"success":true}"#)

        try await service.submitTopicPollVote(
            topicID: TopicID(rawValue: 895_695),
            optionIDs: ["13789"]
        )

        let body = try sentBody(transport)
        XCTAssertEqual(Array(body.keys), ["ids"], "请求体里只该有 ids")
        XCTAssertEqual(body["ids"] as? [Int64] ?? [], [13789])
        XCTAssertEqual(
            transport.requests.last?.url?.path,
            "/api/vote/voteforitem"
        )
    }

    /// 编号是数字。发成字符串站点未必认，而响应只有 success，认不出来也不会告诉你。
    func testItemIDsAreSentAsNumbersNotStrings() async throws {
        let (service, transport) = service(responding: #"{"success":true}"#)

        try await service.submitTopicPollVote(
            topicID: TopicID(rawValue: 1), optionIDs: ["13789"]
        )

        let raw = try XCTUnwrap(
            String(data: try XCTUnwrap(transport.requests.last?.httpBody), encoding: .utf8)
        )
        XCTAssertTrue(raw.contains("[13789]"), "编号被发成字符串了：\(raw)")
    }

    func testAMultipleChoiceVoteSendsEveryID() async throws {
        let (service, transport) = service(responding: #"{"success":true}"#)

        try await service.submitTopicPollVote(
            topicID: TopicID(rawValue: 1), optionIDs: ["10", "11", "12"]
        )

        XCTAssertEqual(try sentBody(transport)["ids"] as? [Int64] ?? [], [10, 11, 12])
    }

    /// 有一个编号认不出来时，宁可整单失败也不能少投一项 —— 少投出去的那一单，
    /// 和用户选的已经不是一回事了。
    func testAnUnreadableIDFailsTheWholeVoteRatherThanDroppingIt() async {
        let (service, transport) = service(responding: #"{"success":true}"#)

        do {
            try await service.submitTopicPollVote(
                topicID: TopicID(rawValue: 1), optionIDs: ["10", "不是数字"]
            )
            XCTFail("认不出来的编号不该被悄悄丢掉")
        } catch {
            XCTAssertTrue(transport.requests.isEmpty, "不该发出去")
        }
    }

    func testAnEmptySelectionIsRefusedBeforeSending() async {
        let (service, transport) = service(responding: #"{"success":true}"#)

        do {
            try await service.submitTopicPollVote(topicID: TopicID(rawValue: 1), optionIDs: [])
            XCTFail("空选择不该发出去")
        } catch {
            XCTAssertTrue(transport.requests.isEmpty)
        }
    }

    /// 站点把结论写在响应体里，状态码是 200 也可能是失败。
    func testAServerRefusalIsRaisedWithItsOwnWords() async {
        let (service, _) = service(responding: #"{"success":false,"message":"你已经投过了"}"#)

        do {
            try await service.submitTopicPollVote(
                topicID: TopicID(rawValue: 1), optionIDs: ["10"]
            )
            XCTFail("站点说失败了")
        } catch {
            XCTAssertEqual(error as? ForumServiceError, .restricted("你已经投过了"))
        }
    }
}

/// 投票从帖子页一路挂到主楼上。
///
/// 前面那些用例各测一段，接不接得起来是另一回事 —— 上一版就是每段都对、
/// 接起来不通：找编号那一步收的是清洗过的正文，标记早没了。
final class NodeSeekPollEndToEndTests: XCTestCase {

    private func pageHTML() throws -> String {
        try String(
            contentsOf: try XCTUnwrap(
                Bundle(for: NodeSeekParserTests.self)
                    .url(forResource: "nodeseek-post-poll", withExtension: "html")
            ),
            encoding: .utf8
        )
    }

    private func voteInfoJSON() throws -> String {
        try String(
            contentsOf: try XCTUnwrap(
                Bundle(for: NodeSeekParserTests.self)
                    .url(forResource: "nodeseek-vote-info", withExtension: "json")
            ),
            encoding: .utf8
        )
    }

    func testThePollReachesTheOpeningPost() async throws {
        let transport = RecordingHTTPTransport(
            responding: try pageHTML(),
            byPath: ["/api/vote/info/": try voteInfoJSON()]
        )
        let service = NodeSeekForumService(
            accountID: AccountID(),
            cookies: [],
            transport: transport,
            userAgent: "probe"
        )

        let page = try await service.threadPage(
            topicID: TopicID(rawValue: 895_695), page: 1, authorUID: nil
        )

        let opening = try XCTUnwrap(page.posts.first { $0.floor == 0 })
        let poll = try XCTUnwrap(opening.poll, "投票没挂到主楼上")
        XCTAssertEqual(try XCTUnwrap(poll.groups.first).options.count, 5)
        XCTAssertEqual(poll.totalVoteCount, 88)
    }

    /// 投票画出来之后，正文里那句退路就该撤掉 —— 留着既多余，说法也不对了
    /// （不用去浏览器，就在这儿投）。
    func testThePlaceholderGoesAwayOnceThePollRenders() async throws {
        let transport = RecordingHTTPTransport(
            responding: try pageHTML(),
            byPath: ["/api/vote/info/": try voteInfoJSON()]
        )
        let service = NodeSeekForumService(
            accountID: AccountID(), cookies: [], transport: transport, userAgent: "probe"
        )

        let page = try await service.threadPage(
            topicID: TopicID(rawValue: 895_695), page: 1, authorUID: nil
        )
        let opening = try XCTUnwrap(page.posts.first { $0.floor == 0 })

        XCTAssertNotNil(opening.poll, "前提：投票挂上了")
        XCTAssertFalse(
            opening.html.contains("在浏览器中打开本帖参与"),
            "投票都画出来了，正文里还留着那句退路"
        )
        // 正文其余部分不能跟着被删掉。
        XCTAssertTrue(opening.html.contains("打开“隐私和安全”"))
    }

    /// 取不到投票时那句退路要留着 —— 否则读者根本不知道这儿有个投票。
    func testThePlaceholderStaysWhenThePollCannotBeFetched() async throws {
        let transport = RecordingHTTPTransport(
            responding: try pageHTML(),
            byPath: ["/api/vote/info/": #"{"success":false}"#]
        )
        let service = NodeSeekForumService(
            accountID: AccountID(), cookies: [], transport: transport, userAgent: "probe"
        )

        let page = try await service.threadPage(
            topicID: TopicID(rawValue: 895_695), page: 1, authorUID: nil
        )
        let opening = try XCTUnwrap(page.posts.first { $0.floor == 0 })

        XCTAssertNil(opening.poll)
        XCTAssertTrue(
            opening.html.contains("在浏览器中打开本帖参与"),
            "投票没画出来，得留下点东西告诉读者这儿有一个"
        )
    }

    /// 按整句匹配，不是见 blockquote 就删 —— 正文里本来就可能有引用。
    func testRemovingThePlaceholderLeavesOtherQuotesAlone() {
        let html = """
        <blockquote>别人说的话</blockquote>        <blockquote>投票 · 在浏览器中打开本帖参与</blockquote>        <blockquote>另一段引用</blockquote>
        """

        let output = NodeSeekParser.removingEmbedPlaceholder(
            html, forNSAppURL: "nsapp://vote?id=3027"
        )

        XCTAssertFalse(output.contains("在浏览器中打开本帖参与"))
        XCTAssertTrue(output.contains("别人说的话"))
        XCTAssertTrue(output.contains("另一段引用"))
    }

    /// 编号得来自正文里的标记，不是话题编号 —— 拿话题编号去请求会取到别人的投票。
    func testThePollIsFetchedByTheMarkersIDNotTheTopicID() async throws {
        let transport = RecordingHTTPTransport(
            responding: try pageHTML(),
            byPath: ["/api/vote/info/": try voteInfoJSON()]
        )
        let service = NodeSeekForumService(
            accountID: AccountID(), cookies: [], transport: transport, userAgent: "probe"
        )

        _ = try await service.threadPage(
            topicID: TopicID(rawValue: 895_695), page: 1, authorUID: nil
        )

        let votePath = transport.requests.compactMap(\.url?.path).first { $0.contains("/vote/info/") }
        XCTAssertEqual(votePath, "/api/vote/info/3027")
    }

    /// 取不到投票时帖子照常显示。为一个附加内容让整页打不开，是把小毛病放大。
    func testAFailedPollFetchStillLeavesTheThreadReadable() async throws {
        let transport = RecordingHTTPTransport(
            responding: try pageHTML(),
            byPath: ["/api/vote/info/": #"{"success":false}"#]
        )
        let service = NodeSeekForumService(
            accountID: AccountID(), cookies: [], transport: transport, userAgent: "probe"
        )

        let page = try await service.threadPage(
            topicID: TopicID(rawValue: 895_695), page: 1, authorUID: nil
        )

        XCTAssertFalse(page.posts.isEmpty, "帖子被投票拖垮了")
        XCTAssertNil(page.posts.first { $0.floor == 0 }?.poll)
    }

    /// 投票接口只认这个头在不在。不带它一律 403，而 403 时投票就不显示 ——
    /// 正是它让投票一直出不来。
    func testEveryJSONRequestCarriesTheDynamicSignHeader() async throws {
        let transport = RecordingHTTPTransport(
            responding: try pageHTML(),
            byPath: ["/api/vote/info/": try voteInfoJSON()]
        )
        let service = NodeSeekForumService(
            accountID: AccountID(), cookies: [], transport: transport, userAgent: "probe"
        )

        _ = try await service.threadPage(
            topicID: TopicID(rawValue: 895_695), page: 1, authorUID: nil
        )

        let voteRequest = try XCTUnwrap(
            transport.requests.first { $0.url?.path.contains("/vote/info/") == true }
        )
        XCTAssertNotNil(
            voteRequest.value(forHTTPHeaderField: "x-dynamic-sign"),
            "少了这个头，站点回 403，投票就再也显示不出来"
        )
    }
}

/// 收藏话题。站点没有收藏夹，只有一个列表。
final class NodeSeekCollectionTests: XCTestCase {

    private func service(_ transport: RecordingHTTPTransport) -> NodeSeekForumService {
        NodeSeekForumService(
            accountID: AccountID(), cookies: [], transport: transport, userAgent: "probe"
        )
    }

    /// 返回空数组会让整个收藏功能停摆：收藏页永远是空的，星标也一声不吭地不干活 ——
    /// 应用里选中、收藏、计数全挂在「有一个收藏夹」上。所以给出一个隐含的。
    func testAFolderlessSiteStillOffersOneImplicitFolder() async throws {
        let folders = try await service(RecordingHTTPTransport(responding: "{}"))
            .favoriteTopicFolders()

        XCTAssertEqual(folders.count, 1)
        XCTAssertTrue(try XCTUnwrap(folders.first).isDefault, "得是默认的，否则选不中")
    }

    /// 界面不该冒出一个收藏夹条目让人选 —— 能力位关着。
    func testTheSiteStillDeclaresItHasNoFolders() {
        XCTAssertFalse(
            service(RecordingHTTPTransport(responding: "{}"))
                .capabilities.contains(.topicFavoriteFolders)
        )
    }

    /// 收藏是发给站点的，隐含的收藏夹编号只在应用内部用，不该出现在请求里。
    func testTheImplicitFolderIDNeverReachesTheSite() async throws {
        let transport = RecordingHTTPTransport(responding: #"{"success":true}"#)

        try await service(transport).updateTopicFavorite(
            topicID: TopicID(rawValue: 884_844),
            folderID: NodeSeekEndpoint.implicitCollectionID,
            isFavorite: true
        )

        let request = try XCTUnwrap(transport.requests.last)
        let body = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any]
        )
        XCTAssertEqual(Set(body.keys), ["postId", "action"])
        XCTAssertEqual(body["postId"] as? Int64, 884_844)
        XCTAssertEqual(body["action"] as? String, "add")
    }

    func testUnfavouritingSendsRemove() async throws {
        let transport = RecordingHTTPTransport(responding: #"{"success":true}"#)

        try await service(transport).updateTopicFavorite(
            topicID: TopicID(rawValue: 1),
            folderID: NodeSeekEndpoint.implicitCollectionID,
            isFavorite: false
        )

        let body = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: try XCTUnwrap(transport.requests.last?.httpBody)
            ) as? [String: Any]
        )
        XCTAssertEqual(body["action"] as? String, "remove")
    }

    /// 收藏夹的增删改仍然该拒绝 —— 站点没有这个东西。
    func testFolderManagementIsStillRefused() async {
        let s = service(RecordingHTTPTransport(responding: "{}"))

        do {
            _ = try await s.createTopicFavoriteFolder(name: "新", isPublic: false, isDefault: false)
            XCTFail("站点没有收藏夹，不该能新建")
        } catch {
            guard case .unsupported = error as? ForumServiceError else {
                return XCTFail("应当是 unsupported，实际是 \(error)")
            }
        }
    }
}

/// 要花鸡腿的两种表态：加鸡腿（1 个）和反对（2 个）。
extension NodeSeekParserTests {

    private func firstPost() throws -> Post {
        let page = try NodeSeekParser().threadPage(
            html: try fixture("nodeseek-post-state"),
            topicID: TopicID(rawValue: 1),
            page: 1
        )
        return try XCTUnwrap(page.posts.first)
    }

    /// 三种表态都要带出来：网页版把三个数并排摆在楼层右下角，少一个就对不上。
    func testAllThreeReactionsAreCarriedWithTheirPrice() throws {
        let reactions = try firstPost().reactions

        XCTAssertEqual(reactions.map(\.id), ["upvote", "like", "dislike"])
        // 站点自己的 JS 里，upvote 那颗按钮的 title 就是「点赞」。
        // 「投喂」是它对**加鸡腿**的说法（确认框写「是否投喂鸡腿」），两个词别接反。
        XCTAssertEqual(reactions.map(\.title), ["点赞", "加鸡腿", "反对"])
        XCTAssertEqual(
            reactions.map(\.cost),
            [nil, "花费 1 个鸡腿", "花费 2 个鸡腿"],
            "点赞免费，另外两种的价钱必须带出来 —— 界面靠它决定问不问"
        )
    }

    /// 三种表态站点都不给撤。界面据此禁掉已经点过的那一项。
    func testEveryPaidReactionIsMarkedIrreversible() throws {
        XCTAssertTrue(try firstPost().reactions.allSatisfy(\.isIrreversible))
    }

    /// 点赞免费，另外两种要花钱。界面靠这个区分「直接发」和「先问一次」。
    func testOnlyTheFreeReactionHasNoPrice() throws {
        let free = try firstPost().reactions.filter { $0.cost == nil }

        XCTAssertEqual(free.map(\.id), ["upvote"])
    }

    /// 「我点过没有」必须带出来。不可撤销的表态里，这一条是防止用户再花一次钱的唯一依据。
    func testWhetherIAlreadyReactedIsCarried() throws {
        let reactions = try NodeSeekParser().threadPage(
            html: try fixture("nodeseek-post-state"),
            topicID: TopicID(rawValue: 1),
            page: 1
        ).posts.flatMap(\.reactions)

        // 夹具里至少有一条能表达「点过」和「没点过」的区别。
        XCTAssertNotNil(reactions.first?.isChosen)
        XCTAssertEqual(reactions.filter { $0.count != nil }.isEmpty, false, "计数没带出来")
    }
}

/// 提交加鸡腿 / 反对。
final class NodeSeekPaidReactionTests: XCTestCase {

    private func service(_ transport: RecordingHTTPTransport) -> NodeSeekForumService {
        NodeSeekForumService(
            accountID: AccountID(), cookies: [], transport: transport, userAgent: "probe"
        )
    }

    func testAddingAChickenLegHitsTheRightEndpoint() async throws {
        let transport = RecordingHTTPTransport(responding: #"{"success":true,"current":4}"#)

        _ = try await service(transport).submitPostReaction(
            topicID: TopicID(rawValue: 1), postID: PostID(rawValue: 77), reactionID: "like"
        )

        let request = try XCTUnwrap(transport.requests.last)
        XCTAssertEqual(request.url?.path, "/api/statistics/like")
        let body = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any]
        )
        XCTAssertEqual(body["commentId"] as? Int64, 77)
        XCTAssertEqual(body["action"] as? String, "add")
    }

    func testDislikeHitsItsOwnEndpoint() async throws {
        let transport = RecordingHTTPTransport(responding: #"{"success":true,"current":1}"#)

        _ = try await service(transport).submitPostReaction(
            topicID: TopicID(rawValue: 1), postID: PostID(rawValue: 77), reactionID: "dislike"
        )

        XCTAssertEqual(transport.requests.last?.url?.path, "/api/statistics/dislike")
    }

    /// 响应里的 current 是这一种表态的计数，不是赞的计数。当成赞数返回会把界面上的
    /// 数字改错，所以这里什么都不返回，由调用方刷新页面拿准数。
    func testTheResponseCountIsNotPassedOffAsTheUpvoteCount() async throws {
        let state = try await service(
            RecordingHTTPTransport(responding: #"{"success":true,"current":99}"#)
        ).submitPostReaction(
            topicID: TopicID(rawValue: 1), postID: PostID(rawValue: 77), reactionID: "like"
        )

        XCTAssertNil(state)
    }

    /// 免费的点赞走 vote 那条路。从这里进来说明调用点串了 —— 放行会让它绕过界面的确认。
    func testTheFreeReactionIsRefusedHere() async {
        let transport = RecordingHTTPTransport(responding: #"{"success":true}"#)
        do {
            _ = try await service(transport).submitPostReaction(
                topicID: TopicID(rawValue: 1), postID: PostID(rawValue: 1), reactionID: "upvote"
            )
            XCTFail("点赞不该从这条路发出去")
        } catch {
            XCTAssertTrue(transport.requests.isEmpty)
        }
    }

    func testAnUnknownReactionIsRefusedBeforeSending() async {
        let transport = RecordingHTTPTransport(responding: #"{"success":true}"#)
        do {
            _ = try await service(transport).submitPostReaction(
                topicID: TopicID(rawValue: 1), postID: PostID(rawValue: 1), reactionID: "喜欢"
            )
            XCTFail("认不出来的表态不该发出去")
        } catch {
            XCTAssertTrue(transport.requests.isEmpty)
        }
    }

    /// 鸡腿不够之类的失败，把站点自己的话抛出去。
    func testAServerRefusalCarriesItsOwnWords() async {
        do {
            _ = try await service(
                RecordingHTTPTransport(responding: #"{"success":false,"message":"鸡腿不足"}"#)
            ).submitPostReaction(
                topicID: TopicID(rawValue: 1), postID: PostID(rawValue: 1), reactionID: "dislike"
            )
            XCTFail("站点说失败了")
        } catch {
            XCTAssertEqual(error as? ForumServiceError, .restricted("鸡腿不足"))
        }
    }
}

/// 列表上标题旁边的标记。
extension NodeSeekParserTests {

    private func dailyTopics() throws -> [Topic] {
        try parser.topicList(
            html: try fixture("nodeseek-category-daily"), forumID: daily, page: 1
        ).topics
    }

    func testPinnedAndAwardBadgesAreRead() throws {
        let topics = try dailyTopics()

        let pinned = try XCTUnwrap(topics.first { $0.badges.contains { $0.title == "置顶" } })
        XCTAssertTrue(pinned.isPinned, "置顶标记在，isPinned 也该跟着")
        XCTAssertEqual(
            pinned.badges.first { $0.title == "置顶" }?.systemImage,
            "pin.fill"
        )
        XCTAssertTrue(
            topics.contains { $0.badges.contains { $0.title == "推荐阅读" } },
            "推荐阅读没读出来"
        )
    }

    /// 没有标记的话题就是没有，不该凭空多出一个。
    func testAnOrdinaryTopicHasNoBadges() throws {
        XCTAssertTrue(
            try dailyTopics().contains { $0.badges.isEmpty },
            "所有话题都带上标记了，说明选择器抓过头"
        )
    }

    /// 标记不按名字一个个认。站点加新标记时认不出来也要照样显示，用它自己的说法。
    func testAnUnknownBadgeIsStillCarriedWithTheSitesWording() throws {
        let html = """
        <li class="post-list-item"><div class="post-list-content">
          <div class="post-title">
            <a href="/post-9-1">帖子</a>
            <span title="等级限制"><svg class="iconpark-icon whatever"></svg></span>
          </div>
          <div class="post-info"><span class="info-item info-author"><a href="/space/1">谁</a></span></div>
        </div></li>
        """
        let topic = try XCTUnwrap(
            try parser.topicList(html: html, forumID: daily, page: 1).topics.first
        )

        XCTAssertEqual(topic.badges.map(\.title), ["等级限制"])
        XCTAssertEqual(topic.badges.first?.systemImage, "tag", "认不出的用中性图标")
        XCTAssertFalse(topic.isPinned, "它不是置顶")
    }

    /// 同一个标记出现两次（图标和外层都带 title）只算一个。
    func testADuplicatedBadgeIsListedOnce() throws {
        let html = """
        <li class="post-list-item"><div class="post-list-content">
          <div class="post-title">
            <a href="/post-9-1">帖子</a>
            <span title="置顶"><svg class="iconpark-icon pined" title="置顶"></svg></span>
          </div>
          <div class="post-info"><span class="info-item info-author"><a href="/space/1">谁</a></span></div>
        </div></li>
        """
        let topic = try XCTUnwrap(
            try parser.topicList(html: html, forumID: daily, page: 1).topics.first
        )

        XCTAssertEqual(topic.badges.count, 1)
    }
}

/// 沙盒区的标记：等级限制和只读。这两个都**没有 title 属性** ——
/// 先前只找带 title 的元素，于是一个都读不到。
extension NodeSeekParserTests {

    private func sandboxTopics() throws -> [Topic] {
        try parser.topicList(
            html: try fixture("nodeseek-category-sandbox"),
            forumID: NodeSeekEndpoint.forumID(key: "sandbox"),
            page: 1
        ).topics
    }

    /// 锁图标后面跟的数字是要求的等级。原样显示成「1」谁也看不懂。
    func testTheLevelRestrictionSaysWhichLevel() throws {
        let restricted = try XCTUnwrap(
            try sandboxTopics().first { topic in
                topic.badges.contains { $0.title.contains("等级") }
            }
        )
        let badge = try XCTUnwrap(restricted.badges.first { $0.title.contains("等级") })

        XCTAssertEqual(badge.title, "等级 1 可见")
        XCTAssertEqual(badge.systemImage, "lock.fill")
    }

    /// 只读是文字标记，说明就在元素的文字里。
    func testTheReadOnlyBadgeIsReadFromItsText() throws {
        let readOnly = try XCTUnwrap(
            try sandboxTopics().first { topic in
                topic.badges.contains { $0.title == "只读" }
            }
        )

        XCTAssertTrue(readOnly.isLocked, "只读就是锁帖，能看不能回")
        XCTAssertTrue(readOnly.isPinned, "夹具里这条同时是置顶")
    }

    /// 一条列表项上可以同时挂好几个标记，别只读到第一个。
    func testSeveralBadgesOnOneTopicAllSurvive() throws {
        let topic = try XCTUnwrap(
            try sandboxTopics().first { $0.badges.count > 1 }
        )

        XCTAssertTrue(topic.badges.map(\.title).contains("置顶"))
        XCTAssertTrue(topic.badges.map(\.title).contains("只读"))
    }

    /// 没有标记的话题仍然是没有 —— 规则放宽之后最容易踩的就是把空节点当成标记。
    func testWideningTheRuleDidNotInventBadges() throws {
        XCTAssertTrue(
            try sandboxTopics().contains { $0.badges.isEmpty },
            "所有话题都带上标记了，说明把空元素也算进去了"
        )
    }

    /// 锁图标后面不是数字时照原话显示，不硬套「等级 N」。
    func testALockedBadgeThatIsNotALevelIsShownAsWritten() throws {
        let html = """
        <li class="post-list-item"><div class="post-list-content">
          <div class="post-title">
            <a href="/post-9-1">帖子</a>
            <span><svg><use href="#lock"></use></svg>仅作者可见</span>
          </div>
          <div class="post-info"><span class="info-item info-author"><a href="/space/1">谁</a></span></div>
        </div></li>
        """
        let topic = try XCTUnwrap(
            try parser.topicList(html: html, forumID: daily, page: 1).topics.first
        )

        XCTAssertEqual(topic.badges.map(\.title), ["仅作者可见"])
    }
}

extension NodeSeekParserTests {

    /// 标题块里空的元素不是标记。
    ///
    /// 规则从「带 title 的元素」放宽到「除标题链接外的每个元素」之后，这是最容易
    /// 踩的一步：站点的模板里会留下没有内容的占位元素，把它们当成标记，
    /// 每条话题后面就会挂上一串没有意义的图标。
    func testEmptyElementsInTheTitleBlockAreNotBadges() throws {
        let html = """
        <li class="post-list-item"><div class="post-list-content">
          <div class="post-title">
            <a href="/post-9-1">帖子</a>
            <span></span>
            <span>   </span>
            <span title="置顶"><svg><use href="#pin"></use></svg></span>
          </div>
          <div class="post-info"><span class="info-item info-author"><a href="/space/1">谁</a></span></div>
        </div></li>
        """
        let topic = try XCTUnwrap(
            try parser.topicList(html: html, forumID: daily, page: 1).topics.first
        )

        XCTAssertEqual(topic.badges.map(\.title), ["置顶"], "空元素被当成标记了")
    }
}

/// 标记旁边画不画字。
extension NodeSeekParserTests {

    private func sandboxBadges() throws -> [TopicBadge] {
        try parser.topicList(
            html: try fixture("nodeseek-category-sandbox"),
            forumID: NodeSeekEndpoint.forumID(key: "sandbox"),
            page: 1
        ).topics.flatMap(\.badges)
    }

    /// 等级那个数字必须画在图标旁边。完整说法留给提示，但屏幕上光有一把锁，
    /// 等于告诉读者「这帖有限制」却不说是什么限制。
    func testTheRequiredLevelIsShownNextToTheLock() throws {
        let badge = try XCTUnwrap(
            try sandboxBadges().first { $0.systemImage == "lock.fill" }
        )

        XCTAssertEqual(badge.value, "1", "锁旁边得有那个数字")
        XCTAssertEqual(badge.title, "等级 1 可见", "提示里给完整说法")
    }

    /// 站点画成文字的标记，我们也画文字。
    func testATextBadgeKeepsItsText() throws {
        let badge = try XCTUnwrap(try sandboxBadges().first { $0.title == "只读" })

        XCTAssertEqual(badge.value, "只读")
    }

    /// 站点只画图标的标记别硬加字 —— 一行里挂着「置顶」「推荐阅读」两串字，
    /// 标题就被挤没了。
    func testIconOnlyBadgesStayIconOnly() throws {
        for title in ["置顶", "推荐阅读"] {
            let badge = try XCTUnwrap(
                try sandboxBadges().first { $0.title == title }
                    ?? parser.topicList(
                        html: try fixture("nodeseek-category-daily"), forumID: daily, page: 1
                    ).topics.flatMap(\.badges).first { $0.title == title }
            )
            XCTAssertNil(badge.value, "「\(title)」站点只画图标，不该加字")
        }
    }
}

/// 看不了的帖子：站点答 404，真正的原因写在正文里。
extension NodeSeekParserTests {

    func testTheSitesOwnReasonIsRecovered() throws {
        let reason = NodeSeekParser.accessDeniedReason(
            inHTML: try fixture("nodeseek-post-denied")
        )

        XCTAssertEqual(reason, "本帖需要注册用户才能查看😭")
    }

    /// 等级不够时站点说的是另一句，而且里面写着该怎么办。原样带出去，别换成自己编的。
    func testALevelRequirementIsPassedThroughWordForWord() {
        let html = """
        <div id="nsk-body-left"><div style="font-size:2rem"><div>
        查看本帖需要Lv2，您的权限不足😑，请赚取🍗升级您的用户等级
        </div></div></div>
        """

        XCTAssertEqual(
            NodeSeekParser.accessDeniedReason(inHTML: html),
            "查看本帖需要Lv2，您的权限不足😑，请赚取🍗升级您的用户等级"
        )
    }

    /// 正常的帖子页不能被当成拒绝页 —— 那样每一次成功都会变成一句报错。
    ///
    /// 用带 `#nsk-body-left` 的那份夹具：换成没有这个容器的，函数在上一道 guard
    /// 就返回了，「楼层还在就不是拒绝页」这条根本没被走到（第一版就是这样，
    /// 变异测试把它照出来了）。
    func testANormalThreadPageIsNotMistakenForARefusal() throws {
        let html = try fixture("nodeseek-post-poll")

        XCTAssertTrue(html.contains("nsk-body-left"), "前提：这份夹具带那个容器")
        XCTAssertNil(NodeSeekParser.accessDeniedReason(inHTML: html))
    }

    /// 楼层很短的正常帖子最危险：文字够短，能溜过「一句话才是解释」那道判断。
    /// 拦住它的是「楼层还在就不是拒绝页」。
    func testAVeryShortPostIsStillNotARefusal() {
        let html = """
        <div id="nsk-body-left">
          <div class="content-item" data-comment-id="1"><article class="post-content">好</article></div>
        </div>
        """

        XCTAssertNil(NodeSeekParser.accessDeniedReason(inHTML: html))
    }

    /// 认错地方就会把整页文字当成「原因」。一句话才是解释。
    func testAWallOfTextIsNotAReason() {
        let html = "<div id=\"nsk-body-left\">\(String(repeating: "很长的正文。", count: 60))</div>"

        XCTAssertNil(NodeSeekParser.accessDeniedReason(inHTML: html))
    }

    func testAPageWithoutThatContainerHasNoReason() {
        XCTAssertNil(NodeSeekParser.accessDeniedReason(inHTML: "<html><body>随便</body></html>"))
    }
}

/// 打不开的帖子，从请求到错误信息这一整条。
final class NodeSeekAccessDeniedTests: XCTestCase {

    private func deniedHTML() throws -> String {
        try String(
            contentsOf: try XCTUnwrap(
                Bundle(for: NodeSeekParserTests.self)
                    .url(forResource: "nodeseek-post-denied", withExtension: "html")
            ),
            encoding: .utf8
        )
    }

    /// 站点用 404 承载「不让看」。报成「服务暂时不可用（HTTP 404）」是两重错：
    /// 站点没坏，而且它那句话里写着该怎么办。
    func testOpeningARestrictedTopicRaisesTheSitesSentence() async throws {
        let service = NodeSeekForumService(
            accountID: AccountID(),
            cookies: [],
            transport: RecordingHTTPTransport(responding: try deniedHTML(), status: 404),
            userAgent: "probe"
        )

        do {
            _ = try await service.threadPage(
                topicID: TopicID(rawValue: 898_539), page: 1, authorUID: nil
            )
            XCTFail("这帖看不了，不该当成成功")
        } catch {
            XCTAssertEqual(
                error as? ForumServiceError,
                .restricted("本帖需要注册用户才能查看😭")
            )
        }
    }

    /// 正文里没有可用解释的 404 仍然报状态码 —— 那种是真的出错了。
    func testAPlain404StillReportsItsStatus() async throws {
        let service = NodeSeekForumService(
            accountID: AccountID(),
            cookies: [],
            transport: RecordingHTTPTransport(responding: "<html><body></body></html>", status: 404),
            userAgent: "probe"
        )

        do {
            _ = try await service.threadPage(
                topicID: TopicID(rawValue: 1), page: 1, authorUID: nil
            )
            XCTFail("应该报错")
        } catch {
            XCTAssertEqual(error as? ForumServiceError, .server(404))
        }
    }
}

/// 正文里的表情和链接。站点用的全是相对地址。
extension NodeSeekParserTests {

    private func pollPostBodyHTML() throws -> String {
        let page = try parser.threadPage(
            html: try fixture("nodeseek-post-poll"),
            topicID: TopicID(rawValue: 895_695),
            page: 1
        )
        return page.posts.map(\.html).joined()
    }

    /// 表情是 `<img class="sticker" src="/static/…">`。清洗白名单按协议校验属性，
    /// 相对地址没有协议 —— 不先转成绝对地址，`src` 会被整个丢掉，表情全变裂图。
    func testStickersKeepTheirImageSource() throws {
        let html = try pollPostBodyHTML()

        XCTAssertTrue(
            html.contains("https://www.nodeseek.com/static/image/sticker/"),
            "表情的地址没了或者没转成绝对地址"
        )
        XCTAssertFalse(html.contains("src=\"/static/"), "还留着相对地址")
    }

    /// 类名要留住，否则没法限制表情尺寸 —— 一张大图会把整层楼撑开。
    func testStickersKeepTheClassThatSizesThem() throws {
        XCTAssertTrue(try pollPostBodyHTML().contains("class=\"sticker\""))
        // 尺寸规则也得真的在文档里。
        XCTAssertTrue(try pollPostBodyHTML().contains(".sticker{max-width"))
    }

    /// 楼层引用和用户链接同样是相对地址，一起被剥掉过。
    func testInPostLinksBecomeAbsolute() throws {
        let html = try pollPostBodyHTML()

        XCTAssertTrue(
            html.contains("https://www.nodeseek.com/post-895695-1#"),
            "楼层引用的链接没了"
        )
        XCTAssertTrue(html.contains("https://www.nodeseek.com/member?t="), "用户链接没了")
    }

    /// 已经是绝对地址的图片不能被改坏。
    func testAlreadyAbsoluteImagesAreLeftAlone() throws {
        XCTAssertTrue(
            try pollPostBodyHTML().contains("https://cdn.nodeimage.com/i/"),
            "外站图片被弄丢了"
        )
    }

    /// `javascript:` 这类链接仍然不能留 —— 正文是别人写的。
    ///
    /// 直接喂一个进去，而不是靠夹具：夹具里唯一那条 `javascript:` 是投票标记，
    /// 在这一步之前就被换掉了，靠它测等于没测。
    ///
    /// 注意这条用例**证不了**是谁拦住的：清洗白名单本身就按协议校验 `href`，
    /// `resolveRelativeURLs` 里那句显式判断是第二道。把那句删掉这条仍然绿 ——
    /// 留着它是因为那正是在重写 href 的地方，意图要写在手边。
    func testPseudoProtocolLinksLoseTheirHref() throws {
        let html = """
        <div class="content-item" data-comment-id="1"><article class="post-content">
          <a href="javascript:alert(1)">点我</a>
          <a href="/post-1-1#3">三楼</a>
        </article></div>
        """
        let bodies = try parser.threadPage(
            html: html, topicID: TopicID(rawValue: 1), page: 1
        ).posts.map(\.html).joined()

        XCTAssertFalse(bodies.contains("javascript:"), "伪协议漏过去了")
        XCTAssertTrue(bodies.contains("点我"), "文字该留着，只是不再是链接")
        XCTAssertTrue(
            bodies.contains("https://www.nodeseek.com/post-1-1#3"),
            "正常的相对链接该转成绝对地址"
        )
    }
}

/// 楼层右下角那四个数。夹具是 post-1033 的真实页面。
extension NodeSeekParserTests {

    private func countsPage() throws -> ThreadPage {
        try parser.threadPage(
            html: try fixture("nodeseek-post-counts"),
            topicID: TopicID(rawValue: 1033),
            page: 1
        )
    }

    func testTheThreeReactionCountsComeFromTheState() throws {
        let opening = try XCTUnwrap(try countsPage().posts.first { $0.floor == 0 })

        XCTAssertEqual(opening.reactions.map(\.count), [176, 307, 0])
        XCTAssertEqual(opening.upvoteCount, 176, "赞的计数仍然是免费那一个")
    }

    /// 收藏是话题级的，但网页版把它画在主楼那一行 —— 楼层视图拿不到 Topic，
    /// 所以跟着主楼走。
    func testTheTopicCollectionCountRidesOnTheOpeningPost() throws {
        let page = try countsPage()
        let opening = try XCTUnwrap(page.posts.first { $0.floor == 0 })

        XCTAssertEqual(opening.topicCollectionCount, 1480)
        XCTAssertFalse(opening.isTopicCollected)
    }

    /// 回帖上不该冒出话题的收藏数 —— 那不是这一层的数。
    func testRepliesDoNotCarryTheCollectionCount() throws {
        let replies = try countsPage().posts.filter { $0.floor != 0 }

        XCTAssertFalse(replies.isEmpty, "前提：这一页有回帖")
        XCTAssertTrue(replies.allSatisfy { $0.topicCollectionCount == nil })
    }

    /// 「我点过没有」三种各读各的键，别串。
    func testEachReactionReadsItsOwnChosenFlag() throws {
        let html = """
        <html><body><script>var s="\(
            Data(#"""
            {"postData":{"postId":1,"title":"t","postPageCount":1,"collectionCount":0,
             "comments":[{"commentId":9,"floorIndex":0,"upvoteCount":1,"likeCount":2,
             "dislikeCount":3,"upvoted":false,"liked":true,"disliked":false,
             "poster":{"uid":1,"name":"谁"},"time":{"createdDate":"2026-08-01T00:00:00.000Z"}}]}}
            """#.utf8).base64EncodedString()
        )"</script></body></html>
        """
        let post = try XCTUnwrap(
            try parser.threadPage(html: html, topicID: TopicID(rawValue: 1), page: 1).posts.first
        )

        XCTAssertEqual(
            post.reactions.map(\.isChosen),
            [false, true, false],
            "只加过鸡腿，点赞和反对都没点过"
        )
    }
}

/// 正文里的标签页（`:::: tabs`）。
extension NodeSeekParserTests {

    private func tabsPostBody() throws -> String {
        let page = try parser.threadPage(
            html: try fixture("nodeseek-post-tabs"),
            topicID: TopicID(rawValue: 898_667),
            page: 1
        )
        return try XCTUnwrap(page.posts.first { $0.floor == 0 }?.html)
    }

    /// 站点的结构全靠 class 区分，而清洗会把 div 的 class 剥掉 ——
    /// 不改写的话几页内容就首尾相接堆在一起了。
    func testTabsBecomeSwitchableSections() throws {
        let html = try tabsPostBody()

        XCTAssertTrue(html.contains("class=\"ns-tabs\""), "容器没改写")
        XCTAssertTrue(html.contains("class=\"ns-tab\""), "标题没变成可点的标签")
        XCTAssertTrue(html.contains("class=\"ns-tab-panel\""), "内容没装进面板")
        XCTAssertTrue(html.contains("type=\"radio\""), "没有切换用的开关")
    }

    func testEveryTabTitleSurvives() throws {
        let html = try tabsPostBody()

        for title in ["基本信息", "IP质量", "网络质量", "回程路由"] {
            XCTAssertTrue(html.contains(title), "少了「\(title)」这一页")
        }
    }

    /// 每一组标签页都要有且只有一页默认展开，否则打开帖子看到的是一排标题和一片空白。
    ///
    /// 一篇正文里可以有好几组（这份夹具就有两组，4 页和 6 页），所以要按组数，
    /// 不能全文数一遍。
    func testExactlyOneTabStartsOpenInEachGroup() throws {
        let html = try tabsPostBody()

        var checkedByGroup: [String: Int] = [:]
        var groups = Set<String>()
        for input in html.components(separatedBy: "<input").dropFirst() {
            let tag = String(input.prefix { $0 != ">" })
            guard let range = tag.range(of: #"name="([^"]+)""#, options: .regularExpression) else {
                continue
            }
            let group = String(tag[range].dropFirst(6).dropLast())
            groups.insert(group)
            if tag.contains("checked") { checkedByGroup[group, default: 0] += 1 }
        }

        XCTAssertEqual(groups.count, 2, "这份夹具里有两组标签页")
        for group in groups {
            XCTAssertEqual(checkedByGroup[group], 1, "「\(group)」这一组默认展开的页数不对")
        }
    }

    /// 两组标签页的开关不能串成一组 —— 那样点第二组会把第一组切走。
    func testSeparateTabGroupsDoNotShareASwitch() throws {
        let html = try tabsPostBody()

        XCTAssertTrue(html.contains(#"name="ns-tabs-0""#))
        XCTAssertTrue(html.contains(#"name="ns-tabs-1""#))
    }

    /// 切换只能靠 CSS：正文文档的 CSP 是 `default-src 'none'`，脚本不会执行。
    func testSwitchingNeedsNoScript() throws {
        let html = try tabsPostBody()

        XCTAssertFalse(html.contains("<script"), "正文里不该出现脚本")
        XCTAssertTrue(html.contains("default-src 'none'"), "CSP 还在")
        XCTAssertTrue(
            html.contains(".ns-tabs input:checked+.ns-tab+.ns-tab-panel{display:block}"),
            "切换用的那条 CSS 不在文档里"
        )
    }

    /// 一页的内容不能跑到另一页里去。
    func testEachPanelKeepsItsOwnContent() throws {
        let html = """
        <div class="content-item" data-comment-id="1"><article class="post-content">
          <div class="nsk-magic-tabs">
            <div class="nsk-magic-tab-title">甲</div>
            <div class="nsk-magic-tab-body"><p>甲的内容</p></div>
            <div class="nsk-magic-tab-title">乙</div>
            <div class="nsk-magic-tab-body"><p>乙的内容</p></div>
          </div>
        </article></div>
        """
        let body = try XCTUnwrap(
            try parser.threadPage(html: html, topicID: TopicID(rawValue: 1), page: 1)
                .posts.first?.html
        )

        let first = try XCTUnwrap(body.range(of: "甲的内容"))
        let secondTitle = try XCTUnwrap(body.range(of: ">乙</label>"))
        XCTAssertLessThan(
            first.lowerBound, secondTitle.lowerBound,
            "甲的内容跑到乙的标签后面去了"
        )
    }

    /// 没有内容的那一页也要有它的标签 —— 站点允许空的 tab-item。
    func testATabWithNoBodyStillGetsItsTitle() throws {
        let html = """
        <div class="content-item" data-comment-id="1"><article class="post-content">
          <div class="nsk-magic-tabs">
            <div class="nsk-magic-tab-title">空的一页</div>
          </div>
        </article></div>
        """
        let body = try XCTUnwrap(
            try parser.threadPage(html: html, topicID: TopicID(rawValue: 1), page: 1)
                .posts.first?.html
        )

        XCTAssertTrue(body.contains("空的一页"))
    }
}

/// 帖子里的终端输出。
extension NodeSeekParserTests {

    func testTerminalOutputIsColouredAndLeavesNoEscapeCodes() throws {
        let html = try tabsPostBody()

        XCTAssertTrue(html.contains("ansi-fg-6"), "青色没渲染出来")
        XCTAssertTrue(html.contains("ansi-fg-2"), "绿色没渲染出来")
        XCTAssertTrue(html.contains("ansi-b"), "粗体没渲染出来")
        // 站点把 ESC 渲染成空 span，清洗会把它连同属性一起丢掉，只剩 `[36m` 这种噪声。
        XCTAssertFalse(html.contains("[36m"), "转义序列漏成了正文")
        XCTAssertFalse(html.contains("[0m"), "转义序列漏成了正文")
        XCTAssertFalse(html.contains("data-ansicode"), "还留着站点的标记")
    }

    /// 报告的正文本身要完整留着。
    func testTheReportTextItselfSurvives() throws {
        let html = try tabsPostBody()

        XCTAssertTrue(html.contains("硬件质量体检报告"))
        XCTAssertTrue(html.contains("KVM 虚拟机"))
    }

    /// 调色板得真的在文档里，否则那些类名什么也不做。
    func testThePaletteIsInTheDocument() throws {
        XCTAssertTrue(try tabsPostBody().contains(".ansi-fg-6"))
    }
}
