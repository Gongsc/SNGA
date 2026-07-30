import Foundation
import Observation
import SwiftData

private struct ThreadNavigationSnapshot: Sendable {
    let topic: Topic
    let posts: [Post]
    let hotReplies: [Post]
    let page: Int
    let hasMore: Bool
    let totalPages: Int
}

@MainActor
@Observable
final class AppModel {
    var accounts: [AccountSummary] = []
    var activeAccountID: AccountID?
    var sidebarSelection: SidebarSelection? = .userCenter(nil)
    var selectedTopicID: TopicID?
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

    var forums: [Forum] = []
    var favorites: [FavoriteSnapshot] = []
    var favoriteTopicFolders: [TopicFavoriteFolder] = []
    var selectedFavoriteTopicFolderID: String?
    var favoriteTopics: [Topic] = []
    var topics: [Topic] = []
    var subforums: [Forum] = []
    var includedSubforumIDs: Set<ForumID> = []
    var forumNavigationPath: [Forum] = []
    var currentForum: Forum?
    var currentTopic: Topic?
    var posts: [Post] = []
    var hotReplies: [Post] = []
    var messages: [ForumMessage] = []
    var currentMessage: ForumMessage?
    var messageFolder: MessageFolder = .privateMessages

    var topicPage = 1
    var topicHasMore = false
    var topicTotalPages = 1
    var favoriteTopicPage = 1
    var favoriteTopicHasMore = false
    var favoriteTopicTotalPages = 1
    var threadPage = 1
    var threadHasMore = false
    var threadTotalPages = 1
    var messagePage = 1
    var messageHasMore = false
    var unreadCount = 0

    var isLoading = false
    var isRefreshingTopics = false
    var topicListScrollToTopRevision = 0
    var isSubmitting = false
    var votingPostIDs: Set<PostID> = []
    var submittingPollTopicIDs: Set<TopicID> = []
    var updatingFavoriteTopicIDs: Set<TopicID> = []
    var isUpdatingFavoriteTopicFolders = false
    var showsLogin = false
    var errorMessage: String?
    var statusMessage: String?
    var statusMessageIsError = false
    var previewImageURL: URL?
    var checkingInAccountIDs: Set<AccountID> = []
    var checkInFailures: [AccountID: String] = [:]
    private(set) var activeAccountCheckInStatus: DailyCheckInStatus = .failed(
        message: "尚未登录"
    )

    @ObservationIgnored private let container: ModelContainer
    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let sessionStore: any SessionStore
    @ObservationIgnored private let notificationService: NotificationService
    @ObservationIgnored private var services: [AccountID: any NGAForumService] = [:]
    @ObservationIgnored private var bootstrapped = false
    @ObservationIgnored private var subforumSelectionForumID: ForumID?
    @ObservationIgnored private var foregroundLoginFailureDates: [AccountID: Date] = [:]
    @ObservationIgnored private var loadingRequestCount = 0
    @ObservationIgnored private var profileRequestID: UUID?
    @ObservationIgnored private var userActivityRequestID: UUID?
    @ObservationIgnored private var forumDirectoryRequestID: UUID?
    @ObservationIgnored private var forumSearchRequestID: UUID?
    @ObservationIgnored private var topicListRequestID: UUID?
    @ObservationIgnored private var threadRequestID: UUID?
    @ObservationIgnored private var messageListRequestID: UUID?
    @ObservationIgnored private var messageDetailRequestID: UUID?
    @ObservationIgnored private var favoriteRequestID: UUID?
    @ObservationIgnored private var favoriteTopicFolderRequestID: UUID?
    @ObservationIgnored private var favoriteTopicRequestID: UUID?
    @ObservationIgnored private var messageUnreadCounts: [MessageFolder: Int] = [:]
    private var forumUserReturnSelection: SidebarSelection?
    private var threadNavigationPath: [ThreadNavigationSnapshot] = []
    private var favoriteTopicIDs: Set<TopicID> = []
    private var favoriteTopicFolderIDsByTopic: [TopicID: Set<String>] = [:]

    init(
        container: ModelContainer,
        sessionStore: any SessionStore = LocalSessionStore.shared,
        notificationService: NotificationService = .shared
    ) {
        self.container = container
        self.context = ModelContext(container)
        self.sessionStore = sessionStore
        self.notificationService = notificationService
        context.autosaveEnabled = true
    }

    var activeAccount: AccountSummary? {
        accounts.first { $0.id == activeAccountID }
    }

    var displayedUserUID: Int64? {
        guard case let .userCenter(uid) = sidebarSelection else { return nil }
        return uid ?? activeAccount?.ngaUID
    }

    var isDisplayingActiveAccount: Bool {
        guard let displayedUserUID, let activeAccount else { return false }
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

    var isCurrentTopicFavorite: Bool {
        guard let currentTopic else { return false }
        return currentTopic.isFavorite || favoriteTopicIDs.contains(currentTopic.id)
    }

    var canReturnToPreviousThread: Bool {
        !threadNavigationPath.isEmpty
    }

    var previousThreadTitle: String? {
        threadNavigationPath.last?.topic.subject
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
        await reloadAccountsAndServices()
        if let activeAccount {
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

    func reloadAccountsAndServices() async {
        do {
            let records = try context.fetch(FetchDescriptor<AccountRecord>(sortBy: [SortDescriptor(\.createdAt)]))
            if !records.isEmpty, !records.contains(where: \.isCurrent) {
                records[0].isCurrent = true
            }
            services.removeAll()
            for record in records {
                let cookies = try await sessionStore.cookies(for: record.accountID)
                let hasUID = cookies.contains {
                    $0.name.caseInsensitiveCompare("ngaPassportUid") == .orderedSame &&
                        Int64($0.value) == record.ngaUID
                }
                let hasCredential = cookies.contains {
                    $0.name.caseInsensitiveCompare("ngaPassportCid") == .orderedSame &&
                        !$0.value.isEmpty
                }
                if !hasUID || !hasCredential {
                    record.sessionState = .requiresLogin
                } else {
                    // 本地凭据仍完整时先恢复为有效。单个 NGA 接口的偶发鉴权失败
                    // 不应在下次启动后继续污染整个账号状态。
                    record.sessionState = .valid
                    services[record.accountID] = makeService(accountID: record.accountID, cookies: cookies)
                }
            }
            try context.save()
            accounts = records.map { $0.summary() }
            activeAccountID = records.first(where: \.isCurrent)?.accountID ?? records.first?.accountID
            refreshActiveAccountCheckInStatus(records: records)
        } catch {
            present(error)
        }
    }

    func addAccount(capture: LoginCapture) async {
        do {
            let records = try context.fetch(FetchDescriptor<AccountRecord>())
            let record: AccountRecord
            if let existing = records.first(where: { $0.ngaUID == capture.uid }) {
                record = existing
                record.sessionState = .valid
            } else {
                record = AccountRecord(ngaUID: capture.uid, displayName: "NGA \(capture.uid)")
                context.insert(record)
            }
            records.forEach { $0.isCurrent = false }
            record.isCurrent = true
            try await sessionStore.save(cookies: capture.cookies, for: record.accountID)
            let service = makeService(accountID: record.accountID, cookies: capture.cookies)
            services[record.accountID] = service
            if let profile = try? await service.profile(uid: capture.uid) {
                record.displayName = profile.displayName
                record.avatarURLString = profile.avatarURL?.absoluteString
            }
            try context.save()
            showsLogin = false
            await reloadAccountsAndServices()
            if let activeAccount {
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
            present(error)
        }
    }

    func selectAccount(_ accountID: AccountID) async {
        if activeAccountID == accountID, let account = activeAccount {
            await openUserCenter(
                uid: account.ngaUID,
                fallbackName: account.displayName,
                fallbackAvatarURL: account.avatarURL
            )
            return
        }
        do {
            let records = try context.fetch(FetchDescriptor<AccountRecord>())
            records.forEach { $0.isCurrent = $0.accountID == accountID }
            try context.save()
            activeAccountID = accountID
            accounts = records.sorted(by: { $0.createdAt < $1.createdAt }).map { $0.summary() }
            refreshActiveAccountCheckInStatus(records: records)
            clearVisibleContent()
            if let activeAccount {
                sidebarSelection = .userCenter(activeAccount.ngaUID)
                currentProfile = Profile(
                    uid: activeAccount.ngaUID,
                    displayName: activeAccount.displayName,
                    avatarURL: activeAccount.avatarURL
                )
            }
            await loadForums()
            await refreshFavorites()
            if let activeAccount {
                await openUserCenter(
                    uid: activeAccount.ngaUID,
                    fallbackName: activeAccount.displayName,
                    fallbackAvatarURL: activeAccount.avatarURL
                )
            }
        } catch {
            present(error)
        }
    }

    func removeAccount(_ accountID: AccountID) async {
        do {
            let accounts = try context.fetch(FetchDescriptor<AccountRecord>())
            let favorites = try context.fetch(FetchDescriptor<FavoriteRecord>())
            let drafts = try context.fetch(FetchDescriptor<DraftRecord>())
            let subforumPreferences = try context.fetch(
                FetchDescriptor<SubforumPreferenceRecord>()
            )
            accounts.filter { $0.accountID == accountID }.forEach(context.delete)
            favorites.filter { $0.accountIDString == accountID.description }.forEach(context.delete)
            drafts.filter { $0.accountIDString == accountID.description }.forEach(context.delete)
            subforumPreferences
                .filter { $0.accountIDString == accountID.description }
                .forEach(context.delete)
            try await sessionStore.remove(accountID: accountID)
            services[accountID] = nil
            try context.save()
            await reloadAccountsAndServices()
            clearVisibleContent()
            if let activeAccount {
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
            present(error)
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
            selectedTopicID = nil
            currentTopic = nil
            resetThreadNavigationHistory()
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

        let account = accounts.first { $0.ngaUID == uid }
        let resolvedName = fallbackName ?? account?.displayName ?? "NGA \(uid)"
        let resolvedAvatarURL = fallbackAvatarURL ?? account?.avatarURL
        currentProfile = Profile(
            uid: uid,
            displayName: resolvedName,
            avatarURL: resolvedAvatarURL
        )

        guard let service = activeService else { return }
        let requestAccountID = service.accountID
        let requestID = UUID()
        profileRequestID = requestID
        beginLoading()
        do {
            var profile = try await service.profile(uid: uid)
            if profile.displayName == "NGA \(uid)", !resolvedName.isEmpty {
                profile.displayName = resolvedName
            }
            if profile.avatarURL == nil {
                profile.avatarURL = resolvedAvatarURL
            }
            if activeAccountID == requestAccountID,
               profileRequestID == requestID,
               displayedUserUID == uid {
                currentProfile = profile
            }
        } catch {
            // 用户中心保留楼层或账号中已有的资料，不因资料接口失败阻断浏览。
        }
        endLoading()
        guard activeAccountID == requestAccountID,
              profileRequestID == requestID,
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
        let requestID = UUID()
        userActivityRequestID = requestID
        let targetPage = max(1, page)
        userActivityUID = uid
        userActivityKind = kind
        await withLoading(isCurrent: { self.userActivityRequestID == requestID }) {
            let result = try await service.userActivities(uid: uid, kind: kind, page: targetPage)
            guard activeAccountID == requestAccountID,
                  userActivityRequestID == requestID,
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
        let requestID = UUID()
        forumDirectoryRequestID = requestID
        await withLoading(isCurrent: { self.forumDirectoryRequestID == requestID }) {
            // NGA 的接口顺序就是官网分组和版面顺序，不能在这里全局排序。
            let result = try await service.forums()
            guard activeAccountID == requestAccountID,
                  forumDirectoryRequestID == requestID else {
                return
            }
            forums = result
            favorites = enrichingFavoriteForums(favorites)
        }
    }

    func searchForum(_ request: ForumSearchRequest, page: Int = 1) async {
        guard let service = activeService else { return }
        let requestAccountID = service.accountID
        let requestID = UUID()
        let targetPage = max(1, page)
        if forumSearchRequest != request {
            forumSearchPage = nil
        }
        forumSearchRequestID = requestID
        forumSearchRequest = request
        forumSearchErrorMessage = nil
        isSearchingForum = true
        defer {
            if forumSearchRequestID == requestID {
                isSearchingForum = false
            }
        }

        do {
            var result = try await service.search(request, page: targetPage)
            guard activeAccountID == requestAccountID,
                  forumSearchRequestID == requestID,
                  forumSearchRequest == request else {
                return
            }
            result = enrichingSearchPage(result)
            forumSearchPage = result
        } catch is CancellationError {
            return
        } catch {
            guard activeAccountID == requestAccountID,
                  forumSearchRequestID == requestID,
                  forumSearchRequest == request else {
                return
            }
            forumSearchPage = nil
            forumSearchErrorMessage = error.localizedDescription
            if let serviceError = error as? NGAServiceError,
               serviceError == .requiresLogin {
                present(error)
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
        forumSearchRequestID = nil
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
        selectedTopicID = nil
        currentTopic = nil
        posts = []
        hotReplies = []
        resetThreadNavigationHistory()
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
        sidebarSelection = .forum(forum.id)
        selectedTopicID = nil
        currentTopic = nil
        selectedMessageID = nil
        currentMessage = nil
        posts = []
        hotReplies = []
        subforums = []
        includedSubforumIDs = []
        subforumSelectionForumID = nil
        resetThreadNavigationHistory()
        await loadTopics(forumID: forum.id, reset: true)
    }

    func loadTopics(forumID: ForumID, reset: Bool) async {
        guard let service = activeService else { return }
        let requestAccountID = service.accountID
        let requestID = UUID()
        topicListRequestID = requestID
        isRefreshingTopics = true
        defer {
            if topicListRequestID == requestID {
                isRefreshingTopics = false
            }
        }
        let page = reset ? 1 : topicPage + 1
        await withLoading(isCurrent: { self.topicListRequestID == requestID }) {
            let result = try await service.topics(forumID: forumID, page: page)
            guard activeAccountID == requestAccountID,
                  topicListRequestID == requestID,
                  selectedForumID == forumID else {
                return
            }
            applyForumPage(result, forumID: forumID, replaceTopics: reset)
        }
    }

    func loadTopicPage(forumID: ForumID, page: Int) async {
        guard let service = activeService else { return }
        let requestAccountID = service.accountID
        let requestID = UUID()
        topicListRequestID = requestID
        isRefreshingTopics = true
        defer {
            if topicListRequestID == requestID {
                isRefreshingTopics = false
            }
        }
        let targetPage = max(1, min(page, topicTotalPages))
        await withLoading(isCurrent: { self.topicListRequestID == requestID }) {
            let result = try await service.topics(forumID: forumID, page: targetPage)
            guard activeAccountID == requestAccountID,
                  topicListRequestID == requestID,
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
        guard let activeAccountID else { return nil }
        let recordID = SubforumPreferenceRecord.recordID(
            accountID: activeAccountID,
            parentForumID: parentForumID
        )
        let records = (try? context.fetch(
            FetchDescriptor<SubforumPreferenceRecord>()
        )) ?? []
        return records.first(where: { $0.id == recordID })?.selectedForumIDs
    }

    private func saveCurrentSubforumSelection() {
        guard let activeAccountID, let parentForumID = currentForum?.id else {
            return
        }
        do {
            let recordID = SubforumPreferenceRecord.recordID(
                accountID: activeAccountID,
                parentForumID: parentForumID
            )
            let records = try context.fetch(
                FetchDescriptor<SubforumPreferenceRecord>()
            )
            if let record = records.first(where: { $0.id == recordID }) {
                record.selectedForumIDs = includedSubforumIDs
            } else {
                context.insert(SubforumPreferenceRecord(
                    accountID: activeAccountID,
                    parentForumID: parentForumID,
                    selectedForumIDs: includedSubforumIDs
                ))
            }
            try context.save()
        } catch {
            present(error)
        }
    }

    func openTopic(_ topic: Topic) async {
        resetThreadNavigationHistory()
        if let mirroredForumID = topic.mirroredForumID {
            let mirroredForum = subforums.first { $0.id == mirroredForumID }
                ?? forums.first { $0.id == mirroredForumID }
                ?? Forum(id: mirroredForumID, name: topic.subject)
            await openSubforum(mirroredForum)
            return
        }
        selectedTopicID = topic.id
        var selectedTopic = topic
        selectedTopic.isFavorite = topic.isFavorite || favoriteTopicIDs.contains(topic.id)
        currentTopic = selectedTopic
        posts = []
        hotReplies = []
        threadPage = 1
        threadTotalPages = max(1, (topic.replyCount + 20) / 20)
        await loadThread(topicID: topic.id, reset: true, showsLoadingIndicator: false)
    }

    @discardableResult
    func beginLinkedTopicNavigation(to topicID: TopicID, page: Int) -> Bool {
        guard selectedTopicID != topicID, let currentTopic else { return false }
        threadNavigationPath.append(ThreadNavigationSnapshot(
            topic: currentTopic,
            posts: posts,
            hotReplies: hotReplies,
            page: threadPage,
            hasMore: threadHasMore,
            totalPages: threadTotalPages
        ))
        threadRequestID = UUID()
        selectedTopicID = topicID
        self.currentTopic = Topic(
            id: topicID,
            forumID: currentTopic.forumID,
            subject: "主题 \(topicID.rawValue)",
            author: "",
            replyCount: 0
        )
        posts = []
        hotReplies = []
        threadPage = max(1, page)
        threadHasMore = false
        threadTotalPages = max(1, page)
        return true
    }

    @discardableResult
    func returnToPreviousThread() -> Bool {
        guard let previous = threadNavigationPath.popLast() else { return false }
        threadRequestID = UUID()
        selectedTopicID = previous.topic.id
        currentTopic = previous.topic
        posts = previous.posts
        hotReplies = previous.hotReplies
        threadPage = previous.page
        threadHasMore = previous.hasMore
        threadTotalPages = previous.totalPages
        return true
    }

    func loadThread(
        topicID: TopicID,
        reset: Bool,
        showsLoadingIndicator: Bool = true
    ) async {
        guard let service = activeService else { return }
        let requestAccountID = service.accountID
        let requestID = UUID()
        threadRequestID = requestID
        let page = reset ? 1 : threadPage + 1
        await withLoading(
            showsIndicator: showsLoadingIndicator,
            isCurrent: { self.threadRequestID == requestID }
        ) {
            let result = try await service.threadPage(topicID: topicID, page: page)
            guard activeAccountID == requestAccountID,
                  threadRequestID == requestID,
                  selectedTopicID == topicID else {
                return
            }
            var loadedTopic = result.topic
            loadedTopic.isFavorite = loadedTopic.isFavorite
                || favoriteTopicIDs.contains(loadedTopic.id)
            currentTopic = loadedTopic
            posts = reset ? result.posts : merged(posts, result.posts)
            if reset || !result.hotReplies.isEmpty {
                hotReplies = result.hotReplies
            }
            threadPage = page
            threadHasMore = result.hasMore
            threadTotalPages = max(result.totalPages, page)
        }
    }

    func loadThreadPage(topicID: TopicID, page: Int) async {
        guard let service = activeService else { return }
        let requestAccountID = service.accountID
        let requestID = UUID()
        threadRequestID = requestID
        let targetPage = max(1, page)
        await withLoading(isCurrent: { self.threadRequestID == requestID }) {
            let result = try await service.threadPage(topicID: topicID, page: targetPage)
            guard activeAccountID == requestAccountID,
                  threadRequestID == requestID,
                  selectedTopicID == topicID else {
                return
            }
            var loadedTopic = result.topic
            loadedTopic.isFavorite = loadedTopic.isFavorite
                || favoriteTopicIDs.contains(loadedTopic.id)
            currentTopic = loadedTopic
            posts = result.posts
            hotReplies = result.hotReplies
            threadPage = result.page
            threadHasMore = result.hasMore
            threadTotalPages = max(result.totalPages, result.page)
        }
    }

    func vote(on postID: PostID, direction: PostVoteDirection) async {
        guard let service = activeService,
              let post = posts.first(where: { $0.id == postID })
                ?? hotReplies.first(where: { $0.id == postID }),
              !votingPostIDs.contains(postID) else {
            return
        }
        votingPostIDs.insert(postID)
        defer { votingPostIDs.remove(postID) }

        let originalState = PostVoteState(
            upvoteCount: post.upvoteCount,
            downvoteCount: post.downvoteCount,
            userVote: post.userVote
        )
        let optimisticState = originalState.optimisticallyApplying(direction)
        updateVoteState(optimisticState, postID: postID, in: &posts)
        updateVoteState(optimisticState, postID: postID, in: &hotReplies)

        do {
            let state = try await service.vote(
                topicID: post.topicID,
                postID: postID,
                direction: direction
            )
            updateVoteState(state, postID: postID, in: &posts)
            updateVoteState(state, postID: postID, in: &hotReplies)
            statusMessage = "评价已更新"
            statusMessageIsError = false
        } catch {
            if voteSubmissionMayHaveSucceeded(error) {
                // NGA 偶尔会先执行点赞，再以 403 或无法解析的响应结束请求。
                // 此时保留即时更新，避免误报失败及用户重复提交。
                statusMessage = "评价已更新"
                statusMessageIsError = false
                return
            }
            updateVoteState(originalState, postID: postID, in: &posts)
            updateVoteState(originalState, postID: postID, in: &hotReplies)
            present(error)
        }
    }

    func submitTopicPollVote(topicID: TopicID, selection: Set<String>) async -> Bool {
        guard let service = activeService,
              let poll = posts.lazy.compactMap(\.poll).first(where: { $0.id == topicID }),
              !submittingPollTopicIDs.contains(topicID) else {
            return false
        }
        guard poll.isAcceptingResponses(at: .now) else {
            present(NGAServiceError.unsupported("该投票已经结束"))
            return false
        }
        guard poll.containsValidSelection(selection) else {
            present(NGAServiceError.unsupported("请选择有效的投票选项"))
            return false
        }

        let optionIDs = poll.orderedOptionIDs(in: selection)
        let requestAccountID = service.accountID
        submittingPollTopicIDs.insert(topicID)
        defer { submittingPollTopicIDs.remove(topicID) }

        do {
            try await service.submitTopicPollVote(
                topicID: topicID,
                optionIDs: optionIDs
            )
            guard activeAccountID == requestAccountID,
                  selectedTopicID == topicID else {
                return false
            }
            await loadThreadPage(topicID: topicID, page: threadPage)
            statusMessage = "投票已提交"
            statusMessageIsError = false
            return true
        } catch {
            guard activeAccountID == requestAccountID,
                  selectedTopicID == topicID else {
                return false
            }
            if voteSubmissionMayHaveSucceeded(error) {
                // 写请求不会自动重试。响应不明确时刷新主题，让服务器状态
                // 决定后续显示，避免用户重复投票。
                await loadThreadPage(topicID: topicID, page: threadPage)
                statusMessage = "投票请求已提交，结果以刷新后的主题为准"
                statusMessageIsError = false
                return true
            }
            present(error)
            return false
        }
    }

    func loadMessages(folder: MessageFolder, reset: Bool = true) async {
        guard let service = activeService else { return }
        let requestAccountID = service.accountID
        let requestID = UUID()
        messageListRequestID = requestID
        messageFolder = folder
        sidebarSelection = .messages(folder)
        let page = reset ? 1 : messagePage + 1
        await withLoading(isCurrent: { self.messageListRequestID == requestID }) {
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
            guard activeAccountID == requestAccountID,
                  messageListRequestID == requestID,
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
        resetThreadNavigationHistory()
        selectedTopicID = nil
        currentTopic = nil
        selectedMessageID = message.id
        let folder = messageFolder
        if folder == .notifications {
            markMessageRead(message, folder: folder)
            if message.kind == .privateMessage {
                guard let service = activeService else { return }
                let requestAccountID = service.accountID
                let requestID = UUID()
                messageDetailRequestID = requestID
                await withLoading(isCurrent: { self.messageDetailRequestID == requestID }) {
                    let result = try await service.message(id: message.id)
                    guard activeAccountID == requestAccountID,
                          messageDetailRequestID == requestID,
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
        let requestID = UUID()
        messageDetailRequestID = requestID
        await withLoading(isCurrent: { self.messageDetailRequestID == requestID }) {
            let result = try await service.message(id: message.id)
            guard activeAccountID == requestAccountID,
                  messageDetailRequestID == requestID,
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
              let activeAccountID,
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
        try? context.save()
    }

    func submitReply(
        topicID: TopicID,
        content: String,
        replyTo: PostID?,
        ratingScores: [String: Int] = [:]
    ) async -> Bool {
        guard let service = activeService,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        if !ratingScores.isEmpty {
            guard let rating = currentTopic?.rating,
                  currentTopic?.id == topicID else {
                present(NGAServiceError.unsupported("当前主题没有可用的评分"))
                return false
            }
            guard rating.isAcceptingResponses(at: .now) else {
                present(NGAServiceError.unsupported("该评分已经结束"))
                return false
            }
            guard rating.containsValidScores(ratingScores) else {
                present(NGAServiceError.unsupported("请选择有效的评分"))
                return false
            }
        }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            _ = try await service.submitReply(
                topicID: topicID,
                submission: ReplySubmission(
                    content: content,
                    replyTo: replyTo,
                    ratingScores: ratingScores
                )
            )
            deleteDraft(topicID: topicID)
            statusMessage = ratingScores.isEmpty ? "回复已发送" : "回复和评分已发送"
            statusMessageIsError = false
            await loadThread(topicID: topicID, reset: true)
            return true
        } catch {
            present(error)
            return false
        }
    }

    func replyToMessage(id: MessageID, content: String) async -> Bool {
        guard let service = activeService, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            try await service.replyMessage(id: id, content: content)
            statusMessage = "私信回复已发送"
            statusMessageIsError = false
            return true
        } catch {
            present(error)
            return false
        }
    }

    func refreshFavorites() async {
        guard let accountID = activeAccountID else {
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
        guard let service = services[accountID] else { return }
        let requestID = UUID()
        favoriteRequestID = requestID

        do {
            let fetchedFavorites = try await service.favorites()
            guard activeAccountID == accountID,
                  favoriteRequestID == requestID else {
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
        guard let accountID = activeAccountID else { return }
        let records = favoriteRecords(accountID: accountID)
        if let record = records.first(where: { $0.forumID == forum.id.rawValue }) {
            if record.syncState == .localOnly || !record.serverPresent {
                context.delete(record)
            } else {
                record.syncState = .pendingRemove
                record.updatedAt = Date()
            }
        } else {
            let order = (records.map(\.order).max() ?? -1) + 1
            context.insert(FavoriteRecord(accountID: accountID, forum: forum, order: order, syncState: .pendingAdd, serverPresent: false))
        }
        try? context.save()
        favorites = enrichingFavoriteForums(
            favoriteRecords(accountID: accountID)
                .filter { $0.syncState != .pendingRemove }
                .map {
                    FavoriteSnapshot(forum: $0.forum, order: $0.order, state: $0.syncState)
                }
                .sorted { $0.order < $1.order }
        )
        if let service = services[accountID] {
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
        let requestID = UUID()
        favoriteTopicFolderRequestID = requestID
        await withLoading(isCurrent: { self.favoriteTopicFolderRequestID == requestID }) {
            let folders = try await service.favoriteTopicFolders()
            guard activeAccountID == requestAccountID,
                  favoriteTopicFolderRequestID == requestID else {
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
        let requestID = UUID()
        favoriteTopicRequestID = requestID
        let targetPage = max(1, page)
        await withLoading(isCurrent: { self.favoriteTopicRequestID == requestID }) {
            let result = try await service.favoriteTopics(folderID: folderID, page: targetPage)
            guard activeAccountID == requestAccountID,
                  favoriteTopicRequestID == requestID,
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
            if currentTopic?.id == topic.id {
                currentTopic?.isFavorite = remainsFavorite
            }
            if let index = topics.firstIndex(where: { $0.id == topic.id }) {
                topics[index].isFavorite = remainsFavorite
            }
            statusMessage = isFavorite
                ? "已收藏到“\(folder.name)”"
                : "已从“\(folder.name)”移除"
            statusMessageIsError = false
        } catch {
            present(error)
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
                if currentTopic?.id == topic.id {
                    currentTopic?.isFavorite = false
                }
                if let index = topics.firstIndex(where: { $0.id == topic.id }) {
                    topics[index].isFavorite = false
                }
            }
            statusMessage = "已取消主题收藏"
            statusMessageIsError = false
        } catch {
            present(error)
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
            statusMessage = "收藏夹已创建"
            statusMessageIsError = false
            if selectedFavoriteTopicFolderID != nil {
                await loadFavoriteTopics(page: 1)
            }
            return true
        } catch {
            present(error)
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
            statusMessage = "收藏夹设置已更新"
            statusMessageIsError = false
            return true
        } catch {
            present(error)
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
            statusMessage = "收藏夹“\(folder.name)”已删除"
            statusMessageIsError = false
            return true
        } catch {
            present(error)
            return false
        }
    }

    func performMaintenance() async {
        await checkInAllAccounts()
        await pollMessages()
    }

    func checkInAllAccounts(force: Bool = false) async {
        await checkInAccounts(force: force, limitedTo: nil)
    }

    func checkInActiveAccount() async {
        guard let activeAccountID else {
            return
        }
        let records = (try? context.fetch(FetchDescriptor<AccountRecord>())) ?? []
        refreshActiveAccountCheckInStatus(records: records)
        guard activeAccountCheckInStatus.canCheckIn else { return }
        await checkInAccounts(force: true, limitedTo: [activeAccountID])
    }

    private func checkInAccounts(force: Bool, limitedTo accountIDs: Set<AccountID>?) async {
        let records = (try? context.fetch(FetchDescriptor<AccountRecord>())) ?? []
        refreshActiveAccountCheckInStatus(records: records)
        var results: [String] = []
        var hasFailure = false
        for record in records where record.sessionState == .valid {
            let accountID = record.accountID
            guard accountIDs?.contains(accountID) ?? true else { continue }
            guard force || CheckInPolicy.shouldCheckIn(lastSuccessfulDay: record.lastCheckInDay) else { continue }
            guard let service = services[accountID] else { continue }
            checkingInAccountIDs.insert(accountID)
            checkInFailures[accountID] = nil
            refreshActiveAccountCheckInStatus(records: records)
            do {
                let result = try await service.checkIn()
                record.lastCheckInDay = CheckInPolicy.dayKey(for: Date())
                switch result {
                case let .success(message), let .alreadyCheckedIn(message):
                    record.lastCheckInMessage = message
                    results.append("\(record.displayName)：\(message)")
                }
            } catch {
                hasFailure = true
                let message = checkInFailureMessage(error)
                checkInFailures[accountID] = message
                results.append("\(record.displayName)：\(message)")
            }
            checkingInAccountIDs.remove(accountID)
            refreshActiveAccountCheckInStatus(records: records)
        }
        try? context.save()
        refreshActiveAccountCheckInStatus(records: records)
        if !results.isEmpty {
            statusMessage = results.joined(separator: "\n")
            statusMessageIsError = hasFailure
        }
    }

    func pollMessages() async {
        let records = (try? context.fetch(FetchDescriptor<AccountRecord>())) ?? []
        for record in records where record.sessionState == .valid {
            guard let service = services[record.accountID] else { continue }
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
                if record.accountID == activeAccountID {
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
                    await notificationService.notify(
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
        try? context.save()
    }

    func refreshCurrentSelection() async {
        if selectedTopicID != nil {
            await refreshThreadContent()
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
            if let targetUID = uid ?? activeAccount?.ngaUID {
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

    func refreshThreadContent() async {
        guard let selectedTopicID else { return }
        await loadThreadPage(topicID: selectedTopicID, page: threadPage)
    }

    func handleNotification(
        accountIDString: String,
        messageIDString: String,
        messageFolderString: String
    ) async {
        guard let accountID = AccountID(accountIDString),
              accounts.contains(where: { $0.id == accountID }),
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

    func draft(topicID: TopicID) -> DraftRecord? {
        guard let activeAccountID else { return nil }
        return ((try? context.fetch(FetchDescriptor<DraftRecord>())) ?? []).first {
            $0.accountIDString == activeAccountID.description && $0.topicID == topicID.rawValue
        }
    }

    func saveDraft(topicID: TopicID, content: String, replyTo: PostID?) {
        guard let activeAccountID else { return }
        if let draft = draft(topicID: topicID) {
            draft.content = content
            draft.replyToPostID = replyTo?.rawValue
            draft.updatedAt = Date()
        } else {
            context.insert(DraftRecord(accountID: activeAccountID, topicID: topicID, replyToPostID: replyTo, content: content))
        }
        try? context.save()
    }

    func clearError() { errorMessage = nil }

    private var activeService: (any NGAForumService)? {
        activeAccountID.flatMap { services[$0] }
    }

    private func makeService(accountID: AccountID, cookies: [SessionCookie]) -> any NGAForumService {
        let sessionStore = sessionStore
        return LiveNGAForumService(accountID: accountID, cookies: cookies) { updatedCookies in
            try? await sessionStore.save(cookies: updatedCookies, for: accountID)
        }
    }

    private func favoriteRecords(accountID: AccountID) -> [FavoriteRecord] {
        ((try? context.fetch(FetchDescriptor<FavoriteRecord>())) ?? [])
            .filter { $0.accountIDString == accountID.description }
            .sorted { $0.order < $1.order }
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
                context.insert(FavoriteRecord(
                    accountID: accountID,
                    forum: snapshot.forum,
                    order: snapshot.order,
                    syncState: snapshot.state,
                    serverPresent: snapshot.state == .synced
                ))
            }
        }
        for record in records where !snapshotIDs.contains(record.forumID) && record.syncState != .pendingRemove {
            context.delete(record)
        }
        try? context.save()
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
                    context.delete(record)
                }
            } catch let error as NGAServiceError {
                if case .unsupported = error {
                    if adding {
                        record.syncState = .localOnly
                        record.serverPresent = false
                    } else {
                        context.delete(record)
                    }
                }
            } catch {
                // 保留 pending 状态，下一次前台刷新时重试。
            }
        }
        try? context.save()
        if activeAccountID == accountID {
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

    private func deleteDraft(topicID: TopicID) {
        guard let draft = draft(topicID: topicID) else { return }
        context.delete(draft)
        try? context.save()
    }

    private func clearVisibleContent() {
        favorites = []
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
        posts = []
        hotReplies = []
        messages = []
        currentForum = nil
        currentTopic = nil
        currentMessage = nil
        currentProfile = nil
        userActivities = []
        userActivityUID = nil
        userActivityKind = .topics
        userActivityPage = 1
        userActivityHasMore = false
        userActivityTotalPages = 1
        clearForumSearch()
        selectedTopicID = nil
        selectedMessageID = nil
        resetThreadNavigationHistory()
        previewImageURL = nil
        threadPage = 1
        threadHasMore = false
        threadTotalPages = 1
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

    private func resetThreadNavigationHistory() {
        threadNavigationPath = []
    }

    private func beginLoading() {
        loadingRequestCount += 1
        isLoading = true
    }

    private func endLoading() {
        loadingRequestCount = max(0, loadingRequestCount - 1)
        isLoading = loadingRequestCount > 0
    }

    private func withLoading(
        showsIndicator: Bool = true,
        isCurrent: () -> Bool = { true },
        _ operation: () async throws -> Void
    ) async {
        let requestAccountID = activeAccountID
        if showsIndicator { beginLoading() }
        defer {
            if showsIndicator { endLoading() }
        }
        do {
            try await operation()
            if let requestAccountID,
               requestAccountID == activeAccountID,
               isCurrent() {
                foregroundLoginFailureDates[requestAccountID] = nil
            }
        } catch {
            guard requestAccountID == activeAccountID, isCurrent() else { return }
            present(error)
        }
    }

    private func present(_ error: Error) {
        Task {
            await RuntimeLogger.shared.log(
                .error,
                category: "app",
                error.localizedDescription
            )
        }
        guard let serviceError = error as? NGAServiceError,
              serviceError == .requiresLogin,
              let activeAccountID else {
            errorMessage = error.localizedDescription
            return
        }

        let now = Date()
        let previousFailure = foregroundLoginFailureDates[activeAccountID]
        let isConsecutiveFailure = previousFailure.map {
            now.timeIntervalSince($0) <= 120
        } ?? false
        foregroundLoginFailureDates[activeAccountID] = now

        if !isConsecutiveFailure,
           accounts.first(where: { $0.id == activeAccountID })?.sessionState != .requiresLogin {
            statusMessage = "NGA 暂时未验证本次请求，已保留当前登录状态，请重试"
            statusMessageIsError = true
            return
        }

        errorMessage = error.localizedDescription
        markSessionRequiresLogin(accountID: activeAccountID)
    }

    private func checkInFailureMessage(_ error: Error) -> String {
        if error.localizedDescription.localizedCaseInsensitiveContains("client error") {
            return "签到请求被 NGA 拒绝，请稍后重试"
        }
        return error.localizedDescription
    }

    private func refreshActiveAccountCheckInStatus(
        records suppliedRecords: [AccountRecord]? = nil
    ) {
        guard let activeAccountID else {
            activeAccountCheckInStatus = .failed(message: "尚未登录")
            return
        }
        if checkingInAccountIDs.contains(activeAccountID) {
            activeAccountCheckInStatus = .checkingIn
            return
        }
        if let failure = checkInFailures[activeAccountID] {
            activeAccountCheckInStatus = .failed(message: failure)
            return
        }
        let records = suppliedRecords
            ?? ((try? context.fetch(FetchDescriptor<AccountRecord>())) ?? [])
        guard let record = records.first(where: { $0.accountID == activeAccountID }) else {
            activeAccountCheckInStatus = .failed(message: "无法读取签到状态")
            return
        }
        if record.lastCheckInDay == CheckInPolicy.dayKey(for: .now) {
            activeAccountCheckInStatus = .checkedIn(
                message: record.lastCheckInMessage ?? "今日已签到"
            )
        } else {
            activeAccountCheckInStatus = .notCheckedIn
        }
    }

    private func markSessionRequiresLogin(accountID: AccountID) {
        if let record = ((try? context.fetch(FetchDescriptor<AccountRecord>())) ?? []).first(where: { $0.accountID == accountID }) {
            record.sessionState = .requiresLogin
            try? context.save()
        }
        if let index = accounts.firstIndex(where: { $0.id == accountID }) {
            accounts[index].sessionState = .requiresLogin
        }
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

        guard let activeAccountID,
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
        try? context.save()
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
        ((try? context.fetch(FetchDescriptor<AccountRecord>())) ?? [])
            .first { $0.accountID == id }
    }

    private func updateVoteState(
        _ state: PostVoteState,
        postID: PostID,
        in posts: inout [Post]
    ) {
        guard let index = posts.firstIndex(where: { $0.id == postID }) else { return }
        posts[index].upvoteCount = state.upvoteCount
        posts[index].downvoteCount = state.downvoteCount
        posts[index].userVote = state.userVote
    }

    private func voteSubmissionMayHaveSucceeded(_ error: Error) -> Bool {
        guard let serviceError = error as? NGAServiceError else { return false }
        switch serviceError {
        case .ambiguousWrite:
            return true
        case let .restricted(message):
            return message.contains("HTTP 403")
        default:
            return false
        }
    }

#if DEBUG
    private func seedUITestData() {
        let accountA = AccountRecord(ngaUID: 10001, displayName: "测试账号 A", isCurrent: true)
        let accountB = AccountRecord(ngaUID: 10002, displayName: "测试账号 B")
        context.insert(accountA)
        context.insert(accountB)
        let favoriteForum = Forum(id: ForumID(rawValue: -7), name: "艾泽拉斯国家地理", subtitle: "UI 测试版面")
        context.insert(FavoriteRecord(
            accountID: accountA.accountID,
            forum: favoriteForum,
            order: 0,
            syncState: .localOnly,
            serverPresent: false
        ))
        try? context.save()
        accounts = [accountA.summary(), accountB.summary()]
        activeAccountID = accountA.accountID
        services[accountA.accountID] = DebugForumService(accountID: accountA.accountID)
        services[accountB.accountID] = DebugForumService(accountID: accountB.accountID)
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
