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
    let showsOnlyTopicAuthor: Bool
}

private struct PostAuthorLocationKey: Hashable, Sendable {
    let accountID: AccountID
    let uid: Int64
}

private struct CachedPostAuthorLocation: Sendable {
    let value: String?
}

private enum PostAuthorLocationResult: Sendable {
    case loaded(String?)
    case failed
}

private struct PostAuthorLocationRequest {
    let id: UUID
    let task: Task<PostAuthorLocationResult, Never>
}

enum AITopicSummaryPhase: Equatable, Sendable {
    case collecting(completedPages: Int, totalPages: Int)
    case generating
}

private struct AITopicSummaryPageLoadError: LocalizedError {
    let page: Int
    let detail: String

    var errorDescription: String? {
        "读取话题第 \(page) 页失败：\(detail)"
    }
}

/// 话题正文域：当前话题、楼层、分页、投票、回复与草稿。
///
/// 只依赖 `AppSession`。是否已收藏属于收藏域，通过 `isTopicFavorite` 反向注入，
/// 免得话题域为了一个布尔值去依赖整个收藏域。
@MainActor
@Observable
final class ThreadStore {
    var selectedTopicID: TopicID?
    var currentTopic: Topic?
    var posts: [Post] = []
    var hotReplies: [Post] = []

    var page = 1
    var hasMore = false
    var totalPages = 1

    var isLoadingContent = false
    var isSubmitting = false
    var votingPostIDs: Set<PostID> = []
    var submittingPollTopicIDs: Set<TopicID> = []
    var isShowingOnlyTopicAuthor = false

    private(set) var aiSummaryText = ""
    private(set) var aiSummaryErrorMessage: String?
    private(set) var aiSummaryTopicID: TopicID?
    private(set) var aiSummaryInput: AITopicSummaryInput?
    private(set) var isSummarizingTopic = false
    private(set) var aiSummaryPhase: AITopicSummaryPhase?

    @ObservationIgnored private let session: AppSession
    @ObservationIgnored private let aiSummarizer: any AITopicSummarizing
    @ObservationIgnored private let aiKeyStore: any AIKeyStore
    @ObservationIgnored private var isTopicFavorite: (TopicID) -> Bool = { _ in false }
    @ObservationIgnored private let threadRequests = RequestSlot()
    @ObservationIgnored private var threadNavigationPath: [ThreadNavigationSnapshot] = []
    @ObservationIgnored private var postAuthorLocationCache: [PostAuthorLocationKey: CachedPostAuthorLocation] = [:]
    @ObservationIgnored private var postAuthorLocationRequests: [PostAuthorLocationKey: PostAuthorLocationRequest] = [:]
    @ObservationIgnored private var aiSummaryTask: Task<Void, Never>?
    @ObservationIgnored private var aiSummaryRequestID = UUID()

    init(
        session: AppSession,
        aiSummarizer: any AITopicSummarizing,
        aiKeyStore: any AIKeyStore
    ) {
        self.session = session
        self.aiSummarizer = aiSummarizer
        self.aiKeyStore = aiKeyStore
        // 话题被锁只有话题域知道该怎么反应；AppSession 只负责统一呈现错误。
        session.onError { [weak self] error in
            guard let self,
                  let serviceError = error as? NGAServiceError,
                  serviceError == .topicLocked,
                  currentTopic?.id == selectedTopicID else {
                return
            }
            currentTopic?.isLocked = true
        }
    }

    func provideFavoriteLookup(_ lookup: @escaping (TopicID) -> Bool) {
        isTopicFavorite = lookup
    }

    private func merged<T: Identifiable>(
        _ existing: [T],
        _ incoming: [T]
    ) -> [T] where T.ID: Hashable {
        var seen = Set(existing.map(\.id))
        return existing + incoming.filter { seen.insert($0.id).inserted }
    }

    /// 切换账号或退出登录时清空正文。
    func reset() {
        clearAISummary()
        selectedTopicID = nil
        currentTopic = nil
        posts = []
        hotReplies = []
        page = 1
        hasMore = false
        totalPages = 1
        isShowingOnlyTopicAuthor = false
        threadRequests.invalidate()
        threadNavigationPath = []
        postAuthorLocationCache = [:]
        // 在途的属地查询必须取消：切账号后它们的结果不该再落到新账号的楼层上。
        postAuthorLocationRequests.values.forEach { $0.task.cancel() }
        postAuthorLocationRequests = [:]
    }

    func loadPostAuthorLocation(uid: Int64) async {
        guard uid > 0, let service = session.activeService else { return }
        let key = PostAuthorLocationKey(accountID: service.accountID, uid: uid)
        if let cached = postAuthorLocationCache[key] {
            applyPostAuthorLocation(cached.value, to: uid)
            return
        }

        let request: PostAuthorLocationRequest
        if let existing = postAuthorLocationRequests[key] {
            request = existing
        } else {
            let requestID = UUID()
            let task = Task<PostAuthorLocationResult, Never> { [service] in
                do {
                    let profile = try await service.profile(uid: uid)
                    return PostAuthorLocationResult.loaded(profile.location)
                } catch {
                    return PostAuthorLocationResult.failed
                }
            }
            request = PostAuthorLocationRequest(id: requestID, task: task)
            postAuthorLocationRequests[key] = request
        }

        let result = await request.task.value
        if postAuthorLocationRequests[key]?.id == request.id {
            postAuthorLocationRequests[key] = nil
        }
        guard session.activeAccountID == key.accountID else { return }

        switch result {
        case let .loaded(location):
            let normalizedLocation = location?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let visibleLocation = normalizedLocation?.isEmpty == false
                ? normalizedLocation
                : nil
            postAuthorLocationCache[key] = CachedPostAuthorLocation(
                value: visibleLocation
            )
            applyPostAuthorLocation(visibleLocation, to: uid)
        case .failed:
            break
        }
    }

    private func applyPostAuthorLocation(_ location: String?, to uid: Int64) {
        guard let location else { return }

        func enriching(_ values: [Post]) -> [Post] {
            values.map { post in
                guard post.authorUID == uid,
                      post.authorInfo?.location != location else {
                    return post
                }
                var updated = post
                var authorInfo = updated.authorInfo ?? PostAuthorInfo()
                authorInfo.location = location
                updated.authorInfo = authorInfo
                return updated
            }
        }

        posts = enriching(posts)
        hotReplies = enriching(hotReplies)
    }

    var currentTopicAuthorUID: Int64? {
        if let authorUID = currentTopic?.authorUID, authorUID != 0 {
            return authorUID
        }
        if let authorUID = posts.first(where: { $0.floor == 0 })?.authorUID,
           authorUID != 0 {
            return authorUID
        }
        return nil
    }

    var canReturnToPreviousThread: Bool {
        !threadNavigationPath.isEmpty
    }

    var previousThreadTitle: String? {
        threadNavigationPath.last?.topic.subject
    }

    /// 展示一个话题。版面相关的处理（镜像版面跳转）留在 AppModel 协调。
    func open(_ topic: Topic) async {
        clearAISummary()
        resetThreadNavigationHistory()
        selectedTopicID = topic.id
        var selectedTopic = topic
        selectedTopic.isFavorite = topic.isFavorite || isTopicFavorite(topic.id)
        currentTopic = selectedTopic
        posts = []
        hotReplies = []
        page = 1
        totalPages = max(1, (topic.replyCount + 20) / 20)
        await load(topicID: topic.id, reset: true, showsLoadingIndicator: false)
    }

    @discardableResult
    func prepareLinkedTopicPage(topicID: TopicID, page: Int) async -> ThreadPage? {
        guard let service = session.activeService,
              let sourceTopicID = selectedTopicID,
              sourceTopicID != topicID else {
            return nil
        }
        let requestAccountID = service.accountID
        let targetPage = max(1, page)
        var loadedPage: ThreadPage?
        let ticket = threadRequests.begin()
        await session.withLoading(isCurrent: { ticket.isCurrent }) {
            let result = try await service.threadPage(
                topicID: topicID,
                page: targetPage,
                authorUID: nil
            )
            guard session.activeAccountID == requestAccountID,
                  ticket.isCurrent,
                  selectedTopicID == sourceTopicID,
                  result.topic.id == topicID else {
                return
            }
            loadedPage = result
        }
        return loadedPage
    }

    @discardableResult
    func beginLinkedTopicNavigation(to destination: ThreadPage) -> Bool {
        guard selectedTopicID != destination.topic.id, let currentTopic else {
            return false
        }
        threadNavigationPath.append(ThreadNavigationSnapshot(
            topic: currentTopic,
            posts: posts,
            hotReplies: hotReplies,
            page: page,
            hasMore: hasMore,
            totalPages: totalPages,
            showsOnlyTopicAuthor: isShowingOnlyTopicAuthor
        ))
        clearAISummary()
        threadRequests.invalidate()
        var loadedTopic = destination.topic
        loadedTopic.isFavorite = loadedTopic.isFavorite
            || isTopicFavorite(loadedTopic.id)
        selectedTopicID = loadedTopic.id
        self.currentTopic = loadedTopic
        posts = destination.posts
        hotReplies = destination.hotReplies
        PostContentDiagnostics.recordPage(
            source: "linkedNavigation",
            topicID: loadedTopic.id.rawValue,
            page: destination.page,
            posts: destination.posts,
            hotReplies: destination.hotReplies
        )
        page = destination.page
        hasMore = destination.hasMore
        totalPages = max(destination.totalPages, destination.page)
        isShowingOnlyTopicAuthor = false
        return true
    }

    @discardableResult
    func returnToPreviousThread() -> Bool {
        guard let previous = threadNavigationPath.popLast() else { return false }
        clearAISummary()
        threadRequests.invalidate()
        selectedTopicID = previous.topic.id
        currentTopic = previous.topic
        posts = previous.posts
        hotReplies = previous.hotReplies
        page = previous.page
        hasMore = previous.hasMore
        totalPages = previous.totalPages
        isShowingOnlyTopicAuthor = previous.showsOnlyTopicAuthor
        return true
    }

    func load(
        topicID: TopicID,
        reset: Bool,
        showsLoadingIndicator: Bool = true
    ) async {
        guard let service = session.activeService else { return }
        clearAISummary()
        let requestAccountID = service.accountID
        let ticket = threadRequests.begin()
        let targetPage = reset ? 1 : page + 1
        let showsSkeleton = reset
        if showsSkeleton {
            isLoadingContent = true
        }
        defer {
            if ticket.isCurrent {
                isLoadingContent = false
            }
        }
        await session.withLoading(
            showsIndicator: showsLoadingIndicator,
            isCurrent: { ticket.isCurrent }
        ) {
            let result = try await service.threadPage(
                topicID: topicID,
                page: targetPage,
                authorUID: isShowingOnlyTopicAuthor ? currentTopicAuthorUID : nil
            )
            guard session.activeAccountID == requestAccountID,
                  ticket.isCurrent,
                  selectedTopicID == topicID else {
                return
            }
            var loadedTopic = result.topic
            loadedTopic.isFavorite = loadedTopic.isFavorite
                || isTopicFavorite(loadedTopic.id)
            loadedTopic.authorUID = loadedTopic.authorUID ?? currentTopic?.authorUID
            currentTopic = loadedTopic
            posts = reset ? result.posts : merged(posts, result.posts)
            if reset || !result.hotReplies.isEmpty {
                hotReplies = result.hotReplies
            }
            PostContentDiagnostics.recordPage(
                source: reset ? "refresh" : "loadMore",
                topicID: topicID.rawValue,
                page: targetPage,
                posts: posts,
                hotReplies: hotReplies
            )
            page = targetPage
            hasMore = result.hasMore
            totalPages = max(result.totalPages, targetPage)
        }
    }

    @discardableResult
    func loadPage(topicID: TopicID, page: Int) async -> Bool {
        guard let service = session.activeService else { return false }
        clearAISummary()
        let requestAccountID = service.accountID
        let ticket = threadRequests.begin()
        let targetPage = max(1, page)
        var didLoad = false
        isLoadingContent = true
        defer {
            if ticket.isCurrent {
                isLoadingContent = false
            }
        }
        await session.withLoading(isCurrent: { ticket.isCurrent }) {
            let result = try await service.threadPage(
                topicID: topicID,
                page: targetPage,
                authorUID: isShowingOnlyTopicAuthor ? currentTopicAuthorUID : nil
            )
            guard session.activeAccountID == requestAccountID,
                  ticket.isCurrent,
                  selectedTopicID == topicID else {
                return
            }
            var loadedTopic = result.topic
            loadedTopic.isFavorite = loadedTopic.isFavorite
                || isTopicFavorite(loadedTopic.id)
            loadedTopic.authorUID = loadedTopic.authorUID ?? currentTopic?.authorUID
            currentTopic = loadedTopic
            posts = result.posts
            hotReplies = result.hotReplies
            PostContentDiagnostics.recordPage(
                source: "loadPage",
                topicID: topicID.rawValue,
                page: result.page,
                posts: result.posts,
                hotReplies: result.hotReplies
            )
            self.page = result.page
            hasMore = result.hasMore
            totalPages = max(result.totalPages, result.page)
            didLoad = true
        }
        return didLoad
    }

    func summarizeCurrentTopic() {
        guard AISettings.isEnabled,
              let topic = currentTopic,
              selectedTopicID == topic.id,
              !posts.isEmpty else {
            return
        }

        cancelAISummary(showsMessage: false, clearsContent: true)
        let requestID = UUID()
        aiSummaryRequestID = requestID
        let visiblePage = page
        let visiblePosts = posts
        let visiblePageIsFiltered = isShowingOnlyTopicAuthor
        let initialTotalPages = max(max(totalPages, visiblePage), 1)
        let pageScope = AISettings.topicSummaryPageScope
        let initialTargetPageCount = pageScope.pageCount(totalPages: initialTotalPages)
        let service = session.activeService
        let requestAccountID = service?.accountID
        aiSummaryTopicID = topic.id
        aiSummaryInput = nil
        aiSummaryErrorMessage = nil
        isSummarizingTopic = true
        aiSummaryPhase = .collecting(completedPages: 0, totalPages: initialTargetPageCount)

        aiSummaryTask = Task { [weak self] in
            guard let self else { return }
            do {
                let apiKey = try await aiKeyStore.apiKey()
                let configuration = try AISettings.configuration(
                    apiKey: apiKey,
                    purpose: .topicSummary
                )
                try Task.checkCancellation()
                guard aiSummaryRequestID == requestID,
                      selectedTopicID == topic.id,
                      AISettings.isEnabled else {
                    return
                }

                var knownTotalPages = initialTotalPages
                var targetPageCount = initialTargetPageCount
                var collectedPosts: [Post] = []
                var targetPage = 1
                while targetPage <= targetPageCount {
                    try Task.checkCancellation()
                    guard aiSummaryRequestID == requestID,
                          selectedTopicID == topic.id,
                          AISettings.isEnabled else {
                        return
                    }

                    let pagePosts: [Post]
                    if targetPage == visiblePage, !visiblePageIsFiltered {
                        pagePosts = visiblePosts
                    } else {
                        guard let service else {
                            throw AITopicSummaryPageLoadError(
                                page: targetPage,
                                detail: "当前没有可用的 NGA 服务"
                            )
                        }
                        let result: ThreadPage
                        do {
                            result = try await service.threadPage(
                                topicID: topic.id,
                                page: targetPage,
                                authorUID: nil
                            )
                        } catch {
                            throw AITopicSummaryPageLoadError(
                                page: targetPage,
                                detail: error.localizedDescription
                            )
                        }
                        try Task.checkCancellation()
                        guard aiSummaryRequestID == requestID,
                              selectedTopicID == topic.id,
                              AISettings.isEnabled,
                              session.activeAccountID == requestAccountID else {
                            return
                        }
                        pagePosts = result.posts
                        knownTotalPages = max(
                            knownTotalPages,
                            max(result.totalPages, result.page)
                        )
                        targetPageCount = pageScope.pageCount(totalPages: knownTotalPages)
                    }

                    collectedPosts = merged(collectedPosts, pagePosts)
                    aiSummaryPhase = .collecting(
                        completedPages: targetPage,
                        totalPages: targetPageCount
                    )
                    targetPage += 1
                }

                let requestedAllPages: Bool
                switch pageScope {
                case .all: requestedAllPages = true
                case .first: requestedAllPages = false
                }
                let input = AITopicSummaryInput.make(
                    topic: topic,
                    posts: collectedPosts,
                    coveredPages: 1...max(1, targetPageCount),
                    totalPages: knownTotalPages,
                    requestedAllPages: requestedAllPages
                )
                aiSummaryInput = input
                aiSummaryPhase = .generating

                var completeText = ""
                for try await fragment in aiSummarizer.streamTopicSummary(
                    configuration: configuration,
                    input: input
                ) {
                    try Task.checkCancellation()
                    guard aiSummaryRequestID == requestID,
                          selectedTopicID == topic.id,
                          AISettings.isEnabled else {
                        return
                    }
                    completeText += fragment
                    aiSummaryText = completeText
                }

                guard !completeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw AIServiceError.emptyResponse
                }
                guard aiSummaryRequestID == requestID else { return }
                isSummarizingTopic = false
                aiSummaryPhase = nil
                aiSummaryTask = nil
            } catch is CancellationError {
                // A newer request, navigation or the master switch owns the state.
            } catch {
                guard aiSummaryRequestID == requestID else { return }
                isSummarizingTopic = false
                aiSummaryPhase = nil
                aiSummaryTask = nil
                aiSummaryErrorMessage = error.localizedDescription
            }
        }
    }

    func cancelAISummary(
        showsMessage: Bool = true,
        clearsContent: Bool = false
    ) {
        let hadActiveRequest = isSummarizingTopic
        aiSummaryRequestID = UUID()
        aiSummaryTask?.cancel()
        aiSummaryTask = nil
        isSummarizingTopic = false
        aiSummaryPhase = nil
        if clearsContent {
            aiSummaryText = ""
        }
        if showsMessage, hadActiveRequest {
            aiSummaryErrorMessage = "已取消话题总结。"
        }
    }

    func clearAISummary() {
        cancelAISummary(showsMessage: false, clearsContent: true)
        aiSummaryErrorMessage = nil
        aiSummaryTopicID = nil
        aiSummaryInput = nil
    }

    func vote(on postID: PostID, direction: PostVoteDirection) async {
        guard let service = session.activeService,
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
            session.statusMessage = "评价已更新"
            session.statusMessageIsError = false
        } catch {
            if voteSubmissionMayHaveSucceeded(error) {
                // NGA 偶尔会先执行点赞，再以 403 或无法解析的响应结束请求。
                // 此时保留即时更新，避免误报失败及用户重复提交。
                session.statusMessage = "评价已更新"
                session.statusMessageIsError = false
                return
            }
            updateVoteState(originalState, postID: postID, in: &posts)
            updateVoteState(originalState, postID: postID, in: &hotReplies)
            session.present(error)
        }
    }

    func submitTopicPollVote(topicID: TopicID, selection: Set<String>) async -> Bool {
        guard let service = session.activeService,
              let poll = posts.lazy.compactMap(\.poll).first(where: { $0.id == topicID }),
              !submittingPollTopicIDs.contains(topicID) else {
            return false
        }
        guard poll.isAcceptingResponses(at: .now) else {
            session.present(NGAServiceError.unsupported("该投票已经结束"))
            return false
        }
        guard poll.containsValidSelection(selection) else {
            session.present(NGAServiceError.unsupported("请选择有效的投票选项"))
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
            guard session.activeAccountID == requestAccountID,
                  selectedTopicID == topicID else {
                return false
            }
            await loadPage(topicID: topicID, page: page)
            session.statusMessage = "投票已提交"
            session.statusMessageIsError = false
            return true
        } catch {
            guard session.activeAccountID == requestAccountID,
                  selectedTopicID == topicID else {
                return false
            }
            if voteSubmissionMayHaveSucceeded(error) {
                // 写请求不会自动重试。响应不明确时刷新话题，让服务器状态
                // 决定后续显示，避免用户重复投票。
                await loadPage(topicID: topicID, page: page)
                session.statusMessage = "投票请求已提交，结果以刷新后的话题为准"
                session.statusMessageIsError = false
                return true
            }
            session.present(error)
            return false
        }
    }

    func submitReply(
        topicID: TopicID,
        content: String,
        replyTo: PostID?,
        ratingScores: [String: Int] = [:]
    ) async -> Bool {
        guard let service = session.activeService,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        if currentTopic?.id == topicID, currentTopic?.isLocked == true {
            session.present(NGAServiceError.topicLocked)
            return false
        }
        if !ratingScores.isEmpty {
            guard let rating = currentTopic?.rating,
                  currentTopic?.id == topicID else {
                session.present(NGAServiceError.unsupported("当前话题没有可用的评分"))
                return false
            }
            guard rating.isAcceptingResponses(at: .now) else {
                session.present(NGAServiceError.unsupported("该评分已经结束"))
                return false
            }
            guard rating.containsValidScores(ratingScores) else {
                session.present(NGAServiceError.unsupported("请选择有效的评分"))
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
            session.statusMessage = ratingScores.isEmpty ? "回复已发送" : "回复和评分已发送"
            session.statusMessageIsError = false
            await load(topicID: topicID, reset: true)
            return true
        } catch {
            session.present(error)
            return false
        }
    }

    func refreshContent() async {
        guard let selectedTopicID else { return }
        await loadPage(topicID: selectedTopicID, page: page)
    }

    func toggleOnlyTopicAuthor() async {
        guard let selectedTopicID,
              isShowingOnlyTopicAuthor || currentTopicAuthorUID != nil else {
            return
        }
        let previousValue = isShowingOnlyTopicAuthor
        isShowingOnlyTopicAuthor.toggle()
        let didLoad = await loadPage(topicID: selectedTopicID, page: 1)
        if !didLoad, self.selectedTopicID == selectedTopicID {
            isShowingOnlyTopicAuthor = previousValue
        }
    }

    func draft(topicID: TopicID) -> DraftRecord? {
        guard let activeAccountID = session.activeAccountID else { return nil }
        return ((try? session.context.fetch(FetchDescriptor<DraftRecord>())) ?? []).first {
            $0.accountIDString == activeAccountID.description && $0.topicID == topicID.rawValue
        }
    }

    func saveDraft(topicID: TopicID, content: String, replyTo: PostID?) {
        guard let activeAccountID = session.activeAccountID else { return }
        if let draft = draft(topicID: topicID) {
            draft.content = content
            draft.replyToPostID = replyTo?.rawValue
            draft.updatedAt = Date()
        } else {
            session.context.insert(DraftRecord(accountID: activeAccountID, topicID: topicID, replyToPostID: replyTo, content: content))
        }
        try? session.context.save()
    }

    private func deleteDraft(topicID: TopicID) {
        guard let draft = draft(topicID: topicID) else { return }
        session.context.delete(draft)
        try? session.context.save()
    }

    private func resetThreadNavigationHistory() {
        threadNavigationPath = []
        isShowingOnlyTopicAuthor = false
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
}
