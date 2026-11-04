import Foundation

/// Linux.do 的地址。
///
/// 站点是 Discourse：几乎每个页面地址加 `.json` 就是它的数据，所以这里拼的全是 JSON 地址，
/// 没有网页。依据见 `Design/SiteProbe-LinuxDo.md`。
enum LinuxDoEndpoint {
    static let base = ForumSiteDescriptor.linuxdo.baseURL

    /// 「话题」那一条的键：网页侧边栏「社区」那一段的第一项，地址是 `/latest`。
    /// 它不是站点的类别。
    static let latestKey = "latest"

    /// 标签的键是 `tag:{编号}`。
    ///
    /// 加前缀是因为标签和类别的编号是两套，各自从小数起，迟早会撞 ——
    /// 和 V2EX 首页分类的 `tab:` 同一个道理。
    static let tagPrefix = "tag:"

    static func forumID(tagID: Int) -> ForumID {
        forumID(key: "\(tagPrefix)\(tagID)")
    }

    /// 这个版面是不是一个标签；是的话给出标签编号。
    static func tagID(of forumID: ForumID) -> Int? {
        guard forumID.key.hasPrefix(tagPrefix) else { return nil }
        return Int(forumID.key.dropFirst(tagPrefix.count))
    }

    /// 一页话题有多少楼。
    ///
    /// Discourse 的话题**不分页**，是一条楼层编号流（`post_stream.stream`）加上前一块楼层的内容。
    /// 应用按页码工作，所以由适配器自己切。取 20 是因为站点自己一次给的就是 20 楼
    /// （`chunk_size`，实测），第一页正好是详情接口带回来的那一块，往后每页正好一次
    /// `posts.json`（实测请求 20 条回 20 条）。
    static let postsPerPage = 20

    static func forumID(key: String) -> ForumID {
        ForumID(site: .linuxdo, key: key)
    }

    /// 类别编号 → 版面。类别的键就是它的数字编号。
    static func forumID(categoryID: Int) -> ForumID {
        forumID(key: String(categoryID))
    }

    // MARK: - 地址

    /// 全部类别，连同子类别。登录后看到的比匿名多（实测多出一个编号 35 的类别），
    /// 所以这一份要拿会话去问，不能写死。
    static var categories: URL {
        url("/categories.json", query: [URLQueryItem(name: "include_subcategories", value: "true")])
    }

    /// 一页话题列表。
    ///
    /// - `slugPath`：类别的 slug 路径（子类别是「父/子」）。不知道时传 nil，用纯编号的地址 ——
    ///   站点也认，只是会先 302 到带 slug 的那个（实测），多一次往返。
    /// - 页码：应用从 1 数，站点从 0 数。
    /// - 「最新话题」是 `order=created`；默认（最后回复）不带参数。
    static func topicList(
        forumID: ForumID,
        slugPath: String?,
        page: Int,
        sortOrder: TopicListSortOrder
    ) -> URL {
        var query: [URLQueryItem] = []
        if sortOrder == .latestTopic {
            query.append(URLQueryItem(name: "order", value: "created"))
        }
        let sitePage = max(1, page) - 1
        if sitePage > 0 {
            query.append(URLQueryItem(name: "page", value: String(sitePage)))
        }
        if forumID.key == latestKey {
            return url("/latest.json", query: query)
        }
        // 标签的地址是 `/tag/{slug}/{编号}`；没有 slug 时只给编号站点也认（实测）。
        if let tagID = tagID(of: forumID) {
            let path = slugPath.map { "\($0)/\(tagID)" } ?? String(tagID)
            return url("/tag/\(path)/l/latest.json", query: query)
        }
        let path = slugPath.map { "\($0)/\(forumID.key)" } ?? forumID.key
        return url("/c/\(path)/l/latest.json", query: query)
    }

    /// 话题详情：元数据、全部楼层编号、前 20 楼。
    static func topic(_ topicID: TopicID) -> URL {
        url("/t/\(topicID.rawValue).json")
    }

    /// 按楼层编号批量取楼层。
    static func topicPosts(_ topicID: TopicID, postIDs: [Int64]) -> URL {
        url(
            "/t/\(topicID.rawValue)/posts.json",
            query: postIDs.map { URLQueryItem(name: "post_ids[]", value: String($0)) }
        )
    }

    /// 按编号取用户卡片。
    ///
    /// 用户的页面地址是**用户名**（`/u/{name}.json`），应用却按编号认人。这一个接口收编号，
    /// 给的是和资料页差不多的一份（实测有加入时间、信任等级、头衔、群组）——
    /// 所以不必像 V2EX 那样先做一次「编号 → 名字」的翻译。`/u/by-id/{id}` 是 404（实测）。
    static func userCards(uids: [Int64]) -> URL {
        url(
            "/user-cards.json",
            query: [URLQueryItem(name: "user_ids", value: uids.map(String.init).joined(separator: ","))]
        )
    }

    /// 完整资料。地址里是**用户名**，所以要先从卡片接口拿到名字。
    ///
    /// 卡片接口（`userCards`）在登录后看别人时只给一份六个字段的精简版（实测：没有加入时间、
    /// 头衔、群组），这里才是全的 —— 加入时间、最后活动、浏览量、点数都在 `user` 里。
    static func userProfile(username: String) -> URL? {
        guard let encoded = username.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            return nil
        }
        return URL(string: "/u/\(encoded).json", relativeTo: base)?.absoluteURL
    }

    /// 站点资料。这里只用它的 `navigation_menu_site_top_tags`：用户没在侧边栏里挑过标签时，
    /// 网页侧边栏「标签」那一段画的就是这一份。
    static var site: URL { url("/site.json") }

    /// 某人发的话题（`filter=4`）或回复（`filter=5`）。一页 30 条，按 `offset` 翻。
    static let userActionsPerPage = 30

    static func userActions(username: String, kind: UserActivityKind, page: Int) -> URL {
        url("/user_actions.json", query: [
            URLQueryItem(name: "username", value: username),
            URLQueryItem(name: "filter", value: kind == .topics ? "4" : "5"),
            URLQueryItem(name: "offset", value: String((max(1, page) - 1) * userActionsPerPage))
        ])
    }

    /// 搜索。条件全写进 `q` 里 —— 站点的搜索框就是这么做的，没有单独的参数。
    ///
    /// 下面每一条都在 2026-11-04 用真实请求核过：`in:title` 只返回主楼；`#develop` 只剩类别 4
    /// 和它的子类别；`@用户名` 只剩那个人；`after:` / `before:` 卡住了日期。一页 50 条。
    /// **`tags:` 不灵**（同一个关键词加上标签 slug 就是 0 条），所以标签里不提供版面内搜索。
    ///
    /// - `categorySlugPath`：类别的 slug 路径，子类别写成「父:子」（站点的 `#` 语法）。
    static func search(
        query: String,
        titleOnly: Bool,
        categorySlugPath: String?,
        author: String?,
        postedAfter: Date?,
        postedBefore: Date?,
        page: Int
    ) -> URL {
        var terms = [query]
        if titleOnly { terms.append("in:title") }
        if let categorySlugPath {
            terms.append("#" + categorySlugPath.replacingOccurrences(of: "/", with: ":"))
        }
        if let author { terms.append("@" + author) }
        if let postedAfter { terms.append("after:" + searchDate(postedAfter)) }
        if let postedBefore { terms.append("before:" + searchDate(postedBefore)) }
        return url("/search.json", query: [
            URLQueryItem(name: "q", value: terms.joined(separator: " ")),
            URLQueryItem(name: "page", value: String(max(1, page)))
        ])
    }

    /// 站点的日期写法是 `2026-10-01`，按用户自己这一侧的日历日算。
    private static func searchDate(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// 写请求要的 CSRF 令牌（`{"csrf": "…"}`，实测登录后拿得到）。
    static var csrf: URL { url("/session/csrf") }

    // MARK: - 消息

    /// 提醒一页 30 条，按 `offset` 翻（站点自己的「加载更多」就是 `offset=30`）。
    static let notificationsPerPage = 30

    static func notifications(page: Int) -> URL {
        url("/notifications.json", query: [
            URLQueryItem(name: "limit", value: String(notificationsPerPage)),
            URLQueryItem(name: "offset", value: String((max(1, page) - 1) * notificationsPerPage))
        ])
    }

    /// 标成已读。带 `id` 是一条，不带是全部（站点「全部已读」那颗按钮就是不带参数的 PUT）。
    static var markNotificationsRead: URL { url("/notifications/mark-read") }

    /// 私信收件箱。私信在 Discourse 里是话题，列表和话题列表同形；页码从 0 数。
    static func privateMessages(username: String, page: Int) -> URL {
        // 不预先转义：`url(_:query:)` 走的是 `URLComponents.path`，它自己会转义，
        // 先转一遍会把 `%` 再转成 `%25`。
        let sitePage = max(1, page) - 1
        return url(
            "/topics/private-messages/\(username).json",
            query: sitePage > 0 ? [URLQueryItem(name: "page", value: String(sitePage))] : []
        )
    }

    /// 发帖（回复话题、回复私信都是它）。表单字段 `raw` + `topic_id`，回复某一楼再加
    /// `reply_to_post_number`（站点前端的字段说明里就是这三样）。
    static var createPost: URL { url("/posts.json") }

    /// 当前会话是谁。cookie 和页面里都没有编号，只能问这里。
    static var sessionCurrent: URL { url("/session/current.json") }

    /// 话题在网页版的地址。`topic` 是 slug 的占位 —— 站点按编号认，slug 写什么都会被纠正。
    static func topicWebURL(topicID: TopicID) -> URL {
        url("/t/topic/\(topicID.rawValue)")
    }

    /// 头像地址。`avatar_template` 是 `/user_avatar/linux.do/{名字}/{size}/…`，
    /// 尺寸要自己填；有的已经是带域名的完整地址（CDN）。
    static func avatarURL(template: String?, size: Int = 96) -> URL? {
        guard let template, !template.isEmpty else { return nil }
        let filled = template.replacingOccurrences(of: "{size}", with: String(size))
        return URL(string: filled, relativeTo: base)?.absoluteURL
    }

    private static func url(_ path: String, query: [URLQueryItem] = []) -> URL {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        components.path = path
        components.queryItems = query.isEmpty ? nil : query
        return components.url!
    }
}
