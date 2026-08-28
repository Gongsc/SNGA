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

/// 记下发出去的请求，好断言请求体到底长什么样。
private final class RecordingTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    private let body: Data

    var requests: [URLRequest] { lock.withLock { _requests } }

    init(responding body: String) {
        self.body = Data(body.utf8)
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { _requests.append(request) }
        return (body, HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!)
    }
}

/// 投票提交。请求体的形状是这一整件事里唯一靠猜会出错的地方，所以直接断言
/// 发出去的字节。
final class NodeSeekPollSubmissionTests: XCTestCase {

    private func service(responding body: String) -> (NodeSeekForumService, RecordingTransport) {
        let transport = RecordingTransport(responding: body)
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

    private func sentBody(_ transport: RecordingTransport) throws -> [String: Any] {
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
