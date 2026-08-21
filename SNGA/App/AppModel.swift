import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class AppModel {
    var sidebarSelection: SidebarSelection? = .userCenter(nil)
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
    var selectedSettingsSection: SettingsSection = .appearance



    var previewImageURL: URL?
    /// 图片操作（复制、另存为、在浏览器中打开）失败的提示，由根视图弹出。
    /// 正文里的每张配图都可能触发，提示放在这里，图片视图自己不必各带一个弹窗。
    var imageActionError: String?

    @ObservationIgnored private var bootstrapped = false
    @ObservationIgnored private let profileRequests = RequestSlot()
    @ObservationIgnored private let userActivityRequests = RequestSlot()
    @ObservationIgnored private let forumSearchRequests = RequestSlot()
    private var forumUserReturnSelection: SidebarSelection?

    let session: AppSession
    let thread: ThreadStore
    let messaging: MessageStore
    let favorite: FavoriteStore
    let browsing: ForumStore

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
        messaging = MessageStore(session: session)
        favorite = FavoriteStore(session: session)
        browsing = ForumStore(session: session)
        // 「是否已收藏」归收藏域所有。话题域只需要这一个查询，用闭包倒置依赖，
        // 避免它为了一个布尔值反过来持有整个 AppModel。
        thread.provideFavoriteLookup { [weak favorite] topicID in
            favorite?.contains(topicID) ?? false
        }
        // 收藏项里的版面信息要靠版面目录补全。
        favorite.provideForumEnrichment { [weak self] forum in
            self?.browsing.enrichingForumFromDirectory(forum) ?? forum
        }
        // 收藏状态变化后，话题列表和当前话题上的标记跟着更新。
        browsing.provideSelectionCheck { [weak self] forumID in
            self?.selectedForumID == forumID
        }
        browsing.provideFavoriteLookup { [weak favorite] topicID in
            favorite?.contains(topicID) ?? false
        }
        browsing.onDirectoryLoad { [weak favorite] in
            favorite?.refreshForumDetails()
        }
        favorite.onFavoriteChange { [weak self] topicID, isFavorite in
            guard let self else { return }
            if thread.currentTopic?.id == topicID {
                thread.currentTopic?.isFavorite = isFavorite
            }
            if let index = browsing.topics.firstIndex(where: { $0.id == topicID }) {
                browsing.topics[index].isFavorite = isFavorite
            }
        }
        // 侧栏选择是导航状态，留在 AppModel；消息域只需要判断用户是否还停在该信箱。
        messaging.provideSelectionCheck { [weak self] folder in
            self?.sidebarSelection == .messages(folder)
        }
    }

    /// 打开一条消息。指向话题的提醒需要跨域跳转，由这里协调。
    func openMessage(_ message: ForumMessage) async {
        thread.reset()
        switch await messaging.open(message) {
        case .handled:
            break
        case let .requestsTopic(id, subject, author):
            await openTopic(Topic(
                id: id,
                forumID: ForumID(rawValue: 0),
                subject: subject,
                author: author,
                replyCount: 0
            ))
        }
    }

    func loadMessages(folder: MessageFolder, reset: Bool = true) async {
        sidebarSelection = .messages(folder)
        await messaging.load(folder: folder, reset: reset)
    }

    func pollMessages() async {
        await messaging.poll()
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
        guard let forum = browsing.currentForum else { return false }
        return favorite.favorites.contains { $0.forum.id == forum.id && $0.state != .pendingRemove }
    }

    var currentPinnedTopicID: TopicID? {
        browsing.currentForum?.pinnedTopicID
    }

    var isCurrentTopicFavorite: Bool {
        guard let topic = thread.currentTopic else { return false }
        return topic.isFavorite || favorite.favoriteTopicIDs.contains(topic.id)
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
            browsing.loadRecentForums()
            sidebarSelection = .userCenter(activeAccount.ngaUID)
            currentProfile = Profile(
                uid: activeAccount.ngaUID,
                displayName: activeAccount.displayName,
                avatarURL: activeAccount.avatarURL
            )
            await browsing.loadForums()
            await favorite.refreshFavorites()
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
                browsing.loadRecentForums()
                sidebarSelection = .userCenter(activeAccount.ngaUID)
                currentProfile = Profile(
                    uid: activeAccount.ngaUID,
                    displayName: activeAccount.displayName,
                    avatarURL: activeAccount.avatarURL
                )
            }
            await browsing.loadForums()
            await favorite.refreshFavorites()
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
            browsing.loadRecentForums()
            if let activeAccount = session.activeAccount {
                sidebarSelection = .userCenter(activeAccount.ngaUID)
                currentProfile = Profile(
                    uid: activeAccount.ngaUID,
                    displayName: activeAccount.displayName,
                    avatarURL: activeAccount.avatarURL
                )
            }
            await browsing.loadForums()
            await favorite.refreshFavorites()
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
            let favoriteRecords = try session.context.fetch(FetchDescriptor<FavoriteRecord>())
            let drafts = try session.context.fetch(FetchDescriptor<DraftRecord>())
            let subforumPreferences = try session.context.fetch(
                FetchDescriptor<SubforumPreferenceRecord>()
            )
            let recentForumRecords = try session.context.fetch(
                FetchDescriptor<RecentForumRecord>()
            )
            accountRecords.filter { $0.accountID == accountID }.forEach(session.context.delete)
            favoriteRecords.filter { $0.accountIDString == accountID.description }.forEach(session.context.delete)
            drafts.filter { $0.accountIDString == accountID.description }.forEach(session.context.delete)
            subforumPreferences
                .filter { $0.accountIDString == accountID.description }
                .forEach(session.context.delete)
            recentForumRecords
                .filter { $0.accountIDString == accountID.description }
                .forEach(session.context.delete)
            try await session.sessionStore.remove(accountID: accountID)
            session.setService(nil, for: accountID)
            try session.context.save()
            await session.reloadAccountsAndServices()
            clearVisibleContent()
            if let activeAccount = session.activeAccount {
                browsing.loadRecentForums()
                sidebarSelection = .userCenter(activeAccount.ngaUID)
                currentProfile = Profile(
                    uid: activeAccount.ngaUID,
                    displayName: activeAccount.displayName,
                    avatarURL: activeAccount.avatarURL
                )
                await browsing.loadForums()
                await favorite.refreshFavorites()
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
        browsing.topicListScrollToTopRevision &+= 1
        await showForum(forum)
    }

    func returnToForumDirectory() {
        clearForumSearch()
        browsing.forumNavigationPath = []
        sidebarSelection = .directory
        thread.reset()
    }

    func openSubforum(_ forum: Forum) async {
        if let currentForum = browsing.currentForum, currentForum.id != forum.id {
            browsing.forumNavigationPath.append(currentForum)
        }
        await showForum(forum)
    }

    func openParentForum() async {
        guard let parent = browsing.forumNavigationPath.popLast() else { return }
        await showForum(parent)
    }

    /// 切换版面：清掉详情栏里属于上一个版面的内容，再交由版面域加载。
    private func showForum(_ forum: Forum) async {
        clearForumSearch()
        thread.reset()
        messaging.currentMessage = nil
        messaging.selectedMessageID = nil
        browsing.beginShowing(forum)
        sidebarSelection = .forum(forum.id)
        await browsing.loadTopics(forumID: forum.id, reset: true)
    }









    func openTopic(_ topic: Topic) async {
        if let mirroredForumID = topic.mirroredForumID {
            let mirroredForum = browsing.subforums.first { $0.id == mirroredForumID }
                ?? browsing.forums.first { $0.id == mirroredForumID }
                ?? Forum(id: mirroredForumID, name: topic.subject)
            await openSubforum(mirroredForum)
            return
        }
        await thread.open(topic)
    }

    func openPinnedTopic() async {
        guard let currentForum = browsing.currentForum,
              let topicID = currentForum.pinnedTopicID else {
            return
        }
        let topic = browsing.topics.first {
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
















    func performMaintenance() async {
        await session.checkInAllAccounts()
        await pollMessages()
    }


    func refreshCurrentSelection() async {
        if thread.selectedTopicID != nil {
            await thread.refreshContent()
            return
        }
        switch sidebarSelection {
        case let .forum(id): await browsing.loadTopics(forumID: id, reset: true)
        case let .messages(folder): await loadMessages(folder: folder)
        case .directory: await browsing.loadForums()
        case .search:
            if let forumSearchRequest {
                await searchForum(
                    forumSearchRequest,
                    page: forumSearchPage?.page ?? 1
                )
            }
        case .favorites: await favorite.loadFavoriteTopics(page: favorite.favoriteTopicPage)
        case .toolbox: refreshToolbox()
        // 设置里没有要重新拉的东西，⌘R 在这里什么都不做。
        case .settings: break
        case let .userCenter(uid):
            if let targetUID = uid ?? session.activeAccount?.ngaUID {
                await openUserCenter(uid: targetUID)
            }
            await browsing.loadForums()
            await favorite.refreshFavorites()
            await performMaintenance()
        case .none:
            await browsing.loadForums()
            await favorite.refreshFavorites()
            await performMaintenance()
        }
    }

    func refreshToolbox() {
        toolboxRefreshRevision &+= 1
    }

    /// 切到设置。清掉话题和消息的选中，右栏才轮得到设置面板 ——
    /// 和边栏其他目的地的做法一致。
    ///
    /// `section` 留空表示停在上次看的那一类：⌘, 该回到用户离开的地方，只有
    /// 「关于 SNGA」这种指名道姓的入口才需要指定落点。
    func openSettings(section: SettingsSection? = nil) {
        if let section {
            selectedSettingsSection = section
        }
        sidebarSelection = .settings
        thread.selectedTopicID = nil
        messaging.selectedMessageID = nil
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
        if let message = messaging.messages.first(where: { $0.id.rawValue == rawMessageID }) {
            await openMessage(message)
        }
    }








    private func enrichingSearchPage(_ page: ForumSearchPage) -> ForumSearchPage {
        var page = page
        page.forums = page.forums.map(browsing.enrichingForumFromDirectory)
        if page.request.forumID == nil {
            let knownForums = Dictionary(
                (browsing.forums + page.forums).map { ($0.id, $0) },
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





    /// 切换或删除账号时清空所有属于上一个账号的可见内容。
    /// 各领域自己知道该清什么，这里只负责调用它们并清理仍留在本类型的状态。
    private func clearVisibleContent() {
        thread.reset()
        messaging.reset()
        favorite.reset()
        browsing.reset()


        browsing.topics = []
        browsing.subforums = []
        browsing.includedSubforumIDs = []
        browsing.forumNavigationPath = []
        browsing.topicPage = 1
        browsing.topicHasMore = false
        browsing.topicTotalPages = 1
        clearForumSearch()

        currentProfile = nil
        userActivities = []
        userActivityUID = nil
        userActivityKind = .topics
        userActivityPage = 1
        userActivityHasMore = false
        userActivityTotalPages = 1

        previewImageURL = nil
        imageActionError = nil
    }


    private func merged<T: Identifiable>(_ existing: [T], _ incoming: [T]) -> [T] where T.ID: Hashable {
        var seen = Set(existing.map(\.id))
        return existing + incoming.filter { seen.insert($0.id).inserted }
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
        browsing.forums = [favoriteForum, Forum(id: ForumID(rawValue: 510381), name: "晴风村")]
        favorite.favorites = [FavoriteSnapshot(forum: favoriteForum, order: 0, state: .localOnly)]
        sidebarSelection = .userCenter(accountA.ngaUID)
        currentProfile = Profile(
            uid: accountA.ngaUID,
            displayName: accountA.displayName,
            avatarURL: nil
        )
    }
#endif
}
