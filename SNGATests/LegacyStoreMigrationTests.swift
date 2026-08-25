import Foundation
import SwiftData
import XCTest
@testable import SNGA

/// 拿一份真的由 1.8.2 写出来的库，用当前 schema 打开。
///
/// `SNGATests/Fixtures/legacy-1.8.2.store` 是在 1.8.2 那个提交的工作树里，用它自己的
/// 模型定义生成的：五张表（那时还没有 `AIProfileSummaryRecord`），`FavoriteRecord`
/// 之类只有 `forumID: Int64`，没有站点和键那两列。
///
/// 别的迁移用例都是拿新 schema 建内存库再手动装成老行 —— 验的是回落逻辑，不是迁移
/// 本身。这一条验的是迁移真的能过：容器打得开、行还在、值没串。
///
/// 夹具是这么来的，以后要换基线照做：
///
/// 1. `git worktree add --detach <某处> <基线提交>`
/// 2. 在那份工作树的 `SNGATests/` 里放一个临时用例，用**那个版本的**模型定义
///    往一个写死的路径建 `ModelContainer(configurations: [.init(schema:url:)])`，
///    塞进有代表性的行（普通版面、子版面、子版面偏好、草稿），`save()`。
///    路径要写死 —— `xcodebuild` 不会把环境变量传进测试包。
/// 3. 跑那一条用例，把生成的 `.store` 拷到 `SNGATests/Fixtures/`，`xcodegen generate`
///    会自动把它挂进测试包资源。
/// 4. 删掉工作树。
final class LegacyStoreMigrationTests: XCTestCase {

    private let accountUID: Int64 = 42_000_042
    private let plainForumID = ForumID(nga: 414)
    private let subforumID = ForumID(ngaSubforum: 35_925_536)

    @MainActor
    func testStoreWrittenBy182OpensUnderTheCurrentSchema() throws {
        let context = try openMigratedCopy()

        let accounts = try context.fetch(FetchDescriptor<AccountRecord>())
        XCTAssertEqual(accounts.count, 1)
        XCTAssertEqual(accounts.first?.ngaUID, accountUID)
        XCTAssertEqual(accounts.first?.displayName, "老库账号")
        XCTAssertEqual(accounts.first?.isCurrent, true)
        XCTAssertEqual(accounts.first?.lastCheckInDay, "2026-08-01")

        XCTAssertEqual(try context.fetch(FetchDescriptor<FavoriteRecord>()).count, 2)
        XCTAssertEqual(try context.fetch(FetchDescriptor<RecentForumRecord>()).count, 2)
        XCTAssertEqual(try context.fetch(FetchDescriptor<SubforumPreferenceRecord>()).count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<DraftRecord>()).count, 1)
        // 1.8.2 之后才加的表，老库里没有，迁移后应该是空的而不是打不开。
        XCTAssertEqual(try context.fetch(FetchDescriptor<AIProfileSummaryRecord>()).count, 0)
    }

    /// 回填之前，老行的键是空的，版面身份只能从 Int64 回落着读。
    @MainActor
    func testForumsReadCorrectlyBeforeTheBackfillRuns() throws {
        let context = try openMigratedCopy()

        let favorites = try context.fetch(
            FetchDescriptor<FavoriteRecord>(sortBy: [SortDescriptor(\.order)])
        )
        XCTAssertEqual(favorites.map(\.forumKey), ["", ""], "老行不该凭空有键")
        XCTAssertEqual(favorites.map(\.forumIdentifier), [plainForumID, subforumID])
        XCTAssertEqual(favorites.map(\.forum.name), ["综合游戏讨论区", "幻兽帕鲁"])
        XCTAssertEqual(favorites.map(\.forum.isSubforum), [false, true])
        XCTAssertEqual(favorites.map(\.syncState), [.synced, .pendingAdd])

        let preference = try XCTUnwrap(
            try context.fetch(FetchDescriptor<SubforumPreferenceRecord>()).first
        )
        XCTAssertEqual(preference.parentForumIdentifier, plainForumID)
        XCTAssertEqual(
            preference.selectedForumIDs,
            [ForumID(nga: 510_381), subforumID]
        )
    }

    /// 回填跑完：键补齐、主键换成新格式、行数不变。
    @MainActor
    func testBackfillCompletesTheMigratedStoreWithoutDuplicating() throws {
        let context = try openMigratedCopy()
        let accountID = try XCTUnwrap(
            try context.fetch(FetchDescriptor<AccountRecord>()).first?.accountID
        )

        ForumKeyBackfill.run(in: context)

        let favorites = try context.fetch(
            FetchDescriptor<FavoriteRecord>(sortBy: [SortDescriptor(\.order)])
        )
        XCTAssertEqual(favorites.count, 2, "回填不该多出行来")
        XCTAssertEqual(favorites.map(\.forumKey), ["414", "s35925536"])
        XCTAssertEqual(favorites.map(\.forumIdentifier), [plainForumID, subforumID])

        let recents = try context.fetch(FetchDescriptor<RecentForumRecord>())
        XCTAssertEqual(recents.count, 2)
        XCTAssertEqual(
            Set(recents.map(\.id)),
            [
                RecentForumRecord.recordID(accountID: accountID, forumID: plainForumID),
                RecentForumRecord.recordID(accountID: accountID, forumID: subforumID)
            ],
            "主键没换成按键拼的形式，下次访问会插重复"
        )
        XCTAssertEqual(
            Set(recents.map(\.forumIdentifier)),
            [plainForumID, subforumID]
        )
        // 图标、分类、置顶话题这些一起从老库带过来。
        let subforumRecent = try XCTUnwrap(recents.first { $0.forumIdentifier == subforumID })
        XCTAssertEqual(subforumRecent.forum.category, "游戏")
        XCTAssertEqual(subforumRecent.forum.pinnedTopicID, TopicID(rawValue: 9003))
        XCTAssertEqual(subforumRecent.forum.iconURL?.scheme, "https")

        let preference = try XCTUnwrap(
            try context.fetch(FetchDescriptor<SubforumPreferenceRecord>()).first
        )
        XCTAssertEqual(
            preference.id,
            SubforumPreferenceRecord.recordID(
                accountID: accountID,
                parentForumID: plainForumID
            )
        )
        XCTAssertEqual(preference.selectedForumKeysRaw, "510381,s35925536")
        XCTAssertEqual(
            preference.selectedForumIDs,
            [ForumID(nga: 510_381), subforumID]
        )

        let draft = try XCTUnwrap(try context.fetch(FetchDescriptor<DraftRecord>()).first)
        XCTAssertEqual(draft.content, "老库草稿")
    }

    // MARK: -

    /// 每条用例都在自己的副本上跑：打开容器会就地迁移那个文件。
    @MainActor
    private func openMigratedCopy() throws -> ModelContext {
        let fixture = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "legacy-1.8.2", withExtension: "store"),
            "测试包里没有 1.8.2 的库夹具"
        )
        let copy = FileManager.default.temporaryDirectory
            .appending(path: "legacy-\(UUID().uuidString).store")
        try FileManager.default.copyItem(at: fixture, to: copy)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: copy)
        }

        let schema = Schema([
            AccountRecord.self,
            FavoriteRecord.self,
            DraftRecord.self,
            SubforumPreferenceRecord.self,
            RecentForumRecord.self,
            AIProfileSummaryRecord.self
        ])
        // 这一行就是被测的迁移：老库 + 新 schema，打不开就抛。
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, url: copy)]
        )
        return ModelContext(container)
    }
}
