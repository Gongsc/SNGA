import Foundation
import SwiftData
import XCTest
@testable import SNGA

/// 搜索历史：只记关键词、去重、按上限截断、按账号隔离。
final class SearchHistoryTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: SearchHistorySettings.maximumCountKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: SearchHistorySettings.maximumCountKey)
        super.tearDown()
    }

    private func makeContainer(_ name: String) throws -> ModelContainer {
        let schema = Schema([
            AccountRecord.self,
            FavoriteRecord.self,
            DraftRecord.self,
            SubforumPreferenceRecord.self,
            RecentForumRecord.self,
            SearchHistoryRecord.self,
            AIProfileSummaryRecord.self
        ])
        return try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(
                "\(name)-\(UUID().uuidString)",
                schema: schema,
                isStoredInMemoryOnly: true
            )]
        )
    }

    @MainActor
    func testHistoryIsDeduplicatedOrderedTrimmedAndPersisted() throws {
        let container = try makeContainer("SearchHistory")
        let accountID = AccountID(rawValue: UUID())
        let model = AppModel(container: container)
        model.session.activeAccountID = accountID

        model.searchHistory.record("显卡")
        model.searchHistory.record("  键盘  ")
        // 同一个词再搜一次是把它挪到最前，不是插第二行。
        model.searchHistory.record("显卡")

        XCTAssertEqual(model.searchHistory.entries, ["显卡", "键盘"])

        // 默认十条：第十一个词进来时最早的那个出局。
        XCTAssertEqual(SearchHistorySettings.defaultMaximumCount, 10)
        for index in 1...9 {
            model.searchHistory.record("关键词\(index)")
        }
        XCTAssertEqual(model.searchHistory.entries.count, 10)
        XCTAssertEqual(model.searchHistory.entries.first, "关键词9")
        XCTAssertFalse(model.searchHistory.entries.contains("键盘"))
        XCTAssertTrue(model.searchHistory.entries.contains("显卡"))

        // 重开一次应用，历史还在。
        let restoredModel = AppModel(container: container)
        restoredModel.session.activeAccountID = accountID
        restoredModel.searchHistory.reload()
        XCTAssertEqual(restoredModel.searchHistory.entries, model.searchHistory.entries)
    }

    @MainActor
    func testHistoryIsScopedToTheAccount() throws {
        let container = try makeContainer("SearchHistoryScope")
        let firstAccountID = AccountID(rawValue: UUID())
        let secondAccountID = AccountID(rawValue: UUID())
        let model = AppModel(container: container)

        model.session.activeAccountID = firstAccountID
        model.searchHistory.record("第一个账号搜的")

        // 账号即站点：换一个账号看到的是另一份历史，而不是对方站上搜不出东西的词。
        model.session.activeAccountID = secondAccountID
        model.searchHistory.reload()
        XCTAssertTrue(model.searchHistory.entries.isEmpty)

        model.searchHistory.record("第二个账号搜的")
        XCTAssertEqual(model.searchHistory.entries, ["第二个账号搜的"])

        model.session.activeAccountID = firstAccountID
        model.searchHistory.reload()
        XCTAssertEqual(model.searchHistory.entries, ["第一个账号搜的"])

        // 没有账号时既不读也不写，而不是攒一份无主的历史。
        model.session.activeAccountID = nil
        model.searchHistory.reload()
        XCTAssertTrue(model.searchHistory.entries.isEmpty)
        model.searchHistory.record("无主的词")
        XCTAssertTrue(model.searchHistory.entries.isEmpty)
    }

    @MainActor
    func testEntriesCanBeRemovedOneByOneOrAllAtOnce() throws {
        let container = try makeContainer("SearchHistoryRemoval")
        let accountID = AccountID(rawValue: UUID())
        let model = AppModel(container: container)
        model.session.activeAccountID = accountID

        model.searchHistory.record("留下的")
        model.searchHistory.record("删掉的")
        model.searchHistory.remove("删掉的")
        XCTAssertEqual(model.searchHistory.entries, ["留下的"])

        // 删过的词不该在重开之后自己回来。
        let restoredModel = AppModel(container: container)
        restoredModel.session.activeAccountID = accountID
        restoredModel.searchHistory.reload()
        XCTAssertEqual(restoredModel.searchHistory.entries, ["留下的"])

        restoredModel.searchHistory.record("再来一个")
        restoredModel.searchHistory.clear()
        XCTAssertTrue(restoredModel.searchHistory.entries.isEmpty)

        let reloadedModel = AppModel(container: container)
        reloadedModel.session.activeAccountID = accountID
        reloadedModel.searchHistory.reload()
        XCTAssertTrue(reloadedModel.searchHistory.entries.isEmpty)
    }

    @MainActor
    func testLoweringTheLimitDeletesTheOverflowInsteadOfHidingIt() throws {
        let container = try makeContainer("SearchHistoryLimit")
        let accountID = AccountID(rawValue: UUID())
        let model = AppModel(container: container)
        model.session.activeAccountID = accountID

        for index in 1...6 {
            model.searchHistory.record("词\(index)")
        }
        XCTAssertEqual(model.searchHistory.entries.count, 6)

        model.searchHistory.updateLimit(3)
        XCTAssertEqual(model.searchHistory.entries, ["词6", "词5", "词4"])

        // 调回大的数字时被删掉的行不该冒出来 —— 用户按「只留 3 条」时想的是「其余的没了」。
        model.searchHistory.updateLimit(10)
        XCTAssertEqual(model.searchHistory.entries, ["词6", "词5", "词4"])
    }

    @MainActor
    func testSearchingRecordsTheKeywordAndOnlyTheKeyword() async throws {
        let container = try makeContainer("SearchHistoryFromSearch")
        let accountID = AccountID(rawValue: UUID())
        let model = AppModel(container: container)
        model.session.activeAccountID = accountID
        model.session.setService(DebugForumService(accountID: accountID), for: accountID)

        let request = try XCTUnwrap(
            ForumSearchRequest(query: "  暗夜精灵  ", kind: .topicSubject)
        )
        await model.searchForum(request)
        XCTAssertEqual(model.searchHistory.entries, ["暗夜精灵"])

        // 换个档位搜同一个词仍然只有一行：历史里的单位是词，不是「词 + 档位」。
        let sameKeywordOtherKind = try XCTUnwrap(
            ForumSearchRequest(query: "暗夜精灵", kind: .topicContent)
        )
        await model.searchForum(sameKeywordOtherKind)
        XCTAssertEqual(model.searchHistory.entries, ["暗夜精灵"])

        // 翻页重发的是同一个请求，也不该多出一行。
        await model.loadForumSearchPage(2)
        XCTAssertEqual(model.searchHistory.entries, ["暗夜精灵"])
    }
}
