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
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
            if let topic = model.currentTopic {
                ReplyComposerView(topic: topic, replyTo: post)
                    .environment(model)
            }
        }
        .sheet(isPresented: $writesNewReply) {
            if let topic = model.currentTopic {
                ReplyComposerView(topic: topic, replyTo: nil)
                    .environment(model)
            }
        }
        .task {
            await model.loadFavoriteTopicFolders()
        }
        .alert("帖子已锁定", isPresented: $showsLockedTopicAlert) {
            Button("好", role: .cancel) {}
        } message: {
            Text("该话题已锁定，无法回复。")
        }
        .ignoresSafeArea(.container, edges: .top)
    }

    private var currentPresentation: ThreadPresentation? {
        guard let topic = model.currentTopic else { return nil }
        return ThreadPresentation(
            topic: topic,
            posts: model.posts,
            hotReplies: model.hotReplies,
            page: model.threadPage,
            totalPages: model.threadTotalPages,
            previousTitle: model.previousThreadTitle
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
                    navigateBack: navigateBack
                )

                ScrollView {
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
                    .padding()
                    .animation(
                        reduceMotion ? nil : .easeOut(duration: 0.18),
                        value: showsSkeleton
                    )
                }
                .accessibilityIdentifier("thread-content-scroll")
                .scrollDisabled(showsSkeleton)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    ThreadPaginationBar(
                        currentPage: presentation.page,
                        totalPages: presentation.totalPages,
                        isLoading: isThreadLoading,
                        showsLoadingIndicator: !showsThreadContentSkeleton,
                        navigate: { page in
                            guard let topicID = model.selectedTopicID else { return }
                            Task {
                                await model.loadThreadPage(topicID: topicID, page: page)
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
                        .disabled(model.currentTopic == nil)
                        .accessibilityIdentifier("thread-scroll-to-top")

                        Button {
                            showsTopicLinkActions = true
                        } label: {
                            Label("分享话题", systemImage: "square.and.arrow.up")
                        }
                        .labelStyle(.iconOnly)
                        .help("复制话题链接或在浏览器中打开")
                        .disabled(model.selectedTopicID == nil)
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

                        Menu {
                            if let topic = model.currentTopic {
                                if model.favoriteTopicFolders.isEmpty {
                                    Text("正在加载收藏目录…")
                                } else {
                                    ForEach(model.sortedFavoriteTopicFolders) { folder in
                                        Toggle(
                                            isOn: Binding(
                                                get: {
                                                    model.isTopicFavorite(topic, in: folder)
                                                },
                                                set: { isFavorite in
                                                    Task {
                                                        await model.setTopicFavorite(
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
                                        .disabled(model.updatingFavoriteTopicIDs.contains(topic.id))
                                    }
                                    Divider()
                                    if model.isCurrentTopicFavorite {
                                        Button(role: .destructive) {
                                            Task {
                                                await model.cancelTopicFavorite(topic)
                                            }
                                        } label: {
                                            Label("取消收藏", systemImage: "star.slash")
                                        }
                                        .disabled(model.updatingFavoriteTopicIDs.contains(topic.id))
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
                        .disabled(model.currentTopic == nil)
                        .accessibilityIdentifier("thread-topic-favorite")

                        Button {
                            Task {
                                await model.toggleOnlyTopicAuthor()
                                await Task.yield()
                                scrollToThreadTop(proxy: proxy)
                            }
                        } label: {
                            Label(
                                model.isShowingOnlyTopicAuthor ? "查看全部回复" : "只看作者",
                                systemImage: model.isShowingOnlyTopicAuthor
                                    ? "person.crop.circle.fill"
                                    : "person.crop.circle"
                            )
                        }
                        .labelStyle(.iconOnly)
                        .help(
                            model.isShowingOnlyTopicAuthor
                                ? "显示话题中的全部回复"
                                : "只显示话题作者的回复"
                        )
                        .disabled(model.currentTopicAuthorUID == nil || isThreadLoading)
                        .accessibilityValue(model.isShowingOnlyTopicAuthor ? "已开启" : "已关闭")
                        .accessibilityIdentifier("thread-only-author")

                        Button {
                            Task { await model.refreshThreadContent() }
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
                        .disabled(model.selectedTopicID == nil)
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
        guard model.currentTopic?.isLocked != true else {
            showsLockedTopicAlert = true
            return
        }
        writesNewReply = true
    }

    private func startReply(to post: Post) {
        guard model.currentTopic?.isLocked != true else {
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
        return model.isLoadingThreadContent
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
        guard model.canReturnToPreviousThread, !isLinkedThreadTransitioning else { return }
        navigationDirection = .backward
        pendingLinkedPostID = nil
        var didReturn = false
        withAnimation(threadNavigationAnimation) {
            isLinkedThreadTransitioning = true
            didReturn = model.returnToPreviousThread()
        } completion: {
            finishLinkedThreadTransition()
        }
        if !didReturn {
            finishLinkedThreadTransition()
        }
    }

    private func scrollToPendingLinkedPost(proxy: ScrollViewProxy) {
        guard let postID = pendingLinkedPostID,
              model.posts.contains(where: { $0.id == postID }) else {
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
            if !model.posts.contains(where: { $0.id == postID }),
               let page {
                await model.loadThreadPage(topicID: topicID, page: page)
            }
            await Task.yield()
            if model.posts.contains(where: { $0.id == postID }) {
                withAnimation(motionAnimation(.easeInOut(duration: 0.25))) {
                    proxy.scrollTo(postID, anchor: .top)
                }
            } else {
                model.statusMessage = "未能在当前帖子页找到引用楼层"
                model.statusMessageIsError = true
            }
        }
    }

    private func openInternalLink(
        _ destination: NGAInternalDestination,
        proxy: ScrollViewProxy
    ) {
        switch destination {
        case let .post(postID, page):
            guard let topicID = model.selectedTopicID else { return }
            revealPost(postID, page: page, topicID: topicID, proxy: proxy)

        case let .topic(topicID, page, postID):
            guard !isLinkedThreadTransitioning else { return }
            if model.selectedTopicID == topicID {
                if let postID {
                    revealPost(postID, page: page, topicID: topicID, proxy: proxy)
                } else if let page, page != model.threadPage {
                    Task { @MainActor in
                        await model.loadThreadPage(topicID: topicID, page: page)
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
                guard let destination = await model.prepareLinkedTopicPage(
                    topicID: topicID,
                    page: targetPage
                ) else {
                    pendingLinkedPostID = nil
                    finishLinkedThreadTransition()
                    return
                }
                var didBegin = false
                withAnimation(threadNavigationAnimation) {
                    didBegin = model.beginLinkedTopicNavigation(to: destination)
                } completion: {
                    finishLinkedThreadTransition()
                }
                guard didBegin else {
                    pendingLinkedPostID = nil
                    finishLinkedThreadTransition()
                    return
                }
                guard model.selectedTopicID == topicID else { return }
                await Task.yield()
                if postID == nil {
                    scrollToThreadTop(proxy: proxy)
                } else if pendingLinkedPostID != nil,
                          !model.posts.contains(where: { $0.id == postID }) {
                    pendingLinkedPostID = nil
                    model.statusMessage = "未能在目标帖子页找到引用楼层"
                    model.statusMessageIsError = true
                }
            }

        case let .forum(forumID):
            let forum = model.subforums.first { $0.id == forumID }
                ?? model.forums.first { $0.id == forumID }
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
        model.selectedTopicID.map(NGAEndpoint.topicWebURL(topicID:))
    }

    private func copyTopicLink() {
        guard let url = topicURL else { return }
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(url.absoluteString, forType: .string) else {
            model.statusMessage = "复制话题链接失败"
            model.statusMessageIsError = true
            return
        }
        model.statusMessage = "话题链接已复制"
        model.statusMessageIsError = false
        didCopyTopicLink = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            didCopyTopicLink = false
        }
    }

    private func openTopicInBrowser() {
        guard let url = topicURL else { return }
        if NSWorkspace.shared.open(url) {
            model.statusMessage = "已在默认浏览器中打开话题"
            model.statusMessageIsError = false
            showsTopicLinkActions = false
        } else {
            model.statusMessage = "无法打开默认浏览器"
            model.statusMessageIsError = true
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

    var body: some View {
        let title = ThreadTitleText(text: normalizedTitle)
            .accessibilityLabel(normalizedTitle)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("thread-topic-title")

        Group {
            if let previousTitle {
                HStack(alignment: .top, spacing: 10) {
                    AnimatedThreadBackButton(
                        previousTitle: previousTitle,
                        isEnabled: isNavigationEnabled,
                        action: navigateBack
                    )
                    title
                        .layoutPriority(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                title
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surfaceColor, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(nsColor: .separatorColor).opacity(0.5))
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

private struct ThreadPaginationBar<Actions: View>: View {
    let currentPage: Int
    let totalPages: Int
    let isLoading: Bool
    let showsLoadingIndicator: Bool
    var navigate: (Int) -> Void
    let actions: Actions

    @State private var pageText = "1"

    init(
        currentPage: Int,
        totalPages: Int,
        isLoading: Bool,
        showsLoadingIndicator: Bool = true,
        navigate: @escaping (Int) -> Void,
        @ViewBuilder actions: () -> Actions
    ) {
        self.currentPage = currentPage
        self.totalPages = totalPages
        self.isLoading = isLoading
        self.showsLoadingIndicator = showsLoadingIndicator
        self.navigate = navigate
        self.actions = actions()
    }

    var body: some View {
        BottomActionBar {
            paginationContent
        }
            .onAppear {
                pageText = String(currentPage)
            }
            .onChange(of: currentPage) { _, newValue in
                pageText = String(newValue)
            }
            .onChange(of: totalPages) { _, newValue in
                if let value = Int(pageText), value > newValue {
                    pageText = String(newValue)
                }
            }
    }

    private var paginationContent: some View {
        HStack(spacing: 4) {
            ViewThatFits(in: .horizontal) {
                paginationControls(isCompact: false)
                paginationControls(isCompact: true)
            }

            if isLoading && showsLoadingIndicator {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("正在加载话题内容")
                    .accessibilityIdentifier("thread-loading-indicator")
            }

            Spacer(minLength: 4)

            HStack(spacing: 4) {
                actions
            }
            .fixedSize()
        }
    }

    private func paginationControls(isCompact: Bool) -> some View {
        HStack(spacing: isCompact ? 3 : 6) {
            Button("首页", systemImage: "backward.end.fill") {
                navigate(1)
            }
            .labelStyle(.iconOnly)
            .help("跳转到首页")
            .disabled(isLoading || currentPage <= 1)

            Button("上一页", systemImage: "chevron.left") {
                navigate(currentPage - 1)
            }
            .labelStyle(.iconOnly)
            .help("上一页")
            .disabled(isLoading || currentPage <= 1)

            TextField("页码", text: $pageText)
                .frame(width: isCompact ? 44 : 54)
                .multilineTextAlignment(.center)
                .textFieldStyle(.roundedBorder)
                .onSubmit(performJump)
                .accessibilityLabel("目标页码")
                .accessibilityIdentifier("thread-page-field")

            if !isCompact {
                Text("/ \(totalPages)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)

                Button("跳转", action: performJump)
                    .disabled(isLoading || parsedPage == nil || parsedPage == currentPage)
            }

            Button("下一页", systemImage: "chevron.right") {
                navigate(currentPage + 1)
            }
            .labelStyle(.iconOnly)
            .help("下一页")
            .disabled(isLoading || currentPage >= totalPages)
            .accessibilityIdentifier("thread-next-page")

            Button("尾页", systemImage: "forward.end.fill") {
                navigate(totalPages)
            }
            .labelStyle(.iconOnly)
            .help("跳转到尾页")
            .disabled(isLoading || currentPage >= totalPages)
        }
        .fixedSize()
    }

    private var parsedPage: Int? {
        guard let value = Int(pageText.trimmingCharacters(in: .whitespacesAndNewlines)),
              (1...totalPages).contains(value) else {
            return nil
        }
        return value
    }

    private func performJump() {
        guard let parsedPage, parsedPage != currentPage, !isLoading else {
            pageText = String(currentPage)
            return
        }
        navigate(parsedPage)
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
                            Text(post.author.isEmpty ? "未知用户" : post.author)
                                .fontWeight(.semibold)
                                .fixedSize(horizontal: true, vertical: false)
                                .frame(
                                    height: PostAuthorHeaderLayout.rowHeight,
                                    alignment: .leading
                                )
                        }
                        .buttonStyle(.plain)
                        .help("查看用户信息")
                        .accessibilityIdentifier("post-author-name-\(post.id.rawValue)")
                    } else {
                        Text(post.author.isEmpty ? "未知用户" : post.author)
                            .fontWeight(.semibold)
                            .fixedSize(horizontal: true, vertical: false)
                            .frame(
                                height: PostAuthorHeaderLayout.rowHeight,
                                alignment: .leading
                            )
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
                    Text(floorLabel)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(isHotReply ? theme.accentColor : Color.secondary)
                    Button("回复", systemImage: "arrowshape.turn.up.left", action: reply)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                }
                .frame(height: PostAuthorHeaderLayout.rowHeight)
            }
            if let authorInfo = post.authorInfo, authorInfo.site != nil {
                PostAuthorSupplementaryInfoView(info: authorInfo)
            }
            PostBodyView(
                html: post.html,
                cacheKey: "thread-\(post.topicID.rawValue)-post-\(post.id.rawValue)",
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
                Spacer()
                voteButton(direction: .up)
                voteButton(direction: .down)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(
                    isHotReply
                        ? theme.accentColor.opacity(0.5)
                        : Color(nsColor: .separatorColor).opacity(0.5)
                )
        }
        .task(id: authorUID) {
            guard post.authorInfo?.location == nil, let authorUID else { return }
            await model.loadPostAuthorLocation(uid: authorUID)
        }
    }

    private var authorUID: Int64? {
        guard let authorUID = post.authorUID, authorUID > 0 else { return nil }
        return authorUID
    }

    private var authorDisplayName: String {
        post.author.isEmpty ? "未知用户" : post.author
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
            ? theme.accentColor.opacity(0.11)
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
            Task { await model.vote(on: post.id, direction: direction) }
        } label: {
            Label("\(count)", systemImage: systemImage)
                .font(.caption.monospacedDigit())
                .foregroundStyle(isSelected ? theme.accentColor : Color.secondary)
        }
        .buttonStyle(.borderless)
        .disabled(model.votingPostIDs.contains(post.id))
        .help(direction == .up ? "点赞" : "点踩")
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

private struct PostAuthorSupplementaryInfoView: View {
    let info: PostAuthorInfo

    var body: some View {
        HStack(spacing: 8) {
            if let site = info.site {
                Text(site)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.leading, 40)
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
                    .disabled(model.isSubmitting)
                Button {
                    model.clearError()
                    Task {
                        if await model.submitReply(
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
                    if model.isSubmitting {
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
                .disabled(content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isSubmitting)
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
                    ForEach(ReplyEditorMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
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
                    PostBodyView(html: NGAParser().sanitizedPostHTML(content))
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
        .interactiveDismissDisabled(model.isSubmitting)
        .alert("回复发送失败", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.clearError() } }
        )) {
            Button("好", role: .cancel) { model.clearError() }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .task {
            guard !loadedDraft else { return }
            loadedDraft = true
            if let draft = model.draft(topicID: topic.id) {
                content = draft.content
            } else if let replyTo {
                content = "[quote]\(replyTo.author) 于 #\(replyTo.floor) 的内容[/quote]\n"
            }
        }
        .onChange(of: content) { _, newValue in
            model.saveDraft(topicID: topic.id, content: newValue, replyTo: replyTo?.id)
        }
        .onDisappear {
            if !submitted { model.saveDraft(topicID: topic.id, content: content, replyTo: replyTo?.id) }
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
        editorButton("下划线", title: "U", action: .underline)
            .underline()
        editorButton("删除线", title: "S", action: .strike)
            .strikethrough()

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

        toolbarDivider
        editorButton("引用", systemImage: "text.quote", action: .quote)
        editorButton("代码", systemImage: "chevron.left.forwardslash.chevron.right", action: .code)
        editorButton("折叠内容", systemImage: "rectangle.compress.vertical", action: .collapse(title: ""))

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

        Button {
            showsEmoticons = true
        } label: {
            Label("选择表情", systemImage: "face.smiling")
        }
        .labelStyle(.iconOnly)
        .help("选择 NGA 表情")
        .popover(isPresented: $showsEmoticons, arrowEdge: .bottom) {
            NGAEmoticonPicker { emoticon in
                apply(.insertUBB(emoticon.code))
                showsEmoticons = false
            }
        }

        Menu {
            Button("左对齐", systemImage: "text.alignleft") { apply(.align("left")) }
            Button("居中", systemImage: "text.aligncenter") { apply(.align("center")) }
            Button("右对齐", systemImage: "text.alignright") { apply(.align("right")) }
        } label: {
            Label("对齐", systemImage: "text.alignleft")
        }
        .labelStyle(.iconOnly)
        .help("段落对齐")

        editorButton("清除格式", systemImage: "eraser", action: .removeFormat)
    }

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

private enum ReplyEditorMode: String, CaseIterable, Identifiable {
    case visual = "可视化"
    case source = "UBB"
    case preview = "预览"

    var id: Self { self }
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
