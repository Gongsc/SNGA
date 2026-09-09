import Foundation
import SwiftData
import XCTest
@testable import SNGA

/// 切账号的一瞬间，界面上还挂着**上一个站**的版面。
///
/// 按版面编号触发的那些 `.task(id:)` 会拿它去问**新**账号的服务 —— 从 NGA 切到
/// V2EX 时，V2EX 收到一个 NGA 的版面号 `-7`，答一张「节点未找到」的正常页面
/// （HTTP 200，不是 404），解析出来就是那句
/// 「V2EX：论坛页面结构已变化：未找到主题列表」。
///
/// 挡在发请求之前：那一次请求本来就不该发出去。
final class CrossSiteForumGuardTests: XCTestCase {

    @MainActor
    func testAForumFromThePreviousSiteIsNeverRequested() async throws {
        let (model, transport) = try makeV2EXModel()

        // NGA 的版面号，配着一个 V2EX 的服务 —— 切账号那一刻就是这个样子。
        await model.browsing.loadTopics(forumID: ForumID(nga: -7), reset: true)

        XCTAssertTrue(transport.requests.isEmpty, "这一次请求本来就不该发出去")
        XCTAssertNil(model.session.errorMessage, "用户没点任何东西，不该弹窗")
        XCTAssertFalse(model.browsing.isRefreshingTopics, "加载指示得收回去")
    }

    /// 翻页那条路同样会带着上一个站的版面进来。
    @MainActor
    func testPagingAForeignForumIsAlsoSkipped() async throws {
        let (model, transport) = try makeV2EXModel()

        await model.browsing.loadTopicPage(
            forumID: NodeSeekEndpoint.forumID(key: "daily"),
            page: 2
        )

        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertNil(model.session.errorMessage)
    }

    /// 反过来：本站的版面照常请求，否则上面两条可能只是因为什么都没发生。
    @MainActor
    func testAForumFromTheActiveSiteStillLoads() async throws {
        let (model, transport) = try makeV2EXModel()

        // 走用户真正走的那条路：`openForum` 会把选中的版面记上，
        // 结果才收得回来（`loadTopics` 拿回结果后要核对「还选着这个版面吗」）。
        await model.openForum(Forum(id: V2EXEndpoint.forumID(key: "qna"), name: "问与答"))

        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertFalse(model.browsing.topics.isEmpty)
    }

    /// 没有账号时谁的版面都不该请求 —— 那时连「当前站点」都没有。
    @MainActor
    func testNothingIsRequestedWithoutAnAccount() async throws {
        let model = AppModel(container: try makeContainer())

        await model.browsing.loadTopics(forumID: ForumID(nga: -7), reset: true)

        XCTAssertNotNil(model.session.statusMessage, "得说清为什么打不开")
        XCTAssertFalse(model.session.belongsToActiveSite(ForumID(nga: -7)))
    }

    // MARK: -

    @MainActor
    private func makeV2EXModel() throws -> (AppModel, RecordingHTTPTransport) {
        let model = AppModel(container: try makeContainer())
        let accountID = AccountID()
        let transport = RecordingHTTPTransport(
            responding: try html("v2ex-node-topics")
        )
        model.session.activeAccountID = accountID
        model.session.setService(
            V2EXForumService(
                accountID: accountID,
                cookies: [],
                transport: transport,
                userAgent: "probe"
            ),
            for: accountID
        )
        return (model, transport)
    }

    @MainActor
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            AccountRecord.self,
            FavoriteRecord.self,
            DraftRecord.self,
            SubforumPreferenceRecord.self,
            RecentForumRecord.self,
            AIProfileSummaryRecord.self
        ])
        return try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(
                "CrossSiteForumGuard-\(UUID().uuidString)",
                schema: schema,
                isStoredInMemoryOnly: true
            )]
        )
    }

    private func html(_ name: String) throws -> String {
        let url = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: name, withExtension: "html"),
            "测试包里没有夹具 \(name).html"
        )
        return try String(contentsOf: url, encoding: .utf8)
    }
}
