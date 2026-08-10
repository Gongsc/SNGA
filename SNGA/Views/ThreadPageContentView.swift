import SwiftUI

struct ThreadPageContentView: View {
    struct Identity: Hashable {
        private struct ContentFingerprint: Hashable {
            let postID: PostID
            let html: String
        }

        let topicID: TopicID
        let page: Int
        private let posts: [ContentFingerprint]
        private let hotReplies: [ContentFingerprint]

        init(topicID: TopicID, page: Int, posts: [Post], hotReplies: [Post]) {
            self.topicID = topicID
            self.page = page
            self.posts = posts.map {
                ContentFingerprint(postID: $0.id, html: $0.html)
            }
            self.hotReplies = hotReplies.map {
                ContentFingerprint(postID: $0.id, html: $0.html)
            }
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

    @State private var readyContentIDs: Set<String> = []
    @State private var didReportReady = false

    var body: some View {
        VStack(spacing: 12) {
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
        }
    }

    private var expectedContentIDs: Set<String> {
        Set(posts.map { "post-\($0.id.rawValue)" })
            .union(hotReplies.map { "hot-\($0.id.rawValue)" })
    }

    private func markContentReady(_ contentID: String) {
        readyContentIDs.insert(contentID)
        reportReadyIfNeeded()
    }

    private func reportReadyIfNeeded() {
        guard !didReportReady,
              expectedContentIDs.isSubset(of: readyContentIDs) else {
            return
        }
        didReportReady = true
        onReady(identity)
    }
}
