import Foundation
import SwiftData
import XCTest
@testable import SNGA

/// 首页分类打开之后，主题一条都不能少。
///
/// 这条盯的是一个真出过的问题：分类底下那第二排节点交给了界面的「子版面」那一格，
/// 而那一格的默认状态是**服务端说勾了才勾**（NGA 的形状）。V2EX 什么都没说，
/// 于是一个都不勾 —— 界面把这几个节点的主题全筛掉了，一格「技术」只剩下几条
/// 来自别的节点的零星主题。
///
/// 站点在服务端就把这些主题聚合进来了，它们本来就全在列表里，所以默认全显示。
final class V2EXTabListingTests: XCTestCase {

    private let tech = V2EXEndpoint.tabForumID(key: "tech")

    @MainActor
    func testOpeningAHomepageTabShowsEveryTopic() async throws {
        let model = try makeModel()

        await model.openForum(Forum(id: tech, name: "技术"))

        XCTAssertFalse(model.browsing.topics.isEmpty, "前提：夹具里有主题")
        XCTAssertEqual(
            model.browsing.displayedTopics.count,
            model.browsing.topics.count,
            "分类里的主题被筛掉了 —— 站点已经把它们聚合进来了，默认就该全显示"
        )
    }

    /// 那一格上的「已显示 N」不能是 0：站点聚合的这几个节点默认全在。
    @MainActor
    func testEveryAggregatedNodeStartsIncluded() async throws {
        let model = try makeModel()

        await model.openForum(Forum(id: tech, name: "技术"))

        XCTAssertEqual(model.browsing.subforums.count, 8)
        XCTAssertEqual(
            model.browsing.includedSubforumIDs,
            Set(model.browsing.subforums.map(\.id))
        )
    }

    /// 反过来也得成立：取消勾选真的能把那个节点的主题筛出去，否则那一格上的
    /// 开关只是摆设。
    @MainActor
    func testUncheckingANodeHidesItsTopics() async throws {
        let model = try makeModel()
        await model.openForum(Forum(id: tech, name: "技术"))
        let programmer = V2EXEndpoint.forumID(key: "programmer")
        let fromProgrammer = model.browsing.topics.filter { $0.sourceForumID == programmer }
        XCTAssertFalse(fromProgrammer.isEmpty, "前提：夹具里有「程序员」的主题")

        model.browsing.setSubforumIncluded(programmer, included: false)

        XCTAssertEqual(
            model.browsing.displayedTopics.count,
            model.browsing.topics.count - fromProgrammer.count
        )
        XCTAssertFalse(
            model.browsing.displayedTopics.contains { $0.sourceForumID == programmer }
        )
    }

    /// 节点页底下没有节点（站点的节点是平的），所以那一格整个不画，
    /// 也不该有任何筛选。
    @MainActor
    func testANodePageHasNothingToFilter() async throws {
        let model = try makeModel(fixture: "v2ex-node-topics")

        await model.openForum(Forum(id: V2EXEndpoint.forumID(key: "qna"), name: "问与答"))

        XCTAssertTrue(model.browsing.subforums.isEmpty)
        XCTAssertEqual(model.browsing.displayedTopics.count, model.browsing.topics.count)
    }

    // MARK: -

    @MainActor
    private func makeModel(fixture name: String = "v2ex-home-tab") throws -> AppModel {
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
            configurations: [ModelConfiguration(
                "V2EXTabListing-\(UUID().uuidString)",
                schema: schema,
                isStoredInMemoryOnly: true
            )]
        )
        let model = AppModel(container: container)
        let accountID = AccountID()
        model.session.activeAccountID = accountID
        model.session.setService(
            V2EXForumService(
                accountID: accountID,
                cookies: [],
                transport: RecordingHTTPTransport(responding: try html(name)),
                userAgent: "probe"
            ),
            for: accountID
        )
        return model
    }

    private func html(_ name: String) throws -> String {
        let url = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: name, withExtension: "html"),
            "测试包里没有夹具 \(name).html"
        )
        return try String(contentsOf: url, encoding: .utf8)
    }
}
