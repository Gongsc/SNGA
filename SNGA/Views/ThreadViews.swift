import AppKit
import SwiftUI

private enum ThreadNavigationDirection {
    case forward
    case backward
}

private struct ThreadPresentation {
    let topic: Topic
    let posts: [Post]
    let hotReplies: [Post]
    let page: Int
    let totalPages: Int
    let previousTitle: String?
}

struct ThreadView: View {
    @Environment(\.forumSiteDescriptor) private var siteDescriptor
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(AISettings.enabledKey) private var aiEnabled = true
    @State private var replyTarget: Post?
    @State private var writesNewReply = false
    @State private var showsLockedTopicAlert = false
    @State private var showsTopicLinkActions = false
    @State private var didCopyTopicLink = false
    @State private var navigationDirection = ThreadNavigationDirection.forward
    @State private var pendingLinkedPostID: PostID?
    @State private var isLinkedThreadTransitioning = false
    @State private var preparedThreadContentIdentity: ThreadPageContentView.Identity?
    private let topAnchor = "thread-page-top"

    var body: some View {
        ZStack {
            if let presentation = currentPresentation {
                threadContent(presentation)
                    .id(presentation.topic.id)
                    .transition(threadTransition)
            }
        }
        .clipped()
        .sheet(item: $replyTarget) { post in
            if let topic = model.thread.currentTopic {
                ReplyComposerView(topic: topic, replyTo: post)
                    .environment(model)
            }
        }
        .sheet(isPresented: $writesNewReply) {
            if let topic = model.thread.currentTopic {
                ReplyComposerView(topic: topic, replyTo: nil)
                    .environment(model)
            }
        }
        .task {
            await model.favorite.loadFavoriteTopicFolders()
        }
        .alert("帖子已锁定", isPresented: $showsLockedTopicAlert) {
            Button("好", role: .cancel) {}
        } message: {
            Text("该话题已锁定，无法回复。")
        }
        .ignoresSafeArea(.container, edges: .top)
        .onDisappear {
            // 缓存项都是存活的 WKWebView，且按话题作键。离开话题视图后这些
            // 实例不会再被复用，留着只是白占内存。
            PostWebViewCache.shared.removeAll()
        }
    }

    private var currentPresentation: ThreadPresentation? {
        guard let topic = model.thread.currentTopic else { return nil }
        return ThreadPresentation(
            topic: topic,
            posts: model.thread.posts,
            hotReplies: model.thread.hotReplies,
            page: model.thread.page,
            totalPages: model.thread.totalPages,
            previousTitle: model.thread.previousThreadTitle
        )
    }

    private func threadContent(_ presentation: ThreadPresentation) -> some View {
        ScrollViewReader { proxy in
            let contentIdentity = ThreadPageContentView.Identity(
                topicID: presentation.topic.id,
                page: presentation.page,
                posts: presentation.posts,
                hotReplies: presentation.hotReplies
            )
            let showsSkeleton = showsThreadContentSkeleton

            VStack(spacing: 0) {
                ThreadTitleHeader(
                    topic: presentation.topic,
                    previousTitle: presentation.previousTitle,
                    isNavigationEnabled: !isLinkedThreadTransitioning,
                    navigateBack: navigateBack,
                    showsAISummaryButton: aiEnabled,
                    canSummarize: !presentation.posts.isEmpty && !showsSkeleton,
                    summarize: summarizeTopic
                )

                ScrollView {
                    VStack(spacing: 12) {
                        if aiEnabled,
                           model.thread.aiSummaryTopicID == presentation.topic.id {
                            AITopicSummaryCard()
                        }

                        ZStack(alignment: .top) {
                            ThreadPageContentView(
                                identity: contentIdentity,
                                topAnchor: topAnchor,
                                posts: presentation.posts,
                                hotReplies: presentation.hotReplies,
                                topicRating: presentation.topic.rating,
                                reply: startReply,
                                openPost: { postID, page, topicID in
                                    revealPost(
                                        postID,
                                        page: page,
                                        topicID: topicID,
                                        proxy: proxy
                                    )
                                },
                                openInternalLink: { destination in
                                    openInternalLink(destination, proxy: proxy)
                                },
                                onReady: markThreadContentReady
                            )
                            .id(contentIdentity)
                            .opacity(showsSkeleton ? 0 : 1)
                            .allowsHitTesting(!showsSkeleton)
                            .accessibilityHidden(showsSkeleton)

                            ThreadContentSkeletonView()
                                .opacity(showsSkeleton ? 1 : 0)
                                .allowsHitTesting(showsSkeleton)
                                .accessibilityHidden(!showsSkeleton)
                        }
                        .animation(
                            reduceMotion ? nil : .easeOut(duration: 0.18),
                            value: showsSkeleton
                        )
                    }
                    .padding()
                }
                .accessibilityIdentifier("thread-content-scroll")
                .scrollDisabled(showsSkeleton)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    PaginationBar(
                        currentPage: presentation.page,
                        totalPages: presentation.totalPages,
                        isLoading: isThreadLoading,
                        showsLoadingIndicator: !showsThreadContentSkeleton,
                        identifierPrefix: "thread",
                        subject: "本话题",
                        navigate: { page in
                            guard let topicID = model.thread.selectedTopicID else { return }
                            Task {
                                await model.thread.loadPage(topicID: topicID, page: page)
                                await Task.yield()
                                scrollToThreadTop(proxy: proxy)
                            }
                        }
                    ) {
                        Button {
                            scrollToThreadTop(proxy: proxy)
                        } label: {
                            Label("回到顶部", systemImage: "arrow.up.to.line")
                        }
                        .labelStyle(.iconOnly)
                        .help("回到话题内容顶部")
                        .disabled(model.thread.currentTopic == nil)
                        .accessibilityIdentifier("thread-scroll-to-top")

                        Button {
                            showsTopicLinkActions = true
                        } label: {
                            Label("分享话题", systemImage: "square.and.arrow.up")
                        }
                        .labelStyle(.iconOnly)
                        .help("复制话题链接或在浏览器中打开")
                        .disabled(model.thread.selectedTopicID == nil)
                        .accessibilityIdentifier("thread-share")
                        .popover(isPresented: $showsTopicLinkActions, arrowEdge: .bottom) {
                            if let topicURL {
                                TopicLinkActionsPopover(
                                    url: topicURL,
                                    didCopy: didCopyTopicLink,
                                    copy: copyTopicLink,
                                    openInBrowser: openTopicInBrowser
                                )
                            }
                        }

                        if !model.session.supports(.topicFavoriteFolders) {
                            // 站点只有一个收藏列表，没有可选的目录。那就是一个开关，
                            // 不是一份菜单 —— 菜单里只有一项，等于让人多点一下去选
                            // 一个没有第二种可能的选项。
                            Button {
                                if let topic = model.thread.currentTopic {
                                    Task { await model.favorite.toggleTopicFavorite(topic) }
                                }
                            } label: {
                                Label(
                                    model.isCurrentTopicFavorite ? "取消收藏" : "收藏话题",
                                    systemImage: model.isCurrentTopicFavorite ? "star.fill" : "star"
                                )
                            }
                            .labelStyle(.iconOnly)
                            .help(model.isCurrentTopicFavorite ? "取消收藏这个话题" : "收藏这个话题")
                            .disabled(
                                model.thread.currentTopic == nil
                                    || model.thread.currentTopic.map {
                                        model.favorite.updatingFavoriteTopicIDs.contains($0.id)
                                    } == true
                            )
                            .accessibilityIdentifier("thread-topic-favorite")
                        } else {
                        Menu {
                            if let topic = model.thread.currentTopic {
                                if model.favorite.favoriteTopicFolders.isEmpty {
                                    Text("正在加载收藏目录…")
                                } else {
                                    ForEach(model.favorite.sortedFavoriteTopicFolders) { folder in
                                        Toggle(
                                            isOn: Binding(
                                                get: {
                                                    model.favorite.isTopicFavorite(topic, in: folder)
                                                },
                                                set: { isFavorite in
                                                    Task {
                                                        await model.favorite.setTopicFavorite(
                                                            topic,
                                                            in: folder,
                                                            isFavorite: isFavorite
                                                        )
                                                    }
                                                }
                                            )
                                        ) {
                                            Text(folder.name)
                                            if folder.isDefault {
                                                Text("默认收藏夹")
                                            }
                                        }
                                        .disabled(model.favorite.updatingFavoriteTopicIDs.contains(topic.id))
                                    }
                                    Divider()
                                    if model.isCurrentTopicFavorite {
                                        Button(role: .destructive) {
                                            Task {
                                                await model.favorite.cancelTopicFavorite(topic)
                                            }
                                        } label: {
                                            Label("取消收藏", systemImage: "star.slash")
                                        }
                                        .disabled(model.favorite.updatingFavoriteTopicIDs.contains(topic.id))
                                        .accessibilityIdentifier("thread-topic-unfavorite")
                                        Divider()
                                    }
                                    Button {
                                        model.sidebarSelection = .favorites
                                    } label: {
                                        Label("管理收藏夹", systemImage: "folder")
                                    }
                                }
                            }
                        } label: {
                            Label(
                                model.isCurrentTopicFavorite ? "管理话题收藏" : "收藏话题",
                                systemImage: model.isCurrentTopicFavorite ? "star.fill" : "star"
                            )
                        }
                        .labelStyle(.iconOnly)
                        .help("选择话题收藏夹")
                        .disabled(model.thread.currentTopic == nil)
                        .accessibilityIdentifier("thread-topic-favorite")
                        }

                        Button {
                            Task {
                                await model.thread.toggleOnlyTopicAuthor()
                                await Task.yield()
                                scrollToThreadTop(proxy: proxy)
                            }
                        } label: {
                            Label(
                                model.thread.isShowingOnlyTopicAuthor ? "查看全部回复" : "只看作者",
                                systemImage: model.thread.isShowingOnlyTopicAuthor
                                    ? "person.crop.circle.fill"
                                    : "person.crop.circle"
                            )
                        }
                        .labelStyle(.iconOnly)
                        .help(
                            model.thread.isShowingOnlyTopicAuthor
                                ? "显示话题中的全部回复"
                                : "只显示话题作者的回复"
                        )
                        .disabled(model.thread.currentTopicAuthorUID == nil || isThreadLoading)
                        .accessibilityValue(model.thread.isShowingOnlyTopicAuthor ? "已开启" : "已关闭")
                        .accessibilityIdentifier("thread-only-author")

                        Button {
                            Task { await model.thread.refreshContent() }
                        } label: {
                            Label("刷新话题内容", systemImage: "arrow.clockwise.circle")
                        }
                        .labelStyle(.iconOnly)
                        .help("刷新当前话题内容")
                        .disabled(isThreadLoading)
                        .accessibilityIdentifier("thread-refresh")

                        Button {
                            startNewReply()
                        } label: {
                            Label(
                                presentation.topic.isLocked ? "话题已锁定" : "回复话题",
                                systemImage: presentation.topic.isLocked
                                    ? "lock.fill"
                                    : "arrowshape.turn.up.left"
                            )
                        }
                        .labelStyle(.iconOnly)
                        .help(presentation.topic.isLocked ? "话题已锁定" : "回复当前话题")
                        .disabled(model.thread.selectedTopicID == nil)
                        .accessibilityIdentifier("thread-reply")
                    }
                }
                .onAppear {
                    scrollToPendingLinkedPost(proxy: proxy)
                }
                .onChange(of: presentation.posts.map(\.id)) {
                    scrollToPendingLinkedPost(proxy: proxy)
                }
            }
        }
    }

    private func summarizeTopic() {
        guard AISettings.isTopicSummaryConfigured else {
            model.openSettings(section: .ai)
            return
        }
        model.thread.summarizeCurrentTopic()
    }

    private var threadTransition: AnyTransition {
        if reduceMotion {
            return .opacity
        }
        switch navigationDirection {
        case .forward:
            return .asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .move(edge: .leading).combined(with: .opacity)
            )
        case .backward:
            return .asymmetric(
                insertion: .move(edge: .leading).combined(with: .opacity),
                removal: .move(edge: .trailing).combined(with: .opacity)
            )
        }
    }

    private func startNewReply() {
        guard model.thread.currentTopic?.isLocked != true else {
            showsLockedTopicAlert = true
            return
        }
        writesNewReply = true
    }

    private func startReply(to post: Post) {
        guard model.thread.currentTopic?.isLocked != true else {
            showsLockedTopicAlert = true
            return
        }
        if post.floor == 0 {
            writesNewReply = true
        } else {
            replyTarget = post
        }
    }

    private var showsThreadContentSkeleton: Bool {
        guard let currentThreadContentIdentity else { return true }
        return model.thread.isLoadingContent
            || isLinkedThreadTransitioning
            || preparedThreadContentIdentity != currentThreadContentIdentity
    }

    private var isThreadLoading: Bool {
        showsThreadContentSkeleton
    }

    private var currentThreadContentIdentity: ThreadPageContentView.Identity? {
        guard let presentation = currentPresentation else { return nil }
        return ThreadPageContentView.Identity(
            topicID: presentation.topic.id,
            page: presentation.page,
            posts: presentation.posts,
            hotReplies: presentation.hotReplies
        )
    }

    private var threadNavigationAnimation: Animation? {
        motionAnimation(.spring(response: 0.38, dampingFraction: 0.86))
    }

    private func navigateBack() {
        guard model.thread.canReturnToPreviousThread, !isLinkedThreadTransitioning else { return }
        navigationDirection = .backward
        pendingLinkedPostID = nil
        var didReturn = false
        withAnimation(threadNavigationAnimation) {
            isLinkedThreadTransitioning = true
            didReturn = model.thread.returnToPreviousThread()
        } completion: {
            finishLinkedThreadTransition()
        }
        if !didReturn {
            finishLinkedThreadTransition()
        }
    }

    private func scrollToPendingLinkedPost(proxy: ScrollViewProxy) {
        guard let postID = pendingLinkedPostID,
              model.thread.posts.contains(where: { $0.id == postID }) else {
            return
        }
        Task { @MainActor in
            await Task.yield()
            withAnimation(motionAnimation(.easeInOut(duration: 0.25))) {
                proxy.scrollTo(postID, anchor: .top)
            }
            pendingLinkedPostID = nil
        }
    }

    private func revealPost(
        _ postID: PostID,
        page: Int?,
        topicID: TopicID,
        proxy: ScrollViewProxy
    ) {
        Task { @MainActor in
            if !model.thread.posts.contains(where: { $0.id == postID }),
               let page {
                await model.thread.loadPage(topicID: topicID, page: page)
            }
            await Task.yield()
            if model.thread.posts.contains(where: { $0.id == postID }) {
                withAnimation(motionAnimation(.easeInOut(duration: 0.25))) {
                    proxy.scrollTo(postID, anchor: .top)
                }
            } else {
                model.session.statusMessage = "未能在当前帖子页找到引用楼层"
                model.session.statusMessageIsError = true
            }
        }
    }

    private func openInternalLink(
        _ destination: NGAInternalDestination,
        proxy: ScrollViewProxy
    ) {
        switch destination {
        case let .post(postID, page):
            guard let topicID = model.thread.selectedTopicID else { return }
            revealPost(postID, page: page, topicID: topicID, proxy: proxy)

        case let .topic(topicID, page, postID):
            guard !isLinkedThreadTransitioning else { return }
            if model.thread.selectedTopicID == topicID {
                if let postID {
                    revealPost(postID, page: page, topicID: topicID, proxy: proxy)
                } else if let page, page != model.thread.page {
                    Task { @MainActor in
                        await model.thread.loadPage(topicID: topicID, page: page)
                        await Task.yield()
                        scrollToThreadTop(proxy: proxy)
                    }
                }
                return
            }

            let targetPage = page ?? 1
            Task { @MainActor in
                navigationDirection = .forward
                pendingLinkedPostID = postID
                withAnimation(motionAnimation(.easeOut(duration: 0.16))) {
                    isLinkedThreadTransitioning = true
                }
                guard let destination = await model.thread.prepareLinkedTopicPage(
                    topicID: topicID,
                    page: targetPage
                ) else {
                    pendingLinkedPostID = nil
                    finishLinkedThreadTransition()
                    return
                }
                var didBegin = false
                withAnimation(threadNavigationAnimation) {
                    didBegin = model.thread.beginLinkedTopicNavigation(to: destination)
                } completion: {
                    finishLinkedThreadTransition()
                }
                guard didBegin else {
                    pendingLinkedPostID = nil
                    finishLinkedThreadTransition()
                    return
                }
                guard model.thread.selectedTopicID == topicID else { return }
                await Task.yield()
                if postID == nil {
                    scrollToThreadTop(proxy: proxy)
                } else if pendingLinkedPostID != nil,
                          !model.thread.posts.contains(where: { $0.id == postID }) {
                    pendingLinkedPostID = nil
                    model.session.statusMessage = "未能在目标帖子页找到引用楼层"
                    model.session.statusMessageIsError = true
                }
            }

        case let .forum(forumID):
            let forum = model.browsing.subforums.first { $0.id == forumID }
                ?? model.browsing.forums.first { $0.id == forumID }
                ?? Forum(id: forumID, name: "版面 \(forumID.description)")
            Task { await model.openForum(forum) }

        case let .user(uid):
            Task {
                await model.openUserCenter(
                    uid: uid,
                    preservingForumContext: true
                )
            }
        }
    }

    private func finishLinkedThreadTransition() {
        withAnimation(motionAnimation(.easeOut(duration: 0.18))) {
            isLinkedThreadTransitioning = false
        }
    }

    private func markThreadContentReady(_ identity: ThreadPageContentView.Identity) {
        guard identity == currentThreadContentIdentity else { return }
        preparedThreadContentIdentity = identity
    }

    private func scrollToThreadTop(proxy: ScrollViewProxy) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            proxy.scrollTo(topAnchor, anchor: .top)
        }
    }

    private var topicURL: URL? {
        model.thread.selectedTopicID.map(siteDescriptor.topicWebURL(topicID:))
    }

    private func copyTopicLink() {
        guard let url = topicURL else { return }
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(url.absoluteString, forType: .string) else {
            model.session.statusMessage = "复制话题链接失败"
            model.session.statusMessageIsError = true
            return
        }
        model.session.statusMessage = "话题链接已复制"
        model.session.statusMessageIsError = false
        didCopyTopicLink = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            didCopyTopicLink = false
        }
    }

    private func openTopicInBrowser() {
        guard let url = topicURL else { return }
        if NSWorkspace.shared.open(url) {
            model.session.statusMessage = "已在默认浏览器中打开话题"
            model.session.statusMessageIsError = false
            showsTopicLinkActions = false
        } else {
            model.session.statusMessage = "无法打开默认浏览器"
            model.session.statusMessageIsError = true
        }
    }

    private func motionAnimation(_ animation: Animation) -> Animation? {
        reduceMotion ? nil : animation
    }
}

private struct TopicLinkActionsPopover: View {
    let url: URL
    let didCopy: Bool
    let copy: () -> Void
    let openInBrowser: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("话题网页链接")
                .font(.headline)
            Text(url.absoluteString)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(2)

            HStack(spacing: 14) {
                Button(action: copy) {
                    ZStack {
                        Label("复制链接", systemImage: "doc.on.doc")
                            .opacity(didCopy ? 0 : 1)
                        Label("已复制", systemImage: "checkmark")
                            .opacity(didCopy ? 1 : 0)
                    }
                    .accessibilityHidden(true)
                }
                .buttonStyle(.bordered)
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityLabel(didCopy ? "已复制" : "复制链接")
                .accessibilityIdentifier("copy-topic-link")
                Button(action: openInBrowser) {
                    Label("在默认浏览器中打开", systemImage: "safari")
                }
                .buttonStyle(.borderedProminent)
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityIdentifier("open-topic-in-browser")
            }
        }
        .padding(14)
        .frame(width: 390)
    }
}

private struct ThreadTitleHeader: View {
    @Environment(\.sngaTheme) private var theme
    let topic: Topic
    let previousTitle: String?
    let isNavigationEnabled: Bool
    let navigateBack: () -> Void
    let showsAISummaryButton: Bool
    let canSummarize: Bool
    let summarize: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if let previousTitle {
                AnimatedThreadBackButton(
                    previousTitle: previousTitle,
                    isEnabled: isNavigationEnabled,
                    action: navigateBack
                )
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if topic.isAnonymous {
                    AnonymousBadge(scale: .medium)
                        .font(.title2)
                        .accessibilityIdentifier("thread-topic-anonymous")
                }
                ThreadTitleText(text: normalizedTitle)
                    .accessibilityLabel(normalizedTitle)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("thread-topic-title")
            }
            .layoutPriority(1)

            if showsAISummaryButton {
                Button(action: summarize) {
                    Label("AI 总结", systemImage: "sparkles")
                }
                .buttonStyle(.bordered)
                .fixedSize()
                .disabled(!canSummarize)
                .help("按 AI 设置中的页数范围总结标题和楼层文字")
                .accessibilityLabel("AI 总结话题")
                .accessibilityHint("设置范围内的页面内容会发送到已配置的 AI 服务")
                .accessibilityIdentifier("thread-ai-summary-button")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surfaceColor, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(theme.separatorColor)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    private var normalizedTitle: String {
        topic.subject
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}

private struct AITopicSummaryCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.sngaTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .foregroundStyle(theme.accentColor)
                    .accessibilityHidden(true)
                Text("AI 话题总结")
                    .font(.headline)
                Spacer()
                if model.thread.isSummarizingTopic {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(summaryProgressAccessibilityLabel)
                }
            }

            if let input = model.thread.aiSummaryInput {
                HStack(spacing: 6) {
                    Text(coverageDescription(input.coverage))
                    Text("·")
                    Text("\(input.coverage.postCount) 层")
                    if input.coverage.wasTruncated {
                        Text("· 输入已裁剪")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if model.thread.aiSummaryText.isEmpty,
               model.thread.isSummarizingTopic {
                Text(summaryProgressDescription)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if !model.thread.aiSummaryText.isEmpty {
                AIMarkdownView(
                    markdown: model.thread.aiSummaryText,
                    accessibilityIdentifier: "thread-ai-summary-content"
                )
            }

            if let error = model.thread.aiSummaryErrorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("thread-ai-summary-error")
            }

            HStack(spacing: 10) {
                if model.thread.isSummarizingTopic {
                    Button("取消", role: .cancel) {
                        model.thread.cancelAISummary()
                    }
                    .accessibilityIdentifier("thread-ai-summary-cancel")
                } else {
                    Button(
                        model.thread.aiSummaryText.isEmpty ? "重试" : "重新总结",
                        systemImage: "arrow.clockwise"
                    ) {
                        model.thread.summarizeCurrentTopic()
                    }
                    .accessibilityIdentifier("thread-ai-summary-regenerate")
                }

                Button("关闭") {
                    model.thread.clearAISummary()
                }
                .accessibilityIdentifier("thread-ai-summary-close")

                Spacer()
                Text("临时结果，不会保存")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surfaceColor, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(theme.separatorColor)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("thread-ai-summary-card")
    }

    private var summaryProgressDescription: String {
        switch model.thread.aiSummaryPhase {
        case let .collecting(completedPages, totalPages):
            if completedPages == 0 {
                return "准备读取 1–\(totalPages) 页…"
            }
            return "正在读取话题页面（\(completedPages)/\(totalPages)）…"
        case .generating:
            return "页面读取完成，正在等待 AI 返回内容…"
        case nil:
            return "正在准备话题总结…"
        }
    }

    private var summaryProgressAccessibilityLabel: String {
        switch model.thread.aiSummaryPhase {
        case let .collecting(completedPages, totalPages):
            return "正在收集话题页面，已完成 \(completedPages) 页，共 \(totalPages) 页"
        case .generating:
            return "AI 正在总结话题"
        case nil:
            return "正在准备话题总结"
        }
    }

    private func coverageDescription(_ coverage: AITopicSummaryInput.Coverage) -> String {
        if coverage.requestedAllPages,
           coverage.loadedPageCount >= coverage.totalPages {
            return "全部 \(coverage.loadedPageCount) 页"
        }
        if coverage.firstPage == coverage.lastPage {
            return "第 \(coverage.firstPage)/\(coverage.totalPages) 页"
        }
        return "第 \(coverage.firstPage)–\(coverage.lastPage) 页 / 共 \(coverage.totalPages) 页"
    }
}

private struct ThreadTitleText: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSTextField {
        let textField = NSTextField(wrappingLabelWithString: text)
        configure(textField)
        return textField
    }

    func updateNSView(_ textField: NSTextField, context: Context) {
        textField.stringValue = text
        configure(textField)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView textField: NSTextField,
        context: Context
    ) -> CGSize? {
        guard let width = proposal.width else {
            return textField.fittingSize
        }
        textField.preferredMaxLayoutWidth = width
        let size = textField.sizeThatFits(
            NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        )
        return CGSize(width: width, height: ceil(size.height))
    }

    private func configure(_ textField: NSTextField) {
        textField.font = .systemFont(
            ofSize: NSFont.preferredFont(forTextStyle: .title2).pointSize,
            weight: .bold
        )
        textField.textColor = .labelColor
        textField.isSelectable = true
        textField.isEditable = false
        textField.isBordered = false
        textField.drawsBackground = false
        textField.maximumNumberOfLines = 0
        textField.lineBreakMode = .byWordWrapping
        textField.lineBreakStrategy = []
        textField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }
}

private struct AnimatedThreadBackButton: View {
    @Environment(\.sngaTheme) private var theme
    let previousTitle: String
    let isEnabled: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.left")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(theme.accentColor)
                .frame(width: 30, height: 30)
                .background(
                    theme.accentColor.opacity(isHovering ? 0.18 : 0.1),
                    in: Circle()
                )
                .overlay {
                    Circle()
                        .stroke(theme.accentColor.opacity(isHovering ? 0.38 : 0.2))
                }
                .offset(x: isHovering ? -1.5 : 0)
                .scaleEffect(isHovering ? 1.06 : 1)
        }
        .buttonStyle(.borderless)
        .disabled(!isEnabled)
        .help("返回：\(previousTitle)")
        .accessibilityLabel("返回上一话题")
        .accessibilityIdentifier("thread-linked-topic-back")
        .onHover { hovering in
            isHovering = hovering
        }
        .animation(
            .spring(response: 0.28, dampingFraction: 0.72),
            value: isHovering
        )
    }
}

struct PostRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.sngaTheme) private var theme
    let post: Post
    let topicRating: TopicRating?
    var isHotReply = false
    var loadOrder: Int? = nil
    var reply: () -> Void
    var openPost: @MainActor @Sendable (PostID, Int?) -> Void
    var openInternalLink: @MainActor @Sendable (NGAInternalDestination) -> Void
    var onContentReady: @MainActor () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 8) {
                if let authorUID {
                    Button {
                        openAuthorProfile(uid: authorUID)
                    } label: {
                        Label {
                            Text("查看 \(authorDisplayName) 的用户信息")
                        } icon: {
                            authorAvatar
                        }
                        .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.plain)
                    .contentShape(.circle)
                    .help("查看用户信息")
                    .accessibilityIdentifier("post-author-avatar-\(post.id.rawValue)")
                } else {
                    authorAvatar
                        .accessibilityIdentifier("post-author-avatar-\(post.id.rawValue)")
                }
                VStack(alignment: .leading, spacing: PostAuthorHeaderLayout.rowSpacing) {
                    if let authorUID {
                        Button {
                            openAuthorProfile(uid: authorUID)
                        } label: {
                            authorNameLabel
                        }
                        .buttonStyle(.plain)
                        .help("查看用户信息")
                        .accessibilityIdentifier("post-author-name-\(post.id.rawValue)")
                    } else {
                        authorNameLabel
                            .accessibilityIdentifier("post-author-name-\(post.id.rawValue)")
                    }
                    if let date = post.postedAt {
                        Text(
                            date,
                            format: .dateTime
                                .year()
                                .month(.twoDigits)
                                .day(.twoDigits)
                                .hour(.twoDigits(amPM: .omitted))
                                .minute(.twoDigits)
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: true, vertical: false)
                        .frame(
                            height: PostAuthorHeaderLayout.rowHeight,
                            alignment: .leading
                        )
                        .accessibilityIdentifier("post-author-date-\(post.id.rawValue)")
                    } else {
                        Color.clear
                            .frame(height: PostAuthorHeaderLayout.rowHeight)
                            .accessibilityHidden(true)
                    }
                }
                .layoutPriority(2)
                if let authorInfo = post.authorInfo {
                    PostAuthorInfoView(info: authorInfo, postID: post.id)
                } else {
                    Spacer()
                }
                HStack(spacing: 8) {
                    if post.isPinnedPost {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(theme.accentColor)
                            .help("楼主置顶的回复")
                            .accessibilityLabel("置顶回复")
                            .accessibilityIdentifier("post-pinned-\(post.id.rawValue)")
                    }
                    if post.isHot {
                        // 站点在楼层右上角打的角标。它和「画在热点那一栏里」是两回事：
                        // 这一层就排在正常楼层中间，只是被标了出来。
                        Text("HOT")
                            .font(.caption2.weight(.heavy))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(theme.hotReplyColor, in: RoundedRectangle(cornerRadius: 4))
                            .foregroundStyle(.white)
                            .help("站点标记的热门回复")
                            .accessibilityLabel("热门回复")
                            .accessibilityIdentifier("post-hot-\(post.id.rawValue)")
                    }
                    Text(floorLabel)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(isHotReply ? theme.hotReplyColor : theme.secondaryForegroundColor)
                    Button("回复", systemImage: "arrowshape.turn.up.left", action: reply)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                }
                .frame(height: PostAuthorHeaderLayout.rowHeight)
            }
            if let punishment = post.punishment {
                PostPunishmentNotice(punishment: punishment) {
                    postBody
                }
                // 折叠状态下 `PostBodyView` 根本没有实例化，页面就绪要在这里汇报，
                // 否则首楼恰好被折叠时骨架屏只能等超时。
                .task(id: post.id) { onContentReady() }
            } else {
                postBody
            }
            if let poll = post.poll {
                TopicPollView(poll: poll)
            }
            if post.floor == 0, let topicRating {
                TopicRatingView(rating: topicRating, startReply: reply)
            } else if let topicRating, !post.ratingScores.isEmpty {
                PostRatingView(rating: topicRating, scores: post.ratingScores)
            }
            HStack(spacing: 12) {
                Label(postDevice.title, systemImage: deviceSystemImage)
                    .labelStyle(.iconOnly)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("发自 \(postDevice.title)")
                    .accessibilityLabel("发自 \(postDevice.title)")
                    .accessibilityIdentifier("post-device-\(post.id.rawValue)")
                if let latestEdit = post.edits.last {
                    Label(editLabel(latestEdit), systemImage: "pencil")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        // 改动不止一次时，网页版会把每一条并排列出；这里只显示最近
                        // 的一条，其余留给悬停。
                        .help(post.edits.map(editLabel).joined(separator: "\n"))
                        .accessibilityIdentifier("post-edited-\(post.id.rawValue)")
                }
                Spacer()
                if !post.reactions.isEmpty {
                    // 站点自己有几种表态就画几个，各带各的数。这一排已经把这层楼的
                    // 全部表态说完了，下面那两个赞踩按钮再画就是重复。
                    PostReactionBar(post: post)
                } else if model.session.supports(.postVote) {
                    voteButton(direction: .up)
                    // 反方向单独问一次。有的站点只有一个方向（V2EX 只能感谢），
                    // 有的站点的反对要花掉用户的钱（NodeSeek 的「反对」扣 2 个鸡腿
                    // 且撤不回来）—— 那种按钮不该画出来等人点了再报错。
                    if model.session.supports(.postDownvote) {
                        voteButton(direction: .down)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(
                    isHotReply
                        ? theme.hotReplyColor.opacity(0.55)
                        : theme.separatorColor
                )
        }
        .task(id: authorUID) {
            guard post.authorInfo?.location == nil, let authorUID else { return }
            await model.thread.loadPostAuthorLocation(uid: authorUID)
        }
    }

    /// 「2026/08/11 12:38 修改」，被人代改时补上改动者，与网页版的措辞一致。
    private func editLabel(_ edit: PostEdit) -> String {
        let time = edit.editedAt.formatted(
            .dateTime
                .year()
                .month(.twoDigits)
                .day(.twoDigits)
                .hour(.twoDigits(amPM: .omitted))
                .minute(.twoDigits)
        )
        guard let editorName = edit.editorName, !editorName.isEmpty else {
            return "\(time) 修改"
        }
        return "\(editorName) 于 \(time) 修改"
    }

    private var postBody: some View {
        PostBodyView(
            html: post.html,
            nativeContent: post.nativeContent,
            cacheKey: contentCacheKey,
            loadOrder: loadOrder,
            onOpenInternalLink: { destination in
                switch destination {
                case let .post(postID, page):
                    openPost(postID, page)
                default:
                    openInternalLink(destination)
                }
            },
            onContentReady: onContentReady
        )
    }

    /// 热点回复区有自己的内边距，同一楼层在两处的排版宽度并不相同，
    /// 因而测得的高度也不同 —— 两者不能共用一份缓存。
    private var contentCacheKey: String {
        let section = isHotReply ? "hot" : "post"
        return "thread-\(post.topicID.rawValue)-\(section)-\(post.id.rawValue)"
    }

    private var authorUID: Int64? {
        guard let authorUID = post.authorUID, authorUID > 0 else { return nil }
        return authorUID
    }

    private var authorDisplayName: String {
        post.author.isEmpty ? "未知用户" : post.author
    }

    private var authorNameLabel: some View {
        HStack(spacing: 4) {
            Text(authorDisplayName)
                .fontWeight(.semibold)
                .fixedSize(horizontal: true, vertical: false)
            if post.isAnonymous {
                AnonymousBadge()
                    .accessibilityIdentifier("post-author-anonymous-\(post.id.rawValue)")
            }
        }
        .frame(height: PostAuthorHeaderLayout.rowHeight, alignment: .leading)
    }

    private var authorAvatar: some View {
        AsyncImage(url: post.avatarURL) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Image(systemName: "person.crop.circle.fill")
                .resizable()
                .scaledToFit()
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .padding(2)
        }
        .frame(
            width: PostAuthorHeaderLayout.avatarSize,
            height: PostAuthorHeaderLayout.avatarSize
        )
        .clipShape(.circle)
    }

    private func openAuthorProfile(uid: Int64) {
        Task {
            await model.openUserCenter(
                uid: uid,
                fallbackName: post.author,
                fallbackAvatarURL: post.avatarURL,
                preservingForumContext: true
            )
        }
    }

    private var floorLabel: String {
        if post.floor == 0 { return "楼主" }
        return isHotReply ? "热点 · #\(post.floor)" : "#\(post.floor)"
    }

    private var rowBackground: Color {
        isHotReply
            ? theme.hotReplyColor.opacity(0.11)
            : theme.surfaceColor
    }

    private var postDevice: PostDevice {
        post.device ?? .desktop
    }

    private var deviceSystemImage: String {
        switch postDevice {
        case .apple: "apple.logo"
        case .android: "rectangle.portrait"
        case .desktop: "desktopcomputer"
        }
    }

    private func voteButton(direction: PostVoteDirection) -> some View {
        let isSelected = post.userVote == direction
        let count = direction == .up ? post.upvoteCount : post.downvoteCount
        let systemImage: String
        switch (direction, isSelected) {
        case (.up, true): systemImage = "hand.thumbsup.fill"
        case (.up, false): systemImage = "hand.thumbsup"
        case (.down, true): systemImage = "hand.thumbsdown.fill"
        case (.down, false): systemImage = "hand.thumbsdown"
        }
        return Button {
            Task { await model.thread.vote(on: post.id, direction: direction) }
        } label: {
            Label("\(count)", systemImage: systemImage)
                .font(.caption.monospacedDigit())
                .foregroundStyle(isSelected ? theme.accentColor : Color.secondary)
        }
        .buttonStyle(.borderless)
        .disabled(model.thread.votingPostIDs.contains(post.id))
        .help(direction == .up ? "点赞" : "点踩")
        .accessibilityIdentifier("post-vote-\(direction.rawValue)-\(post.id.rawValue)")
    }
}

private enum PostAuthorHeaderLayout {
    static let rowHeight: CGFloat = 20
    static let rowSpacing: CGFloat = 3
    static let avatarSize = rowHeight * 2 + rowSpacing
}

private struct PostAuthorInfoView: View {
    let info: PostAuthorInfo
    let postID: PostID

    var body: some View {
        VStack(alignment: .leading, spacing: PostAuthorHeaderLayout.rowSpacing) {
            ScrollView(.horizontal) {
                HStack(spacing: 20) {
                    if let levelTitle = info.levelTitle {
                        detail("级别", value: levelTitle, identifier: "level")
                    }
                    if let reputation = reputationText {
                        detail("声望", value: reputation, identifier: "reputation")
                    }
                    if let registeredAt = info.registeredAt {
                        detail(
                            "注册",
                            value: registeredAt.formatted(
                                .dateTime.year().month(.twoDigits).day(.twoDigits)
                            ),
                            identifier: "registered"
                        )
                    }
                    if let prestige = info.prestige {
                        detail(
                            "威望",
                            value: prestige.formatted(
                                .number.precision(.fractionLength(0...1))
                            ),
                            identifier: "prestige"
                        )
                    }
                    if let userGroup = info.userGroup {
                        detail("用户组", value: userGroup, identifier: "group")
                    }
                }
                .frame(height: PostAuthorHeaderLayout.rowHeight)
            }
            .scrollIndicators(.hidden)
            .frame(height: PostAuthorHeaderLayout.rowHeight)
            HStack(alignment: .center, spacing: 20) {
                if let location = info.location {
                    detail("IP 属地", value: location, identifier: "location")
                        .fixedSize(horizontal: true, vertical: false)
                }
                if !info.medals.isEmpty {
                    HStack(alignment: .center, spacing: 6) {
                        Text("徽章:")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("post-author-medals-\(postID.rawValue)")
                        ScrollView(.horizontal) {
                            LazyHStack(spacing: 5) {
                                ForEach(info.medals) { medal in
                                    medalImage(medal)
                                }
                            }
                        }
                        .scrollIndicators(.hidden)
                        .frame(height: PostAuthorHeaderLayout.rowHeight)
                    }
                }
                if info.location == nil, info.medals.isEmpty {
                    Color.clear
                        .accessibilityHidden(true)
                }
            }
            .frame(height: PostAuthorHeaderLayout.rowHeight)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var reputationText: String? {
        guard let reputation = info.reputation else { return nil }
        if let level = info.reputationLevel {
            return "\(reputation) (lv\(level))"
        }
        return String(reputation)
    }

    private func detail(_ title: String, value: String, identifier: String) -> some View {
        HStack(spacing: 4) {
            Text("\(title):")
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
            Text(value)
                .textSelection(.enabled)
        }
        .font(.caption)
        .lineLimit(1)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("post-author-\(identifier)-\(postID.rawValue)")
    }

    private func medalImage(_ medal: UserMedal) -> some View {
        AsyncImage(url: medal.imageURL) { image in
            image
                .resizable()
                .interpolation(.none)
                .scaledToFit()
        } placeholder: {
            Image(systemName: "seal")
                .foregroundStyle(.secondary)
        }
        .frame(width: 18, height: 18)
        .help(medal.detail.map { "\(medal.name)：\($0)" } ?? medal.name)
        .accessibilityLabel(medal.name)
    }
}

struct HotRepliesSection: View {
    @Environment(\.sngaTheme) private var theme
    let posts: [Post]
    let topicRating: TopicRating?
    var loadOrderOffset = 0
    var reply: (Post) -> Void
    var openPost: @MainActor @Sendable (PostID, Int?) -> Void
    var openInternalLink: @MainActor @Sendable (NGAInternalDestination) -> Void
    var onContentReady: @MainActor (Post) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("热点回复", systemImage: "flame.fill")
                .font(.headline)
                .foregroundStyle(theme.accentColor)
                .padding(.horizontal, 2)

            ForEach(posts.indices, id: \.self) { index in
                let post = posts[index]
                PostRow(
                    post: post,
                    topicRating: topicRating,
                    isHotReply: true,
                    loadOrder: loadOrderOffset + index,
                    reply: { reply(post) },
                    openPost: openPost,
                    openInternalLink: openInternalLink,
                    onContentReady: { onContentReady(post) }
                )
            }
        }
        .padding(10)
        .background(
            theme.accentColor.opacity(0.045),
            in: RoundedRectangle(cornerRadius: 12)
        )
    }
}

struct ReplyComposerView: View {
    @Environment(\.forumSiteDescriptor) private var siteDescriptor
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.sngaTheme) private var theme
    let topic: Topic
    let replyTo: Post?
    @State private var content = ""
    @State private var ratingSelections: [TopicRatingSelection]
    @State private var editorMode = ReplyEditorMode.visual
    @State private var editorCommand: UBBEditorCommand?
    @State private var showsEmoticons = false
    @State private var showsLinkEditor = false
    @State private var showsImageEditor = false
    @State private var loadedDraft = false

    /// 引用某一层时预填的开头。
    ///
    /// 两种标记语言的引用完全不是一回事，所以按站点分：UBB 站点写 `[quote]` 标签，
    /// 由站点自己渲染；Markdown 站点没有服务端的引用机制，引用就是正文里的一段引用块，
    /// 得把被引的话真的抄进去。
    private func quotedPrefix(_ replyTo: Post) -> String {
        switch siteDescriptor.replyMarkup {
        case .ubb:
            return "[quote]\(replyTo.author) 于 #\(replyTo.floor) 的内容[/quote]\n"
        case .markdown:
            let quoted = replyTo.html
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: "\n")
                .prefix(6)
                .map { "> \($0.trimmingCharacters(in: .whitespaces))" }
                .joined(separator: "\n")
            let head = "> **\(replyTo.author)** 在 #\(replyTo.floor) 楼说："
            return ([head] + (quoted.isEmpty ? [] : [quoted]) + ["", ""])
                .joined(separator: "\n")
        }
    }
    @State private var submitted = false

    init(topic: Topic, replyTo: Post?) {
        self.topic = topic
        self.replyTo = replyTo
        _ratingSelections = State(initialValue: topic.rating?.dimensions.map {
            TopicRatingSelection(id: $0.id, score: nil)
        } ?? [])
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading) {
                    Text(replyTo.map { "回复 #\($0.floor) · \($0.author)" } ?? "回复话题")
                        .font(.headline)
                    Text(topic.subject).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.thread.isSubmitting)
                Button {
                    model.session.clearError()
                    Task {
                        if await model.thread.submitReply(
                            topicID: topic.id,
                            content: content,
                            replyTo: replyTo?.id,
                            ratingScores: selectedRatingScores
                        ) {
                            submitted = true
                            dismiss()
                        }
                    }
                } label: {
                    if model.thread.isSubmitting {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("发送中")
                        }
                    } else {
                        Text(selectedRatingScores.isEmpty ? "发送" : "发送并评分")
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.thread.isSubmitting)
            }
            .padding()
            Divider()
            HStack(spacing: 10) {
                ScrollView(.horizontal) {
                    HStack(spacing: 5) {
                        editorToolbar
                            .disabled(editorMode == .preview)
                    }
                }
                .scrollIndicators(.hidden)

                Picker("编辑模式", selection: $editorMode) {
                    ForEach(ReplyEditorMode.modes(for: siteDescriptor.replyMarkup)) { mode in
                        Text(mode.title(for: siteDescriptor.replyMarkup)).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 210)
            }
            .padding(8)
            Divider()

            if let rating = topic.rating,
               rating.isAcceptingResponses(at: .now) {
                TopicRatingEditorView(
                    rating: rating,
                    selections: $ratingSelections
                )
                .padding(10)
                Divider()
            }

            switch editorMode {
            case .visual:
                UBBRichEditor(content: $content, command: editorCommand, theme: theme)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .source:
                TextEditor(text: $content)
                    .font(.body.monospaced())
                    .padding(8)
            case .preview:
                ScrollView {
                    PostBodyView(html: siteDescriptor.sanitizedPreviewHTML(content))
                        .padding()
                }
            }

            Divider()
            HStack {
                Label("实际提交为 NGA UBB", systemImage: "checkmark.shield")
                Spacer()
                Text("\(content.count) 个字符")
                    .monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
        }
        .frame(minWidth: 760, minHeight: 560)
        .interactiveDismissDisabled(model.thread.isSubmitting)
        .alert("回复发送失败", isPresented: Binding(
            get: { model.session.errorMessage != nil },
            set: { if !$0 { model.session.clearError() } }
        )) {
            Button("好", role: .cancel) { model.session.clearError() }
        } message: {
            Text(model.session.errorMessage ?? "")
        }
        .task {
            guard !loadedDraft else { return }
            loadedDraft = true
            // 初值只能写死成可视化 —— 属性初始化时读不到环境里的站点资料。
            // 站点没有这一档的话在这里落到源码，别让选择器停在一个不存在的选项上。
            if !ReplyEditorMode.modes(for: siteDescriptor.replyMarkup).contains(editorMode) {
                editorMode = .source
            }
            if let draft = model.thread.draft(topicID: topic.id) {
                content = draft.content
            } else if let replyTo {
                content = quotedPrefix(replyTo)
            }
        }
        .onChange(of: content) { _, newValue in
            model.thread.saveDraft(topicID: topic.id, content: newValue, replyTo: replyTo?.id)
        }
        .onDisappear {
            if !submitted { model.thread.saveDraft(topicID: topic.id, content: content, replyTo: replyTo?.id) }
        }
    }

    private var selectedRatingScores: [String: Int] {
        Dictionary(
            uniqueKeysWithValues: ratingSelections.compactMap { selection in
                selection.score.map { (selection.id, $0) }
            }
        )
    }

    @ViewBuilder
    private var editorToolbar: some View {
        editorButton("撤销", systemImage: "arrow.uturn.backward", action: .undo)
        editorButton("重做", systemImage: "arrow.uturn.forward", action: .redo)
        toolbarDivider
        editorButton("粗体", title: "B", action: .bold)
            .fontWeight(.bold)
        editorButton("斜体", title: "I", action: .italic)
            .italic()
        if isUBB {
            // Markdown 没有下划线。
            editorButton("下划线", title: "U", action: .underline)
                .underline()
        }
        editorButton("删除线", title: "S", action: .strike)
            .strikethrough()

        if isUBB {
        Menu {
            Button("100%") { apply(.fontSize("100%")) }
            Button("110%") { apply(.fontSize("110%")) }
            Button("120%") { apply(.fontSize("120%")) }
            Button("130%") { apply(.fontSize("130%")) }
            Button("140%") { apply(.fontSize("140%")) }
            Button("150%") { apply(.fontSize("150%")) }
        } label: {
            Label("字号", systemImage: "textformat.size")
        }
        .labelStyle(.iconOnly)
        .help("字号")

        Menu {
            Button("默认") { apply(.removeFormat) }
            colorButton("红色", value: "red")
            colorButton("橙色", value: "orange")
            colorButton("绿色", value: "green")
            colorButton("蓝色", value: "royalblue")
            colorButton("紫色", value: "purple")
            colorButton("灰色", value: "gray")
        } label: {
            Label("文字颜色", systemImage: "paintpalette")
        }
        .labelStyle(.iconOnly)
        .help("文字颜色")
        }   // 字号和颜色都只有 UBB 有

        toolbarDivider
        editorButton("引用", systemImage: "text.quote", action: .quote)
        editorButton("代码", systemImage: "chevron.left.forwardslash.chevron.right", action: .code)
        if isUBB {
            editorButton("折叠内容", systemImage: "rectangle.compress.vertical", action: .collapse(title: ""))
        }

        Button {
            showsLinkEditor = true
        } label: {
            Label("插入链接", systemImage: "link")
        }
        .labelStyle(.iconOnly)
        .help("插入链接")
        .popover(isPresented: $showsLinkEditor, arrowEdge: .bottom) {
            UBBResourcePopover(
                title: "插入链接",
                prompt: "https://example.com",
                buttonTitle: "插入"
            ) { value in
                apply(.link(url: value))
                showsLinkEditor = false
            }
        }

        Button {
            showsImageEditor = true
        } label: {
            Label("插入图片", systemImage: "photo")
        }
        .labelStyle(.iconOnly)
        .help("插入网络图片")
        .popover(isPresented: $showsImageEditor, arrowEdge: .bottom) {
            UBBResourcePopover(
                title: "插入网络图片",
                prompt: "https://example.com/image.png",
                buttonTitle: "插入图片"
            ) { value in
                apply(.image(url: value))
                showsImageEditor = false
            }
        }

        if siteDescriptor.replyMarkup == .ubb {
            Button {
                showsEmoticons = true
            } label: {
                Label("选择表情", systemImage: "face.smiling")
            }
            .labelStyle(.iconOnly)
            .help("选择表情")
            .popover(isPresented: $showsEmoticons, arrowEdge: .bottom) {
                NGAEmoticonPicker { emoticon in
                    apply(.insertUBB(emoticon.code))
                    showsEmoticons = false
                }
            }
        }

        if isUBB {
            Menu {
                Button("左对齐", systemImage: "text.alignleft") { apply(.align("left")) }
                Button("居中", systemImage: "text.aligncenter") { apply(.align("center")) }
                Button("右对齐", systemImage: "text.alignright") { apply(.align("right")) }
            } label: {
                Label("对齐", systemImage: "text.alignleft")
            }
            .labelStyle(.iconOnly)
            .help("段落对齐")

            // 清除格式靠可视化编辑器实现，源码模式下没有对应操作。
            editorButton("清除格式", systemImage: "eraser", action: .removeFormat)
        }
    }

    /// 工具条上有几样是 UBB 独有的：字号、颜色、对齐、下划线、折叠。
    /// Markdown 写不出来，摆着只会插进去一段发出去不生效的东西。
    private var isUBB: Bool { siteDescriptor.replyMarkup == .ubb }

    private var toolbarDivider: some View {
        Divider()
            .frame(height: 18)
            .padding(.horizontal, 2)
    }

    private func editorButton(
        _ help: String,
        systemImage: String,
        action: UBBEditorAction
    ) -> some View {
        Button(help, systemImage: systemImage) {
            apply(action)
        }
        .labelStyle(.iconOnly)
        .help(help)
    }

    private func editorButton(
        _ help: String,
        title: String,
        action: UBBEditorAction
    ) -> some View {
        Button(title) {
            apply(action)
        }
        .help(help)
    }

    private func colorButton(_ title: String, value: String) -> some View {
        Button(title) {
            apply(.color(value))
        }
    }

    private func apply(_ action: UBBEditorAction) {
        guard editorMode != .preview else { return }
        if editorMode == .visual {
            editorCommand = UBBEditorCommand(action: action)
        } else {
            content.append(sourceInsertion(for: action))
        }
    }

    private func sourceInsertion(for action: UBBEditorAction) -> String {
        switch siteDescriptor.replyMarkup {
        case .ubb: ubbInsertion(for: action)
        case .markdown: markdownInsertion(for: action)
        }
    }

    /// Markdown 里没有对应写法的几样（颜色、字号、对齐、下划线）返回空串。
    ///
    /// 它们的按钮已经按标记语言藏起来了，这里再兜一道：真按到了也只是什么都不插，
    /// 而不是把 `[color=red]` 塞进一篇 Markdown。
    private func markdownInsertion(for action: UBBEditorAction) -> String {
        switch action {
        case .undo, .redo, .removeFormat, .underline,
             .color, .fontSize, .align, .collapse, .insertUBB:
            return ""
        case .bold:
            return "****"
        case .italic:
            return "**"
        case .strike:
            return "~~~~"
        case .quote:
            return "\n> "
        case .code:
            return "\n```\n\n```\n"
        case let .link(url):
            return "[\(url)](\(url))"
        case let .image(url):
            return "![](\(url))"
        }
    }

    private func ubbInsertion(for action: UBBEditorAction) -> String {
        switch action {
        case .undo, .redo, .removeFormat:
            return ""
        case .bold:
            return "[b][/b]"
        case .italic:
            return "[i][/i]"
        case .underline:
            return "[u][/u]"
        case .strike:
            return "[s][/s]"
        case .quote:
            return "[quote][/quote]"
        case .code:
            return "[code][/code]"
        case let .collapse(title):
            return title.isEmpty ? "[collapse][/collapse]" : "[collapse=\(title)][/collapse]"
        case let .link(url):
            return "[url=\(url)]\(url)[/url]"
        case let .image(url):
            return "[img]\(url)[/img]"
        case let .color(value):
            return "[color=\(value)][/color]"
        case let .fontSize(value):
            return "[size=\(value)][/size]"
        case let .align(value):
            return "[align=\(value)][/align]"
        case let .insertUBB(value):
            return value
        }
    }
}

private enum ReplyEditorMode: Hashable, Identifiable {
    case visual
    case source
    case preview

    var id: Self { self }

    /// 源码那一档叫什么，取决于写的是哪种标记 —— 在 Markdown 站点上标着「UBB」
    /// 是在教人写错。
    func title(for markup: ReplyMarkup) -> String {
        switch self {
        case .visual: "可视化"
        case .source: markup == .ubb ? "UBB" : "Markdown"
        case .preview: "预览"
        }
    }

    /// 可视化编辑器是围着 UBB 建的：它在 `WKWebView` 里把 UBB 和 HTML 来回转。
    /// Markdown 交给它，源码会被当成 UBB 啃一遍。所以 Markdown 站点只有源码和预览
    /// 两档 —— 少一个档，好过多一个会把正文改坏的档。
    static func modes(for markup: ReplyMarkup) -> [ReplyEditorMode] {
        switch markup {
        case .ubb: [.visual, .source, .preview]
        case .markdown: [.source, .preview]
        }
    }
}

private struct UBBResourcePopover: View {
    let title: String
    let prompt: String
    let buttonTitle: String
    let insert: (String) -> Void

    @State private var value = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
            TextField(prompt, text: $value)
                .textFieldStyle(.roundedBorder)
                .frame(width: 360)
                .onSubmit(performInsert)
            if !value.isEmpty, !isValidURL {
                Text("请输入以 http:// 或 https:// 开头的完整地址")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button(buttonTitle, action: performInsert)
                    .buttonStyle(.borderedProminent)
                    .disabled(!isValidURL)
            }
        }
        .padding(14)
    }

    private var trimmedValue: String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isValidURL: Bool {
        guard let components = URLComponents(string: trimmedValue),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host?.isEmpty == false else {
            return false
        }
        return true
    }

    private func performInsert() {
        guard isValidURL else { return }
        insert(trimmedValue)
    }
}

/// 楼层右下角那一排表态。
///
/// 不折叠成菜单：网页版把每一种的数目并排摆着，读者扫一眼就知道这层楼被怎么看待。
/// 收进菜单就得点开才知道，而那几个数本身就是信息。
///
/// 但**要花钱的那几种仍然先问一次**。价钱写在按钮的提示里，点下去还要再确认 ——
/// NodeSeek 的加鸡腿花 1 个鸡腿、反对花 2 个，而且都撤不回来。
private struct PostReactionBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.sngaTheme) private var theme
    let post: Post

    @State private var pending: PostReaction?

    var body: some View {
        HStack(spacing: 10) {
            ForEach(post.reactions) { reaction in
                Button {
                    if reaction.cost == nil {
                        submit(reaction)
                    } else {
                        pending = reaction
                    }
                } label: {
                    countLabel(
                        systemImage: reaction.systemImage,
                        count: reaction.count,
                        isChosen: reaction.isChosen
                    )
                }
                .buttonStyle(.borderless)
                .help(helpText(for: reaction))
                // 撤不回来的表态点过就不给再点 —— 再点一次只是再花一次。
                .disabled(
                    model.thread.votingPostIDs.contains(post.id)
                        || (reaction.isChosen && reaction.isIrreversible)
                )
                .accessibilityLabel("\(reaction.title) \(reaction.count ?? 0)")
                .accessibilityIdentifier("post-reaction-\(reaction.id)-\(post.id.rawValue)")
            }

            // 收藏是话题级的，只在主楼显示 —— 网页版也是这么摆的。
            if let collections = post.topicCollectionCount {
                Label("\(collections)", systemImage: post.isTopicCollected ? "star.fill" : "star")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(post.isTopicCollected ? theme.accentColor : Color.secondary)
                    .help("收藏 \(collections)")
                    .accessibilityLabel("收藏 \(collections)")
                    .accessibilityIdentifier("post-collections-\(post.id.rawValue)")
            }
        }
        .confirmationDialog(
            pending.map { $0.cost.map { cost in "将\(cost)" } ?? "确认？" } ?? "",
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            titleVisibility: .visible,
            presenting: pending
        ) { reaction in
            Button(reaction.title, role: reaction.id == "dislike" ? .destructive : nil) {
                submit(reaction)
                pending = nil
            }
            Button("取消", role: .cancel) { pending = nil }
        } message: { reaction in
            Text(reaction.isIrreversible ? "这个操作无法撤销。" : "确认要\(reaction.title)吗？")
        }
    }

    private func countLabel(systemImage: String, count: Int?, isChosen: Bool) -> some View {
        Label("\(count ?? 0)", systemImage: systemImage)
            .font(.caption.monospacedDigit())
            .foregroundStyle(isChosen ? theme.accentColor : Color.secondary)
    }

    private func helpText(for reaction: PostReaction) -> String {
        if reaction.isChosen { return "已\(reaction.title)" }
        return [reaction.title, reaction.cost].compactMap { $0 }.joined(separator: " · ")
    }

    /// 免费的点赞走 vote 那条路 —— 适配器只让它从那儿过。
    private func submit(_ reaction: PostReaction) {
        Task {
            if reaction.cost == nil {
                await model.thread.vote(on: post.id, direction: .up)
            } else {
                await model.thread.submitReaction(on: post, reactionID: reaction.id)
            }
        }
    }
}
