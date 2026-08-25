import Foundation
import Observation
import SwiftData

/// 收藏域：版面收藏（含与站端的三方合并与待同步队列）和话题收藏夹。
///
/// 只依赖 `AppSession`。两处跨域协作用注入处理：
/// 版面目录用来补全收藏项的版面信息，收藏状态变化则广播出去，
/// 由话题列表和当前话题各自跟进 —— 收藏域不直接写别的域的状态。
@MainActor
@Observable
final class FavoriteStore {
    var favorites: [FavoriteSnapshot] = []
    var favoriteTopicFolders: [TopicFavoriteFolder] = []
    var selectedFavoriteTopicFolderID: String?
    var favoriteTopics: [Topic] = []
    var favoriteTopicPage = 1
    var favoriteTopicHasMore = false
    var favoriteTopicTotalPages = 1
    var updatingFavoriteTopicIDs: Set<TopicID> = []
    var isUpdatingFavoriteTopicFolders = false

    @ObservationIgnored private let session: AppSession
    @ObservationIgnored private let favoriteRequests = RequestSlot()
    @ObservationIgnored private let favoriteTopicFolderRequests = RequestSlot()
    @ObservationIgnored private let favoriteTopicRequests = RequestSlot()
    @ObservationIgnored private(set) var favoriteTopicIDs: Set<TopicID> = []
    @ObservationIgnored private var favoriteTopicFolderIDsByTopic: [TopicID: Set<String>] = [:]

    /// 用版面目录补全收藏项里的版面信息（名称、分区等）。
    @ObservationIgnored private var enrichForum: (Forum) -> Forum = { $0 }
    /// 某个话题的收藏状态变了。话题列表与当前话题据此更新自己的标记。
    @ObservationIgnored private var favoriteDidChange: (TopicID, Bool) -> Void = { _, _ in }

    init(session: AppSession) {
        self.session = session
    }

    func provideForumEnrichment(_ enrich: @escaping (Forum) -> Forum) {
        enrichForum = enrich
    }

    func onFavoriteChange(_ handler: @escaping (TopicID, Bool) -> Void) {
        favoriteDidChange = handler
    }

    func contains(_ topicID: TopicID) -> Bool {
        favoriteTopicIDs.contains(topicID)
    }

    /// 版面目录加载完成后重新补全收藏项 —— 收藏接口返回的版面信息往往不全。
    func refreshForumDetails() {
        favorites = enrichingFavoriteForums(favorites)
    }

    func reset() {
        favorites = []
        favoriteTopicFolders = []
        selectedFavoriteTopicFolderID = nil
        favoriteTopics = []
        favoriteTopicIDs = []
        favoriteTopicFolderIDsByTopic = [:]
        favoriteTopicPage = 1
        favoriteTopicHasMore = false
        favoriteTopicTotalPages = 1
        updatingFavoriteTopicIDs = []
        isUpdatingFavoriteTopicFolders = false
        favoriteRequests.invalidate()
        favoriteTopicFolderRequests.invalidate()
        favoriteTopicRequests.invalidate()
    }

    private func broadcastFavoriteChange(_ topicID: TopicID, _ isFavorite: Bool) {
        favoriteDidChange(topicID, isFavorite)
    }

    private func enrichingFavoriteForums(
        _ snapshots: [FavoriteSnapshot]
    ) -> [FavoriteSnapshot] {
        snapshots.map { snapshot in
            var enriched = snapshot
            enriched.forum = enrichForum(snapshot.forum)
            return enriched
        }
    }

    private func enrichingForumFromDirectory(_ forum: Forum) -> Forum {
        enrichForum(forum)
    }

    var selectedFavoriteTopicFolder: TopicFavoriteFolder? {
        favoriteTopicFolders.first { $0.id == selectedFavoriteTopicFolderID }
    }

    var sortedFavoriteTopicFolders: [TopicFavoriteFolder] {
        favoriteTopicFolders.sorted { left, right in
            if left.isDefault != right.isDefault { return left.isDefault }
            return left.name.localizedStandardCompare(right.name) == .orderedAscending
        }
    }

    /// 版面收藏是主动去拉的，所以门控放在这里而不是六个调用点上 ——
    /// 漏一个就会在启动时弹一个「不支持」。
    func refreshFavorites() async {
        guard session.supports(.forumFavorites) else {
            favorites = []
            return
        }
        await performRefreshFavorites()
    }

    private func performRefreshFavorites() async {
        guard let accountID = session.activeAccountID else {
            favorites = []
            return
        }
        let records = favoriteRecords(accountID: accountID)
        let local = enrichingFavoriteForums(
            records.map {
                FavoriteSnapshot(forum: $0.forum, order: $0.order, state: $0.syncState)
            }
        )
        favorites = local.filter { $0.state != .pendingRemove }.sorted { $0.order < $1.order }
        guard let service = session.service(for: accountID) else { return }
        let ticket = favoriteRequests.begin()

        do {
            let fetchedFavorites = try await service.favorites()
            guard session.activeAccountID == accountID,
                  ticket.isCurrent else {
                return
            }
            let server = fetchedFavorites.map(enrichingForumFromDirectory)
            let result = FavoriteSyncEngine.merge(server: server, local: local)
            reconcileFavorites(result.visible, accountID: accountID)
            favorites = result.visible
            await replayFavoriteChanges(accountID: accountID, service: service)
        } catch {
            // 收藏读取失败时保留完整本地状态，不阻断论坛浏览。
        }
    }

    func toggleFavorite(_ forum: Forum) async {
        guard session.supports(.forumFavorites),
              let accountID = session.activeAccountID else { return }
        let records = favoriteRecords(accountID: accountID)
        if let record = records.first(where: {
            $0.forumIdentifier == forum.id
        }) {
            if record.syncState == .localOnly || !record.serverPresent {
                session.context.delete(record)
            } else {
                record.syncState = .pendingRemove
                record.updatedAt = Date()
            }
        } else {
            let order = (records.map(\.order).max() ?? -1) + 1
            session.context.insert(FavoriteRecord(accountID: accountID, forum: forum, order: order, syncState: .pendingAdd, serverPresent: false))
        }
        try? session.context.save()
        favorites = enrichingFavoriteForums(
            favoriteRecords(accountID: accountID)
                .filter { $0.syncState != .pendingRemove }
                .map {
                    FavoriteSnapshot(forum: $0.forum, order: $0.order, state: $0.syncState)
                }
                .sorted { $0.order < $1.order }
        )
        if let service = session.service(for: accountID) {
            await replayFavoriteChanges(accountID: accountID, service: service)
        }
    }

    func loadFavoriteTopicFolders(force: Bool = false) async {
        guard force || favoriteTopicFolders.isEmpty else { return }
        guard let service = session.activeService else {
            favoriteTopicFolders = []
            selectedFavoriteTopicFolderID = nil
            return
        }
        let requestAccountID = service.accountID
        let ticket = favoriteTopicFolderRequests.begin()
        await session.withLoading(isCurrent: { ticket.isCurrent }) {
            let folders = try await service.favoriteTopicFolders()
            guard session.activeAccountID == requestAccountID,
                  ticket.isCurrent else {
                return
            }
            applyFavoriteTopicFolders(folders)
        }
    }

    func selectFavoriteTopicFolder(_ folderID: String) async {
        guard favoriteTopicFolders.contains(where: { $0.id == folderID }) else { return }
        selectedFavoriteTopicFolderID = folderID
        favoriteTopicPage = 1
        favoriteTopicHasMore = false
        favoriteTopicTotalPages = 1
        favoriteTopics = []
        await loadFavoriteTopics(page: 1)
    }

    func loadFavoriteTopics(page: Int = 1) async {
        if favoriteTopicFolders.isEmpty {
            await loadFavoriteTopicFolders()
        }
        guard let service = session.activeService else {
            favoriteTopics = []
            favoriteTopicIDs = []
            return
        }
        guard let folderID = selectedFavoriteTopicFolderID else {
            favoriteTopics = []
            return
        }
        let requestAccountID = service.accountID
        let ticket = favoriteTopicRequests.begin()
        let targetPage = max(1, page)
        await session.withLoading(isCurrent: { ticket.isCurrent }) {
            let result = try await service.favoriteTopics(folderID: folderID, page: targetPage)
            guard session.activeAccountID == requestAccountID,
                  ticket.isCurrent,
                  selectedFavoriteTopicFolderID == folderID else {
                return
            }
            let values = result.topics.map { topic in
                var topic = topic
                topic.isFavorite = true
                return topic
            }
            favoriteTopics = values
            favoriteTopicIDs.formUnion(values.map(\.id))
            for topic in values {
                favoriteTopicFolderIDsByTopic[topic.id, default: []].insert(folderID)
            }
            favoriteTopicPage = result.page
            favoriteTopicHasMore = result.hasMore
            favoriteTopicTotalPages = max(result.totalPages, result.page)
        }
    }

    func isTopicFavorite(_ topic: Topic, in folder: TopicFavoriteFolder) -> Bool {
        if favoriteTopicFolderIDsByTopic[topic.id]?.contains(folder.id) == true {
            return true
        }
        if favoriteTopicFolderIDsByTopic[topic.id] == nil,
           (topic.isFavorite || favoriteTopicIDs.contains(topic.id)),
           folder.isDefault {
            return true
        }
        return false
    }

    func toggleTopicFavorite(_ topic: Topic, in folderID: String? = nil) async {
        guard let folder = folderID.flatMap({ id in
            favoriteTopicFolders.first { $0.id == id }
        }) ?? favoriteTopicFolders.first(where: \.isDefault) ?? favoriteTopicFolders.first else {
            await loadFavoriteTopicFolders()
            guard let folder = favoriteTopicFolders.first(where: \.isDefault)
                ?? favoriteTopicFolders.first else {
                return
            }
            await setTopicFavorite(topic, in: folder, isFavorite: true)
            return
        }
        await setTopicFavorite(
            topic,
            in: folder,
            isFavorite: !isTopicFavorite(topic, in: folder)
        )
    }

    func setTopicFavorite(
        _ topic: Topic,
        in folder: TopicFavoriteFolder,
        isFavorite: Bool
    ) async {
        guard let service = session.activeService,
              !updatingFavoriteTopicIDs.contains(topic.id) else {
            return
        }
        updatingFavoriteTopicIDs.insert(topic.id)
        defer { updatingFavoriteTopicIDs.remove(topic.id) }
        let wasFavoriteInFolder = isTopicFavorite(topic, in: folder)
        do {
            try await service.updateTopicFavorite(
                topicID: topic.id,
                folderID: folder.id,
                isFavorite: isFavorite
            )
            if isFavorite {
                favoriteTopicFolderIDsByTopic[topic.id, default: []].insert(folder.id)
                favoriteTopicIDs.insert(topic.id)
                var favorite = topic
                favorite.isFavorite = true
                if selectedFavoriteTopicFolderID == folder.id,
                   !favoriteTopics.contains(where: { $0.id == topic.id }) {
                    favoriteTopics.insert(favorite, at: 0)
                }
            } else {
                favoriteTopicFolderIDsByTopic[topic.id]?.remove(folder.id)
                if favoriteTopicFolderIDsByTopic[topic.id]?.isEmpty == true {
                    favoriteTopicFolderIDsByTopic[topic.id] = nil
                    favoriteTopicIDs.remove(topic.id)
                }
                if selectedFavoriteTopicFolderID == folder.id {
                    favoriteTopics.removeAll { $0.id == topic.id }
                }
            }
            if wasFavoriteInFolder != isFavorite,
               let folderIndex = favoriteTopicFolders.firstIndex(where: { $0.id == folder.id }) {
                favoriteTopicFolders[folderIndex].topicCount = max(
                    0,
                    favoriteTopicFolders[folderIndex].topicCount + (isFavorite ? 1 : -1)
                )
            }
            let remainsFavorite = favoriteTopicIDs.contains(topic.id)
            broadcastFavoriteChange(topic.id, remainsFavorite)
            session.statusMessage = isFavorite
                ? "已收藏到“\(folder.name)”"
                : "已从“\(folder.name)”移除"
            session.statusMessageIsError = false
        } catch {
            session.present(error)
        }
    }

    func cancelTopicFavorite(_ topic: Topic) async {
        if favoriteTopicFolders.isEmpty {
            await loadFavoriteTopicFolders()
        }
        guard let service = session.activeService,
              !updatingFavoriteTopicIDs.contains(topic.id) else {
            return
        }

        let knownFolderIDs = favoriteTopicFolderIDsByTopic[topic.id] ?? []
        let targetFolders: [TopicFavoriteFolder]
        if knownFolderIDs.isEmpty {
            targetFolders = [
                favoriteTopicFolders.first(where: \.isDefault)
                    ?? favoriteTopicFolders.first
            ].compactMap(\.self)
        } else {
            targetFolders = favoriteTopicFolders.filter {
                knownFolderIDs.contains($0.id)
            }
        }
        guard !targetFolders.isEmpty else { return }

        updatingFavoriteTopicIDs.insert(topic.id)
        defer { updatingFavoriteTopicIDs.remove(topic.id) }
        do {
            for folder in targetFolders {
                try await service.updateTopicFavorite(
                    topicID: topic.id,
                    folderID: folder.id,
                    isFavorite: false
                )
                favoriteTopicFolderIDsByTopic[topic.id]?.remove(folder.id)
                if let folderIndex = favoriteTopicFolders.firstIndex(where: { $0.id == folder.id }) {
                    favoriteTopicFolders[folderIndex].topicCount = max(
                        0,
                        favoriteTopicFolders[folderIndex].topicCount - 1
                    )
                }
                if selectedFavoriteTopicFolderID == folder.id {
                    favoriteTopics.removeAll { $0.id == topic.id }
                }
            }

            if favoriteTopicFolderIDsByTopic[topic.id]?.isEmpty != false {
                favoriteTopicFolderIDsByTopic[topic.id] = nil
                favoriteTopicIDs.remove(topic.id)
                broadcastFavoriteChange(topic.id, false)
            }
            session.statusMessage = "已取消话题收藏"
            session.statusMessageIsError = false
        } catch {
            session.present(error)
        }
    }

    func createTopicFavoriteFolder(
        name: String,
        isPublic: Bool,
        isDefault: Bool
    ) async -> Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty,
              let service = session.activeService,
              !isUpdatingFavoriteTopicFolders else {
            return false
        }
        isUpdatingFavoriteTopicFolders = true
        defer { isUpdatingFavoriteTopicFolders = false }
        do {
            let folderID = try await service.createTopicFavoriteFolder(
                name: trimmedName,
                isPublic: isPublic,
                isDefault: isDefault
            )
            let folders = try await service.favoriteTopicFolders()
            applyFavoriteTopicFolders(folders, preferredID: folderID)
            session.statusMessage = "收藏夹已创建"
            session.statusMessageIsError = false
            if selectedFavoriteTopicFolderID != nil {
                await loadFavoriteTopics(page: 1)
            }
            return true
        } catch {
            session.present(error)
            return false
        }
    }

    func updateTopicFavoriteFolder(_ folder: TopicFavoriteFolder) async -> Bool {
        let trimmedName = folder.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty,
              let service = session.activeService,
              !isUpdatingFavoriteTopicFolders else {
            return false
        }
        var updatedFolder = folder
        updatedFolder.name = trimmedName
        isUpdatingFavoriteTopicFolders = true
        defer { isUpdatingFavoriteTopicFolders = false }
        do {
            try await service.updateTopicFavoriteFolder(updatedFolder)
            let folders = try await service.favoriteTopicFolders()
            applyFavoriteTopicFolders(folders, preferredID: folder.id)
            session.statusMessage = "收藏夹设置已更新"
            session.statusMessageIsError = false
            return true
        } catch {
            session.present(error)
            return false
        }
    }

    func deleteTopicFavoriteFolder(_ folder: TopicFavoriteFolder) async -> Bool {
        guard let service = session.activeService,
              !isUpdatingFavoriteTopicFolders else {
            return false
        }
        isUpdatingFavoriteTopicFolders = true
        defer { isUpdatingFavoriteTopicFolders = false }
        do {
            try await service.deleteTopicFavoriteFolder(folderID: folder.id)
            for topicID in Array(favoriteTopicFolderIDsByTopic.keys) {
                favoriteTopicFolderIDsByTopic[topicID]?.remove(folder.id)
                if favoriteTopicFolderIDsByTopic[topicID]?.isEmpty == true {
                    favoriteTopicFolderIDsByTopic[topicID] = nil
                    favoriteTopicIDs.remove(topicID)
                }
            }
            let folders = try await service.favoriteTopicFolders()
            applyFavoriteTopicFolders(folders)
            favoriteTopics = []
            if selectedFavoriteTopicFolderID != nil {
                await loadFavoriteTopics(page: 1)
            }
            session.statusMessage = "收藏夹“\(folder.name)”已删除"
            session.statusMessageIsError = false
            return true
        } catch {
            session.present(error)
            return false
        }
    }

    private func favoriteRecords(accountID: AccountID) -> [FavoriteRecord] {
        ((try? session.context.fetch(FetchDescriptor<FavoriteRecord>())) ?? [])
            .filter { $0.accountIDString == accountID.description }
            .sorted { $0.order < $1.order }
    }

    private func applyFavoriteTopicFolders(
        _ folders: [TopicFavoriteFolder],
        preferredID: String? = nil
    ) {
        favoriteTopicFolders = folders
        let retainedID = preferredID ?? selectedFavoriteTopicFolderID
        if let retainedID, folders.contains(where: { $0.id == retainedID }) {
            selectedFavoriteTopicFolderID = retainedID
        } else {
            selectedFavoriteTopicFolderID = folders.first(where: \.isDefault)?.id
                ?? folders.first?.id
        }
    }

    private func reconcileFavorites(_ snapshots: [FavoriteSnapshot], accountID: AccountID) {
        let records = favoriteRecords(accountID: accountID)
        let snapshotIDs = Set(snapshots.map(\.forum.id))
        for snapshot in snapshots {
            if let record = records.first(where: {
                $0.forumIdentifier == snapshot.forum.id
            }) {
                // 老行的键还是空的，顺手补上；C13 会把剩下的一次补完。
                record.forumSiteRaw = snapshot.forum.id.site.rawValue
                record.forumKey = snapshot.forum.id.key
                record.forumName = snapshot.forum.name
                record.forumSubtitle = snapshot.forum.subtitle
                record.order = snapshot.order
                record.syncState = snapshot.state
                record.serverPresent = snapshot.state == .synced
            } else {
                session.context.insert(FavoriteRecord(
                    accountID: accountID,
                    forum: snapshot.forum,
                    order: snapshot.order,
                    syncState: snapshot.state,
                    serverPresent: snapshot.state == .synced
                ))
            }
        }
        for record in records
        where !snapshotIDs.contains(record.forumIdentifier)
            && record.syncState != .pendingRemove {
            session.context.delete(record)
        }
        try? session.context.save()
    }

    private func replayFavoriteChanges(accountID: AccountID, service: any ForumService) async {
        let records = favoriteRecords(accountID: accountID)
        for record in records where record.syncState == .pendingAdd || record.syncState == .pendingRemove {
            let adding = record.syncState == .pendingAdd
            do {
                try await service.updateFavorite(
                    forumID: record.forumIdentifier,
                    isFavorite: adding
                )
                if adding {
                    record.syncState = .synced
                    record.serverPresent = true
                } else {
                    session.context.delete(record)
                }
            } catch let error as ForumServiceError {
                if case .unsupported = error {
                    if adding {
                        record.syncState = .localOnly
                        record.serverPresent = false
                    } else {
                        session.context.delete(record)
                    }
                }
            } catch {
                // 保留 pending 状态，下一次前台刷新时重试。
            }
        }
        try? session.context.save()
        if session.activeAccountID == accountID {
            favorites = enrichingFavoriteForums(
                favoriteRecords(accountID: accountID)
                    .filter { $0.syncState != .pendingRemove }
                    .map {
                        FavoriteSnapshot(
                            forum: $0.forum,
                            order: $0.order,
                            state: $0.syncState
                        )
                    }
            )
        }
    }
}
