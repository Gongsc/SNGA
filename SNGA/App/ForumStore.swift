import Foundation
import Observation
import SwiftData

/// 版面浏览域：版面目录、最近访问、话题列表、子版面筛选。
///
/// 只依赖 `AppSession`。导航（侧栏选择、切换版面时清空详情栏）留在 AppModel，
/// 本域只需要「用户是否还停在这个版面」这一个判断。
@MainActor
@Observable
final class ForumStore {
    var forums: [Forum] = []
    var recentForums: [Forum] = []
    var topics: [Topic] = []
    var subforums: [Forum] = []
    var includedSubforumIDs: Set<ForumID> = []
    var forumNavigationPath: [Forum] = []
    var currentForum: Forum?

    var topicPage = 1
    var topicHasMore = false
    var topicTotalPages = 1

    var isRefreshingTopics = false
    var topicListScrollToTopRevision = 0
    var topicListSortOrder: TopicListSortOrder = .latestReply
    var isShowingFeaturedTopics = false

    @ObservationIgnored private let session: AppSession
    @ObservationIgnored private let forumDirectoryRequests = RequestSlot()
    @ObservationIgnored private let topicListRequests = RequestSlot()
    @ObservationIgnored private var subforumSelectionForumID: ForumID?
    @ObservationIgnored private var isForumStillSelected: (ForumID) -> Bool = { _ in true }
    @ObservationIgnored private var isTopicFavorite: (TopicID) -> Bool = { _ in false }
    @ObservationIgnored private var directoryDidLoad: () -> Void = {}

    init(session: AppSession) {
        self.session = session
    }

    func provideSelectionCheck(_ check: @escaping (ForumID) -> Bool) {
        isForumStillSelected = check
    }

    func provideFavoriteLookup(_ lookup: @escaping (TopicID) -> Bool) {
        isTopicFavorite = lookup
    }

    /// 版面目录加载完成。收藏项要靠它补全版面信息。
    func onDirectoryLoad(_ handler: @escaping () -> Void) {
        directoryDidLoad = handler
    }

    /// 切换到某个版面时重置本域状态。跨域清理由 AppModel 负责。
    func beginShowing(_ forum: Forum) {
        currentForum = forum
        recordRecentForum(forum)
        topics = []
        topicPage = 1
        topicHasMore = false
        topicTotalPages = 1
        subforums = []
        includedSubforumIDs = []
        subforumSelectionForumID = nil
    }

    private func merged<T: Identifiable>(
        _ existing: [T],
        _ incoming: [T]
    ) -> [T] where T.ID: Hashable {
        var seen = Set(existing.map(\.id))
        return existing + incoming.filter { seen.insert($0.id).inserted }
    }

    func reset() {
        forums = []
        recentForums = []
        topics = []
        subforums = []
        includedSubforumIDs = []
        forumNavigationPath = []
        currentForum = nil
        subforumSelectionForumID = nil
        topicPage = 1
        topicHasMore = false
        topicTotalPages = 1
        isRefreshingTopics = false
        forumDirectoryRequests.invalidate()
        topicListRequests.invalidate()
    }

    var parentForum: Forum? {
        forumNavigationPath.last
    }

    var forumCategories: [ForumCategory] {
        var order: [String] = []
        var grouped: [String: [Forum]] = [:]
        for forum in forums {
            let category = forum.category?.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = category.flatMap { $0.isEmpty ? nil : $0 } ?? "其他版面"
            if grouped[name] == nil { order.append(name) }
            grouped[name, default: []].append(forum)
        }
        return order.map { ForumCategory(id: $0, name: $0, forums: grouped[$0] ?? []) }
    }

    var displayedTopics: [Topic] {
        guard !subforums.isEmpty else { return topics }
        let directSubforumIDs = Set(subforums.map(\.id))
        return topics.filter { topic in
            if let sourceForumID = topic.sourceForumID,
               directSubforumIDs.contains(sourceForumID) {
                return includedSubforumIDs.contains(sourceForumID)
            }
            if let sourceParentForumID = topic.sourceParentForumID,
               directSubforumIDs.contains(sourceParentForumID) {
                return includedSubforumIDs.contains(sourceParentForumID)
            }
            return true
        }
    }

    func loadForums() async {
        guard let service = session.activeService else { return }
        let requestAccountID = service.accountID
        let ticket = forumDirectoryRequests.begin()
        await session.withLoading(isCurrent: { ticket.isCurrent }) {
            // NGA 的接口顺序就是官网分组和版面顺序，不能在这里全局排序。
            let result = try await service.forums()
            guard session.activeAccountID == requestAccountID,
                  ticket.isCurrent else {
                return
            }
            forums = result
            recentForums = recentForums.map(enrichingForumFromDirectory)
            directoryDidLoad()
        }
    }

    func loadRecentForums() {
        guard let activeAccountID = session.activeAccountID else {
            recentForums = []
            return
        }
        do {
            let maximumCount = RecentForumSettings.maximumCount
            let records = try sortedRecentForumRecords(accountID: activeAccountID)
            let discardedRecords = records.dropFirst(maximumCount)
            discardedRecords.forEach(session.context.delete)
            if !discardedRecords.isEmpty {
                try session.context.save()
            }
            recentForums = records
                .prefix(maximumCount)
                .map(\.forum)
                .map(enrichingForumFromDirectory)
        } catch {
            recentForums = []
            session.present(error)
        }
    }

    func updateRecentForumLimit(_ maximumCount: Int) {
        do {
            let maximumCount = RecentForumSettings.normalizedMaximumCount(maximumCount)
            UserDefaults.standard.set(
                maximumCount,
                forKey: RecentForumSettings.maximumCountKey
            )
            let records = try session.context.fetch(FetchDescriptor<RecentForumRecord>())
            let groupedRecords = Dictionary(grouping: records, by: \.accountIDString)
            var removedAnyRecord = false
            for accountRecords in groupedRecords.values {
                let sortedRecords = accountRecords.sorted(by: recentForumRecordComesFirst)
                for record in sortedRecords.dropFirst(maximumCount) {
                    session.context.delete(record)
                    removedAnyRecord = true
                }
            }
            if removedAnyRecord {
                try session.context.save()
            }
            loadRecentForums()
        } catch {
            session.present(error)
        }
    }

    func recordRecentForum(
        _ forum: Forum,
        updatesVisitOrder: Bool = true
    ) {
        guard let activeAccountID = session.activeAccountID else { return }
        do {
            let forum = enrichingForumFromDirectory(forum)
            let recordID = RecentForumRecord.recordID(
                accountID: activeAccountID,
                forumID: forum.id
            )
            let records = try recentForumRecords(accountID: activeAccountID)
            if let record = records.first(where: { $0.id == recordID }) {
                record.update(
                    forum: forum,
                    visitedAt: updatesVisitOrder ? .now : nil
                )
            } else {
                session.context.insert(RecentForumRecord(
                    accountID: activeAccountID,
                    forum: forum
                ))
            }
            try session.context.save()
            loadRecentForums()
        } catch {
            session.present(error)
        }
    }

    func loadTopics(forumID: ForumID, reset: Bool) async {
        guard let service = session.activeService else { return }
        let requestAccountID = service.accountID
        let ticket = topicListRequests.begin()
        isRefreshingTopics = true
        defer {
            if ticket.isCurrent {
                isRefreshingTopics = false
            }
        }
        let page = reset ? 1 : topicPage + 1
        await session.withLoading(isCurrent: { ticket.isCurrent }) {
            let result = try await service.topics(
                forumID: forumID,
                page: page,
                sortOrder: topicListSortOrder,
                featuredOnly: isShowingFeaturedTopics
            )
            guard session.activeAccountID == requestAccountID,
                  ticket.isCurrent,
                  isForumStillSelected(forumID) else {
                return
            }
            applyForumPage(result, forumID: forumID, replaceTopics: reset)
        }
    }

    func loadTopicPage(forumID: ForumID, page: Int) async {
        guard let service = session.activeService else { return }
        let requestAccountID = service.accountID
        let ticket = topicListRequests.begin()
        isRefreshingTopics = true
        defer {
            if ticket.isCurrent {
                isRefreshingTopics = false
            }
        }
        let targetPage = max(1, min(page, topicTotalPages))
        await session.withLoading(isCurrent: { ticket.isCurrent }) {
            let result = try await service.topics(
                forumID: forumID,
                page: targetPage,
                sortOrder: topicListSortOrder,
                featuredOnly: isShowingFeaturedTopics
            )
            guard session.activeAccountID == requestAccountID,
                  ticket.isCurrent,
                  isForumStillSelected(forumID) else {
                return
            }
            applyForumPage(result, forumID: forumID, replaceTopics: true)
        }
    }

    private func applyForumPage(
        _ result: ForumPage,
        forumID: ForumID,
        replaceTopics: Bool
    ) {
        // 只认「这一页确实是这个版面」的描述。
        //
        // 请求哪个版面、回来的是不是同一个，这件事以前指望各站的解析器自己把住 ——
        // NGA 的解析器确实有这道检查，但它在解析器里面，别的适配器不受它管。
        // 结果是：服务端给回一个别的版面，这里照记不误，最近访问里就凭空多一条。
        // 检查挪到用的地方，谁来都逃不过。
        let describedForum = result.forum.flatMap { $0.id == forumID ? $0 : nil }
        currentForum = describedForum ?? currentForum ?? forums.first { $0.id == forumID }
        // 记的必须是刚才打开的那个版面。不是的话宁可不记 —— 记错比不记更难收拾。
        if let currentForum, currentForum.id == forumID {
            recordRecentForum(currentForum, updatesVisitOrder: false)
        }
        topics = replaceTopics ? result.topics : merged(topics, result.topics)
        if result.page == 1 || !result.subforums.isEmpty || subforums.isEmpty {
            let previousSubforumIDs = Set(subforums.map(\.id))
            let knownForums = Dictionary(
                forums.map { ($0.id, $0) },
                uniquingKeysWith: { current, _ in current }
            )
            subforums = result.subforums.map { forum in
                guard let known = knownForums[forum.id] else { return forum }
                return Forum(
                    id: forum.id,
                    name: forum.name,
                    subtitle: forum.subtitle ?? known.subtitle,
                    iconURL: forum.iconURL ?? known.iconURL,
                    category: forum.category ?? known.category,
                    pinnedTopicID: forum.pinnedTopicID ?? known.pinnedTopicID,
                    isSelectedInParent: forum.isSelectedInParent
                )
            }
            let loadedSubforumIDs = Set(subforums.map(\.id))
            let serverSelectedSubforumIDs = Set(
                subforums
                    .filter { $0.isSelectedInParent == true }
                    .map(\.id)
            )
            if subforumSelectionForumID != forumID {
                let preferredSubforumIDs = savedSubforumSelection(
                    parentForumID: forumID
                ) ?? serverSelectedSubforumIDs
                includedSubforumIDs = preferredSubforumIDs.intersection(
                    loadedSubforumIDs
                )
                subforumSelectionForumID = forumID
            } else {
                includedSubforumIDs.formUnion(
                    serverSelectedSubforumIDs.subtracting(previousSubforumIDs)
                )
                includedSubforumIDs.formIntersection(loadedSubforumIDs)
            }
        }
        topicPage = result.page
        topicHasMore = result.hasMore
        topicTotalPages = max(result.totalPages, result.page)
    }

    func setSubforumIncluded(_ forumID: ForumID, included: Bool) {
        if included {
            includedSubforumIDs.insert(forumID)
        } else {
            includedSubforumIDs.remove(forumID)
        }
        saveCurrentSubforumSelection()
    }

    func setAllSubforumsIncluded(_ included: Bool) {
        includedSubforumIDs = included ? Set(subforums.map(\.id)) : []
        saveCurrentSubforumSelection()
    }

    private func savedSubforumSelection(parentForumID: ForumID) -> Set<ForumID>? {
        guard let activeAccountID = session.activeAccountID else { return nil }
        let recordID = SubforumPreferenceRecord.recordID(
            accountID: activeAccountID,
            parentForumID: parentForumID
        )
        let records = (try? session.context.fetch(
            FetchDescriptor<SubforumPreferenceRecord>()
        )) ?? []
        return records.first(where: { $0.id == recordID })?.selectedForumIDs
    }

    private func saveCurrentSubforumSelection() {
        guard let activeAccountID = session.activeAccountID, let parentForumID = currentForum?.id else {
            return
        }
        do {
            let recordID = SubforumPreferenceRecord.recordID(
                accountID: activeAccountID,
                parentForumID: parentForumID
            )
            let records = try session.context.fetch(
                FetchDescriptor<SubforumPreferenceRecord>()
            )
            if let record = records.first(where: { $0.id == recordID }) {
                record.selectedForumIDs = includedSubforumIDs
            } else {
                session.context.insert(SubforumPreferenceRecord(
                    accountID: activeAccountID,
                    parentForumID: parentForumID,
                    selectedForumIDs: includedSubforumIDs
                ))
            }
            try session.context.save()
        } catch {
            session.present(error)
        }
    }

    func refreshTopicList() async {
        guard let forumID = currentForum?.id else { return }
        await loadTopicPage(forumID: forumID, page: topicPage)
    }

    private func recentForumRecords(accountID: AccountID) throws -> [RecentForumRecord] {
        try session.context.fetch(FetchDescriptor<RecentForumRecord>())
            .filter { $0.accountIDString == accountID.description }
    }

    private func sortedRecentForumRecords(accountID: AccountID) throws -> [RecentForumRecord] {
        try recentForumRecords(accountID: accountID)
            .sorted(by: recentForumRecordComesFirst)
    }

    private func recentForumRecordComesFirst(
        _ left: RecentForumRecord,
        _ right: RecentForumRecord
    ) -> Bool {
        if left.lastVisitedAt != right.lastVisitedAt {
            return left.lastVisitedAt > right.lastVisitedAt
        }
        return left.id < right.id
    }

    func enrichingForumFromDirectory(_ forum: Forum) -> Forum {
        guard let directoryForum = forums.first(where: { $0.id == forum.id }) else {
            return forum
        }
        var enriched = forum
        if enriched.subtitle?.isEmpty != false { enriched.subtitle = directoryForum.subtitle }
        if enriched.iconURL == nil { enriched.iconURL = directoryForum.iconURL }
        if enriched.category?.isEmpty != false { enriched.category = directoryForum.category }
        return enriched
    }
}
