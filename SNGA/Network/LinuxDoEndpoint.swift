import Foundation

/// Linux.do 的地址。
///
/// 站点是 Discourse：几乎每个页面地址加 `.json` 就是它的数据，所以这里拼的全是 JSON 地址，
/// 没有网页。依据见 `Design/SiteProbe-LinuxDo.md`。
enum LinuxDoEndpoint {
    static let base = ForumSiteDescriptor.linuxdo.baseURL

    /// 「全站最新」那一条的键。它不是站点的类别，是应用补的入口（`/latest`）。
    static let latestKey = "latest"

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
