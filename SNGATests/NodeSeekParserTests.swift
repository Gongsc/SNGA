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
