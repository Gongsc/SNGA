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

    private func fixture(_ name: String) throws -> String {
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
