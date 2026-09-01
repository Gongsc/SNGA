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
    var site: ForumSite
    var siteUserID: Int64
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
    var pinnedTopicID: TopicID? = nil
    /// NGA 在父版面页面中返回的当前勾选状态；普通版面没有该值。
    var isSelectedInParent: Bool? = nil
    /// 这是不是一个子版面。由适配器在构造时盖章。
    ///
    /// 展示层要的是「画哪个图标」，不该为此去问 `ForumID` 是怎么编码的 —— 那是
    /// NGA 一家的事，别的站点根本没有子版面这个概念。
    var isSubforum: Bool = false
    /// 适配器额外给的搜索词，用来在版面目录里按站点自己的说法过滤。
    ///
    /// NGA 放的是 `fid` / `stid`，于是「fid 510381」能搜到东西。这类词是各站自己的
    /// 术语，目录搜索只管把它们并进待匹配的文本，不必知道它们是什么意思。
    var searchAliases: [String] = []
}

struct ForumCategory: Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    var forums: [Forum]
}

enum TopicSubjectColor: String, Codable, Hashable, Sendable {
    case red
    case blue
    case green
    case orange
    case silver
}

struct Topic: Identifiable, Hashable, Codable, Sendable {
    let id: TopicID
    var forumID: ForumID
    var subject: String
    var author: String
    var authorUID: Int64? = nil
    var replyCount: Int
    var publishedAt: Date? = nil
    var lastReplyAt: Date? = nil
    var isPinned: Bool = false
    var isLocked: Bool = false
    /// 匿名话题：NGA 不公开楼主身份，只按话题给出一个固定的化名。
    var isAnonymous: Bool = false
    var sourceForumID: ForumID? = nil
    var sourceParentForumID: ForumID? = nil
    var sourceForumName: String? = nil
    var mirroredForumID: ForumID? = nil
    var isFavorite: Bool = false
    var subjectColor: TopicSubjectColor? = nil
    /// 列表上挂在标题旁边的标记：置顶、推荐阅读、等级限制这类。
    ///
    /// 站点会随时加新的标记，所以这里不是一组固定的布尔值 —— 认不出来的照样带过来，
    /// 用站点自己的说法显示。少显示一个标记，读者就少一条判断这帖值不值得点的依据。
    var badges: [TopicBadge] = []
    var rating: TopicRating? = nil
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

enum PostDevice: String, Hashable, Codable, Sendable {
    case apple
    case android
    case desktop

    var title: String {
        switch self {
        case .apple: "Apple 设备"
        case .android: "Android 设备"
        case .desktop: "桌面设备"
        }
    }
}

struct UserMedal: Identifiable, Hashable, Codable, Sendable {
    let id: Int
    var name: String
    var detail: String? = nil
    var imageURL: URL? = nil
}

struct PostAuthorInfo: Hashable, Codable, Sendable {
    var levelTitle: String? = nil
    var reputation: Int? = nil
    var reputationLevel: Int? = nil
    var userGroup: String? = nil
    var registeredAt: Date? = nil
    var prestige: Double? = nil
    var location: String? = nil
    var medals: [UserMedal] = []
    var honor: String? = nil
}

struct Post: Identifiable, Hashable, Codable, Sendable {
    let id: PostID
    var topicID: TopicID
    var floor: Int
    var author: String
    var authorUID: Int64? = nil
    var avatarURL: URL? = nil
    var authorInfo: PostAuthorInfo? = nil
    /// 匿名楼层：作者只有化名，没有可以打开的用户资料。
    var isAnonymous: Bool = false
    var postedAt: Date? = nil
    var device: PostDevice? = nil
    var html: String
    /// 可原生渲染的正文结构。为 nil 表示该层含图片、表格等复杂内容，需要 `WKWebView`。
    var nativeContent: PostContent? = nil
    var quotedPostID: PostID? = nil
    /// 该层发出之后的改动记录，按 NGA 下发的先后顺序排列。
    var edits: [PostEdit] = []
    /// 该层被管理操作折叠的原因。为 nil 表示正常楼层。
    var punishment: PostPunishment? = nil
    var upvoteCount: Int = 0
    var downvoteCount: Int = 0
    var userVote: PostVoteDirection? = nil
    /// 除了赞和踩之外，站点还提供的表态。
    ///
    /// NGA 只有赞踩两种，这里就是空的。NodeSeek 有三种：点赞（免费）、加鸡腿、反对 ——
    /// 后两种**要花掉读者自己的鸡腿，而且都不可撤销**，所以每一项都带着代价，
    /// 界面必须把它说出来。
    var reactions: [PostReaction] = []
    /// 站点把这一层标成了热点。
    ///
    /// 和 `PostRow` 的 `isHotReply` 不是一回事：那个说的是「这一行画在热点回复那一栏里」
    /// （NGA 的形状，热点是单独一份列表）；这个是站点在楼层本身上打的标记，
    /// NodeSeek 的热点就混在正常楼层里，只多一个角标。
    var isHot: Bool = false
    /// 楼主把这一层置顶了。
    ///
    /// 和 `Topic.isPinned`（版面里置顶的话题）无关，这个说的是帖子内部的某一层。
    var isPinnedPost: Bool = false
    /// 这个**话题**被收藏了多少次，以及我收藏了没有。
    ///
    /// 只有主楼有。收藏是话题级的，但网页版就是把它和楼层的表态并排画在主楼那一行，
    /// 所以跟着楼层走 —— 楼层视图拿不到 `Topic`。
    var topicCollectionCount: Int? = nil
    var isTopicCollected: Bool = false
    var poll: TopicPoll? = nil
    var ratingScores: [String: Int] = [:]
}

/// 楼层的一次改动，对应网页版楼层末尾「改动」栏里的一条「在 … 修改」。
///
/// 来自 `alterinfo` 里的 `E` 条目。同一层可以有多条：每改一次追加一条。
struct PostEdit: Hashable, Codable, Sendable {
    var editedAt: Date
    /// 代为改动的人。楼主改自己的楼层时两者都为 nil，网页版此时也只写时间。
    var editorUID: Int64? = nil
    var editorName: String? = nil
}

/// 楼层被管理操作折叠的原因，对应网页版的 `lessernuke` 提示条。
///
/// NGA 不删除这类楼层，而是把正文收进一个带提示的框里默认折叠，读者点一下才展开。
/// 三种提示语和 `js_bbscode_core.js` 里的 `ubbcode.lesserNuke` 一一对应。
enum PostPunishment: String, Hashable, Codable, Sendable, CaseIterable {
    /// 用户因此帖中的发言被处罚。来自楼层 `type` 的处罚位，或 `[lessernuke]` / `[lessernuke1]`。
    case post
    /// 用户在主题中被处罚。来自主题的禁言名单，或 `[lessernuke2]`。
    case topic
    /// 被锁定账号发布的内容无法查看。来自 `[lessernuke3]`。
    case lockedAccount

    /// `[lessernuke2]` 里的那个数字。缺省和未知取值都按最普通的处罚处理，
    /// 与网页版把 `[lessernuke]` 当作 `1` 的做法一致。
    init(lesserNukeMarker marker: String) {
        switch marker {
        case "2": self = .topic
        case "3": self = .lockedAccount
        default: self = .post
        }
    }

    var title: String {
        switch self {
        case .post: "用户因此帖中的发言被处罚"
        case .topic: "用户在主题中被处罚"
        case .lockedAccount: "被锁定账号发布的内容无法查看"
        }
    }
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

    func optimisticallyApplying(_ direction: PostVoteDirection) -> PostVoteState {
        var result = self
        if result.userVote == direction {
            switch direction {
            case .up:
                result.upvoteCount = max(0, result.upvoteCount - 1)
            case .down:
                result.downvoteCount = max(0, result.downvoteCount - 1)
            }
            result.userVote = nil
            return result
        }

        switch result.userVote {
        case .up:
            result.upvoteCount = max(0, result.upvoteCount - 1)
        case .down:
            result.downvoteCount = max(0, result.downvoteCount - 1)
        case nil:
            break
        }

        switch direction {
        case .up:
            result.upvoteCount += 1
        case .down:
            result.downvoteCount += 1
        }
        result.userVote = direction
        return result
    }
}

enum MessageFolder: String, CaseIterable, Codable, Sendable, Identifiable {
    case privateMessages = "inbox"
    case notifications = "reminders"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .privateMessages: "短消息"
        case .notifications: "通知"
        }
    }
}

enum ForumMessageKind: String, Codable, Sendable {
    case privateMessage
    case reply
    case quote
    case comment
    case mention
    case unknown

    var notificationTitle: String {
        switch self {
        case .privateMessage: "收到新私信"
        case .reply: "帖子收到新回复"
        case .quote: "帖子被引用"
        case .comment: "帖子收到新评价"
        case .mention: "帖子中有人提到你"
        case .unknown: "收到论坛消息"
        }
    }
}

struct ForumMessagePost: Identifiable, Hashable, Codable, Sendable {
    let id: MessageID
    var author: String
    var authorUID: Int64? = nil
    var avatarURL: URL? = nil
    var sentAt: Date? = nil
    var html: String
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
    var posts: [ForumMessagePost] = []
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

struct CheckInStatistics: Hashable, Codable, Sendable {
    var isCheckedInToday: Bool
    /// 站点不报这两个数时是 nil，界面就不显示那一行。
    ///
    /// 原先是 `Int`，取不到就填 0 —— 于是 NodeSeek 上永远显示「连续签到 0 天」，
    /// 那不是「不知道」，那是在说一件错事。
    var consecutiveDays: Int?
    var totalDays: Int?
}

enum DailyCheckInStatus: Hashable, Sendable {
    case loading
    case checkedIn(statistics: CheckInStatistics, message: String)
    case notCheckedIn(statistics: CheckInStatistics)
    case checkingIn
    case failed(message: String)

    var canCheckIn: Bool {
        switch self {
        case .notCheckedIn:
            true
        case .loading, .checkedIn, .checkingIn, .failed:
            false
        }
    }

    var needsCheckInPrompt: Bool {
        if case .notCheckedIn = self { return true }
        return false
    }

    var canRefresh: Bool {
        if case .failed = self { return true }
        return false
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
    /// 关注了多少人。NGA 的资料里没有这个数。
    var followingCount: Int? = nil
    /// 发过多少条回复。NGA 只报发帖数，不分主题和回复。
    var commentCount: Int? = nil
    /// 未读的回复、@ 和私信。
    ///
    /// **只有看自己的资料时才有。** 站点只对本人报这几个数 —— 看别人的资料时留空，
    /// 那几行就不显示。
    var unreadReplies: Int? = nil
    var unreadMentions: Int? = nil
    var unreadMessages: Int? = nil
    var isMasked: Bool = false
}

/// 话题列表上标题旁边的一个标记。
struct TopicBadge: Identifiable, Hashable, Codable, Sendable {
    /// 站点自己的完整说法。用作悬停提示和读屏文字。
    let title: String
    /// 图标旁边要画出来的那几个字。
    ///
    /// 有的标记光靠图标就说清楚了（置顶、推荐阅读），有的不行 ——「等级 1 可见」
    /// 里真正的信息是那个 1，只画一把锁等于告诉读者「这帖有限制」却不说是什么限制。
    /// 站点自己也是画一把锁再跟一个数字。
    var value: String? = nil
    /// 画哪个图标。认不出来的标记用一个中性的。
    var systemImage: String = "tag"

    var id: String { title }
}

/// 楼层上的一种表态。
///
/// 赞和踩由 `PostVoteState` 表达，那是两站都有的形状。这里装的是超出那两个方向的
/// 东西：站点自己的第三、第四种表态，各有各的代价。
///
/// `cost` 不是装饰。有的站点的表态会当场花掉用户的东西且收不回来 —— 那种按钮不能
/// 一点就发，界面得先把价钱摆出来。
struct PostReaction: Identifiable, Hashable, Codable, Sendable {
    let id: String
    var title: String
    var systemImage: String
    /// 已经有多少人这么表态过。站点不报就留空。
    var count: Int? = nil
    /// 我表态过了。不可撤销的表态尤其要显示这个 —— 否则用户会再花一次钱。
    var isChosen: Bool = false
    /// 这一下要花掉用户什么。免费的表态是 nil。
    var cost: String? = nil
    /// 做了就收不回来。
    var isIrreversible: Bool = false
}

/// 用户资料里的一行。
///
/// 各站报的东西和叫法都不一样：NGA 有用户组、威望、N 币，NodeSeek 有等级、鸡腿、
/// 星辰，连「发帖数」的含义都不同 —— NGA 是总数，NodeSeek 分主题帖和评论。
/// 所以显示哪几行、叫什么，由站点自己说（见 `ForumSiteDescriptor.profileFields`）。
struct ProfileStat: Identifiable, Hashable, Sendable {
    let title: String
    let value: String

    var id: String { title }
}

enum UserActivityKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case topics
    case replies

    var id: String { rawValue }

    var title: String {
        switch self {
        case .topics: "话题"
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
    var ratingScores: [String: Int] = [:]
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
    /// 这次登录发生在哪个站。账号按「站点 + uid」认，两者缺一不可。
    var site: ForumSite
    /// 用户编号。只有把它写在 Cookie 里的站点能当场读到；其余为 nil，
    /// 登录后由 `ForumService.currentUserID()` 问出来。
    var uid: Int64?
    var cookies: [SessionCookie]
}

/// 设置的分类。每一类在中栏占一行，在右栏是一张面板。
///
/// 副标题不放在这里：它读的是当前值（选了哪套主题、日志开没开），要跟着改动
/// 实时变，只能在视图里从 `@AppStorage` 取。
enum SettingsSection: String, CaseIterable, Identifiable, Hashable, Sendable {
    case appearance
    case browsing
    case ai
    case toolbox
    case background
    case runtimeLog
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appearance: "外观"
        case .browsing: "浏览"
        case .ai: "AI"
        case .toolbox: "小工具"
        case .background: "后台行为"
        case .runtimeLog: "运行日志"
        case .about: "关于"
        }
    }

    var systemImage: String {
        switch self {
        case .appearance: "paintpalette"
        case .browsing: "photo.on.rectangle"
        case .ai: "sparkles"
        case .toolbox: "wrench.and.screwdriver"
        case .background: "clock.arrow.circlepath"
        case .runtimeLog: "doc.text"
        case .about: "info.circle"
        }
    }
}

enum SidebarSelection: Hashable, Sendable {
    /// 选站点、选登录方式。加账号本身是个流程，不是一个弹窗。
    case addAccount
    case userCenter(Int64?)
    case aiProfiles
    case forum(ForumID)
    case directory
    case search
    case favorites
    case messages(MessageFolder)
    case toolbox
    case settings
}
