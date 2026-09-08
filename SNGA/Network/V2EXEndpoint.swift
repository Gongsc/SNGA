import Foundation

/// V2EX 的地址词汇表。解析器不拼地址，一律从这里取。
///
/// 站点分成两半，和 NodeSeek 正好相反：**网页是主干**（节点列表、主题、回复、
/// 用户页全是服务端渲染的 HTML，一次请求拿到一整页），JSON 接口只剩两个还活着的
/// 只读端点 —— 节点全表和会员资料。两者站点自己都在用：`/api/nodes/all.json`
/// 就是搜索框里那个节点候选列表的数据源（见站点 combo.js 的 `fetchNodeList`）。
///
/// 写操作没有接口，是表单和 `?once=` 的组合，见文件末尾那一节。
enum V2EXEndpoint {
    static let descriptor = ForumSiteDescriptor.v2ex

    // MARK: - 节点

    /// 「最近主题」的键。
    ///
    /// 站点的首页（`/`）**不分页** —— 它是一屏精选，翻不下去。能一直往下翻的是
    /// `/recent`，所以列表里的「全部」落在它身上，而不是首页。
    ///
    /// 用一个词而不是空串：`ForumID.description` 会进界面标识符，空串在那里没法用。
    static let recentKey = "recent"

    static func forumID(key: String) -> ForumID {
        ForumID(site: .v2ex, key: key)
    }

    // MARK: - 首页分类

    /// 首页顶上那一排分类。
    ///
    /// 它们是站点自己的**聚合版面**：一个分类同时列出若干节点的主题（「技术」下面是
    /// 程序员、Python、iDev、Claude、OpenAI、Local LLM、云计算、宽带症候群）。
    /// 页面上还会把这几个节点画成第二行，见 `V2EXParser` 对 `#SecondaryTabs` 的处理。
    ///
    /// 没有接口能列全，`#Tabs` 里就这么几个，所以写在这里，顺序与网页一致。
    ///
    /// 收进来的只有 `?tab=` 那种。同一排上的 VXNA（`/xna`）是另一个产品、
    /// 「节点」就是节点目录、「关注」（`/my/following`）要登录 —— 三个都不是主题列表，
    /// 混进来只会得到一个打不开的入口。
    static let tabs: [(key: String, name: String)] = [
        ("tech", "技术"),
        ("creative", "创意"),
        ("play", "好玩"),
        ("apple", "Apple"),
        ("jobs", "酷工作"),
        ("deals", "交易"),
        ("city", "城市"),
        ("qna", "问与答"),
        ("hot", "最热"),
        ("all", "全部"),
        ("r2", "R2")
    ]

    /// 分类的键要和节点区分开。
    ///
    /// **不能直接用 `tab` 的名字当键**：站点有一个叫 `qna` 的分类，也有一个叫 `qna`
    /// 的节点（`/?tab=qna` 和 `/go/qna` 是两份不同的列表）。不加前缀，两者会共用
    /// 同一个 `ForumID` —— 收藏、最近访问、子版面偏好都按它做主键，撞上就是串号。
    static let tabKeyPrefix = "tab:"

    static func tabForumID(key: String) -> ForumID {
        forumID(key: tabKeyPrefix + key)
    }

    /// 这个版面是不是首页分类；是的话给出它在站点那边的键。
    static func tabKey(of forumID: ForumID) -> String? {
        guard forumID.key.hasPrefix(tabKeyPrefix) else { return nil }
        return String(forumID.key.dropFirst(tabKeyPrefix.count))
    }

    static func tabName(of forumID: ForumID) -> String? {
        guard let key = tabKey(of: forumID) else { return nil }
        return tabs.first { $0.key == key }?.name
    }

    /// 一页主题列表。首页分类、`/recent` 和 `/go/{节点}` 用的是同一套 `div.cell` 模板，
    /// 所以解析共用一个入口 —— 但地址是三种。
    ///
    /// **首页分类不分页**（页面上根本没有分页条），所以 `page` 到那儿会被忽略。
    static func topicList(forumID: ForumID, page: Int) -> URL {
        if let tab = tabKey(of: forumID) {
            return url("/", query: [.init(name: "tab", value: tab)])
        }
        let page = max(1, page)
        let path = forumID.key == recentKey ? "/recent" : "/go/\(forumID.key)"
        return url(path, query: page == 1 ? [] : [.init(name: "p", value: String(page))])
    }

    /// 节点目录。六个「位面」各带一组节点，是站点自己的分组方式。
    ///
    /// 不用 `/api/nodes/all.json` 来铺目录：那份 JSON 里的 `parent_node_name`
    /// 分出来是 595 个顶层节点加几百个小组，摊在目录里没法看；`/planes` 给的是
    /// 六组（混沌海、机械境……），和网页版的节点页一致。
    static let planes = url("/planes")

    /// 节点全表。搜索节点时用它 —— 站点自己的搜索框也是拉这份数据在本地过滤。
    static let nodes = url("/api/nodes/all.json")

    // MARK: - 主题

    /// 主题页。每页 100 层，见 `repliesPerPage`。
    static func topic(topicID: TopicID, page: Int) -> URL {
        url("/t/\(topicID.rawValue)", query: [.init(name: "p", value: String(max(1, page)))])
    }

    /// 每页楼层数。站点的锚点是 `#reply25` 这样的**楼层号**，不是页码 ——
    /// 要跳过去就得自己算在第几页。
    static let repliesPerPage = 100

    static func page(ofFloor floor: Int) -> Int {
        floor <= 0 ? 1 : (floor - 1) / repliesPerPage + 1
    }

    // MARK: - 用户

    /// 会员资料。站点只有这一个还开着的会员接口，按编号或用户名都能问。
    ///
    /// 用编号问：应用内部一律拿 `Int64` 认人，而页面地址用的是用户名，
    /// 两者之间的翻译就靠这个接口。
    static func member(uid: Int64) -> URL {
        url("/api/members/show.json", query: [.init(name: "id", value: String(uid))])
    }

    static func member(username: String) -> URL {
        url("/api/members/show.json", query: [.init(name: "username", value: username)])
    }

    /// 某人发过的主题 / 回复。地址里是**用户名**，不是编号。
    static func memberTopics(username: String, page: Int) -> URL {
        url("/member/\(username)/topics", query: [.init(name: "p", value: String(max(1, page)))])
    }

    static func memberReplies(username: String, page: Int) -> URL {
        url("/member/\(username)/replies", query: [.init(name: "p", value: String(max(1, page)))])
    }

    /// 用户主页。解析用不上，「在浏览器中打开」用得上。
    static func memberPage(username: String) -> URL { url("/member/\(username)") }

    // MARK: - 站内搜索（第三方）

    /// 主题搜索走 SoV2EX。
    ///
    /// **它不是 V2EX。** `sov2ex.com` 是第三方建的全文索引，V2EX 自己没有主题搜索 ——
    /// 站点搜索框里那四档（节点、用户、谷歌、SoV2EX）它排第四，是唯一一个真能
    /// 搜正文的。接它意味着关键词会离开 V2EX，所以：**绝不能带着用户的会话去请求**，
    /// 见 `V2EXNetworkClient.getThirdParty`。
    ///
    /// 三处和界面上写的不一样（实测 2026-09-08）：
    ///
    /// - 日期范围 `gte` / `lte` 收的是**秒**。它表单上写着 `YYYY-MM-DD`，传日期字符串
    ///   答 400；而传毫秒**不报错、悄悄返回 0 条** —— 那个数落在很远的将来，
    ///   什么都不在范围里。只看状态码验不出这条，得比对结果条数：
    ///   `gte=1735689600`（2025-01-01）是 273 条，同一时刻的毫秒形式是 0 条。
    /// - `node` 收的是**节点名**。表单说「支持节点名称与节点 id」，可传数字编号时
    ///   过滤根本不生效 —— 结果条数和不带这个参数一模一样（410 对 410），
    ///   而传 `qna` 是 41 条。
    /// - `order=0` 是**降序**，`1` 是升序。
    static func search(
        query: String,
        node: String?,
        page: Int,
        pageSize: Int,
        filters: ForumSearchFilters = .none
    ) -> URL {
        var items = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "from", value: String(max(0, (max(1, page) - 1) * pageSize))),
            URLQueryItem(name: "size", value: String(pageSize)),
            URLQueryItem(
                name: "sort",
                // 站点自己的两个词。默认那个（权重）就是不带筛选时的排法。
                value: filters.sort == .postedAt ? "created" : "sumup"
            ),
            URLQueryItem(name: "order", value: filters.isAscending ? "1" : "0")
        ]
        if let node, !node.isEmpty { items.append(URLQueryItem(name: "node", value: node)) }
        // 没填就整个不带。带一个空的 `username=` 和不带不是一回事。
        if let author = filters.trimmedAuthor {
            items.append(URLQueryItem(name: "username", value: author))
        }
        if let after = filters.postedAfter {
            items.append(URLQueryItem(name: "gte", value: String(Self.seconds(startOf: after))))
        }
        if let before = filters.postedBefore {
            items.append(URLQueryItem(name: "lte", value: String(Self.seconds(endOf: before))))
        }
        var components = URLComponents(string: "https://www.sov2ex.com/api/search")!
        components.queryItems = items
        return components.url!
    }

    /// 用户选的是「哪一天」，两端都要含当天。
    ///
    /// 下界取当天零点，上界取当天最后一秒 —— 直接把两端都送成同一个时刻的话，
    /// 「从 1 号到 1 号」会一条都搜不到。按本地时区算：用户看到的日历是本地的。
    private static func seconds(startOf date: Date) -> Int {
        Int(Calendar.current.startOfDay(for: date).timeIntervalSince1970)
    }

    private static func seconds(endOf date: Date) -> Int {
        let start = Calendar.current.startOfDay(for: date)
        let next = Calendar.current.date(byAdding: .day, value: 1, to: start) ?? start
        return Int(next.timeIntervalSince1970) - 1
    }

    /// 每页取多少条。接口允许 1~50，默认 10。
    ///
    /// 取 20：太少的话一屏都填不满，还得马上翻页；取满 50 则要等一次更久的往返，
    /// 而搜索结果很少有人翻到第三屏。
    static let searchPageSize = 20

    /// 搜索结果页上那句「结果来自哪儿」。第三方的事要说出来。
    static let searchProviderName = "SoV2EX"

    // MARK: - 写操作

    /// 一次性令牌。
    ///
    /// 站点的每个写动作都带 `once`，而它**不是每会话一个常量**：站点自己的
    /// `fetchOnce()` 会在本地缓存 10 秒，过期就重新问这个地址（响应体是一串纯数字）。
    /// 所以每次写之前现取一个，不缓存 —— 省下的那点请求不值得赌一个过期的令牌。
    static let pollOnce = url("/poll_once")

    /// 发一条回复。表单 POST 到主题页自己的地址，字段是 `content` 和 `once`。
    static func reply(topicID: TopicID) -> URL { url("/t/\(topicID.rawValue)") }

    /// 感谢一条回复。**这一下会从感谢者账上扣掉 10 个铜币，而且撤不回来。**
    ///
    /// 抄自站点自己的 JS：
    ///
    /// ```js
    /// function thankReply(replyId) {
    ///   $.post('/thank/reply/' + replyId + "?once=" + once, function (data) {
    ///     if (data.success) { once = data.once; ...; refreshMoney(); }
    ///     else { alert(data.message); once = data.once; }
    ///   });
    /// }
    /// ```
    ///
    /// 末尾那句 `refreshMoney()` 就是代价的证据：成功之后余额变了，所以要重新拉一次。
    static func thankReply(postID: PostID, once: String) -> URL {
        url("/thank/reply/\(postID.rawValue)", query: [.init(name: "once", value: once)])
    }

    /// 感谢一个主题。同样扣 10 个铜币，同样撤不回来。
    static func thankTopic(topicID: TopicID, once: String) -> URL {
        url("/thank/topic/\(topicID.rawValue)", query: [.init(name: "once", value: once)])
    }

    /// 感谢那一下的编号。楼层的表态在应用里按字符串认，这是 V2EX 唯一的一种。
    static let thankReactionID = "thank"

    /// 感谢要花掉感谢者多少个铜币。写在按钮的确认框里。
    static let thankCost = 10

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
