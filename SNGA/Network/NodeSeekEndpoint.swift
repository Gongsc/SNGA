import Foundation

/// NodeSeek 的地址词汇表。解析器不拼地址，一律从这里取。
///
/// 站点没有公开 API：**列表页和帖子页都是服务端渲染的 HTML，只能解析**；JSON 接口只覆盖
/// 通知、统计和写操作。所以下面分成两半，前一半是网页地址，后一半才是接口。
///
/// 传输层的三条硬约束记在 `Design/SiteProbe-NodeSeek.md` 第〇节，都是实测的：
/// 请求要带 WebView 的真实 UA、要带站点的**全部** cookie、不能用 curl 验证。
enum NodeSeekEndpoint {
    static let descriptor = ForumSiteDescriptor.nodeseek

    // MARK: - 分类

    /// 站点的分类是固定的一组，没有接口能列全（`/api/content/list-categories` 给的是别的东西），
    /// 所以写在这里。顺序与网页导航一致。
    ///
    /// 综合是混合首页，它的地址是 `/` 而不是 `/categories/…`，用 `homeKey` 表示。
    static let categories: [(key: String, name: String)] = [
        (homeKey, "综合"),
        ("daily", "日常"),
        ("tech", "技术"),
        ("info", "情报"),
        ("review", "测评"),
        ("trade", "交易"),
        ("carpool", "拼车"),
        ("promotion", "推广"),
        ("life", "生活"),
        ("dev", "Dev"),
        ("photo-share", "贴图"),
        ("expose", "曝光"),
        ("inside", "内版"),
        ("meaningless", "无意义"),
        ("sandbox", "沙盒")
    ]

    /// 综合首页的键。它没有 slug，地址是 `/` 和 `/page-N`。
    ///
    /// 用一个词而不是空串：`ForumID.description` 会进界面标识符，空串在那里没法用。
    static let homeKey = "home"

    static func forumID(key: String) -> ForumID {
        ForumID(site: .nodeseek, key: key)
    }

    /// 分类列表页。`sortByPostTime` 为真时按发帖时间排，否则按最后回复（站点默认，不带参数）。
    static func topicList(forumID: ForumID, page: Int, sortByPostTime: Bool) -> URL {
        let page = max(1, page)
        let base = forumID.key == homeKey ? "" : "/categories/\(forumID.key)"
        let path = page == 1 ? (base.isEmpty ? "/" : base) : "\(base)/page-\(page)"
        return url(path, query: sortByPostTime ? [.init(name: "sortBy", value: "postTime")] : [])
    }

    /// 帖子页。每页 10 层，见 `commentsPerPage`。
    static func thread(topicID: TopicID, page: Int) -> URL {
        url("/post-\(topicID.rawValue)-\(max(1, page))")
    }

    /// 每页楼层数。站点只给楼层号不给页码 —— 回复提醒带的是 `#4` 这样的锚点，
    /// 要跳过去就得自己算在第几页。
    static let commentsPerPage = 10

    static func page(ofFloor floor: Int) -> Int {
        floor <= 0 ? 1 : (floor - 1) / commentsPerPage + 1
    }

    static func userSpace(uid: Int64) -> URL { url("/space/\(uid)") }

    /// 帖子搜索。站点限流 1 次 / 2 秒，超出答 429。
    static func search(query: String, page: Int, categoryKey: String?) -> URL {
        var items = [URLQueryItem(name: "q", value: query)]
        if page > 1 { items.append(.init(name: "page", value: String(page))) }
        if let categoryKey, categoryKey != homeKey {
            items.append(.init(name: "category", value: categoryKey))
        }
        return url("/search", query: items)
    }

    // MARK: - JSON 接口

    static func accountInfo(uid: Int64) -> URL {
        // 不带 readme=1 时响应里没有个人简介。
        url("/api/account/getInfo/\(uid)", query: [.init(name: "readme", value: "1")])
    }

    /// 用户动态每页的条数。和帖子页的 `commentsPerPage` 不是一回事 —— 那是楼层分页。
    static let activitiesPerPage = 15

    static func userTopics(uid: Int64, page: Int) -> URL {
        url("/api/content/list-discussions", query: [
            .init(name: "uid", value: String(uid)),
            .init(name: "page", value: String(max(1, page)))
        ])
    }

    static func userComments(uid: Int64, page: Int) -> URL {
        url("/api/content/list-comments", query: [
            .init(name: "uid", value: String(uid)),
            .init(name: "page", value: String(max(1, page)))
        ])
    }

    static let newComment = url("/api/content/new-comment")

    static func notifications(kind: NodeSeekNotificationKind, page: Int) -> URL {
        notifications(kind: kind.rawValue, page: page)
    }

    static func notifications(kind: String, page: Int) -> URL {
        url("/api/notification/\(kind)/list", query: [.init(name: "page", value: String(max(1, page)))])
    }

    static let unreadCount = url("/api/notification/unread-count")
    static func messageThread(uid: Int64) -> URL { url("/api/notification/message/with/\(uid)") }
    static let sendMessage = url("/api/notification/message/send")

    /// 签到。`random=true` 是抽奖式，`false` 领固定的 5 个鸡腿。
    static func checkIn(random: Bool) -> URL {
        url("/api/attendance", query: [.init(name: "random", value: random ? "true" : "false")])
    }

    /// 今日是否已签到要从签到榜的 `record` 读，签到接口本身不给。
    static func checkInBoard(page: Int) -> URL {
        url("/api/attendance/board", query: [.init(name: "page", value: String(max(1, page)))])
    }

    /// 收藏话题，`{"postId":N,"action":"add"|"remove"}`。可逆，和三种反应不一样。
    static let collection = url("/api/statistics/collection")

    static func collectionList(page: Int) -> URL {
        url("/api/statistics/list-collection", query: [.init(name: "page", value: String(max(1, page)))])
    }

    /// 楼层反应。
    ///
    /// **动作名和它的含义对不上，接错会花掉用户的钱**：站点的 `like` 是「加鸡腿」，
    /// 花读者 1 个鸡腿；`dislike` 是「反对」，花 2 个；免费且给作者星辰的是 `upvote`。
    /// 三种都**不可撤销**。见 `NodeSeekReaction`。
    static func reaction(_ reaction: NodeSeekReaction) -> URL {
        url("/api/statistics/\(reaction.rawValue)")
    }

    // MARK: -

    private static func url(_ path: String, query: [URLQueryItem] = []) -> URL {
        var components = URLComponents(
            url: descriptor.baseURL.appending(path: path),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = query.isEmpty ? nil : query
        return components.url!
    }
}

/// 楼层的三种反应。
///
/// 名字保持站点的原样，因为它们要直接进地址；含义写在这里，免得有人照字面接。
enum NodeSeekReaction: String, Sendable, CaseIterable {
    /// 投喂：免费，给作者星辰。想接「点赞」的话是这个。
    case upvote
    /// 加鸡腿：**花掉读者 1 个鸡腿**。
    case like
    /// 反对：**花掉读者 2 个鸡腿**。
    case dislike

    var isFree: Bool { self == .upvote }

    /// 花掉读者多少个鸡腿。
    var chickenCost: Int {
        switch self {
        case .upvote: 0
        case .like: 1
        case .dislike: 2
        }
    }
}

/// 站点把「通知」分成两类，两个接口形状一样。
enum NodeSeekNotificationKind: String, Sendable, CaseIterable {
    case atMe = "at-me"
    case replyToMe = "reply-to-me"

    var messageKind: ForumMessageKind {
        switch self {
        case .atMe: .mention
        case .replyToMe: .reply
        }
    }

    /// 拼摘要用的那半句。响应里没有正文，只能自己说清发生了什么。
    var verb: String {
        switch self {
        case .atMe: "提到了你"
        case .replyToMe: "回复了你"
        }
    }
}
