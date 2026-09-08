import Foundation
import SwiftData
import XCTest
@testable import SNGA

/// 补作者属地这件事是**按楼层数发请求**的，所以它必须由能力位说了算。
///
/// V2EX 一页 100 层。站点报不出属地时，一开帖就是上百次请求排在同一个连接上，
/// 后面所有请求 —— 翻页、刷新、发回复 —— 都得等它们走完；而取回来还没有属地可填。
/// 这就是「V2EX 上有的帖子打开特别慢」的成因。
final class PostAuthorLocationGateTests: XCTestCase {

    /// V2EX 的 `location` 是会员自己填的一行字（「cn」），不是 IP 属地。
    /// 拿它冒充属地既错又贵。
    @MainActor
    func testV2EXNeverFetchesAuthorLocations() async throws {
        let (model, transport) = try makeModel {
            V2EXForumService(
                accountID: $0,
                cookies: [],
                transport: $1,
                userAgent: "probe"
            )
        }

        await model.thread.loadPostAuthorLocation(uid: 1)

        XCTAssertTrue(transport.requests.isEmpty, "一页 100 层，这一下会变成上百次请求")
        XCTAssertFalse(model.session.supports(.postAuthorLocation))
    }

    /// NodeSeek 的资料里根本没有属地这一项，拉回来永远是空 —— 一样别拉。
    @MainActor
    func testNodeSeekNeverFetchesAuthorLocationsEither() async throws {
        let (model, transport) = try makeModel {
            NodeSeekForumService(
                accountID: $0,
                cookies: [],
                transport: $1,
                userAgent: "probe"
            )
        }

        await model.thread.loadPostAuthorLocation(uid: 1)

        XCTAssertTrue(transport.requests.isEmpty)
    }

    /// 反过来：报得出属地的站点照拉不误，否则上面两条可能只是因为什么都没发生。
    @MainActor
    func testASiteThatReportsLocationsStillFillsThemIn() async throws {
        let model = AppModel(container: try makeContainer())
        let accountID = AccountID()
        model.session.activeAccountID = accountID
        model.session.setService(DebugForumService(accountID: accountID), for: accountID)
        model.thread.posts = [
            Post(
                id: PostID(rawValue: 1),
                topicID: TopicID(rawValue: 1),
                floor: 1,
                author: "谁",
                authorUID: 7,
                html: ""
            )
        ]

        await model.thread.loadPostAuthorLocation(uid: 7)

        XCTAssertTrue(model.session.supports(.postAuthorLocation))
        XCTAssertEqual(model.thread.posts.first?.authorInfo?.location, "浙江省")
    }

    // MARK: -

    @MainActor
    private func makeModel(
        _ makeService: (AccountID, RecordingHTTPTransport) -> any ForumService
    ) throws -> (AppModel, RecordingHTTPTransport) {
        let model = AppModel(container: try makeContainer())
        let accountID = AccountID()
        let transport = RecordingHTTPTransport(responding: "{}")
        model.session.activeAccountID = accountID
        model.session.setService(makeService(accountID, transport), for: accountID)
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
                "PostAuthorLocationGate-\(UUID().uuidString)",
                schema: schema,
                isStoredInMemoryOnly: true
            )]
        )
    }
}
