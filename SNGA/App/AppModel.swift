import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class AppModel {
    var sidebarSelection: SidebarSelection? = .userCenter(nil)
    var selectedMessageID: MessageID?
    var currentProfile: Profile?
    var userActivities: [UserActivity] = []
    var userActivityUID: Int64?
    var userActivityKind: UserActivityKind = .topics
    var userActivityPage = 1
    var userActivityHasMore = false
    var userActivityTotalPages = 1
    var forumSearchRequest: ForumSearchRequest?
    var forumSearchPage: ForumSearchPage?
    var forumSearchErrorMessage: String?
    var isSearchingForum = false
    var selectedToolboxFeed: ToolboxFeed = .worldBriefing
    var toolboxRefreshRevision = 0
    var topicListSortOrder: TopicListSortOrder = .latestReply
    var isShowingFeaturedTopics = false

    var forums: [Forum] = []
    var recentForums: [Forum] = []
    var favorites: [FavoriteSnapshot] = []
    var favoriteTopicFolders: [TopicFavoriteFolder] = []
    var selectedFavoriteTopicFolderID: String?
    var favoriteTopics: [Topic] = []
    var topics: [Topic] = []
    var subforums: [Forum] = []
    var includedSubforumIDs: Set<ForumID> = []
    var forumNavigationPath: [Forum] = []
    var currentForum: Forum?
    var messages: [ForumMessage] = []
    var currentMessage: ForumMessage?
    var messageFolder: MessageFolder = .privateMessages

    var topicPage = 1
    var topicHasMore = false
    var topicTotalPages = 1
    var favoriteTopicPage = 1
    var favoriteTopicHasMore = false
    var favoriteTopicTotalPages = 1
    var messagePage = 1
    var messageHasMore = false
    var unreadCount = 0

    var isRefreshingTopics = false
    var topicListScrollToTopRevision = 0
    var updatingFavoriteTopicIDs: Set<TopicID> = []
    var isUpdatingFavoriteTopicFolders = false
    var previewImageURL: URL?

    @ObservationIgnored private var bootstrapped = false
    @ObservationIgnored private var subforumSelectionForumID: ForumID?
    @ObservationIgnored private let profileRequests = RequestSlot()
    @ObservationIgnored private let userActivityRequests = RequestSlot()
    @ObservationIgnored private let forumDirectoryRequests = RequestSlot()
    @ObservationIgnored private let forumSearchRequests = RequestSlot()
    @ObservationIgnored private let topicListRequests = RequestSlot()
    @ObservationIgnored private let messageListRequests = RequestSlot()
    @ObservationIgnored private let messageDetailRequests = RequestSlot()
    @ObservationIgnored private let favoriteRequests = RequestSlot()
    @ObservationIgnored private let favoriteTopicFolderRequests = RequestSlot()
    @ObservationIgnored private let favoriteTopicRequests = RequestSlot()
    @ObservationIgnored private var messageUnreadCounts: [MessageFolder: Int] = [:]
    private var forumUserReturnSelection: SidebarSelection?
    private var favoriteTopicIDs: Set<TopicID> = []
    private var favoriteTopicFolderIDsByTopic: [TopicID: Set<String>] = [:]

    let session: AppSession
    let thread: ThreadStore

    private var activeService: (any NGAForumService)? { session.activeService }

    init(
        container: ModelContainer,
        sessionStore: any SessionStore = LocalSessionStore.shared,
        notificationService: NotificationService = .shared
    ) {
        let session = AppSession(
            container: container,
            sessionStore: sessionStore,
            notificationService: notificationService
        )
        self.session = session
        thread = ThreadStore(session: session)
        // 「是否已收藏」归收藏域所有。话题域只需要这一个查询，用闭包倒置依赖，
        // 避免它为了一个布尔值反过来持有整个 AppModel。
        thread.provideFavoriteLookup { [weak self] topicID in
            self?.favoriteTopicIDs.contains(topicID) ?? false
        }
    }

    var displayedUserUID: Int64? {
        guard case let .userCenter(uid) = sidebarSelection else { return nil }
        return uid ?? session.activeAccount?.ngaUID
    }

    var isDisplayingActiveAccount: Bool {
        guard let displayedUserUID, let activeAccount = session.activeAccount else { return false }
        return displayedUserUID == activeAccount.ngaUID
    }


    var canReturnFromUserCenterToTopicList: Bool {
        guard case .forum = forumUserReturnSelection else { return false }
        return true
    }

    var selectedForumID: ForumID? {
        guard let sidebarSelection else { return nil }
        guard case let .forum(id) = sidebarSelection else { return nil }
        return id
    }

    var isActiveForumFavorite: Bool {
        guard let currentForum else { return false }
        return favorites.contains { $0.forum.id == currentForum.id && $0.state != .pendingRemove }
    }

    var currentPinnedTopicID: TopicID? {
        currentForum?.pinnedTopicID
    }

    var isCurrentTopicFavorite: Bool {
        guard let topic = thread.currentTopic else { return false }
        return topic.isFavorite || favoriteTopicIDs.contains(topic.id)
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

    var isCurrentForumSearchActive: Bool {
        guard let forumSearchRequest,
              let selectedForumID else {
            return false
        }
        return forumSearchRequest.forumID == selectedForumID
    }

    func bootstrap() async {
        guard !bootstrapped else { return }
        bootstrapped = true
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--uitesting-seed") {
            seedUITestData()
            return
        }
#endif
        await session.reloadAccountsAndServices()
        if let activeAccount = session.activeAccount {
            loadRecentForums()
            sidebarSelection = .userCenter(activeAccount.ngaUID)
            currentProfile = Profile(
                uid: activeAccount.ngaUID,
                displayName: activeAccount.displayName,
                avatarURL: activeAccount.avatarURL
            )
            await loadForums()
            await refreshFavorites()
            await performMaintenance()
        }
    }

    func addAccount(capture: LoginCapture) async {
        do {
            let records = try session.context.fetch(FetchDescriptor<AccountRecord>())
            let record: AccountRecord
            if let existing = records.first(where: { $0.ngaUID == capture.uid }) {
                record = existing
                record.sessionState = .valid
            } else {
                record = AccountRecord(ngaUID: capture.uid, displayName: "NGA \(capture.uid)")
                session.context.insert(record)
            }
            records.forEach { $0.isCurrent = false }
            record.isCurrent = true
            try await session.sessionStore.save(cookies: capture.cookies, for: record.accountID)
            let service = session.makeService(accountID: record.accountID, cookies: capture.cookies)
            session.setService(service, for: record.accountID)
            if let profile = try? await service.profile(uid: capture.uid) {
                record.displayName = profile.displayName
                record.avatarURLString = profile.avatarURL?.absoluteString
            }
            try session.context.save()
            session.showsLogin = false
            await session.reloadAccountsAndServices()
            if let activeAccount = session.activeAccount {
                loadRecentForums()
                sidebarSelection = .userCenter(activeAccount.ngaUID)
                currentProfile = Profile(
                    uid: activeAccount.ngaUID,
                    displayName: activeAccount.displayName,
                    avatarURL: activeAccount.avatarURL
                )
            }
            await loadForums()
            await refreshFavorites()
            await performMaintenance()
        } catch {
            session.present(error)
        }
    }

    func selectAccount(_ accountID: AccountID) async {
        if session.activeAccountID == accountID, let account = session.activeAccount {
            await openUserCenter(
                uid: account.ngaUID,
                fallbackName: account.displayName,
                fallbackAvatarURL: account.avatarURL
            )
            return
        }
        do {
            let records = try session.context.fetch(FetchDescriptor<AccountRecord>())
            records.forEach { $0.isCurrent = $0.accountID == accountID }
            try session.context.save()
            session.activeAccountID = accountID
            session.accounts = records.sorted(by: { $0.createdAt < $1.createdAt }).map { $0.summary() }
            session.refreshActiveAccountCheckInStatus(records: records)
            clearVisibleContent()
            loadRecentForums()
            if let activeAccount = session.activeAccount {
                sidebarSelection = .userCenter(activeAccount.ngaUID)
                currentProfile = Profile(
                    uid: activeAccount.ngaUID,
                    displayName: activeAccount.displayName,
                    avatarURL: activeAccount.avatarURL
                )
            }
            await loadForums()
            await refreshFavorites()
            if let activeAccount = session.activeAccount {
                await openUserCenter(
                    uid: activeAccount.ngaUID,
                    fallbackName: activeAccount.displayName,
                    fallbackAvatarURL: activeAccount.avatarURL
                )
            }
        } catch {
            session.present(error)
        }
    }

    func removeAccount(_ accountID: AccountID) async {
        do {
            let accountRecords = try session.context.fetch(FetchDescriptor<AccountRecord>())
            let favorites = try session.context.fetch(FetchDescriptor<FavoriteRecord>())
            let drafts = try session.context.fetch(FetchDescriptor<DraftRecord>())
            let subforumPreferences = try session.context.fetch(
                FetchDescriptor<SubforumPreferenceRecord>()
            )
            let recentForums = try session.context.fetch(
                FetchDescriptor<RecentForumRecord>()
            )
            accountRecords.filter { $0.accountID == accountID }.forEach(session.context.delete)
            favorites.filter { $0.accountIDString == accountID.description }.forEach(session.context.delete)
            drafts.filter { $0.accountIDString == accountID.description }.forEach(session.context.delete)
            subforumPreferences
                .filter { $0.accountIDString == accountID.description }
                .forEach(session.context.delete)
            recentForums
                .filter { $0.accountIDString == accountID.description }
                .forEach(session.context.delete)
            try await session.sessionStore.remove(accountID: accountID)
            session.setService(nil, for: accountID)
            try session.context.save()
            await session.reloadAccountsAndServices()
            clearVisibleContent()
            if let activeAccount = session.activeAccount {
                loadRecentForums()
                sidebarSelection = .userCenter(activeAccount.ngaUID)
                currentProfile = Profile(
                    uid: activeAccount.ngaUID,
                    displayName: activeAccount.displayName,
                    avatarURL: activeAccount.avatarURL
                )
                await loadForums()
                await refreshFavorites()
            } else {
                sidebarSelection = .userCenter(nil)
            }
        } catch {
            session.present(error)
        }
    }

    func openUserCenter(
        uid: Int64,
        fallbackName: String? = nil,
        fallbackAvatarURL: URL? = nil,
        preservingForumContext: Bool = false
    ) async {
        if preservingForumContext {
            if case .forum = sidebarSelection {
                forumUserReturnSelection = sidebarSelection
            }
        } else {
            forumUserReturnSelection = nil
                    }
        sidebarSelection = .userCenter(uid)
        selectedMessageID = nil
        currentMessage = nil
        userActivities = []
        userActivityUID = uid
        userActivityKind = .topics
        userActivityPage = 1
        userActivityHasMore = false
        userActivityTotalPages = 1

        let account = session.accounts.first { $0.ngaUID == uid }
        let resolvedName = fallbackName ?? account?.displayName ?? "NGA \(uid)"
        let resolvedAvatarURL = fallbackAvatarURL ?? account?.avatarURL
        currentProfile = Profile(
            uid: uid,
            displayName: resolvedName,
            avatarURL: resolvedAvatarURL
        )

        guard let service = activeService else { return }
        let requestAccountID = service.accountID
        let ticket = profileRequests.begin()
        session.beginLoading()
        do {
            var profile = try await service.profile(uid: uid)
            if profile.displayName == "NGA \(uid)", !resolvedName.isEmpty {
                profile.displayName = resolvedName
            }
            if profile.avatarURL == nil {
                profile.avatarURL = resolvedAvatarURL
            }
            if session.activeAccountID == requestAccountID,
               ticket.isCurrent,
               displayedUserUID == uid {
                currentProfile = profile
            }
        } catch {
            // 用户中心保留楼层或账号中已有的资料，不因资料接口失败阻断浏览。
        }
        session.endLoading()
        guard session.activeAccountID == requestAccountID,
              ticket.isCurrent,
              displayedUserUID == uid else {
            return
        }
        await loadUserActivities(uid: uid, kind: .topics, page: 1)
    }

    func returnFromUserCenterToTopicList() {
        guard case let .forum(forumID) = forumUserReturnSelection else { return }
        sidebarSelection = .forum(forumID)
        forumUserReturnSelection = nil
    }

    func ensureUserCenterLoaded(uid: Int64) async {
        guard currentProfile?.uid != uid || userActivityUID != uid else { return }
        await openUserCenter(uid: uid)
    }

    func loadUserActivities(uid: Int64, kind: UserActivityKind, page: Int) async {
        guard let service = activeService else { return }
        let requestAccountID = service.accountID
        let ticket = userActivityRequests.begin()
        let targetPage = max(1, page)
        userActivityUID = uid
        userActivityKind = kind
        await session.withLoading(isCurrent: { ticket.isCurrent }) {
            let result = try await service.userActivities(uid: uid, kind: kind, page: targetPage)
            guard session.activeAccountID == requestAccountID,
                  ticket.isCurrent,
                  displayedUserUID == uid,
                  userActivityUID == uid,
                  userActivityKind == kind else {
                return
            }
            userActivities = result.activities
            userActivityPage = result.page
            userActivityHasMore = result.hasMore
            userActivityTotalPages = max(result.totalPages, result.page)
        }
    }

    func openUserActivity(_ activity: UserActivity) async {
        let topic = Topic(
            id: activity.topicID,
            forumID: activity.forumID ?? ForumID(rawValue: 0),
            subject: activity.subject,
            author: currentProfile?.displayName ?? "",
            replyCount: 0,
            publishedAt: activity.postedAt
        )
        await openTopic(topic)
    }

    func loadForums() async {
        guard let service = activeService else { return }
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
            favorites = enrichingFavoriteForums(favorites)
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

    func searchForum(_ request: ForumSearchRequest, page: Int = 1) async {
        guard let service = activeService else { return }
        let requestAccountID = service.accountID
        let targetPage = max(1, page)
        if forumSearchRequest != request {
            forumSearchPage = nil
        }
        let ticket = forumSearchRequests.begin()
        forumSearchRequest = request
        forumSearchErrorMessage = nil
        isSearchingForum = true
        defer {
            if ticket.isCurrent {
                isSearchingForum = false
            }
        }

        do {
            var result = try await service.search(request, page: targetPage)
            guard session.activeAccountID == requestAccountID,
                  ticket.isCurrent,
                  forumSearchRequest == request else {
                return
            }
            result = enrichingSearchPage(result)
            forumSearchPage = result
        } catch is CancellationError {
            return
        } catch {
            guard session.activeAccountID == requestAccountID,
                  ticket.isCurrent,
                  forumSearchRequest == request else {
                return
            }
            forumSearchPage = nil
            forumSearchErrorMessage = error.localizedDescription
            if let serviceError = error as? NGAServiceError,
               serviceError == .requiresLogin {
                session.present(error)
            } else {
                Task {
                    await RuntimeLogger.shared.log(
                        .error,
                        category: "search",
                        error.localizedDescription
                    )
                }
            }
        }
    }

    func loadForumSearchPage(_ page: Int) async {
        guard let forumSearchRequest else { return }
        await searchForum(forumSearchRequest, page: page)
    }

    func clearForumSearch() {
        forumSearchRequests.invalidate()
        forumSearchRequest = nil
        forumSearchPage = nil
        forumSearchErrorMessage = nil
        isSearchingForum = false
    }

    func openForumSearchActivity(_ activity: UserActivity) async {
        let topic = Topic(
            id: activity.topicID,
            forumID: activity.forumID ?? ForumID(rawValue: 0),
            subject: activity.subject,
            author: forumSearchPage?.users.first?.displayName ?? "",
            replyCount: 0,
            publishedAt: activity.postedAt,
            sourceForumName: activity.forumName
        )
        await openTopic(topic)
    }

    func openForum(_ forum: Forum) async {
        forumNavigationPath = []
        topicListScrollToTopRevision &+= 1
        await showForum(forum)
    }

    func returnToForumDirectory() {
        clearForumSearch()
        forumNavigationPath = []
        sidebarSelection = .directory
        thread.selectedTopicID = nil
        thread.currentTopic = nil
        thread.reset()
    }

    func openSubforum(_ forum: Forum) async {
        if let currentForum, currentForum.id != forum.id {
            forumNavigationPath.append(currentForum)
        }
        await showForum(forum)
    }

    func openParentForum() async {
        guard let parent = forumNavigationPath.popLast() else { return }
        await showForum(parent)
    }

    private func showForum(_ forum: Forum) async {
        clearForumSearch()
        currentForum = forum
        recordRecentForum(forum)
        sidebarSelection = .forum(forum.id)
        topics = []
        topicPage = 1
        topicHasMore = false
        topicTotalPages = 1
        thread.selectedTopicID = nil
        thread.currentTopic = nil
        selectedMessageID = nil
        currentMessage = nil
        thread.posts = []
        thread.hotReplies = []
        subforums = []
        includedSubforumIDs = []
        subforumSelectionForumID = nil
        thread.reset()
        await loadTopics(forumID: forum.id, reset: true)
    }

    private func recordRecentForum(
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
        guard let service = activeService else { return }
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
                  selectedForumID == forumID else {
                return
            }
            applyForumPage(result, forumID: forumID, replaceTopics: reset)
        }
    }

    func loadTopicPage(forumID: ForumID, page: Int) async {
        guard let service = activeService else { return }
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
                  selectedForumID == forumID else {
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
        currentForum = result.forum ?? currentForum ?? forums.first { $0.id == forumID }
        if let currentForum {
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

    func openTopic(_ topic: Topic) async {
        if let mirroredForumID = topic.mirroredForumID {
            let mirroredForum = subforums.first { $0.id == mirroredForumID }
                ?? forums.first { $0.id == mirroredForumID }
                ?? Forum(id: mirroredForumID, name: topic.subject)
            await openSubforum(mirroredForum)
            return
        }
        await thread.open(topic)
    }

    func openPinnedTopic() async {
        guard let currentForum, let topicID = currentForum.pinnedTopicID else {
            return
        }
        let topic = topics.first {
            $0.id == topicID && $0.mirroredForumID == nil
        } ?? Topic(
            id: topicID,
            forumID: currentForum.id,
            subject: "置顶话题",
            author: "",
            replyCount: 0,
            isPinned: true
        )
        await openTopic(topic)
    }

    @discardableResult

    func loadMessages(folder: MessageFolder, reset: Bool = true) async {
        guard let service = activeService else { return }
        let requestAccountID = service.accountID
        let ticket = messageListRequests.begin()
        messageFolder = folder
        sidebarSelection = .messages(folder)
        let page = reset ? 1 : messagePage + 1
        await session.withLoading(isCurrent: { ticket.isCurrent }) {
            var result: MessagePage
            if folder == .notifications {
                result = try await unifiedMessageFeedPage(
                    service: service,
                    page: page,
                    accountID: requestAccountID
                )
            } else {
                result = try await service.messages(folder: folder, page: page)
                result.messages = applyingPersistedReadState(
                    to: result.messages,
                    folder: folder,
                    accountID: requestAccountID
                )
            }
            guard session.activeAccountID == requestAccountID,
                  ticket.isCurrent,
                  sidebarSelection == .messages(folder),
                  messageFolder == folder else {
                return
            }
            messages = reset ? result.messages : merged(messages, result.messages)
            messagePage = page
            messageHasMore = result.hasMore
            if folder == .notifications {
                messageUnreadCounts[.privateMessages] = messages.filter {
                    $0.kind == .privateMessage && $0.isUnread
                }.count
            }
            setUnreadCount(messages.filter(\.isUnread).count, for: folder)
        }
    }

    func openMessage(_ message: ForumMessage) async {
        thread.reset()
        thread.selectedTopicID = nil
        thread.currentTopic = nil
        selectedMessageID = message.id
        let folder = messageFolder
        if folder == .notifications {
            markMessageRead(message, folder: folder)
            if message.kind == .privateMessage {
                guard let service = activeService else { return }
                let requestAccountID = service.accountID
                let ticket = messageDetailRequests.begin()
                await session.withLoading(isCurrent: { ticket.isCurrent }) {
                    let result = try await service.message(id: message.id)
                    guard session.activeAccountID == requestAccountID,
                          ticket.isCurrent,
                          selectedMessageID == message.id else {
                        return
                    }
                    currentMessage = result
                }
            } else if let topicID = message.topicID {
                selectedMessageID = nil
                currentMessage = nil
                await openTopic(Topic(
                    id: topicID,
                    forumID: ForumID(rawValue: 0),
                    subject: message.subject,
                    author: message.sender,
                    replyCount: 0
                ))
            } else {
                currentMessage = messages.first(where: { $0.id == message.id }) ?? message
            }
            return
        }
        guard let service = activeService else { return }
        let requestAccountID = service.accountID
        let ticket = messageDetailRequests.begin()
        await session.withLoading(isCurrent: { ticket.isCurrent }) {
            let result = try await service.message(id: message.id)
            guard session.activeAccountID == requestAccountID,
                  ticket.isCurrent,
                  selectedMessageID == message.id else {
                return
            }
            currentMessage = result
            markMessageRead(message, folder: folder)
        }
    }

    func markAllMessagesRead(in folder: MessageFolder) {
        let unreadMessages = messages.filter(\.isUnread)
        guard messageFolder == folder, !unreadMessages.isEmpty else { return }

        for index in messages.indices {
            messages[index].isUnread = false
        }
        currentMessage?.isUnread = false
        setUnreadCount(0, for: folder)

        guard folder == .notifications,
              let activeAccountID = session.activeAccountID,
              let record = accountRecord(id: activeAccountID) else {
            return
        }
        let newKeys = unreadMessages.flatMap { message in
            var keys = [
                UnreadMessagePolicy.key(folder: folder, messageID: message.id)
            ]
            if message.kind == .privateMessage {
                keys.append(UnreadMessagePolicy.key(
                    folder: .privateMessages,
                    messageID: message.id
                ))
            }
            return keys
        }
        var accumulated = Set<String>()
        record.readNotificationKeys = Array(
            (newKeys + record.readNotificationKeys)
                .filter { accumulated.insert($0).inserted }
                .prefix(UnreadMessagePolicy.maximumSeenKeyCount)
        )
        // 通知流中的短消息也属于“全部已读”的范围，避免侧栏保留重复角标。
        messageUnreadCounts[.privateMessages] = 0
        refreshUnreadCount()
        try? session.context.save()
    }


    func replyToMessage(id: MessageID, content: String) async -> Bool {
        guard let service = activeService, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        thread.isSubmitting = true
        defer { thread.isSubmitting = false }
        do {
            try await service.replyMessage(id: id, content: content)
            session.statusMessage = "私信回复已发送"
            session.statusMessageIsError = false
            return true
        } catch {
            session.present(error)
            return false
        }
    }

    func refreshFavorites() async {
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
        guard let accountID = session.activeAccountID else { return }
        let records = favoriteRecords(accountID: accountID)
        if let record = records.first(where: { $0.forumID == forum.id.rawValue }) {
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
        guard let service = activeService else {
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
        guard let service = activeService else {
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
        guard let service = activeService,
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
            if thread.currentTopic?.id == topic.id {
                thread.currentTopic?.isFavorite = remainsFavorite
            }
            if let index = topics.firstIndex(where: { $0.id == topic.id }) {
                topics[index].isFavorite = remainsFavorite
            }
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
        guard let service = activeService,
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
                if thread.currentTopic?.id == topic.id {
                    thread.currentTopic?.isFavorite = false
                }
                if let index = topics.firstIndex(where: { $0.id == topic.id }) {
                    topics[index].isFavorite = false
                }
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
              let service = activeService,
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
              let service = activeService,
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
        guard let service = activeService,
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

    func performMaintenance() async {
        await session.checkInAllAccounts()
        await pollMessages()
    }

    func pollMessages() async {
        let records = (try? session.context.fetch(FetchDescriptor<AccountRecord>())) ?? []
        for record in records where record.sessionState == .valid {
            guard let service = session.service(for: record.accountID) else { continue }
            do {
                async let privateMessages = service.messages(folder: .privateMessages, page: 1)
                async let notifications = service.messages(folder: .notifications, page: 1)
                var pages = try await [privateMessages, notifications]
                if let inboxIndex = pages.firstIndex(where: { $0.folder == .privateMessages }) {
                    pages[inboxIndex].messages = applyingPersistedReadState(
                        to: pages[inboxIndex].messages,
                        folder: .privateMessages,
                        accountID: record.accountID
                    )
                }
                if let notificationIndex = pages.firstIndex(where: { $0.folder == .notifications }) {
                    pages[notificationIndex].messages.removeAll { $0.kind == .privateMessage }
                    pages[notificationIndex].messages = applyingPersistedReadState(
                        to: pages[notificationIndex].messages,
                        folder: .notifications,
                        accountID: record.accountID
                    )
                }
                let update = UnreadMessagePolicy.update(
                    pages: pages,
                    previouslySeenKeys: record.seenUnreadMessageKeys
                )
                record.seenUnreadMessageKeys = update.seenKeys
                record.unreadBaseline = update.unreadCount
                if record.accountID == session.activeAccountID {
                    let inboxUnread = pages
                        .first(where: { $0.folder == .privateMessages })?
                        .messages.filter(\.isUnread).count ?? 0
                    let notificationUnread = pages
                        .first(where: { $0.folder == .notifications })?
                        .messages.filter(\.isUnread).count ?? 0
                    messageUnreadCounts[.privateMessages] = inboxUnread
                    messageUnreadCounts[.notifications] = inboxUnread + notificationUnread
                    refreshUnreadCount()
                }
                let account = record.summary()
                for item in update.newMessages {
                    await session.notificationService.notify(
                        account: account,
                        folder: item.folder,
                        message: item.message
                    )
                }
            } catch {
                // 私信或提醒接口偶发返回未登录时，只跳过本轮轮询。
                // 论坛浏览仍可验证账号有效，后台接口不能单独使整个账号失效。
            }
        }
        try? session.context.save()
    }

    func refreshCurrentSelection() async {
        if thread.selectedTopicID != nil {
            await thread.refreshContent()
            return
        }
        switch sidebarSelection {
        case let .forum(id): await loadTopics(forumID: id, reset: true)
        case let .messages(folder): await loadMessages(folder: folder)
        case .directory: await loadForums()
        case .search:
            if let forumSearchRequest {
                await searchForum(
                    forumSearchRequest,
                    page: forumSearchPage?.page ?? 1
                )
            }
        case .favorites: await loadFavoriteTopics(page: favoriteTopicPage)
        case .toolbox: refreshToolbox()
        case let .userCenter(uid):
            if let targetUID = uid ?? session.activeAccount?.ngaUID {
                await openUserCenter(uid: targetUID)
            }
            await loadForums()
            await refreshFavorites()
            await performMaintenance()
        case .none:
            await loadForums()
            await refreshFavorites()
            await performMaintenance()
        }
    }

    func refreshToolbox() {
        toolboxRefreshRevision &+= 1
    }

    func refreshTopicList() async {
        guard let forumID = selectedForumID else { return }
        await loadTopicPage(forumID: forumID, page: topicPage)
    }

    func handleNotification(
        accountIDString: String,
        messageIDString: String,
        messageFolderString: String
    ) async {
        guard let accountID = AccountID(accountIDString),
              session.accounts.contains(where: { $0.id == accountID }),
              let rawMessageID = Int64(messageIDString) else {
            return
        }
        let folder = MessageFolder(rawValue: messageFolderString) ?? .privateMessages
        await selectAccount(accountID)
        await loadMessages(folder: folder)
        if let message = messages.first(where: { $0.id.rawValue == rawMessageID }) {
            await openMessage(message)
        }
    }


    private func favoriteRecords(accountID: AccountID) -> [FavoriteRecord] {
        ((try? session.context.fetch(FetchDescriptor<FavoriteRecord>())) ?? [])
            .filter { $0.accountIDString == accountID.description }
            .sorted { $0.order < $1.order }
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

    private func enrichingForumFromDirectory(_ forum: Forum) -> Forum {
        guard let directoryForum = forums.first(where: { $0.id == forum.id }) else {
            return forum
        }
        var enriched = forum
        if enriched.subtitle?.isEmpty != false { enriched.subtitle = directoryForum.subtitle }
        if enriched.iconURL == nil { enriched.iconURL = directoryForum.iconURL }
        if enriched.category?.isEmpty != false { enriched.category = directoryForum.category }
        return enriched
    }

    private func enrichingFavoriteForums(
        _ snapshots: [FavoriteSnapshot]
    ) -> [FavoriteSnapshot] {
        snapshots.map { snapshot in
            var enriched = snapshot
            enriched.forum = enrichingForumFromDirectory(snapshot.forum)
            return enriched
        }
    }

    private func enrichingSearchPage(_ page: ForumSearchPage) -> ForumSearchPage {
        var page = page
        page.forums = page.forums.map(enrichingForumFromDirectory)
        if page.request.forumID == nil {
            let knownForums = Dictionary(
                (forums + page.forums).map { ($0.id, $0) },
                uniquingKeysWith: { current, _ in current }
            )
            page.topics = page.topics.map { topic in
                var topic = topic
                if topic.sourceForumName?.isEmpty != false {
                    topic.sourceForumID = topic.forumID
                    topic.sourceForumName = knownForums[topic.forumID]?.name
                        ?? "\(topic.forumID.queryName) \(topic.forumID.description)"
                }
                return topic
            }
        }
        return page
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
        let snapshotIDs = Set(snapshots.map { $0.forum.id.rawValue })
        for snapshot in snapshots {
            if let record = records.first(where: { $0.forumID == snapshot.forum.id.rawValue }) {
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
        for record in records where !snapshotIDs.contains(record.forumID) && record.syncState != .pendingRemove {
            session.context.delete(record)
        }
        try? session.context.save()
    }

    private func replayFavoriteChanges(accountID: AccountID, service: any NGAForumService) async {
        let records = favoriteRecords(accountID: accountID)
        for record in records where record.syncState == .pendingAdd || record.syncState == .pendingRemove {
            let adding = record.syncState == .pendingAdd
            do {
                try await service.updateFavorite(forumID: ForumID(rawValue: record.forumID), isFavorite: adding)
                if adding {
                    record.syncState = .synced
                    record.serverPresent = true
                } else {
                    session.context.delete(record)
                }
            } catch let error as NGAServiceError {
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


    private func clearVisibleContent() {
        thread.reset()
        favorites = []
        recentForums = []
        favoriteTopicFolders = []
        selectedFavoriteTopicFolderID = nil
        favoriteTopics = []
        favoriteTopicIDs = []
        favoriteTopicFolderIDsByTopic = [:]
        forums = []
        topics = []
        subforums = []
        includedSubforumIDs = []
        forumNavigationPath = []
        subforumSelectionForumID = nil
        thread.posts = []
        thread.hotReplies = []
        messages = []
        currentForum = nil
        thread.currentTopic = nil
        currentMessage = nil
        currentProfile = nil
        userActivities = []
        userActivityUID = nil
        userActivityKind = .topics
        userActivityPage = 1
        userActivityHasMore = false
        userActivityTotalPages = 1
        clearForumSearch()
        thread.selectedTopicID = nil
        selectedMessageID = nil
        thread.reset()
        previewImageURL = nil
        topicPage = 1
        topicHasMore = false
        topicTotalPages = 1
        favoriteTopicPage = 1
        favoriteTopicHasMore = false
        favoriteTopicTotalPages = 1
        unreadCount = 0
        messageUnreadCounts = [:]
        isRefreshingTopics = false
    }


    private func merged<T: Identifiable>(_ existing: [T], _ incoming: [T]) -> [T] where T.ID: Hashable {
        var seen = Set(existing.map(\.id))
        return existing + incoming.filter { seen.insert($0.id).inserted }
    }

    private func unifiedMessageFeedPage(
        service: any NGAForumService,
        page: Int,
        accountID: AccountID
    ) async throws -> MessagePage {
        if page > 1 {
            var inbox = try await service.messages(folder: .privateMessages, page: page)
            inbox.messages = applyingPersistedReadState(
                to: inbox.messages,
                folder: .privateMessages,
                accountID: accountID
            )
            return UnifiedMessageFeedPolicy.merging(notifications: nil, inbox: inbox)
        }

        async let notificationRequest: MessagePage? =
            try? await service.messages(folder: .notifications, page: 1)
        do {
            var inbox = try await service.messages(folder: .privateMessages, page: 1)
            inbox.messages = applyingPersistedReadState(
                to: inbox.messages,
                folder: .privateMessages,
                accountID: accountID
            )
            var notifications = await notificationRequest
            if var notificationPage = notifications {
                notificationPage.messages = applyingPersistedReadState(
                    to: notificationPage.messages,
                    folder: .notifications,
                    accountID: accountID
                )
                notifications = notificationPage
            }
            return UnifiedMessageFeedPolicy.merging(
                notifications: notifications,
                inbox: inbox
            )
        } catch {
            guard var notifications = await notificationRequest else {
                throw error
            }
            notifications.messages = applyingPersistedReadState(
                to: notifications.messages,
                folder: .notifications,
                accountID: accountID
            )
            return UnifiedMessageFeedPolicy.merging(
                notifications: notifications,
                inbox: nil
            )
        }
    }

    private func applyingPersistedReadState(
        to messages: [ForumMessage],
        folder: MessageFolder,
        accountID: AccountID
    ) -> [ForumMessage] {
        guard let record = accountRecord(id: accountID) else {
            return messages
        }
        // 提醒接口在读取后会清除服务端未读计数；在用户实际打开提醒前，
        // 用本地状态保留未读标记。短消息则仅应用用户明确标记的本地已读状态。
        return NotificationReadPolicy.applying(
            to: messages,
            folder: folder,
            readKeys: record.readNotificationKeys,
            previouslyUnreadKeys: record.seenUnreadMessageKeys ?? []
        )
    }

    private func markMessageRead(_ message: ForumMessage, folder: MessageFolder) {
        guard message.isUnread else { return }
        if let index = messages.firstIndex(where: { $0.id == message.id }) {
            messages[index].isUnread = false
        }
        if currentMessage?.id == message.id {
            currentMessage?.isUnread = false
        }
        setUnreadCount(max(0, (messageUnreadCounts[folder] ?? 0) - 1), for: folder)

        guard let activeAccountID = session.activeAccountID,
              let record = accountRecord(id: activeAccountID) else {
            return
        }
        var newKeys = [
            UnreadMessagePolicy.key(folder: folder, messageID: message.id)
        ]
        if folder == .notifications, message.kind == .privateMessage {
            newKeys.append(UnreadMessagePolicy.key(
                folder: .privateMessages,
                messageID: message.id
            ))
            messageUnreadCounts[.privateMessages] = max(
                0,
                (messageUnreadCounts[.privateMessages] ?? 0) - 1
            )
            refreshUnreadCount()
        }
        let newKeySet = Set(newKeys)
        var keys = record.readNotificationKeys.filter { !newKeySet.contains($0) }
        keys.insert(contentsOf: newKeys, at: 0)
        record.readNotificationKeys = Array(keys.prefix(UnreadMessagePolicy.maximumSeenKeyCount))
        try? session.context.save()
    }

    private func setUnreadCount(_ count: Int, for folder: MessageFolder) {
        messageUnreadCounts[folder] = max(0, count)
        refreshUnreadCount()
    }

    private func refreshUnreadCount() {
        // “通知”已合并回复、评价、@ 和短消息；取最大值可避免短消息收件箱
        // 与通知流同时加载后把同一批未读重复计数。
        unreadCount = messageUnreadCounts.values.max() ?? 0
    }

    private func accountRecord(id: AccountID) -> AccountRecord? {
        ((try? session.context.fetch(FetchDescriptor<AccountRecord>())) ?? [])
            .first { $0.accountID == id }
    }


#if DEBUG
    private func seedUITestData() {
        UserDefaults.standard.set(
            RecentForumSettings.defaultMaximumCount,
            forKey: RecentForumSettings.maximumCountKey
        )
        let accountA = AccountRecord(ngaUID: 10001, displayName: "测试账号 A", isCurrent: true)
        let accountB = AccountRecord(ngaUID: 10002, displayName: "测试账号 B")
        session.context.insert(accountA)
        session.context.insert(accountB)
        let favoriteForum = Forum(id: ForumID(rawValue: -7), name: "艾泽拉斯国家地理", subtitle: "UI 测试版面")
        session.context.insert(FavoriteRecord(
            accountID: accountA.accountID,
            forum: favoriteForum,
            order: 0,
            syncState: .localOnly,
            serverPresent: false
        ))
        try? session.context.save()
        session.accounts = [accountA.summary(), accountB.summary()]
        session.activeAccountID = accountA.accountID
        session.setService(DebugForumService(accountID: accountA.accountID), for: accountA.accountID)
        session.setService(DebugForumService(accountID: accountB.accountID), for: accountB.accountID)
        forums = [favoriteForum, Forum(id: ForumID(rawValue: 510381), name: "晴风村")]
        favorites = [FavoriteSnapshot(forum: favoriteForum, order: 0, state: .localOnly)]
        sidebarSelection = .userCenter(accountA.ngaUID)
        currentProfile = Profile(
            uid: accountA.ngaUID,
            displayName: accountA.displayName,
            avatarURL: nil
        )
    }
#endif
}
