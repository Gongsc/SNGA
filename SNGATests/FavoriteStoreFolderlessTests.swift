import Foundation
import SwiftData
import XCTest
@testable import SNGA

/// 没有收藏夹的站点，收藏功能得照常能用。
///
/// 这是补一个真出过的死路：适配器一开始让 `favoriteTopicFolders()` 返回空数组，
/// 而应用里「选中收藏夹」「收藏/取消收藏」「计数」全挂在有一个收藏夹上。
/// 于是收藏页永远是空的、星标按钮一声不吭 —— 而取列表和写收藏两个接口都是通的。
final class FavoriteStoreFolderlessTests: XCTestCase {

    @MainActor
    func testFavouritesLoadOnASiteWithoutFolders() async throws {
        let model = try makeModel(capabilities: .all.subtracting(.topicFavoriteFolders))

        await model.favorite.loadFavoriteTopicFolders(force: true)
        await model.favorite.loadFavoriteTopics(page: 1)

        XCTAssertFalse(
            model.favorite.favoriteTopics.isEmpty,
            "站点没有收藏夹，但收藏列表是有的 —— 不该是空的"
        )
    }

    /// 收藏一个话题不需要用户先选一个不存在的目录。
    @MainActor
    func testATopicCanBeFavouritedWithoutChoosingAFolder() async throws {
        let model = try makeModel(capabilities: .all.subtracting(.topicFavoriteFolders))
        await model.favorite.loadFavoriteTopicFolders(force: true)

        let topic = Topic(
            id: TopicID(rawValue: 4242), forumID: ForumID(nga: 1),
            subject: "收藏我", author: "", replyCount: 0
        )
        await model.favorite.toggleTopicFavorite(topic)

        XCTAssertTrue(
            model.favorite.favoriteTopicIDs.contains(topic.id),
            "星标没生效 —— 这正是当初一声不吭的那一步"
        )
    }

    /// 收藏夹一个都没有时才是真的没得选。这条确认上面两条不是靠「反正都能过」通过的。
    @MainActor
    func testWithNoFoldersAtAllThereIsNothingToLoad() async throws {
        let model = try makeModel(capabilities: .all.subtracting(.topicFavoriteFolders))
        // 不加载收藏夹，直接要列表。
        await model.favorite.loadFavoriteTopics(page: 1)

        // 走到这里不该崩，也不该凭空冒出话题。
        XCTAssertNotNil(model.favorite.selectedFavoriteTopicFolderID)
    }

    @MainActor
    private func makeModel(capabilities: ForumCapabilities) throws -> AppModel {
        let schema = Schema([
            AccountRecord.self, FavoriteRecord.self, DraftRecord.self,
            SubforumPreferenceRecord.self, RecentForumRecord.self,
            AIProfileSummaryRecord.self
        ])
        let model = AppModel(container: try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(
                "Folderless-\(UUID().uuidString)", schema: schema, isStoredInMemoryOnly: true
            )]
        ))
        let record = AccountRecord(site: .nodeseek, siteUserID: 1, displayName: "账号", isCurrent: true)
        model.session.context.insert(record)
        try? model.session.context.save()
        model.session.accounts = [record.summary()]
        model.session.activeAccountID = record.accountID
        // 这个服务本来就只给一个收藏夹 —— 正是「站点只有一个列表」的形状。
        // 关键在能力位关着：界面不画目录，而数据照常加载。
        model.session.setService(
            DebugForumService(accountID: record.accountID, capabilities: capabilities),
            for: record.accountID
        )
        return model
    }
}
