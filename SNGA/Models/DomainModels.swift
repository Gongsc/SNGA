import Foundation

enum SessionState: String, Codable, CaseIterable, Sendable {
    case valid
    case requiresLogin
    case restricted
    case temporaryFailure

    var title: String {
        switch self {
        case .valid: "已登录"
        case .requiresLogin: "需要重新登录"
        case .restricted: "访问受限"
        case .temporaryFailure: "暂时不可用"
        }
    }
}

enum FavoriteSyncState: String, Codable, CaseIterable, Sendable {
    case synced
    case pendingAdd
    case pendingRemove
    case localOnly
    case conflict
}

struct AccountSummary: Identifiable, Hashable, Sendable {
    let id: AccountID
    var ngaUID: Int64
    var displayName: String
    var avatarURL: URL?
    var sessionState: SessionState
    var isCurrent: Bool
}

struct Forum: Identifiable, Hashable, Codable, Sendable {
    let id: ForumID
    var name: String
    var subtitle: String? = nil
    var iconURL: URL? = nil
    var category: String? = nil
    /// NGA 在父板块页面中返回的当前勾选状态；普通板块没有该值。
    var isSelectedInParent: Bool? = nil
}

struct ForumCategory: Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    var forums: [Forum]
}

struct Topic: Identifiable, Hashable, Codable, Sendable {
    let id: TopicID
    var forumID: ForumID
    var subject: String
    var author: String
    var replyCount: Int
    var publishedAt: Date? = nil
    var lastReplyAt: Date? = nil
    var isPinned: Bool = false
    var isLocked: Bool = false
    var sourceForumID: ForumID? = nil
    var sourceParentForumID: ForumID? = nil
    var sourceForumName: String? = nil
    var mirroredForumID: ForumID? = nil
    var isFavorite: Bool = false
}

struct TopicFavoriteFolder: Identifiable, Hashable, Codable, Sendable {
    let id: String
    var name: String
    var topicCount: Int = 0
    var isPublic: Bool = false
    var isDefault: Bool = false
}

struct ForumPage: Hashable, Codable, Sendable {
    var forum: Forum?
    var topics: [Topic]
    var page: Int
    var hasMore: Bool
    var totalPages: Int = 1
    var subforums: [Forum] = []
}

struct Post: Identifiable, Hashable, Codable, Sendable {
    let id: PostID
    var topicID: TopicID
    var floor: Int
    var author: String
    var authorUID: Int64? = nil
    var avatarURL: URL? = nil
    var postedAt: Date? = nil
    var html: String
    var quotedPostID: PostID? = nil
    var upvoteCount: Int = 0
    var downvoteCount: Int = 0
    var userVote: PostVoteDirection? = nil
}

struct ThreadPage: Hashable, Codable, Sendable {
    var topic: Topic
    var posts: [Post]
    var hotReplies: [Post] = []
    var page: Int
    var hasMore: Bool
    var totalPages: Int = 1
}

enum PostVoteDirection: String, Hashable, Codable, Sendable {
    case up
    case down

    var requestValue: String {
        switch self {
        case .up: "1"
        case .down: "0"
        }
    }
}

struct PostVoteState: Hashable, Codable, Sendable {
    var upvoteCount: Int
    var downvoteCount: Int
    var userVote: PostVoteDirection?
}

enum MessageFolder: String, CaseIterable, Codable, Sendable, Identifiable {
    case privateMessages = "inbox"
    case notifications = "reminders"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .privateMessages: "短消息"
        case .notifications: "提醒信息"
        }
    }
}

enum ForumMessageKind: String, Codable, Sendable {
    case privateMessage
    case reply
    case quote
    case mention
    case unknown

    var notificationTitle: String {
        switch self {
        case .privateMessage: "收到新私信"
        case .reply: "帖子收到新回复"
        case .quote: "帖子被引用"
        case .mention: "帖子中有人提到你"
        case .unknown: "收到论坛消息"
        }
    }
}

struct ForumMessage: Identifiable, Hashable, Codable, Sendable {
    let id: MessageID
    var kind: ForumMessageKind
    var sender: String
    var subject: String
    var preview: String
    var html: String? = nil
    var sentAt: Date? = nil
    var isUnread: Bool
    var topicID: TopicID? = nil
    var replyURL: URL? = nil
}

struct MessagePage: Hashable, Codable, Sendable {
    var folder: MessageFolder
    var messages: [ForumMessage]
    var page: Int
    var hasMore: Bool
}

enum CheckInResult: Hashable, Codable, Sendable {
    case success(message: String)
    case alreadyCheckedIn(message: String)
}

enum DailyCheckInStatus: Hashable, Sendable {
    case checkedIn(message: String)
    case notCheckedIn
    case checkingIn
    case failed(message: String)

    var canCheckIn: Bool {
        switch self {
        case .notCheckedIn, .failed:
            true
        case .checkedIn, .checkingIn:
            false
        }
    }
}

struct Profile: Hashable, Codable, Sendable {
    var uid: Int64
    var displayName: String
    var avatarURL: URL?
    var userGroup: String? = nil
    var title: String? = nil
    var honor: String? = nil
    var registeredAt: Date? = nil
    var postCount: Int? = nil
    var location: String? = nil
    var signature: String? = nil
    var reputation: Double? = nil
    var fame: Int? = nil
    var money: Int? = nil
    var followerCount: Int? = nil
    var isMasked: Bool = false
}

enum UserActivityKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case topics
    case replies

    var id: String { rawValue }

    var title: String {
        switch self {
        case .topics: "主题"
        case .replies: "回复"
        }
    }
}

struct UserActivity: Identifiable, Hashable, Codable, Sendable {
    let id: String
    var kind: UserActivityKind
    var topicID: TopicID
    var postID: PostID? = nil
    var forumID: ForumID? = nil
    var forumName: String? = nil
    var subject: String
    var excerpt: String? = nil
    var postedAt: Date? = nil
}

struct UserActivityPage: Hashable, Codable, Sendable {
    var kind: UserActivityKind
    var activities: [UserActivity]
    var page: Int
    var hasMore: Bool
    var totalPages: Int
}

struct FavoriteSnapshot: Hashable, Codable, Sendable {
    var forum: Forum
    var order: Int
    var state: FavoriteSyncState
}

struct ReplySubmission: Hashable, Codable, Sendable {
    var content: String
    var replyTo: PostID?
}

struct SessionCookie: Codable, Hashable, Sendable {
    var name: String
    var value: String
    var domain: String
    var path: String
    var expiresAt: Date?
    var isSecure: Bool
    var isHTTPOnly: Bool

    var isExpired: Bool {
        expiresAt.map { $0 <= Date() } ?? false
    }
}

struct LoginCapture: Sendable {
    var uid: Int64
    var cookies: [SessionCookie]
}

enum SidebarSelection: Hashable, Sendable {
    case userCenter(Int64?)
    case forum(ForumID)
    case directory
    case favorites
    case messages(MessageFolder)
}
