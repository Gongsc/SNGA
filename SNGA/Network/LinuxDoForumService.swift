import Foundation

/// Linux.do 的适配器。
///
/// 现在是**只读骨架**：类别、话题列表、话题与楼层、用户资料、「我是谁」。其余一律抛
/// `.unsupported`，能力位也只点亮了 `.subforums`，界面不会画出那些按钮。往后一层一层加，
/// 每加一层点亮一位。依据和还没做的事见 `Design/SiteProbe-LinuxDo.md`。
///
/// 传输约束（实测）：站前的 Cloudflare 对匿名请求话题详情必挑战，登录后的会话搬给
/// `URLSession` 能过，前提是 WebView 的真实 UA 加上这个域下的全部 cookie。
actor LinuxDoForumService: ForumService {
    nonisolated let accountID: AccountID
    nonisolated let site: ForumSite = .linuxdo

    /// 一条条写，不写 `.all`（CLAUDE.md 里 NGA 那次教训）。
    ///
    /// 站点其实有的、只是还没接的：点赞和表情回应（`.postVote`，没有踩）、引用回复、
    /// 投票、私信、提醒、书签（`.topicFavorites`，不分文件夹）、用户动态、登录后的搜索。
    /// 站点没有的：签到、版面收藏（「关注类别」是通知级别）、IP 属地、匿名、评分。
    nonisolated let capabilities: ForumCapabilities = [
        .subforums, .userActivities, .globalSearch, .privateMessages, .notifications, .postVote
    ]

    private let client: LinuxDoNetworkClient
    private let parser = LinuxDoParser()
    /// 「我是谁」一个会话里不会变。
    private var cachedUserID: Int64?
    /// 类别表。拼列表地址要 slug 路径（省一次 302），挂子类别要知道谁是谁的父亲。
    private var categories: [LinuxDoParser.Category]?
    /// 编号 → 用户名。站点按名字认人（用户动态、完整资料的地址都要名字），应用按编号。
    /// 一个会话里名字基本不变；万一改了，取回来的资料会对不上编号，那时候按编号的那一边为准。
    private var usernames: [Int64: String] = [:]
    /// 侧边栏标签。拼地址要 slug，列表页要知道标签叫什么。
    private var tags: [LinuxDoParser.Tag]?
    /// 话题的楼层编号流。翻第二页起要靠它知道该取哪几楼；第一页一来就刷新。
    private var streams: [TopicID: (topic: Topic, stream: [Int64])] = [:]

    init(
        accountID: AccountID,
        cookies: [SessionCookie],
        transport: any HTTPTransport = URLSessionTransport(),
        userAgent: String,
        cookieDidChange: @escaping @Sendable ([SessionCookie]) async -> Void = { _ in }
    ) {
        self.accountID = accountID
        self.client = LinuxDoNetworkClient(
            cookies: cookies,
            transport: transport,
            userAgent: userAgent,
            cookieDidChange: cookieDidChange
        )
    }

    private func notYet(_ what: String) -> ForumServiceError {
        .unsupported("LINUX DO 的\(what)还没做")
    }

    // MARK: - 已实现

    func currentUserID() async throws -> Int64 {
        if let cachedUserID { return cachedUserID }
        let me = try parser.currentUser(json: await client.get(LinuxDoEndpoint.sessionCurrent))
        cachedUserID = me.id
        if !me.username.isEmpty { usernames[me.id] = me.username }
        return me.id
    }

    private func currentUsername() async throws -> String {
        try await username(of: currentUserID())
    }

    /// 两步：卡片接口把编号换成用户名，再拿用户名取完整资料。
    ///
    /// 应用按编号认人，完整资料的地址却要用户名；卡片接口收编号，但在应用里看别人时只给
    /// 六个字段（见 `LinuxDoParser.profile`）。第二步取不到时退回第一步那份 —— 少几行，
    /// 总比整页资料打不开强。取消照常往外抛，不当成失败吞掉。
    func profile(uid: Int64) async throws -> Profile {
        let card = try parser.profile(json: await client.get(LinuxDoEndpoint.userCards(uids: [uid])), uid: uid)
        if !card.displayName.isEmpty { usernames[uid] = card.displayName }
        guard let url = LinuxDoEndpoint.userProfile(username: card.displayName),
              !card.displayName.isEmpty else {
            return card
        }
        do {
            var full = try parser.fullProfile(json: await client.get(url))
            // 以编号为准：用户名改过的话，名字取到的可能是另一个人。
            guard full.uid == uid else { return card }
            full.avatarURL = full.avatarURL ?? card.avatarURL
            return full
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            await RuntimeLogger.shared.log(
                category: "linuxdo",
                "完整资料取不到，退回卡片：\(error.localizedDescription)"
            )
            return card
        }
    }

    /// 和网页侧边栏同一个结构：「社区」里的「话题」、顶层「类别」、「标签」。
    ///
    /// 子类别不进这张表，只在打开父类别时出现在「子类别」那一格里。登录之后几乎每个
    /// 顶层类别底下都挂着一个「某某, Lv1」（信任等级 1 才看得到的分区，实测 14 个），
    /// 平铺出来就是把整张表又列了一遍 —— 用户看到的是一份重复的版面列表。
    /// 类别表本身仍然全量留着：站内链接直接跳进子类别时，拼地址要它的 slug。
    ///
    /// 标签取不到不挡类别：那一段少了，版面照样能逛。
    func forums() async throws -> [Forum] {
        let categories = try await loadCategories().filter { $0.parentID == nil }.map(\.forum)
        let tags = ((try? await loadTags()) ?? []).map(\.forum)
        return [Self.latestForum] + categories + tags
    }

    /// 网页侧边栏「社区」那一段的第一项「话题」，地址是 `/latest`。不是站点的类别。
    static let latestForum = Forum(
        id: LinuxDoEndpoint.forumID(key: LinuxDoEndpoint.latestKey),
        name: "话题",
        subtitle: "全站按最后回复时间排列",
        category: "社区"
    )

    /// `featuredOnly` 无处可去：站点没有精华。界面上那个开关由 NGA 的能力驱动，收到了也只能忽略。
    func topics(
        forumID: ForumID,
        page: Int,
        sortOrder: TopicListSortOrder,
        featuredOnly: Bool
    ) async throws -> ForumPage {
        if forumID.key == LinuxDoEndpoint.latestKey {
            var result = try parser.topicList(
                json: await client.get(LinuxDoEndpoint.topicList(
                    forumID: forumID, slugPath: nil, page: page, sortOrder: sortOrder
                )),
                forumID: forumID,
                page: page
            )
            result.forum = Self.latestForum
            return result
        }
        // 标签：取不到标签表也照样发，没有 slug 就只用编号（站点也认）。
        if LinuxDoEndpoint.tagID(of: forumID) != nil {
            let entry = ((try? await loadTags()) ?? []).first { $0.forum.id == forumID }
            var result = try parser.topicList(
                json: await client.get(LinuxDoEndpoint.topicList(
                    forumID: forumID, slugPath: entry?.slug, page: page, sortOrder: sortOrder
                )),
                forumID: forumID,
                page: page
            )
            result.forum = entry?.forum
            return result
        }
        // 类别表取不到时不挡列表：没有 slug 就走纯编号的地址（多一次 302），没有子类别就不挂。
        let table = (try? await loadCategories()) ?? []
        let entry = table.first { $0.forum.id == forumID }
        let url = LinuxDoEndpoint.topicList(
            forumID: forumID,
            slugPath: entry?.slugPath,
            page: page,
            sortOrder: sortOrder
        )
        var result = try parser.topicList(
            json: await client.get(url),
            forumID: forumID,
            page: page,
            subforums: table.filter { $0.parentID == forumID }.map(\.forum)
        )
        result.forum = entry?.forum
        return result
    }

    /// 一页楼层。
    ///
    /// 站点不分页，见 `LinuxDoEndpoint.postsPerPage`。第一页走详情接口（顺带拿到全部楼层编号），
    /// 往后每页按编号批量取一次。翻到后面的页时如果还没有那条编号流（比如从站内链接直接跳到
    /// 第 3 页），先补一次详情。
    ///
    /// `authorUID` 用不上：「只看楼主」还没接（站点那边是 `username_filters`，要名字不要编号）。
    func threadPage(topicID: TopicID, page: Int, authorUID: Int64?) async throws -> ThreadPage {
        let page = max(1, page)
        var prefetched: [Post] = []
        if page == 1 || streams[topicID] == nil {
            let detail = try parser.topicDetail(json: await client.get(LinuxDoEndpoint.topic(topicID)))
            streams[topicID] = (detail.topic, detail.stream)
            prefetched = detail.posts
        }
        guard let (topic, stream) = streams[topicID] else { throw ForumServiceError.invalidResponse }

        let perPage = LinuxDoEndpoint.postsPerPage
        let totalPages = max(1, (stream.count + perPage - 1) / perPage)
        let start = (page - 1) * perPage
        let wanted = start < stream.count ? Array(stream[start..<min(start + perPage, stream.count)]) : []

        // 详情接口带回来的那一块里有的就不再取；缺的（通常是第二页起的全部）批量取一次。
        let have = Dictionary(prefetched.map { ($0.id.rawValue, $0) }, uniquingKeysWith: { first, _ in first })
        let missing = wanted.filter { have[$0] == nil }
        var fetched: [Int64: Post] = [:]
        if !missing.isEmpty {
            for post in try parser.posts(
                json: await client.get(LinuxDoEndpoint.topicPosts(topicID, postIDs: missing)),
                topicID: topicID
            ) {
                fetched[post.id.rawValue] = post
            }
        }
        // 按编号流的顺序排。被删掉或看不了的楼站点不会给，那一格就空着，不编造。
        let posts = wanted.compactMap { have[$0] ?? fetched[$0] }
        return ThreadPage(
            topic: topic,
            posts: posts,
            page: page,
            hasMore: page < totalPages,
            totalPages: totalPages
        )
    }

    /// 先要用户自己放进侧边栏的那几个；一个都没有（没设过）就退到站点的热门标签 ——
    /// 网页侧边栏也是这么退的。
    private func loadTags() async throws -> [LinuxDoParser.Tag] {
        if let tags { return tags }
        var loaded = try parser.sidebarTags(sessionJSON: await client.get(LinuxDoEndpoint.sessionCurrent))
        if loaded.isEmpty {
            loaded = try parser.siteTopTags(siteJSON: await client.get(LinuxDoEndpoint.site))
        }
        tags = loaded
        return loaded
    }

    private func loadCategories() async throws -> [LinuxDoParser.Category] {
        if let categories { return categories }
        let loaded = try parser.categories(json: await client.get(LinuxDoEndpoint.categories))
        categories = loaded
        return loaded
    }

    /// 某人发的话题或回复。地址要用户名，没记着就先拿卡片接口换一次。
    func userActivities(uid: Int64, kind: UserActivityKind, page: Int) async throws -> UserActivityPage {
        let name = try await username(of: uid)
        var result = try parser.userActivities(
            json: await client.get(LinuxDoEndpoint.userActions(username: name, kind: kind, page: page)),
            kind: kind,
            page: page
        )
        // 版面名从类别表里补；表还没拉过就不为它多发一次请求。
        if let categories {
            let names = Dictionary(categories.map { ($0.forum.id, $0.forum.name) }, uniquingKeysWith: { first, _ in first })
            for index in result.activities.indices {
                result.activities[index].forumName = result.activities[index].forumID.flatMap { names[$0] }
            }
        }
        return result
    }

    /// 搜索。两档（话题和帖子 / 仅标题），可以按作者和日期筛，可以缩在一个类别里。
    ///
    /// 这个站的搜索要登录（匿名时 `site.json` 答 `can_search: false`），而这个服务本来就只在
    /// 登录后存在，所以不另做检查。
    func search(_ request: ForumSearchRequest, page: Int) async throws -> ForumSearchPage {
        guard request.kind == .topicContent || request.kind == .topicSubject else {
            throw ForumServiceError.unsupported("LINUX DO 的搜索只搜话题和帖子")
        }
        var slugPath: String?
        if let forumID = request.forumID {
            guard LinuxDoEndpoint.tagID(of: forumID) == nil, forumID.key != LinuxDoEndpoint.latestKey else {
                throw ForumServiceError.unsupported("LINUX DO 只能在类别里搜，标签里搜不了")
            }
            slugPath = (try? await loadCategories())?.first { $0.forum.id == forumID }?.slugPath
            // 拿不到 slug 就缩不进这个类别。宁可报错，也不能悄悄变成全站搜索 ——
            // 范围上写着「当前版面」，结果却是全站，那是一句谎。
            guard slugPath != nil else {
                throw ForumServiceError.unsupported("找不到这个类别，没法在里面搜")
            }
        }
        let url = LinuxDoEndpoint.search(
            query: request.query,
            titleOnly: request.kind == .topicSubject,
            categorySlugPath: slugPath,
            author: request.filters.trimmedAuthor,
            postedAfter: request.filters.postedAfter,
            postedBefore: request.filters.postedBefore,
            page: page
        )
        return try parser.search(json: await client.get(url), request: request, page: page)
    }

    private func username(of uid: Int64) async throws -> String {
        if let known = usernames[uid] { return known }
        let card = try parser.profile(json: await client.get(LinuxDoEndpoint.userCards(uids: [uid])), uid: uid)
        guard !card.displayName.isEmpty else {
            throw ForumServiceError.restricted("找不到这个用户")
        }
        usernames[uid] = card.displayName
        return card.displayName
    }

    // MARK: - 消息

    func messages(folder: MessageFolder, page: Int) async throws -> MessagePage {
        switch folder {
        case .notifications:
            return try parser.notifications(json: await client.get(LinuxDoEndpoint.notifications(page: page)), page: page)
        case .privateMessages:
            let name = try await currentUsername()
            return try parser.privateMessages(
                json: await client.get(LinuxDoEndpoint.privateMessages(username: name, page: page)),
                page: page
            )
        }
    }

    /// 一段私信。`id` 是私信那个话题的编号（列表和私信类提醒都这么给）。
    ///
    /// 详情接口只带回前 20 楼；私信一般不长，剩下的按编号补齐，每 20 楼一次，最多补到
    /// 200 楼 —— 再长就是一个当论坛用的私信，后面的楼到网页上看。
    func message(id: MessageID) async throws -> ForumMessage {
        let topicID = TopicID(rawValue: id.rawValue)
        let data = try await client.get(LinuxDoEndpoint.topic(topicID))
        let detail = try parser.topicDetail(json: data)
        let loaded = Set(detail.posts.map(\.id.rawValue))
        let missing = Array(detail.stream.filter { !loaded.contains($0) }.prefix(180))
        var extra: [Post] = []
        for start in stride(from: 0, to: missing.count, by: LinuxDoEndpoint.postsPerPage) {
            let chunk = Array(missing[start..<min(start + LinuxDoEndpoint.postsPerPage, missing.count)])
            extra += try parser.posts(
                json: await client.get(LinuxDoEndpoint.topicPosts(topicID, postIDs: chunk)),
                topicID: topicID
            )
        }
        return try parser.privateMessage(json: data, extraPosts: extra)
    }

    /// 回复一段私信：就是在那个话题里发一楼。
    func replyMessage(id: MessageID, content: String) async throws {
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw ForumServiceError.unsupported("私信内容不能为空")
        }
        _ = try await client.send("POST", LinuxDoEndpoint.createPost, form: [
            ("raw", text),
            ("topic_id", String(id.rawValue))
        ])
    }

    /// 站点那边的已读。提醒在站点上各有未读状态，不说一声网页端的红点会一直挂着。
    ///
    /// 私信类的不在这里：它们的 `id` 是话题编号不是提醒编号（见 `LinuxDoParser.notifications`），
    /// 拿去标提醒会标错别的。私信在站点上的已读是「读到第几楼」，打开那段私信时网页才会记，
    /// 应用里先只管本地这一侧。
    func markRead(_ messages: [ForumMessage]) async throws {
        for message in messages where message.isUnread && message.kind != .privateMessage {
            _ = try await client.send("PUT", LinuxDoEndpoint.markNotificationsRead, form: [
                ("id", String(message.id.rawValue))
            ])
        }
    }

    /// 全部已读。只有提醒有这一招（不带参数的 PUT）；私信那边没有对应的接口。
    func markAllRead(folder: MessageFolder) async throws {
        guard folder == .notifications else { return }
        _ = try await client.send("PUT", LinuxDoEndpoint.markNotificationsRead)
    }

    // MARK: - 表态

    /// 赞。只有一个方向 —— 站点没有踩（`.postDownvote` 关着）。
    ///
    /// 楼层上画的是回应那一排（❤️ 走 `submitPostReaction`），这条路只在一层楼没有回应
    /// 数据时才会被用到；照样接上，不让它报「还没做」。
    ///
    /// 撤赞在点过一段时间之后站点会拒（「您无法再移除您自己的赞了」），那句话原样报出来。
    func vote(topicID: TopicID, postID: PostID, direction: PostVoteDirection, isUndo: Bool) async throws -> PostVoteState {
        guard direction == .up else {
            throw ForumServiceError.unsupported("LINUX DO 没有踩")
        }
        let data: Data
        if isUndo {
            data = try await client.send("DELETE", LinuxDoEndpoint.undoPostAction(postID: postID))
        } else {
            data = try await client.send("POST", LinuxDoEndpoint.postActions, form: [
                ("id", String(postID.rawValue)),
                ("post_action_type_id", "2"),
                ("flag_topic", "false")
            ])
        }
        // 答回来的是那一楼。读不出新数时不当失败：请求已经被站点收下了，
        // 报「失败」会让人再点一次。交给调用方保留它先改上去的数。
        guard let state = try? parser.voteState(json: data) else {
            throw ForumServiceError.ambiguousWrite
        }
        return state
    }

    /// 回应：加和撤是同一个请求，站点按「我现在点没点过」自己翻转。
    ///
    /// 返回 nil：调用方本来就会整页刷新，让站点的数说了算。
    func submitPostReaction(topicID: TopicID, postID: PostID, reactionID: String) async throws -> PostVoteState? {
        guard LinuxDoParser.reactionCatalog.contains(where: { $0.id == reactionID }) else {
            throw ForumServiceError.unsupported("LINUX DO 没有这种回应")
        }
        _ = try await client.send("PUT", LinuxDoEndpoint.toggleReaction(postID: postID, reactionID: reactionID))
        return nil
    }

    // MARK: - 还没做的

    func submitReply(topicID: TopicID, submission: ReplySubmission) async throws -> PostID? {
        // 接的时候别忘了 `reply_cost`：大于 0 的话题回复要扣积分，得先让用户确认。
        throw notYet("回复")
    }


    func submitTopicPollVote(topicID: TopicID, optionIDs: [String]) async throws {
        throw notYet("投票")
    }


    func favoriteTopicFolders() async throws -> [TopicFavoriteFolder] {
        throw notYet("书签")
    }

    func favoriteTopics(folderID: String, page: Int) async throws -> ForumPage {
        throw notYet("书签")
    }

    func updateTopicFavorite(topicID: TopicID, folderID: String, isFavorite: Bool) async throws {
        throw notYet("书签")
    }

    func createTopicFavoriteFolder(name: String, isPublic: Bool, isDefault: Bool) async throws -> String? {
        throw ForumServiceError.unsupported("LINUX DO 的书签不分文件夹")
    }

    func updateTopicFavoriteFolder(_ folder: TopicFavoriteFolder) async throws {
        throw ForumServiceError.unsupported("LINUX DO 的书签不分文件夹")
    }

    func deleteTopicFavoriteFolder(folderID: String) async throws {
        throw ForumServiceError.unsupported("LINUX DO 的书签不分文件夹")
    }

    func checkInStatus() async throws -> CheckInStatistics {
        throw ForumServiceError.unsupported("LINUX DO 没有每日签到")
    }

    func checkIn() async throws -> CheckInResult {
        throw ForumServiceError.unsupported("LINUX DO 没有每日签到")
    }
}
