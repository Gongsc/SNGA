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

    /// 撤骨架屏只等首屏这几层。整页楼层都会被实例化，但等齐整页会被任意一层的
    /// 慢图拖住 —— `PostWebView` 的图片就绪脚本自身就有 15 秒上限，一张加载不出来
    /// 的图足以把整页骨架屏挂满 15 秒。
    private static let firstScreenContentCount = 4
    /// 首屏楼层迟迟不回报时的兜底上限。
    private static let readyTimeout = Duration.seconds(2)

    @State private var readyContentIDs: Set<String> = []
    @State private var didReportReady = false

    var body: some View {
        // 顶部锚点单独放在楼层堆栈之外，`scrollTo` 在任何滚动位置下都能解析到实位，
        // 不受楼层排版的影响。
        VStack(spacing: 0) {
            Color.clear
                .frame(height: 0)
                .id(topAnchor)

            content
        }
    }

    private var content: some View {
        // 整页楼层一次性实例化。惰性布局是为了省下「每层一个 WKWebView」而引入的，
        // 而绝大多数楼层现在走原生渲染，一页通常只剩一两层网页视图，这笔开销已经
        // 不在了；换来的是惰性堆栈自身的代价 —— 楼层高度要边滚边测，估值和实测
        // 对不上就会改变内容总高、进而挤动滚动位置、再触发新一轮取值。
        VStack(spacing: 12) {
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

    /// 内容在页面上的实际出现顺序：首楼、紧随其后的热点回复、其余楼层。
    private var orderedContentIDs: [String] {
        var identifiers: [String] = []
        for post in posts {
            identifiers.append("post-\(post.id.rawValue)")
            if post.floor == 0, !hotReplies.isEmpty {
                identifiers.append(
                    contentsOf: hotReplies.map { "hot-\($0.id.rawValue)" }
                )
            }
        }
        return identifiers
    }

    private var firstScreenContentIDs: Set<String> {
        Set(orderedContentIDs.prefix(Self.firstScreenContentCount))
    }

    private func markContentReady(_ contentID: String) {
        readyContentIDs.insert(contentID)
        reportReadyIfNeeded()
    }

    private func reportReadyIfNeeded() {
        guard firstScreenContentIDs.isSubset(of: readyContentIDs) else { return }
        reportReady()
    }

    private func reportReady() {
        guard !didReportReady else { return }
        didReportReady = true
        onReady(identity)
    }
}
