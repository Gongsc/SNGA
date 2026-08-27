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

    /// 站点实际有的功能。缺的五样：版面收藏、子版面、话题评分、匿名楼层、**站内搜索**。
    /// 话题收藏有，但没有文件夹。
    ///
    /// 搜索这一条和最初的能力表不一样，是实测改的：NodeSeek 没有自己的搜索。
    /// `/search?q=X` 会 302 到 `google.com/search?q=site:www.nodeseek.com&q=X`，
    /// 站点自己也只是把搜索转交出去。既然没有能取回结果的接口，这个位就不能点亮 ——
    /// 点亮了等于在界面上摆一个必定失败的入口。
    /// `.postDownvote` 也没点亮：站点的「反对」要花掉用户 2 个鸡腿，而且撤不回来。
    /// 一个不作声就扣钱的按钮不该摆在界面上 —— 真要接，得先让界面能把代价讲明白
    /// （比如二次确认），那是界面那边的事。
    /// `.poll` 也没点亮。站点是有投票的，但这边还不会从帖子里读它 ——
    /// 能力位是用来回答「这里能不能用」的，不是「站点有没有」。读出来之后再打开。
    nonisolated let capabilities: ForumCapabilities = [
        .checkIn, .postVote, .quotePost,
        .privateMessages, .userActivities
    ]

    private let client: NodeSeekNetworkClient
    private let parser = NodeSeekParser()
    /// 「我是谁」要靠抓一整张页面解出来，而一个会话里它不会变。
    /// 不记住的话，每拉一次私信列表就多抓一张首页。
    private var cachedUserID: Int64?

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

    /// 从任意一页的内嵌状态里读出「我是谁」。
    ///
    /// 先前一路排除下来（没有 who-am-I 接口、`pjwt` 不是 JWT、会话接口不带编号、
    /// HTML 里搜不到 `member_id`）得出的结论是「只有浏览器 DOM 里才有」—— 那个结论是错的。
    /// 页面确实带着身份，只是**整段 base64 编过**，所以按明文搜什么都搜不到。
    func currentUserID() async throws -> Int64 {
        if let cachedUserID { return cachedUserID }
        let data = try await client.get(ForumSiteDescriptor.nodeseek.baseURL, asJSON: false)
        guard let html = String(data: data, encoding: .utf8) else {
            throw ForumServiceError.invalidResponse
        }
        guard let uid = NodeSeekParser.signedInUserID(inHTML: html) else {
            throw ForumServiceError.requiresLogin
        }
        cachedUserID = uid
        return uid
    }
    func profile(uid: Int64) async throws -> Profile {
        try parser.profile(json: await client.get(NodeSeekEndpoint.accountInfo(uid: uid)))
    }
    /// 某个用户的主题或评论。
    ///
    /// 这两个接口在站点边缘有防抓取（见 `NodeSeekParser.rejectBulkGate`）。匿名抓不到，
    /// 带完整登录 cookie 能不能过没验过 —— 验它要拿真账号的凭据去发请求。
    /// 被挡时解析器会抛出说明，而不是给一页空的。
    func userActivities(uid: Int64, kind: UserActivityKind, page: Int) async throws -> UserActivityPage {
        let url = switch kind {
        case .topics: NodeSeekEndpoint.userTopics(uid: uid, page: page)
        case .replies: NodeSeekEndpoint.userComments(uid: uid, page: page)
        }
        return try parser.userActivities(
            json: await client.get(url),
            kind: kind,
            page: max(1, page)
        )
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
    /// 站点没有站内搜索，`.globalSearch` 也没点亮，界面不会走到这里。
    func search(_ request: ForumSearchRequest, page: Int) async throws -> ForumSearchPage {
        throw ForumServiceError.unsupported("NodeSeek 没有站内搜索，它的搜索是转交给 Google 的")
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
    /// 发一条回复。
    ///
    /// `replyTo` 在这里用不上：站点没有服务端的引用机制，引用是把被引的话作为 Markdown
    /// 引用块写进正文 —— 那由编辑器在起草时完成，到这一层已经是正文的一部分了。
    ///
    /// 返回 nil：响应只给 `redirect` 和 `redirectHash`（形如 `#3`），那是**楼层号**不是
    /// 楼层编号，拿它构造 `PostID` 会指向别的东西。调用方本来也不看返回值。
    func submitReply(topicID: TopicID, submission: ReplySubmission) async throws -> PostID? {
        let text = submission.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw ForumServiceError.unsupported("回复内容不能为空")
        }
        let data = try await client.postJSON(
            NodeSeekEndpoint.newComment,
            body: [
                "content": text,
                "mode": "new-comment",
                "postId": topicID.rawValue
            ],
            referer: NodeSeekEndpoint.thread(topicID: topicID, page: 1)
        )
        try parser.confirmWrite(json: data, what: "回复")
        return nil
    }
    /// 给一层投喂。
    ///
    /// 界面上的赞接的是三种反应里唯一免费的 `upvote`：它给作者星辰，不花读者的东西。
    /// 另外两种（加鸡腿 1 个、反对 2 个）花的是用户自己的鸡腿，一次点击就扣掉、
    /// 而且收不回来，所以这里一个都不接 —— 见 `capabilities` 里关于 `.postDownvote` 的话。
    ///
    /// 三种反应都不可撤销。再点一次已经投喂过的楼层不能当成取消，也不该默默再投一次，
    /// 所以直接说清楚。
    func vote(
        topicID: TopicID,
        postID: PostID,
        direction: PostVoteDirection,
        isUndo: Bool
    ) async throws -> PostVoteState {
        guard direction == .up else {
            throw ForumServiceError.unsupported(
                "NodeSeek 的「反对」要花掉你 2 个鸡腿且撤不回来，SNGA 没有接这个按钮"
            )
        }
        guard !isUndo else {
            throw ForumServiceError.unsupported("NodeSeek 的投喂撤不回来")
        }
        return try parser.reactionState(json: await client.postJSON(
            NodeSeekEndpoint.reaction(.upvote),
            body: ["commentId": postID.rawValue, "action": "add"],
            referer: NodeSeekEndpoint.thread(topicID: topicID, page: 1)
        ))
    }
    func submitTopicPollVote(topicID: TopicID, optionIDs: [String]) async throws { throw notYet("投票") }
    /// 私信或通知的一页。
    ///
    /// 两个文件夹落到完全不同的接口上：私信是一个会话列表，通知则是 `at-me` 和
    /// `reply-to-me` **两个**接口 —— 站点把「提到我」和「回复我」分开放，而应用这边
    /// 只有一个「通知」，所以取回来合成一份，按时间倒序。
    func messages(folder: MessageFolder, page: Int) async throws -> MessagePage {
        switch folder {
        case .privateMessages:
            return try parser.messages(
                json: await client.get(NodeSeekEndpoint.notifications(kind: "message", page: page)),
                page: max(1, page),
                currentUserID: await currentUserID()
            )
        case .notifications:
            var merged: [ForumMessage] = []
            for kind in NodeSeekNotificationKind.allCases {
                merged += try parser.notifications(
                    json: await client.get(NodeSeekEndpoint.notifications(kind: kind, page: page)),
                    kind: kind,
                    page: max(1, page)
                )
            }
            // 没时间的排在后面，别让它们挤到最前面去。
            merged.sort { ($0.sentAt ?? .distantPast) > ($1.sentAt ?? .distantPast) }
            return MessagePage(
                folder: folder,
                messages: merged,
                page: max(1, page),
                hasMore: !merged.isEmpty
            )
        }
    }

    /// 一段私信会话。
    ///
    /// `id` 里放的是对方的编号（见 `NodeSeekParser.messages`），这里正好当路径用。
    func message(id: MessageID) async throws -> ForumMessage {
        let me = try await currentUserID()
        let page = try parser.messages(
            json: await client.get(NodeSeekEndpoint.messageThread(uid: id.rawValue)),
            page: 1,
            currentUserID: me
        )
        guard let message = page.messages.first else {
            throw ForumServiceError.unexpectedPage("这段会话读不出内容")
        }
        return message
    }

    func replyMessage(id: MessageID, content: String) async throws {
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw ForumServiceError.unsupported("私信内容不能为空")
        }
        try parser.confirmWrite(
            json: await client.postJSON(
                NodeSeekEndpoint.sendMessage,
                // 这一个字段是 camelCase，而这套接口其余字段都是 snake_case
                // （实测自站点自己的 notification.js）。照抄，别顺手改成统一风格。
                body: ["receiverUid": id.rawValue, "content": text]
            ),
            what: "私信"
        )
    }
    func favoriteTopicFolders() async throws -> [TopicFavoriteFolder] { [] }
    /// 收藏的话题。站点没有收藏夹，`folderID` 无处可去。
    func favoriteTopics(folderID: String, page: Int) async throws -> ForumPage {
        try parser.favoriteTopics(
            json: await client.get(NodeSeekEndpoint.collectionList(page: page)),
            page: max(1, page)
        )
    }
    /// 收藏或取消收藏一个话题。
    ///
    /// 和三种反应不同，这个可逆，所以两个方向都接。站点没有收藏夹，`folderID` 无处可去。
    func updateTopicFavorite(topicID: TopicID, folderID: String, isFavorite: Bool) async throws {
        try parser.confirmWrite(
            json: await client.postJSON(
                NodeSeekEndpoint.collection,
                body: ["postId": topicID.rawValue, "action": isFavorite ? "add" : "remove"],
                referer: NodeSeekEndpoint.thread(topicID: topicID, page: 1)
            ),
            what: isFavorite ? "收藏" : "取消收藏"
        )
    }
    func createTopicFavoriteFolder(name: String, isPublic: Bool, isDefault: Bool) async throws -> String? {
        throw notYet("收藏夹")
    }
    func updateTopicFavoriteFolder(_ folder: TopicFavoriteFolder) async throws { throw notYet("收藏夹") }
    func deleteTopicFavoriteFolder(folderID: String) async throws { throw notYet("收藏夹") }
    func checkInStatus() async throws -> CheckInStatistics {
        try parser.checkInStatistics(json: await client.get(NodeSeekEndpoint.checkInBoard(page: 1)))
    }

    /// 签到。
    ///
    /// `random=false` 领固定的 5 个鸡腿，`true` 是抽奖。这里固定用不抽奖的那种：
    /// 应用替用户赌一把不合适，而界面上现在也没有让他选的地方。
    func checkIn() async throws -> CheckInResult {
        try parser.checkInResult(
            json: await client.postJSON(NodeSeekEndpoint.checkIn(random: false), body: [:])
        )
    }
}
