import Foundation
import SwiftData
import XCTest
@testable import SNGA

/// 打开一个版面会走两次「记一笔最近访问」：`beginShowing` 用点击的那个版面记一次，
/// 列表回来后 `applyForumPage` 再用**服务端返回的**版面记一次。
///
/// 两次的版面编号只要不一样，就会各留一行 —— 最近访问里于是多出一条。
final class RecentForumDuplicationTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: RecentForumSettings.maximumCountKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: RecentForumSettings.maximumCountKey)
        super.tearDown()
    }

    @MainActor
    func testOpeningAForumLeavesOneRecentEntryNotTwo() async throws {
        let container = try makeContainer()
        let model = AppModel(container: container)
        let accountID = AccountID(rawValue: UUID())
        model.session.activeAccountID = accountID
        // 这个服务不管请求哪个版面，回来的都是同一个（编号 -7）—— 真实适配器也不保证
        // 返回的版面就是请求的那个。
        model.session.setService(DebugForumService(accountID: accountID), for: accountID)

        let clicked = Forum(id: ForumID(nga: 510_381), name: "晴风村")
        await model.openForum(clicked)

        XCTAssertEqual(
            model.browsing.recentForums.map(\.id),
            [clicked.id],
            "点开一个版面只该留下这一个版面，不该多出服务端返回的那个"
        )
        XCTAssertEqual(
            try container.mainContext.fetch(FetchDescriptor<RecentForumRecord>()).count,
            1
        )
    }

    /// 同一个版面点第二次仍然只有一行，而且排在最前。
    @MainActor
    func testOpeningTheSameForumTwiceDoesNotAccumulate() async throws {
        let container = try makeContainer()
        let model = AppModel(container: container)
        let accountID = AccountID(rawValue: UUID())
        model.session.activeAccountID = accountID
        model.session.setService(DebugForumService(accountID: accountID), for: accountID)

        let clicked = Forum(id: ForumID(nga: 510_381), name: "晴风村")
        await model.openForum(clicked)
        await model.openForum(clicked)

        XCTAssertEqual(model.browsing.recentForums.map(\.id), [clicked.id])
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
                "RecentForumDuplication-\(UUID().uuidString)",
                schema: schema,
                isStoredInMemoryOnly: true
            )]
        )
    }
}
