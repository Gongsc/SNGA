#if DEBUG
import Foundation

actor DebugForumService: NGAForumService {
    nonisolated let accountID: AccountID
    private let forum = Forum(
        id: ForumID(rawValue: -7),
        name: "艾泽拉斯国家地理",
        subtitle: "UI 测试版面",
        pinnedTopicID: TopicID(rawValue: 9003)
    )

    init(accountID: AccountID) {
        self.accountID = accountID
    }

    func profile(uid: Int64) async throws -> Profile {
        Profile(
            uid: uid,
            displayName: "测试账号",
            avatarURL: nil,
            userGroup: "学徒",
            registeredAt: Date(timeIntervalSince1970: 1_435_199_662),
            postCount: 394,
            location: "浙江省",
            signature: "这是一条测试签名",
            reputation: 1.5,
            fame: 15,
            money: 168,
            followerCount: 6
        )
    }

    func userActivities(uid: Int64, kind: UserActivityKind, page: Int) async throws -> UserActivityPage {
        let values = [
            UserActivity(
                id: "\(kind.rawValue)-9001",
                kind: kind,
                topicID: TopicID(rawValue: 9001),
                forumID: forum.id,
                forumName: forum.name,
                subject: "话题一：欢迎使用 SNGA",
                excerpt: kind == .replies ? "这是一条用于 UI 测试的用户回复摘要。" : nil,
                postedAt: Date(timeIntervalSince1970: 1_785_000_000)
            )
        ]
        return UserActivityPage(
            kind: kind,
            activities: values,
            page: page,
            hasMore: page < 2,
            totalPages: 2
        )
    }

    func forums() async throws -> [Forum] {
        [
            Forum(
                id: forum.id,
                name: forum.name,
                subtitle: forum.subtitle,
                category: "网事杂谈",
                pinnedTopicID: forum.pinnedTopicID
            ),
            Forum(id: ForumID(rawValue: 510381), name: "晴风村", category: "手机游戏")
        ]
    }

    func search(
        _ request: ForumSearchRequest,
        page: Int
    ) async throws -> ForumSearchPage {
        let targetPage = max(1, page)
        switch request.kind {
        case .topicSubject, .topicContent:
            let resultForumID = request.forumID ?? forum.id
            return ForumSearchPage(
                request: request,
                topics: [
                    Topic(
                        id: TopicID(rawValue: 9101),
                        forumID: resultForumID,
                        subject: "搜索结果：\(request.query)",
                        author: "搜索测试用户",
                        replyCount: 6,
                        sourceForumName: request.forumID == nil ? forum.name : nil
                    )
                ],
                page: targetPage,
                hasMore: targetPage < 2,
                totalPages: 2
            )
        case .forum:
            return ForumSearchPage(
                request: request,
                forums: [
                    Forum(
                        id: forum.id,
                        name: "\(request.query) · \(forum.name)",
                        subtitle: forum.subtitle
                    )
                ]
            )
        case .user:
            return ForumSearchPage(
                request: request,
                users: [try await profile(uid: 42)]
            )
        case .userTopics, .userContent:
            let kind = request.kind.userActivityKind ?? .topics
            let result = try await userActivities(
                uid: 42,
                kind: kind,
                page: targetPage
            )
            return ForumSearchPage(
                request: request,
                users: [try await profile(uid: 42)],
                activities: result.activities,
                page: result.page,
                hasMore: result.hasMore,
                totalPages: result.totalPages
            )
        }
    }

    func topics(
        forumID: ForumID,
        page: Int,
        sortOrder: TopicListSortOrder,
        featuredOnly: Bool
    ) async throws -> ForumPage {
        // Keep the UI-test response pending long enough to verify refresh animations.
        try await Task.sleep(for: .seconds(2))
        let topics = [
            Topic(id: TopicID(rawValue: 9001), forumID: forumID, subject: "话题一：欢迎使用 SNGA", author: "测试用户", authorUID: 1001, replyCount: 2),
            Topic(id: TopicID(rawValue: 9002), forumID: forumID, subject: "话题二：多账号与收藏测试", author: "另一位用户", authorUID: 1002, replyCount: 8)
        ]
        let sortedTopics = sortOrder == .latestReply
            ? topics
            : Array(topics.reversed())
        return ForumPage(
            forum: forum,
            topics: featuredOnly
                ? sortedTopics.filter { $0.id == TopicID(rawValue: 9002) }
                : sortedTopics,
            page: page,
            hasMore: featuredOnly ? false : page < 3,
            totalPages: featuredOnly ? 1 : 3
        )
    }

    func threadPage(
        topicID: TopicID,
        page: Int,
        authorUID: Int64?
    ) async throws -> ThreadPage {
        // Keep UI-test responses pending long enough to observe thread skeleton transitions.
        try await Task.sleep(for: .seconds(1))
        let isPrimaryTopic = topicID == TopicID(rawValue: 9001)
        let isPinnedTopic = topicID == forum.pinnedTopicID
        let subject: String
        if isPrimaryTopic {
            subject = "话题一：欢迎使用 SNGA"
        } else if isPinnedTopic {
            subject = "版面置顶话题"
        } else {
            subject = "话题二：多账号与收藏测试"
        }
        let topic = Topic(
            id: topicID,
            forumID: forum.id,
            subject: subject,
            author: "测试用户",
            authorUID: isPrimaryTopic ? 1001 : 1002,
            replyCount: 1,
            isPinned: isPinnedTopic,
            rating: isPrimaryTopic
                ? TopicRating(
                    id: topicID,
                    dimensions: [
                        TopicRatingDimension(
                            id: "100",
                            title: "客户端体验",
                            ratingCount: 30,
                            totalScore: 234
                        )
                    ],
                    minimumScore: 1,
                    maximumScore: 10,
                    endsAt: Date(timeIntervalSince1970: 1_893_427_200),
                    participantCount: 30
                )
                : nil
        )
        let firstPostHTML = isPrimaryTopic
            ? """
              <p>这是一条用于 UI 测试的帖子内容。</p>
              <p><a href="https://bbs.nga.cn/read.php?tid=9002">打开站内关联话题</a></p>
              """
            : "<p>这是通过站内链接打开的关联话题。</p>"
        let sanitizedFirstPostHTML = NGAParser().sanitizedPostHTML(firstPostHTML)
        let renderedFirstPostHTML: String
        if isPrimaryTopic,
           ProcessInfo.processInfo.arguments.contains("--uitesting-image-thread") {
            let tallImage = """
            <img
                src="data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHdpZHRoPSIxMDAiIGhlaWdodD0iMjQwMCI+PHJlY3Qgd2lkdGg9IjEwMCIgaGVpZ2h0PSIyNDAwIiBmaWxsPSIjY2NjIi8+PC9zdmc+"
                width="100"
                height="2400"
                loading="eager"
                decoding="async"
                alt="滚动性能测试图片"
            >
            """
            renderedFirstPostHTML = sanitizedFirstPostHTML.replacingOccurrences(
                of: "</main>",
                with: "\(tallImage)</main>"
            )
        } else {
            renderedFirstPostHTML = sanitizedFirstPostHTML
        }
        let postIDOffset = page == 1 ? 0 : Int64((page - 1) * 100)
        let allPosts = [
            Post(
                id: PostID(rawValue: 1 + postIDOffset),
                topicID: topicID,
                floor: 0,
                author: "测试用户",
                authorUID: isPrimaryTopic ? 1001 : 1002,
                authorInfo: isPrimaryTopic
                    ? PostAuthorInfo(
                        levelTitle: "一心净土",
                        reputation: 2030,
                        reputationLevel: 11,
                        userGroup: "Warden",
                        registeredAt: Date(timeIntervalSince1970: 1_487_143_790),
                        prestige: 29.7,
                        medals: [
                            UserMedal(
                                id: 386,
                                name: "流浪地球",
                                imageURL: URL(string: "https://img4.nga.cn/ngabbs/medal/386.gif")
                            )
                        ],
                        honor: "于明日落下，静寂与月光",
                        site: "星辰驰骋终幕蔷薇"
                    )
                    : nil,
                postedAt: Date(timeIntervalSince1970: 1_785_000_000),
                html: renderedFirstPostHTML,
                poll: isPrimaryTopic
                    ? TopicPoll(
                        id: topicID,
                        groups: [
                            TopicPoll.Group(
                                id: 0,
                                title: nil,
                                options: [
                                    TopicPoll.Option(id: "1", title: "原生客户端", voteCount: 18),
                                    TopicPoll.Option(id: "2", title: "网页端", voteCount: 7),
                                    TopicPoll.Option(id: "3", title: "都在使用", voteCount: 5)
                                ]
                            )
                        ],
                        maximumSelectionsPerGroup: 1,
                        endsAt: Date(timeIntervalSince1970: 1_893_427_200),
                        hidesResultsUntilVoting: false,
                        hidesResultsUntilEnd: false,
                        participantCount: 30
                    )
                    : nil
            ),
            Post(
                id: PostID(rawValue: 2 + postIDOffset),
                topicID: topicID,
                floor: 1,
                author: "回复用户",
                authorUID: 2001,
                html: NGAParser().sanitizedPostHTML(
                    "<blockquote>引用内容</blockquote><p>回复成功。</p>"
                ),
                ratingScores: isPrimaryTopic ? ["100": 8] : [:]
            )
        ]
        let visiblePosts = authorUID.map { targetUID in
            allPosts.filter { $0.authorUID == targetUID }
        } ?? allPosts
        let totalPages = authorUID == nil ? 3 : 1
        return ThreadPage(
            topic: topic,
            posts: visiblePosts,
            page: page,
            hasMore: page < totalPages,
            totalPages: totalPages
        )
    }

    func submitReply(topicID: TopicID, submission: ReplySubmission) async throws -> PostID? {
        PostID(rawValue: 3)
    }

    func vote(topicID: TopicID, postID: PostID, direction: PostVoteDirection) async throws -> PostVoteState {
        PostVoteState(
            upvoteCount: direction == .up ? 13 : 12,
            downvoteCount: direction == .down ? 2 : 1,
            userVote: direction
        )
    }

    func submitTopicPollVote(topicID: TopicID, optionIDs: [String]) async throws {}

    func messages(folder: MessageFolder, page: Int) async throws -> MessagePage {
        let isNotification = folder == .notifications
        return MessagePage(folder: folder, messages: [
            ForumMessage(
                id: MessageID(rawValue: isNotification ? 7003 : 7001),
                kind: isNotification ? .mention : .privateMessage,
                sender: "系统测试",
                subject: isNotification ? "测试通知" : "测试消息",
                preview: isNotification ? "这是通知预览" : "这是消息预览",
                sentAt: Date(timeIntervalSince1970: isNotification ? 1_700_000_100 : 1_700_000_000),
                isUnread: true
            )
        ], page: page, hasMore: false)
    }

    func message(id: MessageID) async throws -> ForumMessage {
        let sentAt = Date(timeIntervalSince1970: 1_700_000_000)
        let html = NGAParser().sanitizedPostHTML("<p>这是消息正文。</p>")
        return ForumMessage(
            id: id,
            kind: .privateMessage,
            sender: "系统测试",
            subject: "测试消息",
            preview: "这是消息预览",
            html: html,
            sentAt: sentAt,
            isUnread: false,
            posts: [
                ForumMessagePost(
                    id: MessageID(rawValue: 7002),
                    author: "系统测试",
                    sentAt: sentAt,
                    html: html
                )
            ]
        )
    }

    func replyMessage(id: MessageID, content: String) async throws {}
    func favorites() async throws -> [Forum] { [forum] }
    func updateFavorite(forumID: ForumID, isFavorite: Bool) async throws {}
    func favoriteTopicFolders() async throws -> [TopicFavoriteFolder] {
        [
            TopicFavoriteFolder(
                id: "1",
                name: "默认收藏夹",
                topicCount: 1,
                isDefault: true
            ),
            TopicFavoriteFolder(
                id: "541",
                name: "未命名的收藏夹#541",
                isPublic: false
            )
        ]
    }
    func favoriteTopics(folderID: String, page: Int) async throws -> ForumPage {
        ForumPage(
            forum: nil,
            topics: [
                Topic(
                    id: TopicID(rawValue: 9001),
                    forumID: forum.id,
                    subject: "话题一：欢迎使用 SNGA",
                    author: "测试用户",
                    replyCount: 2,
                    isFavorite: true
                )
            ],
            page: page,
            hasMore: false
        )
    }
    func updateTopicFavorite(topicID: TopicID, folderID: String, isFavorite: Bool) async throws {}
    func createTopicFavoriteFolder(name: String, isPublic: Bool, isDefault: Bool) async throws -> String? { "542" }
    func updateTopicFavoriteFolder(_ folder: TopicFavoriteFolder) async throws {}
    func deleteTopicFavoriteFolder(folderID: String) async throws {}
    func checkIn() async throws -> CheckInResult { .alreadyCheckedIn(message: "今日已签到") }
}
#endif
