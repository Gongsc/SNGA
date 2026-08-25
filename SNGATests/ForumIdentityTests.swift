import Foundation
import SwiftData
import XCTest
@testable import SNGA

/// 钉住 `ForumID` 今天的表示，以及三张按版面存取的表的往返。
///
/// 阶段 1 后面会把 `ForumID` 换成「站点 + 字符串键」（C11），再给持久化层加一列
/// 字符串键并回填（C12、C13）。这些用例不评价现有设计，只记录现状里**不该跟着变**
/// 的那部分：版面存进去再取出来还是同一个版面，界面标识符还是同样的字符串。
///
/// 刻意不钉的东西：
///
/// - `recordID(...)` 的确切字符串。C12 会把它从 `rawValue` 换成字符串键，那是设计
///   内的改动。这里改钉它的性质 —— 按账号隔离、按版面隔离、同样的输入给同样的输出。
/// - `ForumID` 的 `Codable` 编码。全仓没有任何地方把 `Forum` 编成 JSON 存下来，
///   所以那个形状不是承重的，C11 可以随便改。
final class ForumIdentityTests: XCTestCase {

    // MARK: - ForumID 的表示

    func testPlainForumIsNotASubforum() {
        let forumID = ForumID(rawValue: 414)

        XCTAssertFalse(forumID.isSubforum)
        XCTAssertEqual(forumID.queryName, "fid")
        XCTAssertEqual(forumID.ngaValue, 414)
        XCTAssertEqual(forumID.description, "414")
    }

    /// 负数版面号照样是普通版面。
    ///
    /// UI 测试里的假版面用的就是 `-7`，按钮标识符是 `favorite-forum--7` ——
    /// `description` 一旦变样，那几条用例会以看不出原因的方式红掉。
    func testNegativeForumIDIsStillAPlainForum() {
        let forumID = ForumID(rawValue: -7)

        XCTAssertFalse(forumID.isSubforum)
        XCTAssertEqual(forumID.queryName, "fid")
        XCTAssertEqual(forumID.description, "-7")
    }

    /// UI 测试里另一个真实版面号，标识符是 `directory-forum-510381`。
    func testLargeForumIDIsStillAPlainForum() {
        let forumID = ForumID(rawValue: 510_381)

        XCTAssertFalse(forumID.isSubforum)
        XCTAssertEqual(forumID.description, "510381")
    }

    /// 子版面把 stid 编码成 `Int64.min` 的偏移量，取回来要还是同一个 stid。
    func testSubforumRoundTripsThroughItsOffsetEncoding() {
        let forumID = ForumID(stid: 35_925_536)

        XCTAssertTrue(forumID.isSubforum)
        XCTAssertEqual(forumID.queryName, "stid")
        XCTAssertEqual(forumID.ngaValue, 35_925_536)
        XCTAssertEqual(forumID.description, "35925536")
        XCTAssertEqual(forumID.rawValue, Int64.min + 35_925_536)
    }

    func testZeroStidIsStillRecognizedAsASubforum() {
        let forumID = ForumID(stid: 0)

        XCTAssertTrue(forumID.isSubforum)
        XCTAssertEqual(forumID.ngaValue, 0)
        XCTAssertEqual(forumID.description, "0")
    }

    /// 同号的版面和子版面是两个不同的 ID，却给出同一个 `description`。
    ///
    /// 这是现状里的一个真实隐患：界面标识符按 `description` 拼，两者会撞。今天撞不着
    /// 只因为没有哪个页面同时列出同号的版面和子版面。C11 给子版面加上 `s` 前缀之后
    /// 这个坑就没了 —— 到那时本用例的后半段该跟着改，那是修好了，不是走样了。
    func testPlainForumAndSubforumWithTheSameNumberAreDifferentIdentities() {
        let plain = ForumID(rawValue: 414)
        let subforum = ForumID(stid: 414)

        XCTAssertNotEqual(plain, subforum)
        XCTAssertNotEqual(plain.rawValue, subforum.rawValue)
        XCTAssertEqual(plain.description, subforum.description)
    }

    // MARK: - 持久化往返

    @MainActor
    func testFavoriteRecordRoundTripsItsForumThroughTheStore() throws {
        let container = try Self.makeContainer("ForumIdentityTests.Favorite")
        let context = ModelContext(container)
        let accountID = AccountID()
        let plain = Forum(id: ForumID(rawValue: 414), name: "综合游戏讨论区", subtitle: "综合")
        let subforum = Forum(id: ForumID(stid: 35_925_536), name: "幻兽帕鲁")

        for (order, forum) in [plain, subforum].enumerated() {
            context.insert(FavoriteRecord(
                accountID: accountID,
                forum: forum,
                order: order,
                syncState: .synced,
                serverPresent: true
            ))
        }
        try context.save()

        let stored = try ModelContext(container)
            .fetch(FetchDescriptor<FavoriteRecord>(sortBy: [SortDescriptor(\.order)]))

        XCTAssertEqual(stored.map(\.forum.id), [plain.id, subforum.id])
        XCTAssertEqual(stored.map(\.forum.name), [plain.name, subforum.name])
        XCTAssertEqual(stored.map(\.forum.subtitle), [plain.subtitle, subforum.subtitle])
        XCTAssertEqual(stored.map(\.forum.id.isSubforum), [false, true])
        // 展示层读的是盖在 Forum 上的这一位；C13 拿掉 Int64 之后只剩它。
        XCTAssertEqual(stored.map(\.forum.isSubforum), [false, true])
    }

    @MainActor
    func testRecentForumRecordRoundTripsEveryFieldItStores() throws {
        let container = try Self.makeContainer("ForumIdentityTests.Recent")
        let context = ModelContext(container)
        let accountID = AccountID()
        let iconURL = try XCTUnwrap(
            URL(string: "https://img4.nga.cn/ngabbs/nga_classic/f/app/414.png")
        )
        let forum = Forum(
            id: ForumID(stid: 35_925_536),
            name: "幻兽帕鲁",
            subtitle: "子版面",
            iconURL: iconURL,
            category: "游戏",
            pinnedTopicID: TopicID(rawValue: 9003)
        )

        context.insert(RecentForumRecord(accountID: accountID, forum: forum))
        try context.save()

        let stored = try XCTUnwrap(
            try ModelContext(container)
                .fetch(FetchDescriptor<RecentForumRecord>())
                .first
        )

        XCTAssertEqual(stored.forum.id, forum.id)
        XCTAssertTrue(stored.forum.id.isSubforum)
        XCTAssertTrue(stored.forum.isSubforum)
        XCTAssertEqual(stored.forum.name, forum.name)
        XCTAssertEqual(stored.forum.subtitle, forum.subtitle)
        XCTAssertEqual(stored.forum.iconURL, iconURL)
        XCTAssertEqual(stored.forum.category, forum.category)
        XCTAssertEqual(stored.forum.pinnedTopicID, forum.pinnedTopicID)
    }

    @MainActor
    func testSubforumPreferenceRoundTripsAMixOfPlainAndSubforumIDs() throws {
        let container = try Self.makeContainer("ForumIdentityTests.Subforum")
        let context = ModelContext(container)
        let accountID = AccountID()
        let parentForumID = ForumID(rawValue: 414)
        let selected: Set<ForumID> = [
            ForumID(rawValue: 510_381),
            ForumID(stid: 35_925_536),
            ForumID(stid: 0)
        ]

        context.insert(SubforumPreferenceRecord(
            accountID: accountID,
            parentForumID: parentForumID,
            selectedForumIDs: selected
        ))
        try context.save()

        let stored = try XCTUnwrap(
            try ModelContext(container)
                .fetch(FetchDescriptor<SubforumPreferenceRecord>())
                .first
        )

        XCTAssertEqual(stored.selectedForumIDs, selected)
        XCTAssertEqual(ForumID(rawValue: stored.parentForumID), parentForumID)
    }

    @MainActor
    func testEmptySubforumSelectionRoundTripsAsEmptyRatherThanOneBlankID() throws {
        let container = try Self.makeContainer("ForumIdentityTests.SubforumEmpty")
        let context = ModelContext(container)

        let record = SubforumPreferenceRecord(
            accountID: AccountID(),
            parentForumID: ForumID(rawValue: 414),
            selectedForumIDs: []
        )
        context.insert(record)
        try context.save()

        XCTAssertTrue(record.selectedForumIDs.isEmpty)
    }

    // MARK: - 记录主键的性质

    /// C12 会把主键里的版面部分从 `rawValue` 换成字符串键，所以这里钉的是性质，
    /// 不是确切的字符串：同样的输入给同样的键，换账号或换版面就得是另一个键。
    func testRecentForumRecordIdentifiersAreScopedPerAccountAndForum() {
        let accountID = AccountID()
        let otherAccountID = AccountID()
        let forumID = ForumID(rawValue: 414)

        let key = RecentForumRecord.recordID(accountID: accountID, forumID: forumID)

        XCTAssertEqual(
            key,
            RecentForumRecord.recordID(accountID: accountID, forumID: forumID)
        )
        XCTAssertNotEqual(
            key,
            RecentForumRecord.recordID(accountID: otherAccountID, forumID: forumID)
        )
        XCTAssertNotEqual(
            key,
            RecentForumRecord.recordID(accountID: accountID, forumID: ForumID(rawValue: 415))
        )
        XCTAssertNotEqual(
            key,
            RecentForumRecord.recordID(accountID: accountID, forumID: ForumID(stid: 414))
        )
        XCTAssertTrue(key.hasPrefix(accountID.description))
    }

    func testSubforumPreferenceIdentifiersAreScopedPerAccountAndParentForum() {
        let accountID = AccountID()
        let parentForumID = ForumID(rawValue: 414)

        let key = SubforumPreferenceRecord.recordID(
            accountID: accountID,
            parentForumID: parentForumID
        )

        XCTAssertEqual(
            key,
            SubforumPreferenceRecord.recordID(
                accountID: accountID,
                parentForumID: parentForumID
            )
        )
        XCTAssertNotEqual(
            key,
            SubforumPreferenceRecord.recordID(
                accountID: AccountID(),
                parentForumID: parentForumID
            )
        )
        XCTAssertTrue(key.hasPrefix(accountID.description))
    }

    /// 草稿按「账号 + 话题」存。`TopicID` 在阶段 1 不动，钉在这里是因为它和上面两张表
    /// 共用同一套「账号打头的字符串主键」的做法 —— C12 动那两张表时不该顺手动它。
    func testDraftRecordIdentifierIsScopedPerAccountAndTopic() {
        let accountID = AccountID()
        let topicID = TopicID(rawValue: 9001)

        let draft = DraftRecord(accountID: accountID, topicID: topicID)

        XCTAssertEqual(draft.id, "\(accountID.description):9001")
        XCTAssertNotEqual(
            draft.id,
            DraftRecord(accountID: accountID, topicID: TopicID(rawValue: 9002)).id
        )
        XCTAssertNotEqual(
            draft.id,
            DraftRecord(accountID: AccountID(), topicID: topicID).id
        )
    }

    // MARK: -

    private static func makeContainer(_ name: String) throws -> ModelContainer {
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
            configurations: [
                ModelConfiguration(name, schema: schema, isStoredInMemoryOnly: true)
            ]
        )
    }
}
