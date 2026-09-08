import Foundation

/// V2EX 的适配器。
///
/// 能做的和不能做的分得很清楚，界线就是**登录**：站点的浏览面全部公开，节点、
/// 主题、回复、会员资料匿名就能抓全，所以这一半是照着真实响应写的、有夹具可对；
/// 收藏、通知、每日奖励那一半是登录之后才画出来的链接和表单，匿名连标记都看不见，
/// 所以一律不接，也不点亮对应的能力位 —— 见 `Design/SiteProbe-V2EX.md`。
///
/// 三件和另外两个站不一样的事：
///
/// 1. **用户名和编号是两套。** 页面地址里是用户名（`/member/Livid`），应用内部一律
///    拿 `Int64` 认人。翻译只能问 `/api/members/show.json`，所以按编号看动态时
///    会多一次请求 —— 结果缓存在 `usernames` 里。
/// 2. **写操作靠一次性令牌 `once`**，不是请求头签名。每次写之前现取一个。
/// 3. **「感谢」要花掉感谢者 10 个铜币，而且撤不回来**，所以它不是赞踩，
///    是一种带代价的表态，走 `submitPostReaction` 那条要先确认的路。
actor V2EXForumService: ForumService {
    nonisolated let accountID: AccountID
    nonisolated let site: ForumSite = .v2ex

    /// 站点实际有的功能。
    ///
    /// `.postVote` 没点亮：站点的「感谢」只有一个方向，而且**花掉感谢者 10 个铜币、
    /// 撤不回来**。一个不作声就扣钱的按钮不该摆成赞踩那种一点就发的样子，
    /// 所以它走 `Post.reactions`，由界面先问一次 —— 和 NodeSeek 的鸡腿同一个道理。
    ///
    /// `.globalSearch` 点亮的是**节点搜索**，不是主题全文搜索：站点没有后者。
    /// 这个结论不是从「匿名访问 `/search` 被转走」推出来的（那是 NodeSeek 上踩过的坑），
    /// 而是读站点自己的 `combo.js`：搜索框给的四档是节点、用户、谷歌
    /// `site:v2ex.com/t`、第三方 SoV2EX，头两档是本地过滤和跳转，后两档在站外。
    ///
    /// `.subforums` 点亮的是**首页分类底下那第二排节点**：「技术」这一格聚合了程序员、
    /// Python、iDev……站点自己就把它们画成第二行。它们不是站点意义上的「子版面」
    /// （V2EX 的节点是平的），但在界面上就是这个形状：一格里列出几个版面，
    /// 可以点进去，也可以筛掉几个不看。
    ///
    /// 收藏（话题和节点都是）、通知、每日奖励都还没接：它们的链接和表单只在登录后
    /// 的页面上，匿名抓不到，没有夹具就不写解析器。
    nonisolated let capabilities: ForumCapabilities = [.globalSearch, .userActivities, .subforums]

    private let client: V2EXNetworkClient
    private let parser = V2EXParser()
    /// 「我是谁」要抓一整张页面才解得出来，而一个会话里它不会变。
    private var cachedUserID: Int64?
    /// 编号到用户名。用户页的地址里是用户名，翻译一次就够。
    private var usernames: [Int64: String] = [:]
    /// 节点全表。搜索节点时在本地过滤，翻页不必重拉。
    private var cachedNodes: [Forum]?

    init(
        accountID: AccountID,
        cookies: [SessionCookie],
        transport: any HTTPTransport = URLSessionTransport(),
        userAgent: String,
        cookieDidChange: @escaping @Sendable ([SessionCookie]) async -> Void = { _ in }
    ) {
        self.accountID = accountID
        self.client = V2EXNetworkClient(
            cookies: cookies,
            transport: transport,
            userAgent: userAgent,
            cookieDidChange: cookieDidChange
        )
    }

    private func notYet(_ what: String) -> ForumServiceError {
        .unsupported("V2EX 的\(what)还没做")
    }

    private func html(_ data: Data) throws -> String {
        guard let html = String(data: data, encoding: .utf8) else {
            throw ForumServiceError.invalidResponse
        }
        return html
    }

    // MARK: - 身份

    /// 从任意一张页面上读出「我是谁」。
    ///
    /// 站点不把编号写进 Cookie（`A2` 是一个签名过的会话串），也没有 who-am-I 接口 ——
    /// `/api/members/show.json` 只按编号或用户名查别人，问不了自己。登录之后的页面上
    /// 有 `memberId` 这个全局，顶栏头像的地址里也带着编号，所以抓一张首页来读。
    func currentUserID() async throws -> Int64 {
        if let cachedUserID { return cachedUserID }
        let html = try html(await client.get(V2EXEndpoint.descriptor.baseURL))
        guard let uid = V2EXParser.signedInUserID(inHTML: html) else {
            throw ForumServiceError.requiresLogin
        }
        cachedUserID = uid
        return uid
    }

    /// 用户资料。
    ///
    /// 要两次请求，因为站点把资料分在两处：接口给身份和自我介绍，
    /// **今日活跃度排名、公司职位、外部链接**只画在网页上。
    ///
    /// 网页那次是附带的 —— 取不到就少显示几行，别把整张资料页拖垮。
    /// 它也只能在拿到用户名之后才发得出去：网页地址里是用户名，不是编号。
    func profile(uid: Int64) async throws -> Profile {
        var profile = try parser.profile(json: await client.get(
            V2EXEndpoint.member(uid: uid),
            asJSON: true
        ))
        usernames[uid] = profile.displayName
        do {
            try parser.applyMemberPage(
                html: try html(await client.get(
                    V2EXEndpoint.memberPage(username: profile.displayName)
                )),
                to: &profile
            )
        } catch {
            await RuntimeLogger.shared.log(
                category: "v2ex",
                "资料页取不到，基础资料照常显示：\(error.localizedDescription)"
            )
        }
        return profile
    }

    /// 编号 → 用户名。用户页的地址里只认用户名。
    private func username(of uid: Int64) async throws -> String {
        if let cached = usernames[uid] { return cached }
        let name = try parser.username(json: await client.get(
            V2EXEndpoint.member(uid: uid),
            asJSON: true
        ))
        usernames[uid] = name
        return name
    }

    /// 某人发过的主题或回复。
    ///
    /// 两条路的页面形状不一样：主题那页用的是和节点页同一套列表模板，回复那页是
    /// 「一条动态摊成两个相邻兄弟节点」的样子，所以解析分开。
    func userActivities(uid: Int64, kind: UserActivityKind, page: Int) async throws -> UserActivityPage {
        let username = try await username(of: uid)
        switch kind {
        case .topics:
            return try parser.userTopics(
                html: try html(await client.get(
                    V2EXEndpoint.memberTopics(username: username, page: page)
                )),
                page: max(1, page)
            )
        case .replies:
            return try parser.userReplies(
                html: try html(await client.get(
                    V2EXEndpoint.memberReplies(username: username, page: page)
                )),
                page: max(1, page)
            )
        }
    }

    // MARK: - 浏览

    /// 节点目录。
    ///
    /// 站点把一千三百多个节点分进六个「位面」，这个分组只有 `/planes` 这一张页面有 ——
    /// `/api/nodes/all.json` 里的 `parent_node_name` 分出来是五百多个顶层节点，
    /// 摊在目录里没法看。
    ///
    /// 「最近主题」排在最前面：站点首页翻不下去（它是一屏精选），能一直往下翻的是
    /// `/recent`，那才是这个应用里「全部」的对应物。
    func forums() async throws -> [Forum] {
        let nodes = try parser.planes(html: try html(await client.get(V2EXEndpoint.planes)))
        return [Self.recentForum] + V2EXEndpoint.descriptor.pinnedForums + nodes
    }

    /// 「最近主题」这一条是应用自己补的，不是站点的版面。
    ///
    /// 站点首页（`/`）**翻不下去** —— 它是一屏精选。能一直往下翻的是 `/recent`，
    /// 所以这个应用里「全部」落在它身上。
    private static let recentForum = Forum(
        id: V2EXEndpoint.forumID(key: V2EXEndpoint.recentKey),
        name: "最近主题",
        subtitle: "全站按最后回复时间排列",
        category: "站点"
    )

    /// 搜索。
    ///
    /// 只有节点一档，因为站点只有这一档（见 `capabilities` 的说明）。做法和站点
    /// 自己的搜索框一样：拉一次节点全表，在本地按名字和英文名过滤。
    ///
    /// 分页也在本地做 —— 那份 JSON 是一次给全的，没有页码可传。
    func search(_ request: ForumSearchRequest, page: Int) async throws -> ForumSearchPage {
        guard request.kind == .forum else {
            throw ForumServiceError.unsupported(
                "V2EX 没有主题搜索，只能按名称找节点。找帖子请在浏览器里用谷歌的 site: 搜索"
            )
        }
        let nodes = try await allNodes()
        let keyword = request.query.lowercased()
        let matches = nodes.filter { forum in
            forum.name.lowercased().contains(keyword)
                || forum.searchAliases.contains { $0.lowercased().contains(keyword) }
        }
        let pageSize = 40
        let page = max(1, page)
        let totalPages = max(1, (matches.count + pageSize - 1) / pageSize)
        let start = min((page - 1) * pageSize, matches.count)
        let end = min(start + pageSize, matches.count)
        return ForumSearchPage(
            request: request,
            forums: Array(matches[start..<end]),
            page: page,
            hasMore: page < totalPages,
            totalPages: totalPages
        )
    }

    private func allNodes() async throws -> [Forum] {
        if let cachedNodes { return cachedNodes }
        let nodes = try parser.nodes(json: await client.get(V2EXEndpoint.nodes, asJSON: true))
        cachedNodes = nodes
        return nodes
    }

    /// 一页主题列表。
    ///
    /// `sortOrder` 和 `featuredOnly` 都无处可去：节点页只有一种排序（最后回复在前），
    /// 也没有精华筛选。界面上那两个开关由 NGA 的能力驱动。
    func topics(
        forumID: ForumID,
        page: Int,
        sortOrder: TopicListSortOrder,
        featuredOnly: Bool
    ) async throws -> ForumPage {
        // 首页分类没有分页条，翻页无处可去。收下一个大于 1 的页码只会把同一屏
        // 再取一遍，还让界面以为「还有下一页」。
        let isTab = V2EXEndpoint.tabKey(of: forumID) != nil
        let page = isTab ? 1 : max(1, page)
        var result = try parser.topicList(
            html: try html(await client.get(V2EXEndpoint.topicList(forumID: forumID, page: page))),
            forumID: forumID,
            page: page
        )
        // 首页分类和「最近主题」都不是节点，页面上没有节点抬头，补一个出来 ——
        // 否则列表顶上空着一格，读者不知道自己在看什么。
        if result.forum == nil {
            if let name = V2EXEndpoint.tabName(of: forumID) {
                result.forum = Forum(
                    id: forumID,
                    name: name,
                    subtitle: result.subforums.isEmpty
                        ? nil
                        // 站点自己就把这几个节点画在分类底下，说清楚这一格聚合了什么。
                        : result.subforums.map(\.name).joined(separator: " · "),
                    category: V2EXEndpoint.descriptor.pinnedForumsTitle
                )
            } else if forumID.key == V2EXEndpoint.recentKey {
                result.forum = Self.recentForum
            }
        }
        return result
    }

    /// 一页主题。
    ///
    /// `authorUID` 用不上：站点没有「只看楼主」。界面上那个开关由 NGA 的能力驱动。
    func threadPage(topicID: TopicID, page: Int, authorUID: Int64?) async throws -> ThreadPage {
        let page = max(1, page)
        return try parser.threadPage(
            html: try html(await client.get(V2EXEndpoint.topic(topicID: topicID, page: page))),
            topicID: topicID,
            page: page
        )
    }

    // MARK: - 写

    /// 发一条回复。
    ///
    /// 站点没有回复接口，只有一张表单：`content` 加一个一次性令牌 `once`，POST 到
    /// 主题页自己的地址。成功之后站点 302 回主题页，没有 JSON 可读 —— 所以成败靠
    /// 「返回的页面里有没有 `.problem` 那条提示」来判（见 `V2EXParser.confirmReply`）。
    ///
    /// `replyTo` 在这里用不上：站点没有服务端的引用机制，回某一层就是在正文开头写
    /// `@用户名`（站点自己的 `replyOne(username)` 干的正是这件事），那由编辑器在起草时
    /// 完成，到这一层已经是正文的一部分了。
    ///
    /// 返回 nil：302 回去的地址里没有新楼层的编号。调用方本来也不看返回值。
    func submitReply(topicID: TopicID, submission: ReplySubmission) async throws -> PostID? {
        let text = submission.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw ForumServiceError.unsupported("回复内容不能为空")
        }
        let once = try await client.freshOnce()
        let data = try await client.postForm(
            V2EXEndpoint.reply(topicID: topicID),
            fields: ["content": text, "once": once],
            referer: V2EXEndpoint.topic(topicID: topicID, page: 1)
        )
        try parser.confirmReply(html: try html(data))
        return nil
    }

    /// 赞踩。站点没有 —— 它只有「感谢」，而感谢要花钱且撤不回来，走
    /// `submitPostReaction`，由界面先确认。
    func vote(
        topicID: TopicID,
        postID: PostID,
        direction: PostVoteDirection,
        isUndo: Bool
    ) async throws -> PostVoteState {
        throw ForumServiceError.unsupported(
            "V2EX 没有赞踩，只有「感谢」——"
                + "它会花掉你 \(V2EXEndpoint.thankCost) 个铜币且撤不回来，所以要先确认一次"
        )
    }

    /// 感谢一层楼，或者感谢主题本身。
    ///
    /// **这一下会从账上扣掉 10 个铜币，站点不给撤。**
    /// 所以这里只管发，「要不要花这个钱」必须在界面上问清楚再调过来 ——
    /// 见 `PostReaction.cost` 和 `PostReactionBar` 的二次确认。
    ///
    /// 主楼和回复走的是两个地址（`/thank/topic/` 和 `/thank/reply/`）。分辨靠编号：
    /// 主楼没有自己的回复编号，解析器给它填的就是主题编号（见 `V2EXParser.opening`）。
    func submitPostReaction(
        topicID: TopicID,
        postID: PostID,
        reactionID: String
    ) async throws -> PostVoteState? {
        guard reactionID == V2EXEndpoint.thankReactionID else {
            throw ForumServiceError.unsupported("认不出这种表态：\(reactionID)")
        }
        let once = try await client.freshOnce()
        let isOpeningPost = postID.rawValue == topicID.rawValue
        let url = isOpeningPost
            ? V2EXEndpoint.thankTopic(topicID: topicID, once: once)
            : V2EXEndpoint.thankReply(postID: postID, once: once)
        try parser.confirmThank(json: await client.postForm(
            url,
            referer: V2EXEndpoint.topic(topicID: topicID, page: 1)
        ))
        // 响应里只有一个新的 `once`，没有这一层现在被感谢了多少次。
        // 编一个数会把界面上的计数写错，让调用方刷新页面拿准数。
        return nil
    }

    // MARK: - 还没接的

    func submitTopicPollVote(topicID: TopicID, optionIDs: [String]) async throws {
        throw ForumServiceError.unsupported("V2EX 没有主题内投票")
    }

    func messages(folder: MessageFolder, page: Int) async throws -> MessagePage {
        throw notYet("提醒系统")
    }

    func message(id: MessageID) async throws -> ForumMessage { throw notYet("提醒系统") }

    func replyMessage(id: MessageID, content: String) async throws {
        throw ForumServiceError.unsupported("V2EX 没有站内私信")
    }

    /// 站点是有收藏的（`/my/topics`），但收藏和取消收藏是登录后才画出来的两个链接，
    /// 匿名连它们的地址长什么样都看不见。没有夹具就不写，`.topicFavorites`
    /// 也关着 —— 侧栏那个入口整个不画，不会有人点进一个永远是空的页面。
    func favoriteTopicFolders() async throws -> [TopicFavoriteFolder] { [] }

    func favoriteTopics(folderID: String, page: Int) async throws -> ForumPage {
        throw notYet("话题收藏")
    }

    func updateTopicFavorite(topicID: TopicID, folderID: String, isFavorite: Bool) async throws {
        throw notYet("话题收藏")
    }

    func createTopicFavoriteFolder(name: String, isPublic: Bool, isDefault: Bool) async throws -> String? {
        throw ForumServiceError.unsupported("V2EX 的收藏没有分组")
    }

    func updateTopicFavoriteFolder(_ folder: TopicFavoriteFolder) async throws {
        throw ForumServiceError.unsupported("V2EX 的收藏没有分组")
    }

    func deleteTopicFavoriteFolder(folderID: String) async throws {
        throw ForumServiceError.unsupported("V2EX 的收藏没有分组")
    }

    func checkInStatus() async throws -> CheckInStatistics { throw notYet("每日登录奖励") }

    func checkIn() async throws -> CheckInResult { throw notYet("每日登录奖励") }
}
