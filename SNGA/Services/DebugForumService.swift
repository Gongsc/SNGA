#if DEBUG
import Foundation

actor DebugForumService: NGAForumService {
    nonisolated let accountID: AccountID
    private let forum = Forum(id: ForumID(rawValue: -7), name: "艾泽拉斯国家地理", subtitle: "UI 测试版面")

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
                subject: "主题一：欢迎使用 SNGA",
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
            Forum(id: forum.id, name: forum.name, subtitle: forum.subtitle, category: "网事杂谈"),
            Forum(id: ForumID(rawValue: 510381), name: "晴风村", category: "手机游戏")
        ]
    }

    func topics(forumID: ForumID, page: Int) async throws -> ForumPage {
        // Keep the UI-test response pending long enough to verify refresh animations.
        try await Task.sleep(for: .seconds(2))
        return ForumPage(
            forum: forum,
            topics: [
                Topic(id: TopicID(rawValue: 9001), forumID: forumID, subject: "主题一：欢迎使用 SNGA", author: "测试用户", replyCount: 2),
                Topic(id: TopicID(rawValue: 9002), forumID: forumID, subject: "主题二：多账号与收藏测试", author: "另一位用户", replyCount: 8)
            ],
            page: page,
            hasMore: page < 3,
            totalPages: 3
        )
    }

    func threadPage(topicID: TopicID, page: Int) async throws -> ThreadPage {
        let topic = Topic(id: topicID, forumID: forum.id, subject: "主题一：欢迎使用 SNGA", author: "测试用户", replyCount: 1)
        return ThreadPage(topic: topic, posts: [
            Post(id: PostID(rawValue: 1), topicID: topicID, floor: 0, author: "测试用户", html: NGAParser().sanitizedPostHTML("<p>这是一条用于 UI 测试的帖子内容。</p>")),
            Post(id: PostID(rawValue: 2), topicID: topicID, floor: 1, author: "回复用户", html: NGAParser().sanitizedPostHTML("<blockquote>引用内容</blockquote><p>回复成功。</p>"))
        ], page: page, hasMore: page < 3, totalPages: 3)
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
                    subject: "主题一：欢迎使用 SNGA",
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
