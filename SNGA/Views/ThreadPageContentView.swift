import SwiftUI

struct ThreadPageContentView: View {
    struct Identity: Hashable {
        // 该标识会作为 `.id()` 参与 SwiftUI 的每次更新，因此只保留定长字段。
        // 早前这里存了每楼的完整 HTML，导致每个更新周期都要哈希数百 KB 文本。
        private struct ContentFingerprint: Hashable {
            let postID: PostID
            let htmlByteCount: Int

            init(_ post: Post) {
                postID = post.id
                htmlByteCount = post.html.utf8.count
            }
        }

        let topicID: TopicID
        let page: Int
        private let posts: [ContentFingerprint]
        private let hotReplies: [ContentFingerprint]

        init(topicID: TopicID, page: Int, posts: [Post], hotReplies: [Post]) {
            self.topicID = topicID
            self.page = page
            self.posts = posts.map(ContentFingerprint.init)
            self.hotReplies = hotReplies.map(ContentFingerprint.init)
        }
    }

    let identity: Identity
    let topAnchor: String
    let posts: [Post]
    let hotReplies: [Post]
    let topicRating: TopicRating?
    var reply: (Post) -> Void
    var openPost: @MainActor @Sendable (PostID, Int?, TopicID) -> Void
    var openInternalLink: @MainActor @Sendable (NGAInternalDestination) -> Void
    var onReady: @MainActor (Identity) -> Void

    /// 撤骨架屏只等首楼。
    ///
    /// 楼层现在按需创建（`LazyVStack`），SwiftUI 只会实例化填满视口所需的那几层，
    /// 具体几层取决于楼层高度，视图这边无从预知；等待固定数量的楼层在惰性布局下
    /// 并不成立。首楼一定会被创建，也正是撤掉骨架屏时用户真正在看的内容，
    /// 其余楼层随滚动渐进呈现。
    ///
    /// 兜底上限仍然保留：`PostWebView` 的图片就绪脚本自身有 15 秒上限，
    /// 首楼里一张加载不出来的图不应该把整页骨架屏一起挂住。
    private static let readyTimeout = Duration.seconds(2)

    @State private var readyContentIDs: Set<String> = []
    @State private var didReportReady = false

    var body: some View {
        // 惰性布局：整页楼层原先会被一次性实例化，而每个 PostRow 内嵌一个 WKWebView，
        // 一页二十余层就是二十余个渲染实例。
        LazyVStack(spacing: 12) {
            Color.clear
                .frame(height: 0)
                .id(topAnchor)

            ForEach(posts.indices, id: \.self) { index in
                let post = posts[index]
                PostRow(
                    post: post,
                    topicRating: topicRating,
                    loadOrder: index,
                    reply: { reply(post) },
                    openPost: { postID, page in
                        openPost(postID, page, post.topicID)
                    },
                    openInternalLink: openInternalLink,
                    onContentReady: {
                        markContentReady("post-\(post.id.rawValue)")
                    }
                )
                .id(post.id)

                if post.floor == 0, !hotReplies.isEmpty {
                    HotRepliesSection(
                        posts: hotReplies,
                        topicRating: topicRating,
                        loadOrderOffset: posts.count,
                        reply: reply,
                        openPost: { postID, page in
                            openPost(postID, page, post.topicID)
                        },
                        openInternalLink: openInternalLink,
                        onContentReady: { hotReply in
                            markContentReady("hot-\(hotReply.id.rawValue)")
                        }
                    )
                }
            }
        }
        .task(id: identity) {
            reportReadyIfNeeded()
            guard !didReportReady else { return }
            try? await Task.sleep(for: Self.readyTimeout)
            guard !Task.isCancelled else { return }
            reportReady()
        }
    }

    /// 页面顶部的那一层。没有楼层可显示时为 nil，此时无需等待。
    private var leadingContentID: String? {
        posts.first.map { "post-\($0.id.rawValue)" }
    }

    private func markContentReady(_ contentID: String) {
        readyContentIDs.insert(contentID)
        reportReadyIfNeeded()
    }

    private func reportReadyIfNeeded() {
        guard let leadingContentID else {
            reportReady()
            return
        }
        guard readyContentIDs.contains(leadingContentID) else { return }
        reportReady()
    }

    private func reportReady() {
        guard !didReportReady else { return }
        didReportReady = true
        onReady(identity)
    }
}
