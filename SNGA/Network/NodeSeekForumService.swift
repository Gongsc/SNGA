import Foundation

/// NodeSeek 的适配器。
///
/// 现在只声明身份和能力，各个方法还没实现 —— 一层一层加，每加一层就有一个真能用的功能。
/// 没实现的一律抛 `.unsupported`，界面按 `capabilities` 决定画不画，正常路径走不到那里。
///
/// 三条传输约束（`Design/SiteProbe-NodeSeek.md` 第〇节，实测）：
///
/// 1. 请求必须带 `WKWebView` 自报的真实 UA。写死会和页面 JS 环境对不上，触发无限挑战。
/// 2. 必须带站点的**全部** cookie。登录后有 6 个，只带其中两个会被 Cloudflare 拒。
/// 3. 别用 curl 验证这个站 —— 同样的请求 curl 被挑战、`URLSession` 通过。
actor NodeSeekForumService: ForumService {
    nonisolated let accountID: AccountID
    nonisolated let site: ForumSite = .nodeseek

    /// 站点实际有的功能。缺的四样：版面收藏、子版面、话题评分、匿名楼层。
    /// 话题收藏有，但没有文件夹。
    nonisolated let capabilities: ForumCapabilities = [
        .checkIn, .postVote, .postDownvote, .quotePost,
        .poll, .privateMessages, .globalSearch, .userActivities
    ]

    private let client: NodeSeekNetworkClient
    private let parser = NodeSeekParser()

    init(
        accountID: AccountID,
        cookies: [SessionCookie],
        transport: any HTTPTransport = URLSessionTransport(),
        userAgent: String,
        cookieDidChange: @escaping @Sendable ([SessionCookie]) async -> Void = { _ in }
    ) {
        self.accountID = accountID
        self.client = NodeSeekNetworkClient(
            cookies: cookies,
            transport: transport,
            userAgent: userAgent,
            cookieDidChange: cookieDidChange
        )
    }

    // MARK: - 还没实现的

    private func notYet(_ what: String) -> ForumServiceError {
        .unsupported("NodeSeek 的\(what)还没做")
    }

    /// 这个站问不出来 —— 用户编号只在浏览器渲染完的 DOM 里。
    ///
    /// 排除过：没有 who-am-I 接口（六个候选路径全 404，而存在但未登录的端点答 500，
    /// 所以这个判别可信）；`pjwt` 不是 JWT；服务端 HTML 登录与否都不含身份；
    /// `unread-count`、`list-collection`、`progress/today` 等六个会话接口的字段里也没有。
    ///
    /// 编号在登录时由 `LoginWebView` 从用户卡片里读出来，存进 `AccountRecord.siteUserID`，
    /// 之后不会再变。见 `ForumSiteDescriptor.userIDSource`。
    func currentUserID() async throws -> Int64 {
        throw ForumServiceError.unsupported(
            "NodeSeek 的用户编号只在登录时取得到，不能在这里问"
        )
    }
    func profile(uid: Int64) async throws -> Profile {
        try parser.profile(json: await client.get(NodeSeekEndpoint.accountInfo(uid: uid)))
    }
    func userActivities(uid: Int64, kind: UserActivityKind, page: Int) async throws -> UserActivityPage {
        throw notYet("用户动态")
    }
    /// 分类是固定的一组，没有接口能列全，所以直接给出来 —— 不发请求。
    func forums() async throws -> [Forum] {
        NodeSeekEndpoint.categories.map { entry in
            Forum(
                id: NodeSeekEndpoint.forumID(key: entry.key),
                name: entry.name,
                category: "分类"
            )
        }
    }
    func search(_ request: ForumSearchRequest, page: Int) async throws -> ForumSearchPage {
        throw notYet("搜索")
    }
    /// 一页话题列表。
    ///
    /// `featuredOnly` 无处可去：站点没有精华筛选。界面上那个开关由 NGA 的能力驱动，
    /// 这里收到了也只能忽略。
    func topics(
        forumID: ForumID,
        page: Int,
        sortOrder: TopicListSortOrder,
        featuredOnly: Bool
    ) async throws -> ForumPage {
        let url = NodeSeekEndpoint.topicList(
            forumID: forumID,
            page: page,
            sortByPostTime: sortOrder == .latestTopic
        )
        let data = try await client.get(url, asJSON: false)
        guard let html = String(data: data, encoding: .utf8) else {
            throw ForumServiceError.invalidResponse
        }
        var result = try parser.topicList(html: html, forumID: forumID, page: page)
        // 列表页不带分类自己的名字，从固定表里补上。
        result.forum = NodeSeekEndpoint.categories
            .first { $0.key == forumID.key }
            .map { Forum(id: forumID, name: $0.name, category: "分类") }
        return result
    }
    /// 一页帖子。
    ///
    /// `authorUID` 用不上：站点没有「只看楼主」。界面上那个开关由 NGA 的能力驱动。
    func threadPage(topicID: TopicID, page: Int, authorUID: Int64?) async throws -> ThreadPage {
        let data = try await client.get(
            NodeSeekEndpoint.thread(topicID: topicID, page: page),
            asJSON: false
        )
        guard let html = String(data: data, encoding: .utf8) else {
            throw ForumServiceError.invalidResponse
        }
        return try parser.threadPage(html: html, topicID: topicID, page: page)
    }
    func submitReply(topicID: TopicID, submission: ReplySubmission) async throws -> PostID? {
        throw notYet("回复")
    }
    func vote(topicID: TopicID, postID: PostID, direction: PostVoteDirection) async throws -> PostVoteState {
        throw notYet("楼层反应")
    }
    func submitTopicPollVote(topicID: TopicID, optionIDs: [String]) async throws { throw notYet("投票") }
    func messages(folder: MessageFolder, page: Int) async throws -> MessagePage { throw notYet("消息") }
    func message(id: MessageID) async throws -> ForumMessage { throw notYet("消息详情") }
    func replyMessage(id: MessageID, content: String) async throws { throw notYet("私信回复") }
    func favoriteTopicFolders() async throws -> [TopicFavoriteFolder] { [] }
    func favoriteTopics(folderID: String, page: Int) async throws -> ForumPage { throw notYet("收藏话题") }
    func updateTopicFavorite(topicID: TopicID, folderID: String, isFavorite: Bool) async throws {
        throw notYet("收藏话题")
    }
    func createTopicFavoriteFolder(name: String, isPublic: Bool, isDefault: Bool) async throws -> String? {
        throw notYet("收藏夹")
    }
    func updateTopicFavoriteFolder(_ folder: TopicFavoriteFolder) async throws { throw notYet("收藏夹") }
    func deleteTopicFavoriteFolder(folderID: String) async throws { throw notYet("收藏夹") }
    func checkInStatus() async throws -> CheckInStatistics { throw notYet("签到状态") }
    func checkIn() async throws -> CheckInResult { throw notYet("签到") }
}
