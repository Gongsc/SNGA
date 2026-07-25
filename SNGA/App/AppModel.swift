import Foundation
import Observation
import SwiftData

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

    var forums: [Forum] = []
    var favorites: [FavoriteSnapshot] = []
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
    var threadPage = 1
    var threadHasMore = false
    var threadTotalPages = 1
    var messagePage = 1
    var messageHasMore = false
    var unreadCount = 0

    var isLoading = false
    var isSubmitting = false
    var votingPostIDs: Set<PostID> = []
    var showsLogin = false
    var errorMessage: String?
    var statusMessage: String?
    var statusMessageIsError = false
    var previewImageURL: URL?
    var checkingInAccountIDs: Set<AccountID> = []
    var checkInFailures: [AccountID: String] = [:]
    private var checkInRevision = 0

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
    @ObservationIgnored private var topicListRequestID: UUID?
    @ObservationIgnored private var threadRequestID: UUID?
    @ObservationIgnored private var messageListRequestID: UUID?
    @ObservationIgnored private var messageDetailRequestID: UUID?
    @ObservationIgnored private var favoriteRequestID: UUID?
    @ObservationIgnored private var messageUnreadCounts: [MessageFolder: Int] = [:]
    private var forumUserReturnSelection: SidebarSelection?

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

    var activeAccountCheckInStatus: DailyCheckInStatus {
        _ = checkInRevision
        guard let activeAccountID else {
            return .failed(message: "尚未登录")
        }
        if checkingInAccountIDs.contains(activeAccountID) {
            return .checkingIn
        }
        if let failure = checkInFailures[activeAccountID] {
            return .failed(message: failure)
        }
        let records = (try? context.fetch(FetchDescriptor<AccountRecord>())) ?? []
        guard let record = records.first(where: { $0.accountID == activeAccountID }) else {
            return .failed(message: "无法读取签到状态")
        }
        if record.lastCheckInDay == CheckInPolicy.dayKey(for: Date()) {
            return .checkedIn(message: record.lastCheckInMessage ?? "今日已签到")
        }
        return .notCheckedIn
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

    var parentForum: Forum? {
        forumNavigationPath.last
    }

    var forumCategories: [ForumCategory] {
        var order: [String] = []
        var grouped: [String: [Forum]] = [:]
        for forum in forums {
            let category = forum.category?.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = category.flatMap { $0.isEmpty ? nil : $0 } ?? "其他板块"
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
            // NGA 的接口顺序就是官网分组和板块顺序，不能在这里全局排序。
            let result = try await service.forums()
            guard activeAccountID == requestAccountID,
                  forumDirectoryRequestID == requestID else {
                return
            }
            forums = result
        }
    }

    func openForum(_ forum: Forum) async {
        forumNavigationPath = []
        await showForum(forum)
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
        currentForum = forum
        sidebarSelection = .forum(forum.id)
        selectedTopicID = nil
        currentTopic = nil
        posts = []
        hotReplies = []
        subforums = []
        includedSubforumIDs = []
        subforumSelectionForumID = nil
        await loadTopics(forumID: forum.id, reset: true)
    }

    func loadTopics(forumID: ForumID, reset: Bool) async {
        guard let service = activeService else { return }
        let requestAccountID = service.accountID
        let requestID = UUID()
        topicListRequestID = requestID
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
        if let mirroredForumID = topic.mirroredForumID {
            let mirroredForum = subforums.first { $0.id == mirroredForumID }
                ?? forums.first { $0.id == mirroredForumID }
                ?? Forum(id: mirroredForumID, name: topic.subject)
            await openSubforum(mirroredForum)
            return
        }
        selectedTopicID = topic.id
        currentTopic = topic
        posts = []
        hotReplies = []
        threadPage = 1
        threadTotalPages = max(1, (topic.replyCount + 20) / 20)
        await loadThread(topicID: topic.id, reset: true)
    }

    func loadThread(topicID: TopicID, reset: Bool) async {
        guard let service = activeService else { return }
        let requestAccountID = service.accountID
        let requestID = UUID()
        threadRequestID = requestID
        let page = reset ? 1 : threadPage + 1
        await withLoading(isCurrent: { self.threadRequestID == requestID }) {
            let result = try await service.threadPage(topicID: topicID, page: page)
            guard activeAccountID == requestAccountID,
                  threadRequestID == requestID,
                  selectedTopicID == topicID else {
                return
            }
            currentTopic = result.topic
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
            currentTopic = result.topic
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
            present(error)
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
            var result = try await service.messages(folder: folder, page: page)
            guard activeAccountID == requestAccountID,
                  messageListRequestID == requestID,
                  sidebarSelection == .messages(folder),
                  messageFolder == folder else {
                return
            }
            result.messages = applyingPersistedReadState(
                to: result.messages,
                folder: folder,
                accountID: requestAccountID
            )
            messages = reset ? result.messages : merged(messages, result.messages)
            messagePage = page
            messageHasMore = result.hasMore
            setUnreadCount(messages.filter(\.isUnread).count, for: folder)
        }
    }

    func openMessage(_ message: ForumMessage) async {
        selectedTopicID = nil
        currentTopic = nil
        selectedMessageID = message.id
        let folder = messageFolder
        if folder == .notifications {
            markMessageRead(message, folder: folder)
            currentMessage = messages.first(where: { $0.id == message.id }) ?? message
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

    func submitReply(topicID: TopicID, content: String, replyTo: PostID?) async -> Bool {
        guard let service = activeService, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            _ = try await service.submitReply(topicID: topicID, submission: ReplySubmission(content: content, replyTo: replyTo))
            deleteDraft(topicID: topicID)
            statusMessage = "回复已发送"
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
        let local = records.map {
            FavoriteSnapshot(forum: $0.forum, order: $0.order, state: $0.syncState)
        }
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
            let server = fetchedFavorites.map { favorite in
                guard let directoryForum = forums.first(where: { $0.id == favorite.id }) else {
                    return favorite
                }
                var enriched = favorite
                if enriched.subtitle?.isEmpty != false { enriched.subtitle = directoryForum.subtitle }
                if enriched.iconURL == nil { enriched.iconURL = directoryForum.iconURL }
                if enriched.category?.isEmpty != false { enriched.category = directoryForum.category }
                return enriched
            }
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
        favorites = favoriteRecords(accountID: accountID)
            .filter { $0.syncState != .pendingRemove }
            .map { FavoriteSnapshot(forum: $0.forum, order: $0.order, state: $0.syncState) }
            .sorted { $0.order < $1.order }
        if let service = services[accountID] {
            await replayFavoriteChanges(accountID: accountID, service: service)
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
        guard let activeAccountID,
              activeAccountCheckInStatus.canCheckIn else {
            return
        }
        await checkInAccounts(force: true, limitedTo: [activeAccountID])
    }

    private func checkInAccounts(force: Bool, limitedTo accountIDs: Set<AccountID>?) async {
        let records = (try? context.fetch(FetchDescriptor<AccountRecord>())) ?? []
        var results: [String] = []
        var hasFailure = false
        for record in records where record.sessionState == .valid {
            let accountID = record.accountID
            guard accountIDs?.contains(accountID) ?? true else { continue }
            guard force || CheckInPolicy.shouldCheckIn(lastSuccessfulDay: record.lastCheckInDay) else { continue }
            guard let service = services[accountID] else { continue }
            checkingInAccountIDs.insert(accountID)
            checkInFailures[accountID] = nil
            checkInRevision += 1
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
            checkInRevision += 1
        }
        try? context.save()
        checkInRevision += 1
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
                if let notificationIndex = pages.firstIndex(where: { $0.folder == .notifications }) {
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
                    for page in pages {
                        messageUnreadCounts[page.folder] = page.messages.filter(\.isUnread).count
                    }
                    unreadCount = messageUnreadCounts.values.reduce(0, +)
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
            favorites = favoriteRecords(accountID: accountID)
                .filter { $0.syncState != .pendingRemove }
                .map { FavoriteSnapshot(forum: $0.forum, order: $0.order, state: $0.syncState) }
        }
    }

    private func deleteDraft(topicID: TopicID) {
        guard let draft = draft(topicID: topicID) else { return }
        context.delete(draft)
        try? context.save()
    }

    private func clearVisibleContent() {
        favorites = []
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
        selectedTopicID = nil
        selectedMessageID = nil
        previewImageURL = nil
        threadPage = 1
        threadHasMore = false
        threadTotalPages = 1
        topicPage = 1
        topicHasMore = false
        topicTotalPages = 1
        unreadCount = 0
        messageUnreadCounts = [:]
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
        isCurrent: () -> Bool = { true },
        _ operation: () async throws -> Void
    ) async {
        let requestAccountID = activeAccountID
        beginLoading()
        defer { endLoading() }
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

    private func applyingPersistedReadState(
        to messages: [ForumMessage],
        folder: MessageFolder,
        accountID: AccountID
    ) -> [ForumMessage] {
        guard folder == .notifications,
              let record = accountRecord(id: accountID) else {
            return messages
        }
        // NGA 的提醒接口在读取后会清除服务端未读计数；在用户实际打开提醒前，
        // 用本地状态保留未读标记，避免下一轮轮询把提醒误判为已读。
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

        guard folder == .notifications,
              let activeAccountID,
              let record = accountRecord(id: activeAccountID) else {
            return
        }
        let key = UnreadMessagePolicy.key(folder: folder, messageID: message.id)
        var keys = record.readNotificationKeys.filter { $0 != key }
        keys.insert(key, at: 0)
        record.readNotificationKeys = Array(keys.prefix(UnreadMessagePolicy.maximumSeenKeyCount))
        try? context.save()
    }

    private func setUnreadCount(_ count: Int, for folder: MessageFolder) {
        messageUnreadCounts[folder] = max(0, count)
        unreadCount = messageUnreadCounts.values.reduce(0, +)
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

#if DEBUG
    private func seedUITestData() {
        let accountA = AccountRecord(ngaUID: 10001, displayName: "测试账号 A", isCurrent: true)
        let accountB = AccountRecord(ngaUID: 10002, displayName: "测试账号 B")
        context.insert(accountA)
        context.insert(accountB)
        let favoriteForum = Forum(id: ForumID(rawValue: -7), name: "艾泽拉斯国家地理", subtitle: "UI 测试板块")
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
