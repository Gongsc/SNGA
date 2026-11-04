import Foundation
import SwiftSoup

/// Linux.do（Discourse）的解析器。无状态。
///
/// 和另外三个站不同，这里吃的全是 JSON —— 站点几乎每个页面加 `.json` 就是它的数据。
/// 只有楼层正文是 HTML（`cooked`，服务端把 Markdown 渲染好的结果），要清洗了才能进
/// `WKWebView` 或交给 `PostContentBuilder`。
///
/// 字段形状都对着 `SNGATests/Fixtures/linuxdo-*.json` 的真实响应（2026-11-04 抓取，
/// 用户名和用户编号已替换）。用不到的字段一律不声明 —— Discourse 的话题对象有 75 个
/// 字段，声明得越多，站点改一个不相干的字段就越可能让整页解析失败。
struct LinuxDoParser: Sendable {

    // MARK: - 当前用户

    /// `/session/current.json` → 编号。会话不被认时站点答的是 404 或者没有 `current_user`，
    /// 两种都当作要重新登录。
    func currentUserID(json data: Data) throws -> Int64 {
        try currentUser(json: data).id
    }

    /// 编号和用户名一起：私信收件箱的地址要名字。
    func currentUser(json data: Data) throws -> (id: Int64, username: String) {
        let response = try decode(SessionCurrentResponse.self, from: data, what: "当前用户")
        guard let user = response.currentUser else { throw ForumServiceError.requiresLogin }
        return (user.id, user.username ?? "")
    }

    // MARK: - 类别

    /// 一个类别连同它的 slug 路径（子类别是「父/子」）。
    ///
    /// slug 路径不进 `Forum`：它只是拼地址时省一次 302 用的，`ForumID` 用编号就够。
    struct Category: Sendable, Hashable {
        var forum: Forum
        var slugPath: String
        var parentID: ForumID?
    }

    /// `/categories.json?include_subcategories=true` → 顶层类别和子类别，子类别紧跟在父类别后面。
    func categories(json data: Data) throws -> [Category] {
        let response = try decode(CategoryListResponse.self, from: data, what: "类别列表")
        var result: [Category] = []
        for top in response.categoryList.categories {
            let topID = LinuxDoEndpoint.forumID(categoryID: top.id)
            result.append(Category(
                forum: Forum(
                    id: topID,
                    name: top.name,
                    subtitle: Self.nonEmpty(top.descriptionText),
                    category: "类别"
                ),
                slugPath: top.slug
            ))
            for child in top.subcategoryList ?? [] {
                result.append(Category(
                    forum: Forum(
                        id: LinuxDoEndpoint.forumID(categoryID: child.id),
                        name: Self.subcategoryName(child.name, parentName: top.name),
                        subtitle: Self.nonEmpty(child.descriptionText),
                        category: "类别",
                        isSubforum: true
                    ),
                    slugPath: "\(top.slug)/\(child.slug)",
                    parentID: topID
                ))
            }
        }
        guard !result.isEmpty else {
            throw ForumServiceError.unexpectedPage("类别列表是空的")
        }
        return result
    }

    /// 子类别显示时去掉重复的父类别名。
    ///
    /// 站点把等级分区命名成「开发调优, Lv1」（实测，半角逗号加空格），放在「开发调优」底下的
    /// 「子类别」那一格里再写一遍父名是多余的，只留「Lv1」。不是这种写法的（「网盘资源」）原样。
    static func subcategoryName(_ name: String, parentName: String) -> String {
        for separator in [", ", "，", ","] {
            let prefix = parentName + separator
            if name.hasPrefix(prefix) {
                let rest = name.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
                if !rest.isEmpty { return rest }
            }
        }
        return name
    }

    // MARK: - 标签

    /// 侧边栏里的一个标签。和类别一样，slug 只用来拼地址。
    struct Tag: Sendable, Hashable {
        var forum: Forum
        var slug: String
    }

    /// 用户自己在侧边栏里放的标签（`/session/current.json` 的 `current_user.sidebar_tags`）。
    ///
    /// 网页侧边栏「标签」那一段画的就是这一份（2026-11-04 实测，7 个），所以「全部版面」照它来，
    /// 而不是去列站点几千个标签。没登录或没设时给空，由调用方退到站点的热门标签。
    func sidebarTags(sessionJSON data: Data) throws -> [Tag] {
        let response = try decode(SessionCurrentResponse.self, from: data, what: "侧边栏标签")
        return Self.tags(response.currentUser?.sidebarTags ?? [])
    }

    /// 站点给的热门标签（`/site.json` 的 `navigation_menu_site_top_tags`）。
    func siteTopTags(siteJSON data: Data) throws -> [Tag] {
        Self.tags(try decode(SiteResponse.self, from: data, what: "站点标签").navigationMenuSiteTopTags ?? [])
    }

    /// 网页侧边栏按名字排（「抽奖、公告、集中帖、精华神帖、快问快答、人工智能、原创」——
    /// 是拼音序，不是接口给的顺序），照着排。
    private static func tags(_ items: [TagItem]) -> [Tag] {
        let collation = Locale(identifier: "zh_Hans_CN")
        return items
            .filter { !($0.pmOnly ?? false) }
            .sorted { $0.name.compare($1.name, locale: collation) == .orderedAscending }
            .map { item in
                Tag(
                    forum: Forum(
                        id: LinuxDoEndpoint.forumID(tagID: item.id),
                        name: item.name,
                        subtitle: Self.nonEmpty(item.description.map(Self.plainText)),
                        category: "标签"
                    ),
                    slug: item.slug ?? String(item.id)
                )
            }
    }

    // MARK: - 话题列表

    /// 一页话题列表。
    ///
    /// - `forumID`：请求的是哪个版面。话题自己的 `category_id` 记在 `sourceForumID` 上 ——
    ///   父类别的列表里混着子类别的话题（实测），界面靠它把子类别筛出去。
    /// - `subforums`：这个类别底下的子类别，原样挂到 `ForumPage.subforums` 上。
    func topicList(
        json data: Data,
        forumID: ForumID,
        page: Int,
        subforums: [Forum] = []
    ) throws -> ForumPage {
        let response = try decode(TopicListResponse.self, from: data, what: "话题列表")
        let users = Dictionary(
            (response.users ?? []).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let topics = response.topicList.topics.map { item -> Topic in
            // 第一个发帖人就是楼主；站点在 `description` 里写着「原始发帖人」，
            // 但那是本地化文字，按位置认更稳。
            let opUID = item.posters?.first?.userID
            let op = opUID.flatMap { users[$0] }
            return Topic(
                id: TopicID(rawValue: item.id),
                forumID: forumID,
                subject: item.title,
                author: op?.username ?? "",
                authorUID: opUID.flatMap { $0 > 0 ? $0 : nil },
                replyCount: max(0, item.postsCount - 1),
                publishedAt: Self.date(item.createdAt),
                lastReplyAt: Self.date(item.lastPostedAt ?? item.bumpedAt),
                isPinned: item.pinned ?? false,
                isLocked: (item.closed ?? false) || (item.archived ?? false),
                sourceForumID: item.categoryID.map(LinuxDoEndpoint.forumID(categoryID:))
            )
        }
        let hasMore = response.topicList.moreTopicsURL != nil
        let page = max(1, page)
        return ForumPage(
            forum: nil,
            topics: topics,
            page: page,
            hasMore: hasMore,
            // 站点不报总页数，只说还有没有下一页。
            totalPages: hasMore ? page + 1 : page,
            subforums: subforums.map { forum in
                var forum = forum
                // **一律勾上。** 站点在服务端就把子类别的话题聚合进来了，留空的话
                // 界面会把它们统统筛掉 —— V2EX 的聚合节点踩过同一个坑。
                forum.isSelectedInParent = true
                return forum
            }
        )
    }

    // MARK: - 话题与楼层

    /// 话题详情里应用要的那几样：话题本身、全部楼层编号、带回来的那一块楼层。
    struct TopicDetail: Sendable {
        var topic: Topic
        /// 全部楼层编号，按楼层顺序。应用靠它自己切页。
        var stream: [Int64]
        /// 详情接口顺手带回来的楼层（前 20 楼）。
        var posts: [Post]
    }

    func topicDetail(json data: Data) throws -> TopicDetail {
        let response = try decode(TopicDetailResponse.self, from: data, what: "话题")
        let topicID = TopicID(rawValue: response.id)
        let creator = response.details?.createdBy
        let topic = Topic(
            id: topicID,
            forumID: response.categoryID.map(LinuxDoEndpoint.forumID(categoryID:))
                ?? ForumID.placeholder(site: .linuxdo),
            subject: response.title,
            author: creator?.username ?? "",
            authorUID: creator?.id ?? response.userID,
            replyCount: max(0, response.postsCount - 1),
            publishedAt: Self.date(response.createdAt),
            lastReplyAt: Self.date(response.lastPostedAt),
            isPinned: response.pinned ?? false,
            isLocked: (response.closed ?? false) || (response.archived ?? false)
        )
        let posts = try response.postStream.posts.map { try post(from: $0, topicID: topicID) }
        return TopicDetail(
            topic: topic,
            // 极少数情况下站点不给 `stream`（比如只看某人时），那就只有带回来的这些。
            stream: response.postStream.stream ?? posts.map(\.id.rawValue),
            posts: posts
        )
    }

    /// `/t/{id}/posts.json?post_ids[]=…` → 楼层。顺序按楼层号排，不按站点返回的顺序。
    func posts(json data: Data, topicID: TopicID) throws -> [Post] {
        let response = try decode(PostsResponse.self, from: data, what: "楼层")
        return try response.postStream.posts
            .map { try post(from: $0, topicID: topicID) }
            .sorted { $0.floor < $1.floor }
    }

    private func post(from item: PostItem, topicID: TopicID) throws -> Post {
        let body = try Self.sanitizedBody(item.cooked)
        return Post(
            id: PostID(rawValue: item.id),
            topicID: topicID,
            // 应用的楼层从 0 数（主楼是 0），站点的 `post_number` 从 1 数。
            floor: max(0, item.postNumber - 1),
            author: item.username,
            authorUID: item.userID.flatMap { $0 > 0 ? $0 : nil },
            avatarURL: LinuxDoEndpoint.avatarURL(template: item.avatarTemplate),
            postedAt: Self.date(item.createdAt),
            html: PostDocument.html(body: body, extraCSS: PostDocument.markdownStyleSheet),
            nativeContent: try Self.nativeContent(body),
            // 赞是 `actions_summary` 里编号 2 的那一项（`site.json` 的 `post_action_types`，实测）。
            // 装了回应插件之后它是**所有回应加起来**的数（实测：86 个 ❤️ + 22 个别的 = 108），
            // 所以界面上画的是下面那一排各自的数，不画这一个。
            upvoteCount: item.actionsSummary?.first { $0.id == 2 }?.count ?? 0,
            userVote: Self.hasLiked(item) ? .up : nil,
            reactions: Self.reactions(of: item)
        )
    }

    /// 站点开放的回应（话题详情的 `valid_reactions`，2026-11-04 实测这 10 个）。
    ///
    /// 表情字符和叫法是应用这边配的：站点只给名字（`laughing`）。最后两个是站点自定义的
    /// 贴吧、B 站表情图，没有对应的字符，退回一个系统图标。`distorted_face` 是新近才进
    /// Unicode 的，系统字体未必画得出，也退回图标。
    static let reactionCatalog: [(id: String, title: String, emoji: String?)] = [
        ("heart", "赞", "❤️"),
        ("+1", "赞同", "👍"),
        ("laughing", "大笑", "😆"),
        ("open_mouth", "惊讶", "😮"),
        ("clap", "鼓掌", "👏"),
        ("confetti_ball", "庆祝", "🎊"),
        ("hugs", "拥抱", "🤗"),
        ("distorted_face", "无语", nil),
        ("tieba_087", "贴吧表情", nil),
        ("bili_057", "B 站表情", nil)
    ]

    /// 楼层下那一排回应：❤️ 总是在（它就是这个站的「赞」），其余只列有人点过的和我点过的 ——
    /// 网页上也是只摆有数的，再加一个选择器。十个全摆出来，一层楼的右下角就挤满了。
    ///
    /// 全部走回应插件的切换接口（`routesToVote: false`），包括 ❤️：插件把 ❤️ 当成主回应，
    /// 和核心的「赞」是一回事。点完整页刷新，数以站点为准。
    private static func reactions(of item: PostItem) -> [PostReaction] {
        let counts = Dictionary(
            (item.reactions ?? []).map { ($0.id, $0.count ?? 0) },
            uniquingKeysWith: { first, _ in first }
        )
        let mine = item.currentUserReaction?.id
        return reactionCatalog.compactMap { entry in
            let count = counts[entry.id] ?? 0
            let isMine = mine == entry.id || (entry.id == "heart" && item.currentUserUsedMainReaction == true)
            guard entry.id == "heart" || count > 0 || isMine else { return nil }
            return PostReaction(
                id: entry.id,
                title: entry.title,
                systemImage: entry.id == "heart" ? "heart" : "face.smiling",
                count: count,
                isChosen: isMine,
                emoji: entry.emoji,
                routesToVote: false
            )
        }
    }

    /// 我点过赞没有：核心的赞（`actions_summary` 里 `acted`）或者回应插件的主回应。
    private static func hasLiked(_ item: PostItem) -> Bool {
        item.actionsSummary?.contains { $0.id == 2 && $0.acted == true } == true
            || item.currentUserUsedMainReaction == true
    }

    /// 点赞 / 撤赞之后站点答回来的那一楼 → 新的赞数。
    func voteState(json data: Data) throws -> PostVoteState {
        let item = try decode(PostItem.self, from: data, what: "点赞结果")
        return PostVoteState(
            upvoteCount: item.actionsSummary?.first { $0.id == 2 }?.count ?? 0,
            downvoteCount: 0,
            userVote: Self.hasLiked(item) ? .up : nil
        )
    }

    // MARK: - 用户

    /// `/user-cards.json?user_ids={uid}` → 资料（简版）。
    ///
    /// **它只够把编号换成用户名。** 应用登录后看别人时，这里给的那一条只有六个字段
    /// （`id`、`username`、`name`、`avatar_template`、`trust_level`、`animated_avatar`，
    /// 2026-11-04 在应用里实测）—— 没有加入时间、头衔、群组。同一个请求在浏览器里却是全的，
    /// 差在哪没查清。完整资料改走 `/u/{用户名}.json`（`fullProfile`），这一份只当退路。
    ///
    /// 编号相同的几条并起来取，每个字段取第一份有值的：站点的 `users` 是个「本次出现过的人」
    /// 的表，同一个人以不同详略出现几次并不稀奇，挑第一条是在赌顺序。
    func profile(json data: Data, uid: Int64) throws -> Profile {
        let response = try decode(UserCardsResponse.self, from: data, what: "用户资料")
        var entries = response.users.filter { $0.id == uid }
        if entries.isEmpty, let first = response.users.first { entries = [first] }
        guard let user = entries.first else {
            throw ForumServiceError.restricted("找不到这个用户")
        }
        func merged<T>(_ field: (UserCardsResponse.CardUser) -> T?) -> T? {
            entries.lazy.compactMap(field).first
        }
        return Profile(
            uid: user.id,
            displayName: user.username,
            avatarURL: LinuxDoEndpoint.avatarURL(template: merged(\.avatarTemplate), size: 240),
            userGroup: Self.nonEmpty(merged(\.primaryGroupName)),
            level: merged(\.trustLevel),
            title: Self.nonEmpty(merged(\.title)),
            registeredAt: Self.date(merged(\.createdAt)),
            signature: Self.nonEmpty(merged(\.bioExcerpt).map(Self.plainText))
        )
    }

    /// `/u/{用户名}.json` → 完整资料。资料在 `user` 里；同级的 `users` 是精简列表，不看。
    func fullProfile(json data: Data) throws -> Profile {
        let user = try decode(UserProfileResponse.self, from: data, what: "用户资料").user
        return Profile(
            uid: user.id,
            displayName: user.username,
            avatarURL: LinuxDoEndpoint.avatarURL(template: user.avatarTemplate, size: 240),
            userGroup: Self.nonEmpty(user.primaryGroupName),
            level: user.trustLevel,
            title: Self.nonEmpty(user.title),
            registeredAt: Self.date(user.createdAt),
            // 会员自己填的一行字（「咸阳」），不是 IP 属地。界面上标「所在地」。
            location: Self.nonEmpty(user.location),
            signature: Self.nonEmpty(user.bioExcerpt.map(Self.plainText)),
            followerCount: user.totalFollowers,
            followingCount: user.totalFollowing,
            lastSeenAt: Self.date(user.lastSeenAt),
            lastPostedAt: Self.date(user.lastPostedAt),
            profileViewCount: user.profileViewCount,
            points: user.gamificationScore,
            readingSeconds: user.timeRead
        )
    }

    /// 信任等级在站点上的叫法（Discourse 的中文语言包，资料页上写的就是这些）。
    static func trustLevelTitle(_ level: Int) -> String {
        switch level {
        case 0: "新用户"
        case 1: "基本用户"
        case 2: "成员"
        case 3: "活跃用户"
        case 4: "领导者"
        default: "\(level) 级"
        }
    }

    // MARK: - 用户动态

    /// `/user_actions.json` → 某人的话题或回复。
    ///
    /// 站点不报总数，一页给满 30 条就当还有下一页。
    func userActivities(json data: Data, kind: UserActivityKind, page: Int) throws -> UserActivityPage {
        let response = try decode(UserActionsResponse.self, from: data, what: "用户动态")
        let activities = response.userActions.map { item in
            UserActivity(
                id: "\(item.topicId)-\(item.postNumber ?? 0)-\(item.actionType)",
                kind: kind,
                topicID: TopicID(rawValue: item.topicId),
                postID: item.postId.map(PostID.init(rawValue:)),
                forumID: item.categoryId.map(LinuxDoEndpoint.forumID(categoryID:)),
                subject: item.title ?? "",
                excerpt: Self.nonEmpty(item.excerpt.map(Self.plainText)),
                postedAt: Self.date(item.createdAt)
            )
        }
        let hasMore = response.userActions.count >= LinuxDoEndpoint.userActionsPerPage
        let page = max(1, page)
        return UserActivityPage(
            kind: kind,
            activities: activities,
            page: page,
            hasMore: hasMore,
            totalPages: hasMore ? page + 1 : page
        )
    }

    // MARK: - 搜索

    /// `/search.json` → 话题。
    ///
    /// 站点按**楼层**给结果（`posts`），同一个话题可能命中好几楼；应用的搜索页列的是话题，
    /// 所以按命中的先后去重。作者只在命中的是主楼时才填 —— 命中第 30 楼时那一楼的作者
    /// 不是楼主，写上去就是在说错话。
    func search(json data: Data, request: ForumSearchRequest, page: Int) throws -> ForumSearchPage {
        let response = try decode(SearchResponse.self, from: data, what: "搜索结果")
        let topics = Dictionary(
            (response.topics ?? []).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var seen = Set<Int64>()
        var results: [Topic] = []
        for hit in response.posts ?? [] {
            guard let topic = topics[hit.topicId], seen.insert(hit.topicId).inserted else { continue }
            results.append(Topic(
                id: TopicID(rawValue: topic.id),
                forumID: topic.categoryId.map(LinuxDoEndpoint.forumID(categoryID:))
                    ?? ForumID.placeholder(site: .linuxdo),
                subject: topic.title,
                author: hit.postNumber == 1 ? (hit.username ?? "") : "",
                replyCount: max(0, (topic.postsCount ?? 1) - 1),
                publishedAt: Self.date(topic.createdAt),
                lastReplyAt: Self.date(topic.lastPostedAt ?? topic.bumpedAt),
                isPinned: topic.pinned ?? false,
                isLocked: (topic.closed ?? false) || (topic.archived ?? false),
                sourceForumID: topic.categoryId.map(LinuxDoEndpoint.forumID(categoryID:))
            ))
        }
        let hasMore = response.groupedSearchResult?.moreFullPageResults ?? false
        let page = max(1, page)
        return ForumSearchPage(
            request: request,
            topics: results,
            page: page,
            hasMore: hasMore,
            totalPages: hasMore ? page + 1 : page
        )
    }

    // MARK: - 消息

    /// `/notifications.json` → 提醒。
    ///
    /// 每条有一个类型编号（`site.json` 的 `notification_types`，实测），`data` 里装什么随类型变。
    /// 私信类（6、7）的 `id` 换成那段私信的话题编号：应用点开私信类提醒时调的是
    /// `message(id:)`，那边按话题编号取；拿提醒编号去取会扑空。它们的已读也不在这里同步
    /// （见 `LinuxDoForumService.markRead`），所以换掉编号不影响已读。
    func notifications(json data: Data, page: Int) throws -> MessagePage {
        let response = try decode(NotificationsResponse.self, from: data, what: "提醒")
        let messages = response.notifications.compactMap { item -> ForumMessage? in
            let kind = Self.messageKind(ofNotificationType: item.notificationType)
            let id: Int64
            if kind == .privateMessage {
                guard let topicID = item.topicId else { return nil }
                id = topicID
            } else {
                id = item.id
            }
            let info = item.data
            let subject = info?.topicTitle
                ?? info?.badgeName.map { "获得了徽章「\($0)」" }
                ?? ""
            return ForumMessage(
                id: MessageID(rawValue: id),
                kind: kind,
                sender: info?.displayUsername ?? info?.originalUsername ?? "",
                subject: subject,
                preview: Self.notificationSummary(ofType: item.notificationType),
                sentAt: Self.date(item.createdAt),
                isUnread: !item.read,
                topicID: item.topicId.map(TopicID.init(rawValue:))
            )
        }
        return MessagePage(
            folder: .notifications,
            messages: messages,
            page: max(1, page),
            // 站点不报总数，给满一页就当还有。
            hasMore: response.notifications.count >= LinuxDoEndpoint.notificationsPerPage
        )
    }

    /// 提醒类型 → 应用的消息种类。认不出的归 `.unknown`，照样列出来。
    static func messageKind(ofNotificationType type: Int) -> ForumMessageKind {
        switch type {
        case 1, 15: .mention          // 提到你、提到你所在的群组
        case 2, 9: .reply             // 回复了你、在你关注的话题里发帖
        case 3: .quote
        case 6, 7: .privateMessage    // 私信、被拉进私信
        case 5, 19, 25: .comment      // 赞、赞（合并）、表情回应
        default: .unknown
        }
    }

    /// 列表里那一行小字。站点的提醒没有正文，只有「谁对哪个话题做了什么」。
    static func notificationSummary(ofType type: Int) -> String {
        switch type {
        case 1: "在帖子里提到了你"
        case 15: "提到了你所在的群组"
        case 2: "回复了你"
        case 3: "引用了你的帖子"
        case 5, 19: "赞了你的帖子"
        case 25: "回应了你的帖子"
        case 6: "给你发了私信"
        case 7: "邀请你加入私信"
        case 9: "在你关注的话题里发了帖子"
        case 12: "你获得了新徽章"
        case 17, 36: "发布了新话题"
        default: ""
        }
    }

    /// 私信收件箱 → 消息。私信在站点上是话题，一段私信就是一个话题。
    func privateMessages(json data: Data, page: Int) throws -> MessagePage {
        let response = try decode(TopicListResponse.self, from: data, what: "私信")
        let messages = response.topicList.topics.map { item in
            ForumMessage(
                id: MessageID(rawValue: item.id),
                kind: .privateMessage,
                sender: item.lastPosterUsername ?? "",
                subject: item.title,
                preview: item.postsCount > 1 ? "共 \(item.postsCount) 条" : "",
                sentAt: Self.date(item.lastPostedAt ?? item.bumpedAt),
                // 有没读到的楼就算未读：`unread_posts` 是读过之后又来的，`new_posts` 是从没打开过的。
                isUnread: (item.unreadPosts ?? 0) + (item.newPosts ?? 0) > 0 || (item.unseen ?? false)
            )
        }
        return MessagePage(
            folder: .privateMessages,
            messages: messages,
            page: max(1, page),
            hasMore: response.topicList.moreTopicsURL != nil
        )
    }

    /// 一段私信（话题详情的形状）→ 消息，楼层按顺序摆成一条条消息。
    ///
    /// 只用详情带回来的那一块（前 20 楼）加上调用方补齐的楼层，见 `LinuxDoForumService.message`。
    func privateMessage(json data: Data, extraPosts: [Post] = []) throws -> ForumMessage {
        let detail = try topicDetail(json: data)
        let posts = (detail.posts + extraPosts).sorted { $0.floor < $1.floor }
        return ForumMessage(
            id: MessageID(rawValue: detail.topic.id.rawValue),
            kind: .privateMessage,
            sender: posts.first?.author ?? detail.topic.author,
            subject: detail.topic.subject,
            preview: "",
            sentAt: posts.last?.postedAt ?? detail.topic.lastReplyAt,
            isUnread: false,
            posts: posts.map { post in
                ForumMessagePost(
                    id: MessageID(rawValue: post.id.rawValue),
                    author: post.author,
                    authorUID: post.authorUID,
                    avatarURL: post.avatarURL,
                    sentAt: post.postedAt,
                    html: post.html
                )
            }
        )
    }

    // MARK: - 正文清洗

    /// 把 `cooked` 清洗成能进 `WKWebView`、也能交给 `PostContentBuilder` 的正文。
    ///
    /// 站点的渲染结果里有几样是给它自己的前端用的壳，原样留着既画不对也点不动：
    ///
    /// - 图片外面包着一层灯箱（`div.lightbox-wrapper > a.lightbox > img` 外加一个 `.meta`
    ///   信息条和几个 `svg` 图标）。只留那张图。
    /// - 引用是 `aside.quote`，里面一个 `div.title`（头像、被引的人或话题）加一个 `blockquote`。
    ///   换成一个普通的引用块，抬头那一行写成粗体。
    /// - 链接预览卡片 `aside.onebox` 换成一条链接 —— 卡片的样式全靠站点的 CSS。
    /// - 标题前面那个锚点（`a.anchor`）和所有 `svg` 去掉。
    static func sanitizedBody(_ cooked: String) throws -> String {
        let document = try SwiftSoup.parseBodyFragment(cooked, baseURI)
        document.outputSettings(verbatimOutput)
        guard let body = try document.body() else { return "" }

        for wrapper in try body.select("div.lightbox-wrapper") {
            if let image = try wrapper.select("img").first() {
                try wrapper.before(image)
            }
            try wrapper.remove()
        }
        for quote in try body.select("aside.quote") {
            let header = try quote.select("div.title").first()?.text()
                .trimmingCharacters(in: CharacterSet(charactersIn: ": ：\n\t"))
            let replacement = try document.createElement("blockquote")
            if let header, !header.isEmpty {
                try replacement.appendElement("p").appendElement("strong").text(header)
            }
            if let inner = try quote.select("> blockquote").first() {
                for child in inner.getChildNodes() {
                    try replacement.appendChild(child)
                }
            }
            try quote.replaceWith(replacement)
        }
        for box in try body.select("aside.onebox") {
            let source = try box.attr("data-onebox-src")
            let title = try box.select("h3, h4").first()?.text()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let paragraph = try document.createElement("p")
            if !source.isEmpty {
                try paragraph.appendElement("a").attr("href", source)
                    .text(title.flatMap { $0.isEmpty ? nil : $0 } ?? source)
            }
            try box.replaceWith(paragraph)
        }
        try body.select("svg, a.anchor, .quote-controls, .meta, script, style, iframe, form").remove()

        try resolveRelativeURLs(in: body)
        return try SwiftSoup.clean(try body.html(), baseURI, try whitelist(), verbatimOutput) ?? ""
    }

    /// 能原生画就原生画，画不了返回 nil 交给 `WKWebView`。
    ///
    /// 交给 `PostContentBuilder` 的必须是 **body 元素**，不是整份文档（V2EX 那边踩过）。
    /// 这个站的长帖常带表格、标题和折叠块，那些它还原不了，整层回退是预期之内的。
    private static func nativeContent(_ body: String) throws -> PostContent? {
        let fragment = try SwiftSoup.parseBodyFragment(body)
        fragment.outputSettings(verbatimOutput)
        guard let root = try fragment.body() else { return nil }
        return PostContentBuilder.content(from: root)
    }

    private static func resolveRelativeURLs(in element: Element) throws {
        for image in try element.select("img[src]") {
            let absolute = try image.attr("abs:src")
            if absolute.isEmpty { try image.remove() } else { try image.attr("src", absolute) }
            // `srcset` 里是几张不同尺寸的同一张图，相对地址解不出来，留着只会让 WebView 去抓坏链接。
            try image.removeAttr("srcset")
        }
        for link in try element.select("a[href]") {
            let absolute = try link.attr("abs:href")
            if absolute.hasPrefix("http://") || absolute.hasPrefix("https://") {
                try link.attr("href", absolute)
            } else {
                try link.removeAttr("href")
            }
        }
    }

    private static func whitelist() throws -> Whitelist {
        let whitelist = try Whitelist.relaxed()
        // relaxed 不放行这几个，而站点的正文里常见：删除线、分隔线、折叠块。
        _ = try whitelist.addTags("s", "del", "hr", "details", "summary")
        // 代码块的语言写在类名上；表情图靠 `emoji` 这个类名和普通配图分开。
        _ = try whitelist.addAttributes("code", "class")
        _ = try whitelist.addAttributes("pre", "class")
        _ = try whitelist.addAttributes("img", "class")
        return whitelist
    }

    /// 原样输出：不要 pretty-print，否则 `<pre>` 里会多出换行和缩进。
    private static var verbatimOutput: OutputSettings {
        OutputSettings().prettyPrint(pretty: false)
    }

    private static let baseURI = LinuxDoEndpoint.base.absoluteString

    // MARK: - 小工具

    private func decode<T: Decodable>(_ type: T.Type, from data: Data, what: String) throws -> T {
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(type, from: data)
        } catch {
            throw ForumServiceError.unexpectedPage("\(what)解析失败")
        }
    }

    /// 站点的时间是带毫秒的 ISO 8601（`2026-11-01T02:17:46.149Z`）。
    static func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        return (try? Date(value, strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true)))
            ?? (try? Date(value, strategy: .iso8601))
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    /// 简介摘录里可能夹着几个标签，资料页那一栏是纯文本。
    private static func plainText(_ html: String) -> String {
        (try? SwiftSoup.parseBodyFragment(html).text()) ?? html
    }
}

// MARK: - 响应形状

/// 只声明用得到的字段。全部按 `convertFromSnakeCase` 解码。
private struct SessionCurrentResponse: Decodable {
    struct User: Decodable {
        var id: Int64
        var username: String?
        var sidebarTags: [TagItem]?
    }
    var currentUser: User?
}

private struct TagItem: Decodable {
    var id: Int
    var name: String
    var slug: String?
    var description: String?
    var pmOnly: Bool?
}

private struct SiteResponse: Decodable {
    var navigationMenuSiteTopTags: [TagItem]?
}

private struct CategoryListResponse: Decodable {
    struct CategoryList: Decodable { var categories: [CategoryItem] }
    struct CategoryItem: Decodable {
        var id: Int
        var name: String
        var slug: String
        var descriptionText: String?
        var subcategoryList: [CategoryItem]?
    }
    var categoryList: CategoryList
}

private struct UserItem: Decodable {
    var id: Int64
    var username: String
    var avatarTemplate: String?
}

private struct TopicListResponse: Decodable {
    struct TopicList: Decodable {
        var topics: [TopicItem]
        // `convertFromSnakeCase` 把 `more_topics_url` 变成 `moreTopicsUrl`，不是 `URL`。
        var moreTopicsUrl: String?
        var moreTopicsURL: String? { moreTopicsUrl }
    }
    struct TopicItem: Decodable {
        var id: Int64
        var title: String
        var postsCount: Int
        var createdAt: String?
        var lastPostedAt: String?
        var bumpedAt: String?
        var pinned: Bool?
        var closed: Bool?
        var archived: Bool?
        var categoryId: Int?
        var posters: [Poster]?
        // 私信列表才有的几样。
        var lastPosterUsername: String?
        var unreadPosts: Int?
        var newPosts: Int?
        var unseen: Bool?
        var categoryID: Int? { categoryId }
    }
    struct Poster: Decodable {
        var userId: Int64?
        var userID: Int64? { userId }
    }
    var users: [UserItem]?
    var topicList: TopicList
}

private struct PostItem: Decodable {
    struct Action: Decodable {
        var id: Int
        var count: Int?
        var acted: Bool?
    }
    struct Reaction: Decodable {
        var id: String
        var count: Int?
    }
    struct CurrentReaction: Decodable {
        var id: String
    }
    var reactions: [Reaction]?
    var currentUserReaction: CurrentReaction?
    var currentUserUsedMainReaction: Bool?
    var id: Int64
    var username: String
    var avatarTemplate: String?
    var createdAt: String?
    var cooked: String
    var postNumber: Int
    var userId: Int64?
    var actionsSummary: [Action]?
    var userID: Int64? { userId }
}

private struct TopicDetailResponse: Decodable {
    struct PostStream: Decodable {
        var posts: [PostItem]
        var stream: [Int64]?
    }
    struct Details: Decodable {
        var createdBy: UserItem?
    }
    var id: Int64
    var title: String
    var postsCount: Int
    var createdAt: String?
    var lastPostedAt: String?
    var categoryId: Int?
    var userId: Int64?
    var pinned: Bool?
    var closed: Bool?
    var archived: Bool?
    var postStream: PostStream
    var details: Details?
    var categoryID: Int? { categoryId }
    var userID: Int64? { userId }
}

private struct PostsResponse: Decodable {
    struct PostStream: Decodable { var posts: [PostItem] }
    var postStream: PostStream
}

private struct UserProfileResponse: Decodable {
    struct FullUser: Decodable {
        var id: Int64
        var username: String
        var avatarTemplate: String?
        var createdAt: String?
        var lastSeenAt: String?
        var lastPostedAt: String?
        var trustLevel: Int?
        var title: String?
        var primaryGroupName: String?
        var location: String?
        var bioExcerpt: String?
        var totalFollowers: Int?
        var totalFollowing: Int?
        var profileViewCount: Int?
        var gamificationScore: Int?
        var timeRead: Int?
    }
    var user: FullUser
}

private struct NotificationsResponse: Decodable {
    struct Item: Decodable {
        struct Payload: Decodable {
            var topicTitle: String?
            var displayUsername: String?
            var originalUsername: String?
            var badgeName: String?
        }
        var id: Int64
        var notificationType: Int
        var read: Bool
        var createdAt: String?
        var topicId: Int64?
        var data: Payload?
    }
    var notifications: [Item]
}

private struct UserActionsResponse: Decodable {
    struct Item: Decodable {
        var actionType: Int
        var topicId: Int64
        var postId: Int64?
        var postNumber: Int?
        var categoryId: Int?
        var title: String?
        var excerpt: String?
        var createdAt: String?
    }
    var userActions: [Item]
}

private struct SearchResponse: Decodable {
    struct Hit: Decodable {
        var topicId: Int64
        var postNumber: Int?
        var username: String?
    }
    struct TopicItem: Decodable {
        var id: Int64
        var title: String
        var postsCount: Int?
        var categoryId: Int?
        var createdAt: String?
        var lastPostedAt: String?
        var bumpedAt: String?
        var pinned: Bool?
        var closed: Bool?
        var archived: Bool?
    }
    struct Grouped: Decodable {
        var moreFullPageResults: Bool?
    }
    var posts: [Hit]?
    var topics: [TopicItem]?
    var groupedSearchResult: Grouped?
}

private struct UserCardsResponse: Decodable {
    struct CardUser: Decodable {
        var id: Int64
        var username: String
        var avatarTemplate: String?
        var createdAt: String?
        var trustLevel: Int?
        var title: String?
        var primaryGroupName: String?
        var bioExcerpt: String?
    }
    var users: [CardUser]
}
