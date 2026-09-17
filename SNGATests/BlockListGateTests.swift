import SwiftData
import XCTest
@testable import SNGA

/// 黑名单在 `AppModel` 这一侧的行为。
///
/// 解析和请求体归 `NodeSeekBlockListTests` 管，这里管的是三件会咬人的事：
/// 门控挡不挡得住请求、查失败之后界面拿到的是什么、以及写之前那次重查。
@MainActor
final class BlockListGateTests: XCTestCase {
    /// 站点没有这回事时，**一个请求都不该发出去**。
    ///
    /// 光把按钮藏起来不够：打开用户中心是主动去拉的，请求照发，用户会看到一个
    /// 「不支持站点黑名单」的报错 —— 这正是能力位门控要挡在调用层的原因。
    func testAnUnsupportedSiteIsNeverAsked() async throws {
        let accountID = AccountID()
        let service = CountingBlockService(accountID: accountID, capabilities: [])
        let model = try makeModel(accountID: accountID, service: service)

        await model.loadBlockedUsers()

        let listCount = await service.listCount
        XCTAssertEqual(listCount, 0)
        XCTAssertNil(model.blockedUserIDs)
        XCTAssertNil(model.isBlocked(uid: 20002))
    }

    /// 查失败留在 nil，**不退化成空集合**。
    ///
    /// 空集合的意思是「你没屏蔽任何人」，界面会把每个人都画成「屏蔽」—— 而其中
    /// 可能正有一个已经被屏蔽了的人，点下去就做反了。
    func testAFailedQueryStaysUnknownRatherThanEmpty() async throws {
        let accountID = AccountID()
        let service = CountingBlockService(accountID: accountID, listFails: true)
        let model = try makeModel(accountID: accountID, service: service)

        await model.loadBlockedUsers()

        XCTAssertNil(model.blockedUserIDs, "查不到被当成了『名单是空的』")
        XCTAssertNil(model.isBlocked(uid: 20002))
        XCTAssertNil(model.session.errorMessage, "顺手拉的这一趟不是用户要的东西，不该弹错")
    }

    func testASuccessfulQueryAnswersBothWays() async throws {
        let accountID = AccountID()
        let service = CountingBlockService(accountID: accountID, blocked: [20002])
        let model = try makeModel(accountID: accountID, service: service)

        await model.loadBlockedUsers()

        XCTAssertEqual(model.isBlocked(uid: 20002), true)
        XCTAssertEqual(model.isBlocked(uid: 30003), false)
    }

    /// 动手之前重查一遍。界面上那个标签可能已经放了很久（另一台设备上改过，
    /// 或者上一次查询本来就失败了），按过期的标签动作会把「屏蔽」做成「解除屏蔽」。
    func testAStaleLabelNeverFlipsTheActionAround() async throws {
        let accountID = AccountID()
        let service = CountingBlockService(accountID: accountID, blocked: [])
        let model = try makeModel(accountID: accountID, service: service)
        await model.loadBlockedUsers()
        XCTAssertEqual(model.isBlocked(uid: 20002), false)

        // 别处把他屏蔽了。界面还以为他没被屏蔽，于是发起一次「屏蔽」。
        await service.setBlocked([20002])
        await model.setBlocked(true, uid: 20002, name: "someone")

        let writeCount = await service.writeCount
        XCTAssertEqual(writeCount, 0, "状态早就变了，这一发不该出门")
        XCTAssertEqual(model.isBlocked(uid: 20002), true, "重查之后界面要跟上真实状态")
        XCTAssertEqual(model.session.statusMessage, "someone 已经在黑名单里了")
    }

    func testAnAcceptedWriteUpdatesTheLocalList() async throws {
        let accountID = AccountID()
        let service = CountingBlockService(accountID: accountID, blocked: [])
        let model = try makeModel(accountID: accountID, service: service)
        await model.loadBlockedUsers()

        await model.setBlocked(true, uid: 20002, name: "someone")

        let writeCount = await service.writeCount
        XCTAssertEqual(writeCount, 1)
        XCTAssertEqual(model.isBlocked(uid: 20002), true)
        XCTAssertEqual(model.session.statusMessage, "已屏蔽 someone")
    }

    /// 写失败之后**不留一份自以为是的名单**：下次打开重新查。
    func testAFailedWriteDropsTheListInsteadOfGuessing() async throws {
        let accountID = AccountID()
        let service = CountingBlockService(accountID: accountID, blocked: [], writeFails: true)
        let model = try makeModel(accountID: accountID, service: service)
        await model.loadBlockedUsers()
        XCTAssertNotNil(model.blockedUserIDs)

        await model.setBlocked(true, uid: 20002, name: "someone")

        XCTAssertNil(model.blockedUserIDs)
        XCTAssertNotNil(model.session.errorMessage, "用户按了按钮，没成要说一声")
    }

    private func makeModel(
        accountID: AccountID,
        service: CountingBlockService
    ) throws -> AppModel {
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
            configurations: [
                ModelConfiguration(
                    "BlockListGateTests.\(UUID().uuidString)",
                    schema: schema,
                    isStoredInMemoryOnly: true
                )
            ]
        )
        let model = AppModel(container: container)
        model.session.activeAccountID = accountID
        model.session.setService(service, for: accountID)
        return model
    }
}

/// 一个能被摆布的黑名单服务：数一数发了几次，也能中途改变主意。
private actor CountingBlockService: ForumService {
    nonisolated let accountID: AccountID
    nonisolated let site: ForumSite = .nodeseek
    nonisolated let capabilities: ForumCapabilities

    private var blocked: Set<Int64>
    private let listFails: Bool
    private let writeFails: Bool
    private(set) var listCount = 0
    private(set) var writeCount = 0

    init(
        accountID: AccountID,
        capabilities: ForumCapabilities = [.userBlocking],
        blocked: Set<Int64> = [],
        listFails: Bool = false,
        writeFails: Bool = false
    ) {
        self.accountID = accountID
        self.capabilities = capabilities
        self.blocked = blocked
        self.listFails = listFails
        self.writeFails = writeFails
    }

    func setBlocked(_ ids: Set<Int64>) { blocked = ids }

    func blockedUserIDs() async throws -> Set<Int64> {
        listCount += 1
        if listFails { throw ForumServiceError.unexpectedPage("黑名单查询失败") }
        return blocked
    }

    func updateUserBlock(uid: Int64, name: String, isBlocked: Bool) async throws {
        writeCount += 1
        if writeFails { throw ForumServiceError.restricted("操作未确认") }
        if isBlocked { blocked.insert(uid) } else { blocked.remove(uid) }
    }

    // 其余的一概走不到 —— 这几条用例只碰黑名单那一路。
    private var unused: ForumServiceError { .unsupported("测试替身没实现这个") }

    func currentUserID() async throws -> Int64 { throw unused }
    func profile(uid: Int64) async throws -> Profile { throw unused }
    func userActivities(uid: Int64, kind: UserActivityKind, page: Int) async throws -> UserActivityPage { throw unused }
    func forums() async throws -> [Forum] { throw unused }
    func search(_ request: ForumSearchRequest, page: Int) async throws -> ForumSearchPage { throw unused }
    func topics(forumID: ForumID, page: Int, sortOrder: TopicListSortOrder, featuredOnly: Bool) async throws -> ForumPage { throw unused }
    func threadPage(topicID: TopicID, page: Int, authorUID: Int64?) async throws -> ThreadPage { throw unused }
    func submitReply(topicID: TopicID, submission: ReplySubmission) async throws -> PostID? { throw unused }
    func vote(topicID: TopicID, postID: PostID, direction: PostVoteDirection, isUndo: Bool) async throws -> PostVoteState { throw unused }
    func submitTopicPollVote(topicID: TopicID, optionIDs: [String]) async throws { throw unused }
    func messages(folder: MessageFolder, page: Int) async throws -> MessagePage { throw unused }
    func message(id: MessageID) async throws -> ForumMessage { throw unused }
    func replyMessage(id: MessageID, content: String) async throws { throw unused }
    func favoriteTopicFolders() async throws -> [TopicFavoriteFolder] { throw unused }
    func favoriteTopics(folderID: String, page: Int) async throws -> ForumPage { throw unused }
    func updateTopicFavorite(topicID: TopicID, folderID: String, isFavorite: Bool) async throws { throw unused }
    func createTopicFavoriteFolder(name: String, isPublic: Bool, isDefault: Bool) async throws -> String? { throw unused }
    func updateTopicFavoriteFolder(_ folder: TopicFavoriteFolder) async throws { throw unused }
    func deleteTopicFavoriteFolder(folderID: String) async throws { throw unused }
    func checkInStatus() async throws -> CheckInStatistics { throw unused }
    func checkIn() async throws -> CheckInResult { throw unused }
}
