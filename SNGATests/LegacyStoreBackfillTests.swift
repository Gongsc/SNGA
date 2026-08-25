import Foundation
import SwiftData
import XCTest
@testable import SNGA

/// 回填要做两件事：把 C12 之前的行补上版面键，把主键换成按键拼的形式。
///
/// 第二件事是这里真正的风险所在 —— 主键算法一改，没补过的老行就查不到了，
/// 接着会被当成新行插进去，用户看到的是重复的最近访问和丢失的子版面偏好。
final class LegacyStoreBackfillTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "LegacyStoreBackfillTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        try super.tearDownWithError()
    }

    @MainActor
    func testBackfillFillsKeysLeftEmptyByOlderVersions() throws {
        let context = try makeContext("Fill")
        let accountID = AccountID()
        let plain = Forum(id: ForumID(nga: 414), name: "综合游戏讨论区")
        let subforum = Forum(id: ForumID(ngaSubforum: 35_925_536), name: "幻兽帕鲁")

        for (order, forum) in [plain, subforum].enumerated() {
            let record = FavoriteRecord(
                accountID: accountID,
                forum: forum,
                order: order,
                syncState: .synced,
                serverPresent: true
            )
            makeLegacy(record)
            context.insert(record)
        }
        try context.save()

        LegacyStoreBackfill.run(in: context)

        let stored = try context.fetch(
            FetchDescriptor<FavoriteRecord>(sortBy: [SortDescriptor(\.order)])
        )
        XCTAssertEqual(stored.map(\.forumKey), ["414", "s35925536"])
        XCTAssertEqual(stored.map(\.forumSiteRaw), ["nga", "nga"])
        XCTAssertEqual(stored.map(\.forumIdentifier), [plain.id, subforum.id])
    }

    /// 回填之后按新算法查得到 —— 查不到就意味着下次访问会插一条重复的。
    @MainActor
    func testBackfilledRecentForumIsFoundByItsNewRecordID() throws {
        let context = try makeContext("RecentID")
        let accountID = AccountID()
        let forum = Forum(id: ForumID(ngaSubforum: 35_925_536), name: "幻兽帕鲁")

        let record = RecentForumRecord(accountID: accountID, forum: forum)
        makeLegacy(record, accountID: accountID)
        context.insert(record)
        try context.save()

        let newID = RecentForumRecord.recordID(accountID: accountID, forumID: forum.id)
        XCTAssertNotEqual(record.id, newID, "先得确实是老格式，否则这条用例什么也没验")

        LegacyStoreBackfill.run(in: context)

        let stored = try context.fetch(FetchDescriptor<RecentForumRecord>())
        XCTAssertEqual(stored.count, 1, "回填不该多出行来")
        XCTAssertEqual(stored.first?.id, newID)
        XCTAssertEqual(stored.first?.forumIdentifier, forum.id)
    }

    @MainActor
    func testBackfilledSubforumPreferenceKeepsItsSelection() throws {
        let context = try makeContext("Selection")
        let accountID = AccountID()
        let parentForumID = ForumID(nga: 414)
        let selected: Set<ForumID> = [
            ForumID(nga: 510_381),
            ForumID(ngaSubforum: 35_925_536)
        ]

        let record = SubforumPreferenceRecord(
            accountID: accountID,
            parentForumID: parentForumID,
            selectedForumIDs: selected
        )
        makeLegacy(record, accountID: accountID)
        context.insert(record)
        try context.save()

        LegacyStoreBackfill.run(in: context)

        let stored = try XCTUnwrap(
            try context.fetch(FetchDescriptor<SubforumPreferenceRecord>()).first
        )
        XCTAssertEqual(
            stored.id,
            SubforumPreferenceRecord.recordID(
                accountID: accountID,
                parentForumID: parentForumID
            )
        )
        XCTAssertEqual(stored.parentForumIdentifier, parentForumID)
        XCTAssertEqual(stored.selectedForumIDs, selected)
        XCTAssertEqual(stored.selectedForumKeysRaw, "510381,s35925536")
    }

    /// 中途崩了下次会重来，所以跑两趟必须和跑一趟结果一样。
    @MainActor
    func testBackfillIsIdempotent() throws {
        let context = try makeContext("Idempotent")
        let accountID = AccountID()
        let forum = Forum(id: ForumID(ngaSubforum: 35_925_536), name: "幻兽帕鲁")

        let record = RecentForumRecord(accountID: accountID, forum: forum)
        makeLegacy(record, accountID: accountID)
        context.insert(record)
        try context.save()

        LegacyStoreBackfill.run(in: context)
        let afterFirst = try context.fetch(FetchDescriptor<RecentForumRecord>())
            .map { ($0.id, $0.forumKey) }

        LegacyStoreBackfill.run(in: context)
        let afterSecond = try context.fetch(FetchDescriptor<RecentForumRecord>())
            .map { ($0.id, $0.forumKey) }

        XCTAssertEqual(afterFirst.count, 1)
        XCTAssertEqual(afterFirst.map(\.0), afterSecond.map(\.0))
        XCTAssertEqual(afterFirst.map(\.1), afterSecond.map(\.1))
    }

    @MainActor
    func testRunIfNeededOnlyRunsUntilItHasSucceeded() throws {
        let context = try makeContext("Flag")
        let accountID = AccountID()
        let record = FavoriteRecord(
            accountID: accountID,
            forum: Forum(id: ForumID(nga: 414), name: "综合游戏讨论区"),
            order: 0,
            syncState: .synced,
            serverPresent: true
        )
        makeLegacy(record)
        context.insert(record)
        try context.save()

        LegacyStoreBackfill.runIfNeeded(in: context, defaults: defaults)
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<FavoriteRecord>()).first?.forumKey,
            "414"
        )

        // 标记已经落地，第二趟不该再动数据；把键清掉验证它确实没跑。
        try context.fetch(FetchDescriptor<FavoriteRecord>()).first?.forumKey = ""
        try context.save()
        LegacyStoreBackfill.runIfNeeded(in: context, defaults: defaults)
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<FavoriteRecord>()).first?.forumKey,
            "",
            "标记已落地就不该再跑"
        )
    }

    /// 画像原本按裸 uid 存主键。不迁移的话下次生成会新插一条，
    /// 列表里就出现两条同一个人的画像。
    @MainActor
    func testBackfillRekeysAIProfilesBySite() throws {
        let context = try makeContext("AIProfile")
        let record = AIProfileSummaryRecord(
            site: .nga,
            uid: 42,
            displayName: "某用户",
            avatarURL: nil,
            summary: "画像正文",
            model: "gpt-test",
            topicCount: 1,
            replyCount: 2,
            wasTruncated: false
        )
        record.id = "42"          // 老格式：只有 uid
        context.insert(record)
        try context.save()

        LegacyStoreBackfill.run(in: context)

        let stored = try context.fetch(FetchDescriptor<AIProfileSummaryRecord>())
        XCTAssertEqual(stored.count, 1, "回填不该多出行来")
        XCTAssertEqual(stored.first?.id, "nga:42")
        XCTAssertEqual(stored.first?.summary, "画像正文", "花过 token 的结果要留住")
    }

    // MARK: -

    /// 把一行改回 C12 之前的样子：键为空，主键按旧算法拼。
    private func makeLegacy(_ record: FavoriteRecord) {
        record.forumKey = ""
    }

    private func makeLegacy(_ record: RecentForumRecord, accountID: AccountID) {
        record.forumKey = ""
        record.id = "\(accountID.description):\(record.forumID)"
    }

    private func makeLegacy(_ record: SubforumPreferenceRecord, accountID: AccountID) {
        record.parentForumKey = ""
        record.selectedForumKeysRaw = ""
        record.id = "\(accountID.description):\(record.parentForumID)"
    }

    @MainActor
    private func makeContext(_ name: String) throws -> ModelContext {
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
                    "LegacyStoreBackfillTests.\(name).\(UUID().uuidString)",
                    schema: schema,
                    isStoredInMemoryOnly: true
                )
            ]
        )
        return ModelContext(container)
    }
}
