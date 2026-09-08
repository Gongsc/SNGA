import Foundation
import SwiftSoup

/// 解析 V2EX 的网页与那两个还活着的 JSON 接口。
///
/// 站点的形状和 NodeSeek 相反：**网页是主干**。节点列表、主题、回复、用户页全是
/// 服务端渲染的 HTML，而且从首页到节点页到「某人发过的主题」，用的都是同一套
/// `div.cell` 模板 —— 所以 `topicList` 一个入口吃下四种页面，不必各写一份。
///
/// 这里只解析，不拼地址 —— 地址一律来自 `V2EXEndpoint`。
/// 每个入口都配一份取自真实响应的夹具，见 `SNGATests/Fixtures/`。
struct V2EXParser: Sendable {

    // MARK: - 主题列表

    /// 一页主题列表。
    ///
    /// 同一个方法要认四种页面：`/recent`、`/go/{节点}`、`/member/{用户名}/topics`、
    /// 以及登录后的收藏列表。它们的外层类名不一样（节点页是
    /// `div.cell.from_{会员}.t_{主题}`，其余是 `div.cell.item`），里面那张表却是同一份，
    /// 所以按「这个 `div.cell` 里有没有标题链接」来认，而不是按类名。
    func topicList(html: String, forumID: ForumID, page: Int) throws -> ForumPage {
        let document = try SwiftSoup.parse(html, Self.baseURI)
        let topics = try self.topics(in: document, fallbackForumID: forumID)
        guard !topics.isEmpty else {
            // 空节点是真的存在的，但那种页面上仍然有节点抬头。抬头都没有才另说。
            if try document.select("input.page_input, .node-header, .cell_tabs, #SecondaryTabs")
                .isEmpty() {
                // 先看是不是站点在说「没有这个节点」。它答的是 **200**，不是 404，
                // 页面结构也正常，只是里面没有列表 —— 报成「结构已变化」既不对
                // 也没用：站点没坏，是节点不在。
                if let reason = try Self.missingNodeReason(in: document) {
                    throw ForumServiceError.restricted(reason)
                }
                throw ForumServiceError.unexpectedPage("未找到主题列表")
            }
            return ForumPage(forum: nil, topics: [], page: page, hasMore: false, totalPages: 1)
        }

        let totalPages = try Self.totalPages(in: document, currentPage: page)
        return ForumPage(
            forum: try Self.nodeHeader(in: document, forumID: forumID),
            topics: topics,
            page: page,
            hasMore: page < totalPages,
            totalPages: totalPages,
            subforums: try Self.secondaryTabs(in: document)
        )
    }

    /// 首页分类底下那第二排节点。
    ///
    /// 站点把它画成 `#SecondaryTabs`，一排 `/go/{节点}` 的链接 ——「技术」这一格
    /// 下面是程序员、Python、iDev……它们就是这个分类聚合的那几个节点，
    /// 所以当作子版面交出去：界面已经有一套画子版面的东西，还能按节点筛掉几个不看。
    ///
    /// 只有首页分类有这一排；节点页和 `/recent` 上没有这个元素，返回空数组。
    private static func secondaryTabs(in document: Document) throws -> [Forum] {
        var forums: [Forum] = []
        var seen = Set<String>()
        for link in try document.select("#SecondaryTabs a[href^=/go/]") {
            guard let id = Self.forumID(fromPath: try link.attr("href")) else { continue }
            guard seen.insert(id.key).inserted else { continue }
            let name = try link.text().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            forums.append(Forum(
                id: id,
                name: name,
                category: "节点",
                // **一律是勾上的。** 站点在服务端就把这几个节点的主题聚合进来了，
                // 它们本来就全在列表里；留空的话界面会把它们统统筛掉，
                // 一格分类只剩下几条来自别的节点的零星主题。
                isSelectedInParent: true,
                isSubforum: true,
                searchAliases: [id.key]
            ))
        }
        return forums
    }

    /// 把一张页面上的主题都刮下来。
    ///
    /// 四种页面（首页分类、节点页、`/recent`、某人发过的主题）的外层类名不一样，
    /// 里面那张表却是同一份，所以按「这个 `div.cell` 里有没有标题链接」来认。
    private func topics(in document: Document, fallbackForumID: ForumID) throws -> [Topic] {
        var topics: [Topic] = []
        for cell in try document.select("div.cell") {
            guard let topic = try self.topic(from: cell, fallbackForumID: fallbackForumID) else {
                continue
            }
            topics.append(topic)
        }
        return topics
    }

    private func topic(from cell: Element, fallbackForumID: ForumID) throws -> Topic? {
        guard let titleLink = try cell.select("span.item_title > a[href]").first() else {
            return nil
        }
        guard let topicID = Self.topicID(fromPath: try titleLink.attr("href")) else { return nil }
        let subject = try titleLink.text().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !subject.isEmpty else { return nil }

        let info = try cell.select("span.topic_info").first()
        // 第一个会员链接是作者，第二个是「最后回复来自」。顺序是模板定的，
        // 不按顺序取的话，有人回过的帖子作者会变成最后那个回帖的人。
        let authorLink = try info?.select("strong > a[href]").first()
        let author = try authorLink?.text().trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // 头像上带着编号。「某人发过的主题」那种页面整列头像都不画，那里就没有编号 ——
        // 打开主题用不到它，缺了不影响。
        let authorUID = try cell.select("img.avatar[data-uid]").first()
            .flatMap { Int64(try $0.attr("data-uid")) }

        // 节点链接只有混合列表才有（首页、最近、某人的主题）。节点页里每条都属于
        // 当前节点，模板就不重复画了 —— 那时用调用方给的那个。
        let nodeLink = try info?.select("a.node[href]").first()
        let nodeForumID = try nodeLink.flatMap { Self.forumID(fromPath: try $0.attr("href")) }
        let forumID = nodeForumID ?? fallbackForumID
        let nodeName = try nodeLink?.text().trimmingCharacters(in: .whitespacesAndNewlines)

        // 列表上那个数是**最后回复时间**，不是发帖时间：同一个帖子，列表写
        // 14:43、主题页的抬头写 10:07。所以它进 `lastReplyAt`。
        let lastReplyAt = try info?.select("span[title]").first()
            .flatMap { Self.date(fromTitle: try $0.attr("title")) }

        // 零回复的帖子模板里干脆不画这个链接，不是画一个 0。
        let replyCount = try cell.select("a.count_livid, a.count_orange").first()
            .flatMap { Int(try $0.text().trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0

        return Topic(
            id: topicID,
            forumID: forumID,
            subject: subject,
            author: author,
            authorUID: authorUID,
            replyCount: replyCount,
            lastReplyAt: lastReplyAt,
            // 只有混合列表才填「这条实际来自哪个节点」。节点页里每条都属于当前节点，
            // 填了等于说它来自别处。首页分类靠这个值把主题按第二排的节点筛开 ——
            // 见 `ForumStore.displayedTopics`。
            sourceForumID: nodeForumID,
            sourceForumName: nodeName
        )
    }

    /// 站点说「没有这个节点」的那句话。
    ///
    /// 面包屑的最后一段就是它：`<div class="header"><a href="/">V2EX</a> › 节点未找到</div>`。
    /// 取 `ownText()` 才拿得到那几个字 —— `text()` 会把前面的「V2EX ›」也带上。
    /// 这一段站点没有翻译过，英文语言下也是这几个字。
    ///
    /// **面包屑里必须只有一个链接。** 光看「抬头里有句短文字」远远不够，栽过一次：
    /// `/member/{名字}/topics` 的抬头是「V2EX › 某人 › 全部主题」，一个没发过主题、
    /// 或者把主题列表藏起来的会员，那一页上同样没有列表 —— 于是每次切到 V2EX
    /// 都弹一句「V2EX：全部主题」。那种页面的面包屑有**两个**链接，这里挡掉。
    private static func missingNodeReason(in document: Document) throws -> String? {
        guard let header = try document.select("#Main .box .header").first() else { return nil }
        guard try header.select("a").count == 1 else { return nil }
        let text = try header.ownText()
            .trimmingCharacters(in: CharacterSet(charactersIn: " ›\u{00A0}\n\t"))
        // 一句话才是说明。整页的文字都堆在这里，说明认错了地方。
        guard !text.isEmpty, text.count <= 20 else { return nil }
        return text
    }

    /// 节点页抬头里的节点资料。不是节点页（首页、最近、用户页）就返回 nil。
    private static func nodeHeader(in document: Document, forumID: ForumID) throws -> Forum? {
        guard let header = try document.select(".node-header .page-content-header").first() else {
            return nil
        }
        // 面包屑长成「V2EX › 问与答」：前半截是个链接，节点名是后面那段裸文字，
        // 所以取 `ownText()` 而不是 `text()` —— 后者会得到「V2EX › 问与答」。
        let name = try header.select(".node-breadcrumb").first()?
            .ownText()
            .trimmingCharacters(in: CharacterSet(charactersIn: " ›\u{00A0}\n\t"))
        guard let name, !name.isEmpty else { return nil }
        let intro = try header.select(".intro").first()?
            .text()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Forum(
            id: forumID,
            name: name,
            subtitle: (intro?.isEmpty ?? true) ? nil : intro,
            iconURL: try header.select("img[src]").first()
                .flatMap { URL(string: try $0.attr("abs:src")) },
            category: "节点",
            // 节点的英文名（`qna`）是站点自己的说法，也是地址里的那一段。
            // 并进搜索词，目录里搜 "qna" 才找得到「问与答」。
            searchAliases: [forumID.key]
        )
    }

    /// 从分页条读总页数。
    ///
    /// 读的是那个跳页输入框的 `max`，不是页码链接：链接列表在页数多时会省略成
    /// 「1 2 3 … 12072」，而 `max` 一直是准数。只有一页时模板不画分页条。
    static func totalPages(in document: Document, currentPage: Int) throws -> Int {
        guard let input = try document.select("input.page_input[max]").first() else {
            return max(1, currentPage)
        }
        return max(max(1, currentPage), Int(try input.attr("max")) ?? 1)
    }

    // MARK: - 主题页

    /// 一页主题。
    ///
    /// 主楼画在抬头那个 `div.box` 里，回复在下一个 `div.box` 里，各是各的形状 ——
    /// 和 NodeSeek 那种「一个类名选完」不一样，所以分两段解析。
    ///
    /// **主楼只在第一页给出。** 站点每一页都重画一遍抬头和正文，跟着照搬的话，
    /// 翻到第二页会看到主楼又出现在第 101 层前面。
    func threadPage(html: String, topicID: TopicID, page: Int) throws -> ThreadPage {
        let document = try SwiftSoup.parse(html, Self.baseURI)
        guard let header = try document.select("#Main .box .header").first() else {
            throw ForumServiceError.unexpectedPage("未找到主题抬头")
        }
        let opening = try self.opening(in: document, header: header, topicID: topicID)
        var posts = try document.select("#Main div[id^=r_]").compactMap {
            try post(from: $0, topicID: topicID)
        }
        if page <= 1, let opening {
            posts.insert(opening, at: 0)
        }
        guard !posts.isEmpty else {
            throw ForumServiceError.unexpectedPage("未找到主题正文")
        }

        let totalPages = try Self.totalPages(in: document, currentPage: page)
        return ThreadPage(
            topic: try topic(in: document, header: header, topicID: topicID, opening: opening),
            posts: posts,
            page: page,
            hasMore: page < totalPages,
            totalPages: totalPages
        )
    }

    /// 主楼。
    ///
    /// 正文之外还要收拢「附言」：站点把它们摆在正文后面一串 `div.subtle` 里，
    /// 每条带一个序号和时间。它们是主楼的一部分，漏掉就等于把楼主后来的更正吞了 ——
    /// 而更正往往正是最要紧的那句。
    private func opening(in document: Document, header: Element, topicID: TopicID) throws -> Post? {
        guard let content = try document.select("#Main .box .topic_content").first(),
              // 附言也用 `.topic_content`，但它们裹在 `.subtle` 里。第一个不该是附言。
              try content.parents().first(where: { try $0.hasClass("subtle") }) == nil else {
            return nil
        }
        let authorLink = try header.select("small.gray a[href]").first()
        var body = try Self.sanitizedBody(of: content)
        for supplement in try document.select("#Main .subtle") {
            guard let text = try supplement.select(".topic_content").first() else { continue }
            let caption = try supplement.select(".fade").first()?
                .text()
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "附言"
            body += "<hr><p><strong>\(Entities.escape(caption))</strong></p>"
            body += try Self.sanitizedBody(of: text)
        }

        return Post(
            // 主楼没有自己的回复编号 —— 站点感谢主楼走的是 `/thank/topic/{主题}`，
            // 感谢回复才走 `/thank/reply/{回复}`。所以这里放主题编号，
            // 适配器据此分辨该走哪条路（见 `V2EXForumService.submitPostReaction`）。
            id: PostID(rawValue: topicID.rawValue),
            topicID: topicID,
            floor: 0,
            author: try authorLink?.text().trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            authorUID: try header.select("img[data-uid]").first()
                .flatMap { Int64(try $0.attr("data-uid")) },
            avatarURL: try header.select("img[src]").first()
                .flatMap { URL(string: try $0.attr("abs:src")) },
            postedAt: try header.select("small.gray span[title]").first()
                .flatMap { Self.date(fromTitle: try $0.attr("title")) },
            html: Self.document(body),
            nativeContent: try Self.nativeContent(body),
            reactions: [Self.thankReaction(count: nil, isChosen: false)]
        )
    }

    private func post(from item: Element, topicID: TopicID) throws -> Post? {
        guard let postID = Self.postID(fromElementID: try item.id()) else { return nil }
        guard let content = try item.select("div.reply_content").first() else { return nil }
        let authorLink = try item.select("strong > a[href]").first()
        let ago = try item.select("span.ago").first()
        let agoText = try ago?.text() ?? ""
        let body = try Self.sanitizedBody(of: content)

        return Post(
            id: postID,
            topicID: topicID,
            floor: try item.select("span.no").first()
                .flatMap { Int(try $0.text().trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0,
            author: try authorLink?.text().trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            authorUID: try item.select("img[data-uid]").first()
                .flatMap { Int64(try $0.attr("data-uid")) },
            avatarURL: try item.select("img.avatar[src]").first()
                .flatMap { URL(string: try $0.attr("abs:src")) },
            postedAt: try ago.flatMap { Self.date(fromTitle: try $0.attr("title")) },
            device: Self.device(inAgoText: agoText),
            html: Self.document(body),
            nativeContent: try Self.nativeContent(body),
            reactions: [
                Self.thankReaction(
                    count: try Self.thankCount(in: item),
                    // 只有登录着才看得到这个类名 —— 匿名抓回来的页面里没有感谢按钮。
                    isChosen: try !item.select(".thanked").isEmpty()
                )
            ]
        )
    }

    private func topic(
        in document: Document,
        header: Element,
        topicID: TopicID,
        opening: Post?
    ) throws -> Topic {
        let nodeLink = try header.select("a[href^=/go/]").first()
        let forumID = try nodeLink
            .flatMap { Self.forumID(fromPath: try $0.attr("href")) }
            ?? ForumID.placeholder(site: .v2ex)
        return Topic(
            id: topicID,
            forumID: forumID,
            subject: try header.select("h1").first()?
                .text()
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            author: opening?.author ?? "",
            authorUID: opening?.authorUID,
            replyCount: try Self.replyCount(in: document),
            publishedAt: opening?.postedAt,
            sourceForumName: try nodeLink?.text().trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// 回复总数。
    ///
    /// 从「25 条回复」那一行读，不数这一页的楼层：主题超过 100 层就分页了，
    /// 数出来的只是本页的层数。
    private static func replyCount(in document: Document) throws -> Int {
        for cell in try document.select("#Main .box .cell > span.gray") {
            let text = try cell.text()
            guard let match = text.firstMatch(of: /(\d+)\s*条回复/) else { continue }
            return Int(match.1) ?? 0
        }
        return try document.select("#Main div[id^=r_]").count
    }

    /// 一条回复收到了多少次感谢。
    ///
    /// 站点画成一个心形图标加一个数字，那个 `span` 除了 `small fade` 没有别的标记 ——
    /// 而 `fade` 在页面里到处都是。所以认里面那张心形图，不认类名。
    private static func thankCount(in item: Element) throws -> Int? {
        for span in try item.select("span.fade") {
            guard try !span.select("img[src*=heart]").isEmpty() else { continue }
            let digits = try span.text().filter(\.isNumber)
            return digits.isEmpty ? nil : Int(digits)
        }
        return nil
    }

    /// 楼层上的「感谢」。
    ///
    /// **要花掉感谢者 10 个铜币，而且撤不回来**，所以它是一种带代价的表态
    /// （`PostReaction`），不是赞踩。界面据此先问一次再发 —— 见 `PostReactionBar`。
    static func thankReaction(count: Int?, isChosen: Bool) -> PostReaction {
        PostReaction(
            id: V2EXEndpoint.thankReactionID,
            title: "感谢",
            systemImage: "heart",
            count: count,
            isChosen: isChosen,
            cost: "花费 \(V2EXEndpoint.thankCost) 个铜币",
            isIrreversible: true
        )
    }

    /// 楼层时间后面跟的那半句 `via iPhone`。
    ///
    /// 站点只在客户端发的楼层上写这个，网页发的什么都不写 —— 所以认不出来时是 nil，
    /// 不是「桌面」。硬填桌面等于替站点断言了一件它没说的事。
    static func device(inAgoText text: String) -> PostDevice? {
        guard let match = text.firstMatch(of: /via\s+([A-Za-z]+)/) else { return nil }
        switch match.1.lowercased() {
        case "iphone", "ipad", "ipod", "mac", "macos", "safari": return .apple
        case "android": return .android
        default: return .desktop
        }
    }

    /// 页面里那个一次性令牌。
    ///
    /// 站点写成 `var once = "35953";`，主题页上就有 —— 匿名页也有，所以这一段
    /// 有夹具可对。写请求现取一个更稳（见 `V2EXNetworkClient.freshOnce`），
    /// 这里留着是为了「先取页面上的那个」这条路：同一次会话里它就是有效的那个。
    static func once(inHTML html: String) -> String? {
        guard let match = html.firstMatch(of: /var\s+once\s*=\s*"(\d+)"/) else { return nil }
        return String(match.1)
    }

    /// 从任意一张页面上读出「我是谁」。
    ///
    /// 登录之后站点会在页面里写一个 `memberId` 全局（它自己的草稿功能拿它当键），
    /// 顶栏头像的地址里也带着编号。两条都试：用 gravatar 当头像的会员，
    /// 地址里是一串哈希、没有编号，那时只有前一条管用。
    static func signedInUserID(inHTML html: String) -> Int64? {
        if let match = html.firstMatch(of: /var\s+memberId\s*=\s*(\d+)/) {
            return Int64(match.1)
        }
        guard let document = try? SwiftSoup.parse(html),
              let images = try? document.select("#menu-entry img, #Top img.avatar, .tools img") else {
            return nil
        }
        for image in images {
            if let uid = try? image.attr("data-uid"), let value = Int64(uid) { return value }
            guard let source = try? image.attr("src"),
                  let match = source.firstMatch(of: /\/avatar\/[^"'\s]*?(\d+)_[a-z]+\./) else {
                continue
            }
            return Int64(match.1)
        }
        return nil
    }

    // MARK: - 节点目录

    /// 节点目录。六个「位面」各带一组节点，是站点自己的分组。
    func planes(html: String) throws -> [Forum] {
        let document = try SwiftSoup.parse(html, Self.baseURI)
        var forums: [Forum] = []
        var seen = Set<String>()
        for box in try document.select("#Main .box") {
            // 抬头里除了位面名还有它的英文名和节点数，那两样是子元素，
            // 所以取 `ownText()`。
            let plane = try box.select(".header").first()?
                .ownText()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            for link in try box.select("a.item_node[href]") {
                guard let id = Self.forumID(fromPath: try link.attr("href")) else { continue }
                guard seen.insert(id.key).inserted else { continue }
                let name = try link.text().trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { continue }
                forums.append(Forum(
                    id: id,
                    name: name,
                    category: (plane?.isEmpty ?? true) ? "节点" : plane,
                    searchAliases: [id.key]
                ))
            }
        }
        guard !forums.isEmpty else {
            throw ForumServiceError.unexpectedPage("未找到节点目录")
        }
        return forums
    }

    /// 节点全表。搜索节点用它 —— 站点自己的搜索框也是拉这份数据在本地过滤。
    func nodes(json data: Data) throws -> [Forum] {
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw ForumServiceError.unexpectedPage("无法读取节点列表")
        }
        return rows.compactMap { row in
            guard let key = row["name"] as? String, !key.isEmpty else { return nil }
            let title = (row["title"] as? String) ?? key
            return Forum(
                id: V2EXEndpoint.forumID(key: key),
                name: title.isEmpty ? key : title,
                // 站点在节点页上就是这么写的：「主题总数 241,426」。
                subtitle: (row["topics"] as? NSNumber).map { "主题总数 \($0.intValue)" },
                category: "节点",
                searchAliases: [key] + ((row["aliases"] as? [String]) ?? [])
            )
        }
    }

    // MARK: - 会员

    func profile(json data: Data) throws -> Profile {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let uid = (root["id"] as? NSNumber)?.int64Value else {
            throw ForumServiceError.unexpectedPage("无法读取会员资料")
        }
        func text(_ key: String) -> String? {
            let value = (root[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (value?.isEmpty ?? true) ? nil : value
        }
        return Profile(
            uid: uid,
            displayName: text("username") ?? "会员 \(uid)",
            avatarURL: text("avatar_large").flatMap { URL(string: $0) },
            // 站点只分「PRO」和普通，没有等级也没有用户组。不是 PRO 就不说 ——
            // 填一个「普通会员」是我们自己编的词。
            userGroup: ((root["pro"] as? NSNumber)?.intValue ?? 0) > 0 ? "PRO" : nil,
            title: text("tagline"),
            registeredAt: (root["created"] as? NSNumber)
                .map { Date(timeIntervalSince1970: $0.doubleValue) },
            location: text("location"),
            signature: text("bio")
        )
    }

    /// 资料接口没有、只有网页上才有的那几样。
    ///
    /// 资料接口给的是身份和自我介绍；**今日活跃度排名、公司职位、外部链接**这三样
    /// 只画在网页上。所以看一份完整的资料要两次请求 —— 网页那次是附带的，
    /// 取不到就少显示几行，不该把整张资料页拖垮（见 `V2EXForumService.profile`）。
    ///
    /// 注意时间戳一律读 `title` 属性。网页上那几个 `data-original-title` 是
    /// tippy.js 在浏览器里改写出来的，服务端发的是 `title` —— 照着浏览器里看到的
    /// DOM 写选择器，抓下来的页面上一个都匹配不到。
    func applyMemberPage(html: String, to profile: inout Profile) throws {
        let document = try SwiftSoup.parse(html, Self.baseURI)
        guard let cell = try document.select("#Main .box .cell").first() else { return }

        // 「今日活跃度排名 626」—— 那个数字是一个指向排行榜的链接。
        // 认链接不认前面那句话：话是中文的，链接不是。
        profile.dailyRank = try cell.select("a[href=/top/dau]").first()
            .flatMap { Int(try $0.text().trimmingCharacters(in: .whitespacesAndNewlines)) }

        // 「🏢 公司 职位」。这一段没有类名，只能认那个图标 —— 站点自己也是拿它
        // 当标记的。公司和职位分别在 `<strong>` 和它后面的裸文字里，
        // 只填一样的人很多，所以拼起来之后再看剩什么。
        for span in try cell.select("span") where try span.text().contains("🏢") {
            let text = try span.text()
                .replacingOccurrences(of: "🏢", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            profile.affiliation = text.isEmpty ? nil : text
            break
        }

        // 站点在资料页上给的徽章：MOD（管理社区的权限）、PRO 这些。
        // 资料接口只报 `pro`，认不出管理员 —— 而那是读者最想一眼看到的一条。
        let badges = try cell.select(".badges .badge")
            .map { try $0.text().trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !badges.isEmpty {
            profile.userGroup = badges.joined(separator: " · ")
        }

        profile.links = try Self.profileLinks(in: document)
    }

    /// 资料页上那一排外部链接。
    ///
    /// 站点把它们画成 `.widgets` 里的 `a.social_label`，图标的 `alt` 就是种类
    /// （`Website`、`GitHub`、`Twitter`……），链接文字是显示出来的那串。
    /// 从这里读而不是从资料接口拼：接口给的是裸用户名，拼地址等于把
    /// 「GitHub 的主页长什么样」这件事抄进我们自己的代码；而且站点随时会加新的种类，
    /// 认不出来的照样带过来，用它自己的说法。
    private static func profileLinks(in document: Document) throws -> [ProfileLink] {
        var links: [ProfileLink] = []
        for anchor in try document.select(".widgets a.social_label") {
            guard let url = URL(string: try anchor.attr("abs:href")),
                  url.scheme == "http" || url.scheme == "https" else {
                continue
            }
            let value = try anchor.text().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            let kind = try anchor.select("img[alt]").first()
                .map { try $0.attr("alt").trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
            // 属地已经在「所在地」那一行了，再画一条指向谷歌地图的链接是重复。
            guard kind.caseInsensitiveCompare("Geo") != .orderedSame else { continue }
            links.append(ProfileLink(title: Self.linkTitle(kind: kind), value: value, url: url))
        }
        return links
    }

    /// 链接种类在界面上叫什么。认不出来的用站点自己写的那个词，不瞎猜。
    private static func linkTitle(kind: String) -> String {
        switch kind.lowercased() {
        case "website": "主页"
        case "": "链接"
        default: kind
        }
    }

    /// 会员编号到用户名。
    ///
    /// 用户页的地址里是**用户名**，应用内部一律拿编号认人，中间这一步只能问接口。
    func username(json data: Data) throws -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let username = root["username"] as? String,
              !username.isEmpty else {
            throw ForumServiceError.unexpectedPage("这个会员编号查不到用户名")
        }
        return username
    }

    // MARK: - 用户动态

    /// 某人发过的主题。列表模板和节点页是同一套。
    ///
    /// **一条都没有是正常的，不是解析失败。** 站点允许会员把自己的主题列表藏起来
    /// （那一页上写着「根据 X 的设置，主题列表被隐藏」），也有人就是没发过主题。
    /// 这两种页面上都没有列表、没有分页条 —— 走版面列表那道「什么都认不出来就报错」
    /// 的关卡，会把一件平常事说成故障，而用户中心一打开就会撞上它。
    func userTopics(html: String, page: Int) throws -> UserActivityPage {
        let document = try SwiftSoup.parse(html, Self.baseURI)
        let topics = try self.topics(in: document, fallbackForumID: .placeholder(site: .v2ex))
        let totalPages = try Self.totalPages(in: document, currentPage: page)
        return UserActivityPage(
            kind: .topics,
            activities: topics.map { topic in
                UserActivity(
                    id: "topics-\(topic.id.rawValue)",
                    kind: .topics,
                    topicID: topic.id,
                    forumID: topic.forumID,
                    forumName: topic.sourceForumName,
                    subject: topic.subject,
                    postedAt: topic.lastReplyAt
                )
            },
            page: page,
            hasMore: page < totalPages,
            totalPages: totalPages
        )
    }

    /// 某人发过的回复。
    ///
    /// 这一页的形状和别处都不一样：一条动态摊成**两个相邻的兄弟节点** ——
    /// `div.dock_area` 装「回复了谁的哪个主题」，紧跟着的 `div.inner` 装回复正文。
    /// 所以要成对地走，不能各选各的再按下标配对：中间夹一条广告，两列就错开了。
    func userReplies(html: String, page: Int) throws -> UserActivityPage {
        let document = try SwiftSoup.parse(html, Self.baseURI)
        var activities: [UserActivity] = []
        for (index, dock) in try document.select("#Main .dock_area").enumerated() {
            guard let topicLink = try dock.select("a[href^=/t/]").last(),
                  let topicID = Self.topicID(fromPath: try topicLink.attr("href")) else {
                continue
            }
            let nodeLink = try dock.select("a[href^=/go/]").first()
            // 正文在下一个兄弟节点里。不是 `.inner` 就说明这条没有正文，别往下找 ——
            // 再往下找会捡到下一条动态的正文，把话安在错的人头上。
            let excerpt = try dock.nextElementSibling()
                .flatMap { try $0.hasClass("inner") ? $0.select(".reply_content").first() : nil }
                .map { try $0.text().trimmingCharacters(in: .whitespacesAndNewlines) }
            activities.append(UserActivity(
                // 同一个主题可以回好几层，光用主题编号会撞。页码带上，
                // 翻页之后两页的动态并排放也不会撞。
                id: "replies-\(topicID.rawValue)-\(page)-\(index)",
                kind: .replies,
                topicID: topicID,
                forumID: try nodeLink.flatMap { Self.forumID(fromPath: try $0.attr("href")) },
                forumName: try nodeLink?.text().trimmingCharacters(in: .whitespacesAndNewlines),
                subject: try topicLink.text().trimmingCharacters(in: .whitespacesAndNewlines),
                excerpt: (excerpt?.isEmpty ?? true) ? nil : excerpt,
                // 这一页的时间戳只有相对说法（「23 分钟前」），没有 `title` 属性。
                // 把相对时间硬换算成绝对时间会得到一个假的精确值，所以留空。
                postedAt: try dock.select("span[title]").first()
                    .flatMap { Self.date(fromTitle: try $0.attr("title")) }
            ))
        }
        let totalPages = try Self.totalPages(in: document, currentPage: page)
        return UserActivityPage(
            kind: .replies,
            activities: activities,
            page: page,
            hasMore: page < totalPages,
            totalPages: totalPages
        )
    }

    // MARK: - 写操作的结果

    /// 一次感谢之后站点说了什么。
    ///
    /// 响应形如 `{"success": true, "once": 12345}`；失败时 `success` 为假，
    /// `message` 里是要显示给用户的那句话（抄自站点的 `thankReply`：
    /// 失败那一支就是 `alert(data.message)`）。
    func confirmThank(json data: Data) throws {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ForumServiceError.unexpectedPage("无法读取感谢的结果")
        }
        let succeeded = (root["success"] as? NSNumber)?.boolValue
            ?? (root["success"] as? Bool)
            ?? false
        guard succeeded else {
            let message = (root["message"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw ForumServiceError.restricted(message.isEmpty ? "感谢没有成功" : message)
        }
    }

    /// 一次回复之后站点说了什么。
    ///
    /// 回复是表单提交，成功时站点 302 回主题页 —— 没有 JSON 可读。所以判据反过来：
    /// **看返回的页面里有没有出错提示**。站点把它写成 `div.problem`
    /// （「请输入回复内容」「你上一条回复的时间过近」这类）。
    func confirmReply(html: String) throws {
        guard let document = try? SwiftSoup.parse(html) else { return }
        guard let problem = try? document.select("#Main .problem").first() else { return }
        let message = (try? problem.text().trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
        guard !message.isEmpty else { return }
        throw ForumServiceError.restricted(message)
    }

    // MARK: - 正文

    /// 预览用：把一段纯文本变成站点会渲染出来的样子。
    ///
    /// 站点对回复只做两件事 —— 转义，然后把换行换成 `<br>`。照着做，
    /// 别借道 Markdown：那样 `**粗体**` 会在预览里变粗，发出去却是四个星号。
    static func plainTextPreviewHTML(_ source: String) -> String {
        let escaped = source
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return "<p>" + escaped
            .split(separator: "\n", omittingEmptySubsequences: false)
            .joined(separator: "<br>") + "</p>"
    }

    /// 正文清洗：脚本、样式、iframe、表单、事件属性一律去掉。
    ///
    /// 楼层正文是别人写的，要进 `WKWebView`。SwiftSoup 的 relaxed 白名单已经挡掉了
    /// 脚本和事件属性，这里再显式去掉几类它允许但我们不想要的。
    private static func sanitizedBody(of element: Element) throws -> String {
        // 主题正文外面还套着一层 `.markdown_body`，剥掉它只是少一层 div，
        // 但正文里的 `<div>` 白名单本来就不放行，留着反而多一层没有样式的壳。
        let source = try element.select("> .markdown_body").first() ?? element
        // 换在清洗之前：清洗会把 iframe 整个丢掉，连地址一起。
        try replaceEmbeds(in: source)
        try resolveRelativeURLs(in: source)
        let cleaned = try SwiftSoup.clean(
            try source.html(),
            baseURI,
            try postWhitelist(),
            verbatimOutput
        ) ?? ""
        let document = try SwiftSoup.parseBodyFragment(cleaned)
        document.outputSettings(verbatimOutput)
        for tag in ["script", "style", "iframe", "form", "object", "embed"] {
            try document.select(tag).remove()
        }
        return try document.body()?.html() ?? cleaned
    }

    /// 把清洗好的正文装进外壳。字体、配色、主题变量和 CSP 全在这层里，
    /// 少了它正文会用 WebKit 的默认字体，深色下还是白底黑字。
    private static func document(_ body: String) -> String {
        PostDocument.html(body: body, extraCSS: PostDocument.markdownStyleSheet)
    }

    /// 能原生画就原生画，画不了返回 nil 交给 `WKWebView`。
    ///
    /// 交给 `PostContentBuilder` 的必须是 **body 元素**，不是整份文档 ——
    /// 后者外面还套着 `html`，那是它不认识的节点，于是整层回退。
    /// 这个站的正文十有八九是几段文字加链接，本来都还原得了。
    private static func nativeContent(_ body: String) throws -> PostContent? {
        let fragment = try SwiftSoup.parseBodyFragment(body)
        fragment.outputSettings(verbatimOutput)
        guard let root = try fragment.body() else { return nil }
        return PostContentBuilder.content(from: root)
    }

    /// 把内嵌的播放器换成一条链接。
    ///
    /// 站点会把视频地址渲染成一个播放器：
    /// `<div class="embedded_video_wrapper"><iframe src="https://www.youtube.com/embed/…"></iframe></div>`。
    /// 而 `iframe` 是清洗时一定要去掉的东西 —— 正文是别人写的，要进 `WKWebView`。
    /// 于是那一层楼里的视频**连地址都不剩**：读者只看到半句话，不知道后面本来有东西。
    ///
    /// 也不能改成留着 iframe 让它播：文档的 CSP 是 `default-src 'none'`，
    /// 留着也是一块空白。所以在清洗**之前**把它换成一条能点的链接 ——
    /// 播不了，至少去得了。
    ///
    /// 按标签认，不按站点认：`embedded_video_wrapper` 这个类名是 V2EX 现在的写法，
    /// 而「iframe 里装着一个地址」是通用的。哪天它换个包装，这里照样接得住。
    private static func replaceEmbeds(in element: Element) throws {
        for embed in try element.select("iframe[src], video[src], video source[src]") {
            let source = try embed.attr("abs:src")
            guard source.hasPrefix("http://") || source.hasPrefix("https://") else {
                // 解不出地址的播放器留着也没用，去掉 —— 反正清洗那一步也会去掉。
                try embed.remove()
                continue
            }
            // `<video>` 里的 `<source>` 要换掉的是整个 `<video>`，
            // 不然剩一个空壳在那儿。
            let target = embed.tagName() == "source" ? (embed.parent() ?? embed) : embed
            let document = target.ownerDocument()
            let paragraph = try document?.createElement("p") ?? Element(Tag.valueOf("p"), "")
            let anchor = try document?.createElement("a") ?? Element(Tag.valueOf("a"), "")
            try anchor.attr("href", source)
            // 链接文字就写地址本身：说「视频」而不给地址，读者还是不知道去哪儿；
            // 而地址里通常就带着是哪个站、哪一支。
            try anchor.text("视频：\(source)")
            try paragraph.appendChild(anchor)
            try target.replaceWith(paragraph)
        }
    }

    private static func resolveRelativeURLs(in element: Element) throws {
        for image in try element.select("img[src]") {
            let absolute = try image.attr("abs:src")
            // 解不出绝对地址的图只会渲染成一个裂图，不如去掉。
            if absolute.isEmpty { try image.remove() } else { try image.attr("src", absolute) }
        }
        for link in try element.select("a[href]") {
            let absolute = try link.attr("abs:href")
            if absolute.hasPrefix("http://") || absolute.hasPrefix("https://") {
                try link.attr("href", absolute)
            } else {
                // `javascript:` 之类的留着比丢掉危险。
                try link.removeAttr("href")
            }
        }
    }

    private static func postWhitelist() throws -> Whitelist {
        let whitelist = try Whitelist.relaxed()
        // 站点把代码块渲染成 `<pre><code class="language-swift">`，高亮靠那个类名。
        _ = try whitelist.addAttributes("code", "class")
        _ = try whitelist.addAttributes("pre", "class")
        return whitelist
    }

    /// 原样输出：不要 pretty-print，否则 `<pre>` 里会多出换行和缩进。
    private static var verbatimOutput: OutputSettings {
        OutputSettings().prettyPrint(pretty: false)
    }

    private static let baseURI = ForumSiteDescriptor.v2ex.baseURL.absoluteString

    // MARK: - 路径与时间

    static func topicID(fromPath path: String) -> TopicID? {
        guard let match = path.firstMatch(of: /\/t\/(\d+)/), let id = Int64(match.1) else {
            return nil
        }
        return TopicID(rawValue: id)
    }

    static func forumID(fromPath path: String) -> ForumID? {
        guard let match = path.firstMatch(of: /\/go\/([^\/?#]+)/) else { return nil }
        let key = String(match.1)
        return V2EXEndpoint.forumID(key: key.removingPercentEncoding ?? key)
    }

    static func username(fromPath path: String) -> String? {
        guard let match = path.firstMatch(of: /\/(?:member|u)\/([^\/?#]+)/) else { return nil }
        return String(match.1).removingPercentEncoding
    }

    /// `r_18060707` → 18060707。
    static func postID(fromElementID id: String) -> PostID? {
        guard let match = id.wholeMatch(of: /r_(\d+)/), let value = Int64(match.1) else {
            return nil
        }
        return PostID(rawValue: value)
    }

    /// `2026-09-08 10:07:41 +08:00`。
    ///
    /// 页面上写的是「4 小时 38 分钟前」这种相对时间，只有 `title` 属性里是绝对时间。
    /// 相对时间不能用 —— 它随着页面被抓取的时刻漂移。
    static func date(fromTitle value: String) -> Date? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        // 每次现造一个：`DateFormatter` 不是 Sendable，存成静态属性过不了严格并发检查。
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss XXXXX"
        return formatter.date(from: text)
    }
}
