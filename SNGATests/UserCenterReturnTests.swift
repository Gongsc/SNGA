import Foundation
import SwiftData
import XCTest
@testable import SNGA

/// 进了别人的资料页，还得能退回来。
///
/// 补的是一条真出过的死路：返回目标原先只在**版面**里记，从通知、私信、收藏夹、
/// 搜索结果点进一个人的资料就没有返回按钮了。看着像「NGA 有、NodeSeek 没有」——
/// NGA 的用户大多是在帖子里点作者，那时正好在版面下；而 NodeSeek 把通知并进了消息，
/// 从那里点人是常事。实际是「版面有、别处没有」，和站点无关。
final class UserCenterReturnTests: XCTestCase {

    /// 版面里点作者：原先就有的那条路，不能改坏。
    @MainActor
    func testOpeningSomeoneFromAForumStillOffersTheWayBack() async throws {
        let model = try makeModel()
        let forumID = ForumID(nga: 414)
        model.sidebarSelection = .forum(forumID)

        await model.openUserCenter(uid: 99, remembersOrigin: true)

        XCTAssertTrue(model.canReturnFromUserCenter)
        XCTAssertEqual(model.userCenterReturnTitle, "返回话题列表")

        model.returnFromUserCenter()

        XCTAssertEqual(model.sidebarSelection, .forum(forumID))
        XCTAssertFalse(model.canReturnFromUserCenter, "退回来之后就不该再有返回了")
    }

    /// 消息里点人：原先就是从这里走不回去的。
    @MainActor
    func testOpeningSomeoneFromMessagesAlsoOffersTheWayBack() async throws {
        let model = try makeModel()
        model.sidebarSelection = .messages(.notifications)

        await model.openUserCenter(uid: 99, remembersOrigin: true)

        XCTAssertTrue(model.canReturnFromUserCenter, "从通知点进来的人也得能退回去")
        XCTAssertEqual(
            model.userCenterReturnTitle, "返回消息",
            "按钮上不该写「返回话题列表」—— 他不是从话题列表来的"
        )

        model.returnFromUserCenter()

        XCTAssertEqual(model.sidebarSelection, .messages(.notifications))
    }

    /// 刷新不是一次导航。原先它按「新打开一个用户中心」处理，把来路清了，
    /// 返回按钮就在眼皮底下消失。
    @MainActor
    func testRefreshingTheProfileKeepsTheWayBack() async throws {
        let model = try makeModel()
        model.sidebarSelection = .forum(ForumID(nga: 414))
        await model.openUserCenter(uid: 99, remembersOrigin: true)

        // 刷新按钮和 ⌘R 走的就是这一条。
        await model.openUserCenter(uid: 99, remembersOrigin: true)

        XCTAssertTrue(model.canReturnFromUserCenter, "刷新一下就出不去了")
        XCTAssertEqual(
            model.userCenterReturnTitle, "返回话题列表",
            "来路不该被改写成用户中心自己"
        )
    }

    /// 视图重新加载时会调它。同样不能把来路清掉。
    @MainActor
    func testReloadingTheViewKeepsTheWayBack() async throws {
        let model = try makeModel()
        model.sidebarSelection = .forum(ForumID(nga: 414))
        await model.openUserCenter(uid: 99, remembersOrigin: true)
        // 换一个人，制造出 `ensureUserCenterLoaded` 真会去加载的那种状态。
        model.sidebarSelection = .userCenter(1234)

        await model.ensureUserCenterLoaded(uid: 1234)

        XCTAssertTrue(model.canReturnFromUserCenter)
    }

    /// 从侧栏直接点「用户中心」不是从哪儿进来的，就不该有返回。
    @MainActor
    func testGoingToTheUserCentreFromTheSidebarHasNothingToReturnTo() async throws {
        let model = try makeModel()
        model.sidebarSelection = .forum(ForumID(nga: 414))
        await model.openUserCenter(uid: 99, remembersOrigin: true)

        model.sidebarSelection = .forum(ForumID(nga: 414))
        await model.openUserCenter(uid: 1)

        XCTAssertFalse(
            model.canReturnFromUserCenter,
            "上一次的来路得清掉，否则返回按钮会把人送到一个他没来过的地方"
        )
    }

    @MainActor
    private func makeModel() throws -> AppModel {
        let schema = Schema([
            AccountRecord.self, FavoriteRecord.self, DraftRecord.self,
            SubforumPreferenceRecord.self, RecentForumRecord.self,
            AIProfileSummaryRecord.self
        ])
        let model = AppModel(container: try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(
                "UserCenterReturn-\(UUID().uuidString)",
                schema: schema,
                isStoredInMemoryOnly: true
            )]
        ))
        let record = AccountRecord(
            site: .nodeseek, siteUserID: 1, displayName: "账号", isCurrent: true
        )
        model.session.context.insert(record)
        try? model.session.context.save()
        model.session.accounts = [record.summary()]
        model.session.activeAccountID = record.accountID
        model.session.setService(
            DebugForumService(accountID: record.accountID, capabilities: .all),
            for: record.accountID
        )
        return model
    }
}
