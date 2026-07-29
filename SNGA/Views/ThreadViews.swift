import AppKit
import SwiftUI

private enum ThreadNavigationDirection {
    case forward
    case backward
}

struct ThreadView: View {
    @Environment(AppModel.self) private var model
    @State private var replyTarget: Post?
    @State private var writesNewReply = false
    @State private var showsTopicLinkActions = false
    @State private var didCopyTopicLink = false
    @State private var navigationDirection = ThreadNavigationDirection.forward
    @State private var pendingLinkedPostID: PostID?
    private let topAnchor = "thread-page-top"

    var body: some View {
        ZStack {
            threadContent
                .id(model.selectedTopicID)
                .transition(threadTransition)
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
        .ignoresSafeArea(.container, edges: .top)
    }

    private var threadContent: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // A thread page contains at most about 20 posts. Build every row
                // up front so each embedded WKWebView can load and measure before
                // the user scrolls to it; lazy creation caused visible stalls at
                // every newly reached floor.
                VStack(spacing: 12) {
                    if let topic = model.currentTopic {
                        ThreadTitleHeader(
                            topic: topic,
                            previousTitle: model.previousThreadTitle,
                            navigateBack: navigateBack
                        )
                            .id(topAnchor)
                    }
                    ForEach(model.posts) { post in
                        PostRow(
                            post: post,
                            reply: {
                                replyTarget = post
                            },
                            openPost: { postID, page in
                                revealPost(
                                    postID,
                                    page: page,
                                    topicID: post.topicID,
                                    proxy: proxy
                                )
                            },
                            openInternalLink: { destination in
                                openInternalLink(destination, proxy: proxy)
                            }
                        )
                        .id(post.id)
                        if post.floor == 0, !model.hotReplies.isEmpty {
                            HotRepliesSection(
                                posts: model.hotReplies,
                                reply: { replyTarget = $0 },
                                openPost: { postID, page in
                                    revealPost(
                                        postID,
                                        page: page,
                                        topicID: post.topicID,
                                        proxy: proxy
                                    )
                                },
                                openInternalLink: { destination in
                                    openInternalLink(destination, proxy: proxy)
                                }
                            )
                        }
                    }
                }
                .padding()
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                ThreadPaginationBar(
                    currentPage: model.threadPage,
                    totalPages: model.threadTotalPages,
                    isLoading: model.isLoading,
                    navigate: { page in
                        guard let topicID = model.selectedTopicID else { return }
                        Task {
                            await model.loadThreadPage(topicID: topicID, page: page)
                            await Task.yield()
                            withAnimation(.easeInOut(duration: 0.2)) {
                                proxy.scrollTo(topAnchor, anchor: .top)
                            }
                        }
                    }
                ) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            proxy.scrollTo(topAnchor, anchor: .top)
                        }
                    } label: {
                        Label("回到顶部", systemImage: "arrow.up.to.line")
                    }
                    .labelStyle(.iconOnly)
                    .help("回到主题内容顶部")
                    .disabled(model.currentTopic == nil)
                    .accessibilityIdentifier("thread-scroll-to-top")

                    Button {
                        showsTopicLinkActions = true
                    } label: {
                        Label("分享主题", systemImage: "square.and.arrow.up")
                    }
                    .labelStyle(.iconOnly)
                    .help("复制主题链接或在浏览器中打开")
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
                            model.isCurrentTopicFavorite ? "管理主题收藏" : "收藏主题",
                            systemImage: model.isCurrentTopicFavorite ? "star.fill" : "star"
                        )
                    }
                    .labelStyle(.iconOnly)
                    .help("选择主题收藏夹")
                    .disabled(model.currentTopic == nil)
                    .accessibilityIdentifier("thread-topic-favorite")

                    Button {
                        Task { await model.refreshThreadContent() }
                    } label: {
                        Label("刷新主题内容", systemImage: "arrow.clockwise.circle")
                    }
                    .labelStyle(.iconOnly)
                    .help("刷新当前主题内容")
                    .disabled(model.isLoading)
                    .accessibilityIdentifier("thread-refresh")

                    Button {
                        writesNewReply = true
                    } label: {
                        Label("回复主题", systemImage: "arrowshape.turn.up.left")
                    }
                    .labelStyle(.iconOnly)
                    .help("回复当前主题")
                    .disabled(model.selectedTopicID == nil)
                    .accessibilityIdentifier("thread-reply")
                }
            }
            .onAppear {
                scrollToPendingLinkedPost(proxy: proxy)
            }
            .onChange(of: model.posts.map(\.id)) {
                scrollToPendingLinkedPost(proxy: proxy)
            }
        }
    }

    private var threadTransition: AnyTransition {
        switch navigationDirection {
        case .forward:
            .asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .move(edge: .leading).combined(with: .opacity)
            )
        case .backward:
            .asymmetric(
                insertion: .move(edge: .leading).combined(with: .opacity),
                removal: .move(edge: .trailing).combined(with: .opacity)
            )
        }
    }

    private var threadNavigationAnimation: Animation {
        .spring(response: 0.38, dampingFraction: 0.86)
    }

    private func navigateBack() {
        guard model.canReturnToPreviousThread else { return }
        withAnimation(threadNavigationAnimation) {
            navigationDirection = .backward
            pendingLinkedPostID = nil
            model.returnToPreviousThread()
        }
    }

    private func scrollToPendingLinkedPost(proxy: ScrollViewProxy) {
        guard let postID = pendingLinkedPostID,
              model.posts.contains(where: { $0.id == postID }) else {
            return
        }
        Task { @MainActor in
            await Task.yield()
            withAnimation(.easeInOut(duration: 0.25)) {
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
                withAnimation(.easeInOut(duration: 0.25)) {
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
            if model.selectedTopicID == topicID {
                if let postID {
                    revealPost(postID, page: page, topicID: topicID, proxy: proxy)
                } else if let page, page != model.threadPage {
                    Task { @MainActor in
                        await model.loadThreadPage(topicID: topicID, page: page)
                        await Task.yield()
                        withAnimation(.easeInOut(duration: 0.2)) {
                            proxy.scrollTo(topAnchor, anchor: .top)
                        }
                    }
                }
                return
            }

            let targetPage = page ?? 1
            navigationDirection = .forward
            pendingLinkedPostID = postID
            let didBegin = withAnimation(threadNavigationAnimation) {
                model.beginLinkedTopicNavigation(to: topicID, page: targetPage)
            }
            guard didBegin else { return }
            Task { @MainActor in
                await model.loadThreadPage(topicID: topicID, page: targetPage)
                guard model.selectedTopicID == topicID else { return }
                await Task.yield()
                if postID == nil {
                    proxy.scrollTo(topAnchor, anchor: .top)
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

    private var topicURL: URL? {
        model.selectedTopicID.map(NGAEndpoint.topicWebURL(topicID:))
    }

    private func copyTopicLink() {
        guard let url = topicURL else { return }
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(url.absoluteString, forType: .string) else {
            model.statusMessage = "复制主题链接失败"
            model.statusMessageIsError = true
            return
        }
        model.statusMessage = "主题链接已复制"
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
            model.statusMessage = "已在默认浏览器中打开主题"
            model.statusMessageIsError = false
            showsTopicLinkActions = false
        } else {
            model.statusMessage = "无法打开默认浏览器"
            model.statusMessageIsError = true
        }
    }
}

private struct TopicLinkActionsPopover: View {
    let url: URL
    let didCopy: Bool
    let copy: () -> Void
    let openInBrowser: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("主题网页链接")
                .font(.headline)
            Text(url.absoluteString)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(2)

            HStack {
                Button(action: copy) {
                    Label(
                        didCopy ? "已复制" : "复制链接",
                        systemImage: didCopy ? "checkmark" : "doc.on.doc"
                    )
                }
                .accessibilityIdentifier("copy-topic-link")
                Button(action: openInBrowser) {
                    Label("在默认浏览器中打开", systemImage: "safari")
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("open-topic-in-browser")
            }
        }
        .padding(14)
        .frame(width: 390)
    }
}

private struct ThreadTitleHeader: View {
    let topic: Topic
    let previousTitle: String?
    let navigateBack: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if let previousTitle {
                AnimatedThreadBackButton(
                    previousTitle: previousTitle,
                    action: navigateBack
                )
                .transition(
                    .move(edge: .leading)
                        .combined(with: .opacity)
                        .combined(with: .scale(scale: 0.8))
                )
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(topic.subject)
                    .font(.title2.bold())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 14) {
                    if !topic.author.isEmpty {
                        Label(topic.author, systemImage: "person")
                    }
                    Label("\(topic.replyCount) 条回复", systemImage: "bubble.left")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(.separator.opacity(0.5))
        }
    }
}

private struct AnimatedThreadBackButton: View {
    @Environment(\.sngaTheme) private var theme
    let previousTitle: String
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
        .buttonStyle(.plain)
        .help("返回：\(previousTitle)")
        .accessibilityLabel("返回上一主题")
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
    var navigate: (Int) -> Void
    let actions: Actions

    @State private var pageText = "1"

    init(
        currentPage: Int,
        totalPages: Int,
        isLoading: Bool,
        navigate: @escaping (Int) -> Void,
        @ViewBuilder actions: () -> Actions
    ) {
        self.currentPage = currentPage
        self.totalPages = totalPages
        self.isLoading = isLoading
        self.navigate = navigate
        self.actions = actions()
    }

    var body: some View {
        paginationContent
            .buttonStyle(BottomActionBarButtonStyle())
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial)
            .overlay(alignment: .top) {
                Divider()
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

            if isLoading {
                ProgressView()
                    .controlSize(.small)
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

private struct PostRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.sngaTheme) private var theme
    let post: Post
    var isHotReply = false
    var reply: () -> Void
    var openPost: @MainActor @Sendable (PostID, Int?) -> Void
    var openInternalLink: @MainActor @Sendable (NGAInternalDestination) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                if let authorUID {
                    Button {
                        openAuthorProfile(uid: authorUID)
                    } label: {
                        authorAvatar
                    }
                    .buttonStyle(.plain)
                    .contentShape(.circle)
                    .help("查看用户信息")
                } else {
                    authorAvatar
                }
                VStack(alignment: .leading, spacing: 1) {
                    if let authorUID {
                        Button {
                            openAuthorProfile(uid: authorUID)
                        } label: {
                            Text(post.author.isEmpty ? "未知用户" : post.author)
                                .fontWeight(.semibold)
                        }
                        .buttonStyle(.plain)
                        .help("查看用户信息")
                    } else {
                        Text(post.author.isEmpty ? "未知用户" : post.author)
                            .fontWeight(.semibold)
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
                    }
                }
                Spacer()
                Text(floorLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(isHotReply ? theme.accentColor : Color.secondary)
                Button("回复", systemImage: "arrowshape.turn.up.left", action: reply)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
            }
            PostBodyView(
                html: post.html,
                cacheKey: "thread-\(post.topicID.rawValue)-post-\(post.id.rawValue)",
                onOpenInternalLink: { destination in
                    switch destination {
                    case let .post(postID, page):
                        openPost(postID, page)
                    default:
                        openInternalLink(destination)
                    }
                }
            )
            HStack(spacing: 12) {
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
    }

    private var authorUID: Int64? {
        guard let authorUID = post.authorUID, authorUID > 0 else { return nil }
        return authorUID
    }

    private var authorAvatar: some View {
        AsyncImage(url: post.avatarURL) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Image(systemName: "person.crop.circle.fill").foregroundStyle(.secondary)
        }
        .frame(width: 30, height: 30)
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

private struct HotRepliesSection: View {
    @Environment(\.sngaTheme) private var theme
    let posts: [Post]
    var reply: (Post) -> Void
    var openPost: @MainActor @Sendable (PostID, Int?) -> Void
    var openInternalLink: @MainActor @Sendable (NGAInternalDestination) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("热点回复", systemImage: "flame.fill")
                .font(.headline)
                .foregroundStyle(theme.accentColor)
                .padding(.horizontal, 2)

            ForEach(posts) { post in
                PostRow(
                    post: post,
                    isHotReply: true,
                    reply: { reply(post) },
                    openPost: openPost,
                    openInternalLink: openInternalLink
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
    @State private var editorMode = ReplyEditorMode.visual
    @State private var editorCommand: UBBEditorCommand?
    @State private var showsEmoticons = false
    @State private var showsLinkEditor = false
    @State private var showsImageEditor = false
    @State private var loadedDraft = false
    @State private var submitted = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading) {
                    Text(replyTo.map { "回复 #\($0.floor) · \($0.author)" } ?? "回复主题")
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
                        if await model.submitReply(topicID: topic.id, content: content, replyTo: replyTo?.id) {
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
                        Text("发送")
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
        Button {
            apply(action)
        } label: {
            Image(systemName: systemImage)
        }
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
