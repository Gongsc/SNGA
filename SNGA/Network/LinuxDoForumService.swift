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
    nonisolated let capabilities: ForumCapabilities = [.subforums]

    private let client: LinuxDoNetworkClient
    private let parser = LinuxDoParser()
    /// 「我是谁」一个会话里不会变。
    private var cachedUserID: Int64?
    /// 类别表。拼列表地址要 slug 路径（省一次 302），挂子类别要知道谁是谁的父亲。
    private var categories: [LinuxDoParser.Category]?
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
        let uid = try parser.currentUserID(json: await client.get(LinuxDoEndpoint.sessionCurrent))
        cachedUserID = uid
        return uid
    }

    func profile(uid: Int64) async throws -> Profile {
        try parser.profile(json: await client.get(LinuxDoEndpoint.userCards(uids: [uid])), uid: uid)
    }

    /// 「全站最新」放在最前，然后是站点的**顶层**类别。
    ///
    /// 子类别不进这张表，只在打开父类别时出现在「子类别」那一格里。登录之后几乎每个
    /// 顶层类别底下都挂着一个「某某, Lv1」（信任等级 1 才看得到的分区，实测 14 个），
    /// 平铺出来就是把整张表又列了一遍 —— 用户看到的是一份重复的版面列表。
    /// 类别表本身仍然全量留着：站内链接直接跳进子类别时，拼地址要它的 slug。
    func forums() async throws -> [Forum] {
        [Self.latestForum] + (try await loadCategories()).filter { $0.parentID == nil }.map(\.forum)
    }

    /// 应用补的入口，不是站点的类别。
    static let latestForum = Forum(
        id: LinuxDoEndpoint.forumID(key: LinuxDoEndpoint.latestKey),
        name: "最新",
        subtitle: "全站按最后回复时间排列",
        category: "站点"
    )

    /// `featuredOnly` 无处可去：站点没有精华。界面上那个开关由 NGA 的能力驱动，收到了也只能忽略。
    func topics(
        forumID: ForumID,
        page: Int,
        sortOrder: TopicListSortOrder,
        featuredOnly: Bool
    ) async throws -> ForumPage {
        // 类别表取不到时不挡列表：没有 slug 就走纯编号的地址（多一次 302），没有子类别就不挂。
        let table = forumID.key == LinuxDoEndpoint.latestKey ? [] : ((try? await loadCategories()) ?? [])
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
        result.forum = forumID.key == LinuxDoEndpoint.latestKey ? Self.latestForum : entry?.forum
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

    private func loadCategories() async throws -> [LinuxDoParser.Category] {
        if let categories { return categories }
        let loaded = try parser.categories(json: await client.get(LinuxDoEndpoint.categories))
        categories = loaded
        return loaded
    }

    // MARK: - 还没做的

    func userActivities(uid: Int64, kind: UserActivityKind, page: Int) async throws -> UserActivityPage {
        throw notYet("用户动态")
    }

    func search(_ request: ForumSearchRequest, page: Int) async throws -> ForumSearchPage {
        throw notYet("搜索")
    }

    func submitReply(topicID: TopicID, submission: ReplySubmission) async throws -> PostID? {
        // 接的时候别忘了 `reply_cost`：大于 0 的话题回复要扣积分，得先让用户确认。
        throw notYet("回复")
    }

    func vote(topicID: TopicID, postID: PostID, direction: PostVoteDirection, isUndo: Bool) async throws -> PostVoteState {
        throw notYet("点赞")
    }

    func submitTopicPollVote(topicID: TopicID, optionIDs: [String]) async throws {
        throw notYet("投票")
    }

    func messages(folder: MessageFolder, page: Int) async throws -> MessagePage {
        throw notYet("消息")
    }

    func message(id: MessageID) async throws -> ForumMessage {
        throw notYet("消息")
    }

    func replyMessage(id: MessageID, content: String) async throws {
        throw notYet("私信")
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
