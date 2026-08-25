import Foundation
import SwiftData
import XCTest
@testable import SNGA

/// 钉住 `ForumID` 的表示，以及三张按版面存取的表的往返。
///
/// C11 把 `ForumID` 换成了「站点 + 字符串键」。持久化层暂时仍存原来的 Int64，
/// 由 `ngaRawValue` / `init(ngaStoredValue:)` 换算；C12 起加一列存键本身。
/// 因此这里最要紧的一条是：**老库里的数值还原出来必须是同一个版面**。
///
/// 刻意不钉的东西：
///
/// - `recordID(...)` 的确切字符串。C12 会把它从 Int64 换成字符串键，那是设计内的
///   改动。这里改钉它的性质 —— 按账号隔离、按版面隔离、同样的输入给同样的输出。
/// - `ForumID` 的 `Codable` 编码。全仓没有任何地方把 `Forum` 编成 JSON 存下来，
///   所以那个形状不是承重的。
final class ForumIdentityTests: XCTestCase {

    // MARK: - ForumID 的表示

    func testPlainForumIsNotASubforum() {
        let forumID = ForumID(nga: 414)

        XCTAssertEqual(forumID.site, .nga)
        XCTAssertEqual(forumID.key, "414")
        XCTAssertFalse(forumID.ngaIsSubforum)
        XCTAssertEqual(forumID.ngaQueryName, "fid")
        XCTAssertEqual(forumID.ngaValue, 414)
        XCTAssertEqual(forumID.description, "414")
    }

    /// 负数版面号照样是普通版面。
    ///
    /// UI 测试里的假版面用的就是 `-7`，按钮标识符是 `favorite-forum--7` ——
    /// `description` 一旦变样，那几条用例会以看不出原因的方式红掉。
    func testNegativeForumIDIsStillAPlainForum() {
        let forumID = ForumID(nga: -7)

        XCTAssertFalse(forumID.ngaIsSubforum)
        XCTAssertEqual(forumID.ngaQueryName, "fid")
        XCTAssertEqual(forumID.description, "-7")
    }

    /// UI 测试里另一个真实版面号，标识符是 `directory-forum-510381`。
    func testLargeForumIDIsStillAPlainForum() {
        let forumID = ForumID(nga: 510_381)

        XCTAssertFalse(forumID.ngaIsSubforum)
        XCTAssertEqual(forumID.description, "510381")
    }

    /// 子版面的键是 `s` 加 stid；发请求时要还原成那个数字。
    func testSubforumKeepsItsStidBehindAnSPrefix() {
        let forumID = ForumID(ngaSubforum: 35_925_536)

        XCTAssertTrue(forumID.ngaIsSubforum)
        XCTAssertEqual(forumID.key, "s35925536")
        XCTAssertEqual(forumID.ngaQueryName, "stid")
        XCTAssertEqual(forumID.ngaValue, 35_925_536)
        XCTAssertEqual(forumID.description, "s35925536")
    }

    func testZeroStidIsStillRecognizedAsASubforum() {
        let forumID = ForumID(ngaSubforum: 0)

        XCTAssertTrue(forumID.ngaIsSubforum)
        XCTAssertEqual(forumID.key, "s0")
        XCTAssertEqual(forumID.ngaValue, 0)
    }

    /// C1 记下的那个隐患到这里修好了。
    ///
    /// 从前同号的版面和子版面给出同一个 `description`，界面标识符按它拼，所以理论上
    /// 会撞。现在子版面带 `s` 前缀，两者的字符串不再相同。
    func testPlainForumAndSubforumWithTheSameNumberNoLongerShareAString() {
        let plain = ForumID(nga: 414)
        let subforum = ForumID(ngaSubforum: 414)

        XCTAssertNotEqual(plain, subforum)
        XCTAssertNotEqual(plain.description, subforum.description)
        XCTAssertEqual(plain.description, "414")
        XCTAssertEqual(subforum.description, "s414")
    }

    // MARK: - 老库里的数值

    /// 1.8.2 的库里存的是 Int64。C12 加上键那一列之前，读写都要经过这一层换算，
    /// 换算错了等于用户的收藏和最近访问指向别的版面。
    func testStoredInt64RoundTripsBackToTheSameForum() {
        for forumID in [
            ForumID(nga: 414),
            ForumID(nga: -7),
            ForumID(nga: 510_381),
            ForumID(nga: 0),
            ForumID(ngaSubforum: 35_925_536),
            ForumID(ngaSubforum: 0)
        ] {
            let stored = try? XCTUnwrap(forumID.ngaRawValue)
            XCTAssertNotNil(stored, "\(forumID) 应该能存进老库")
            guard let stored = stored else { continue }
            XCTAssertEqual(
                ForumID(ngaStoredValue: stored),
                forumID,
                "\(forumID) 存成 \(stored) 之后还原成了别的版面"
            )
        }
    }

    /// 换算出来的数值必须和 1.8.2 写进库里的完全一致，否则老数据对不上号。
    func testStoredInt64MatchesTheEncodingUsedBefore() {
        XCTAssertEqual(ForumID(nga: 414).ngaRawValue, 414)
        XCTAssertEqual(ForumID(nga: -7).ngaRawValue, -7)
        XCTAssertEqual(ForumID(ngaSubforum: 35_925_536).ngaRawValue, Int64.min + 35_925_536)
        XCTAssertEqual(ForumID(ngaSubforum: 0).ngaRawValue, Int64.min)
    }

    // MARK: - 持久化往返

    @MainActor
    func testFavoriteRecordRoundTripsItsForumThroughTheStore() throws {
        let container = try Self.makeContainer("ForumIdentityTests.Favorite")
        let context = ModelContext(container)
        let accountID = AccountID()
        let plain = Forum(id: ForumID(nga: 414), name: "综合游戏讨论区", subtitle: "综合")
        let subforum = Forum(id: ForumID(ngaSubforum: 35_925_536), name: "幻兽帕鲁")

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
            id: ForumID(ngaSubforum: 35_925_536),
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
        let parentForumID = ForumID(nga: 414)
        let selected: Set<ForumID> = [
            ForumID(nga: 510_381),
            ForumID(ngaSubforum: 35_925_536),
            ForumID(ngaSubforum: 0)
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
        XCTAssertEqual(ForumID(ngaStoredValue: stored.parentForumID), parentForumID)
    }

    @MainActor
    func testEmptySubforumSelectionRoundTripsAsEmptyRatherThanOneBlankID() throws {
        let container = try Self.makeContainer("ForumIdentityTests.SubforumEmpty")
        let context = ModelContext(container)

        let record = SubforumPreferenceRecord(
            accountID: AccountID(),
            parentForumID: ForumID(nga: 414),
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
        let forumID = ForumID(nga: 414)

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
            RecentForumRecord.recordID(accountID: accountID, forumID: ForumID(nga: 415))
        )
        XCTAssertNotEqual(
            key,
            RecentForumRecord.recordID(accountID: accountID, forumID: ForumID(ngaSubforum: 414))
        )
        XCTAssertTrue(key.hasPrefix(accountID.description))
    }

    func testSubforumPreferenceIdentifiersAreScopedPerAccountAndParentForum() {
        let accountID = AccountID()
        let parentForumID = ForumID(nga: 414)

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
