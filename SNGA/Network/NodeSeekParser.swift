import Foundation
import SwiftSoup

/// 解析 NodeSeek 的网页。
///
/// 站点没有公开 API：列表页和帖子页都是服务端渲染的 HTML。这里只解析，不拼地址 ——
/// 地址一律来自 `NodeSeekEndpoint`。
///
/// 每个入口都配一份取自真实响应的夹具，见 `SNGATests/Fixtures/`。
struct NodeSeekParser: Sendable {

    /// 一页话题列表。
    ///
    /// 页码不从「有没有下一页」按钮读：站点在翻过尾页时**仍然渲染那个按钮**，
    /// 靠它判断会一直往下翻。改从分页条里最大的那个页码取。
    func topicList(html: String, forumID: ForumID, page: Int) throws -> ForumPage {
        let document = try SwiftSoup.parse(html, ForumSiteDescriptor.nodeseek.baseURL.absoluteString)
        let items = try document.select("li.post-list-item")
        guard !items.isEmpty() else {
            throw ForumServiceError.unexpectedPage("未找到话题列表")
        }

        var topics: [Topic] = []
        for item in items {
            guard let topic = try self.topic(from: item, fallbackForumID: forumID) else { continue }
            topics.append(topic)
        }
        guard !topics.isEmpty else {
            throw ForumServiceError.unexpectedPage("话题列表为空")
        }

        let totalPages = try self.totalPages(in: document, currentPage: page)
        return ForumPage(
            forum: nil,
            topics: topics,
            page: page,
            hasMore: page < totalPages,
            totalPages: totalPages
        )
    }

    private func topic(from item: Element, fallbackForumID: ForumID) throws -> Topic? {
        guard let titleLink = try item.select("div.post-title > a[href]").first() else { return nil }
        let href = try titleLink.attr("href")
        guard let topicID = Self.topicID(fromPath: href) else { return nil }
        let subject = try titleLink.text().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !subject.isEmpty else { return nil }

        let authorLink = try item.select("span.info-author a[href]").first()
        let author = try authorLink?.text().trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let authorUID = try authorLink.map { try Self.uid(fromPath: $0.attr("href")) } ?? nil

        // 两个数字挨在一起，都在 title 属性里：外层 span 是回复数，内层是楼层总数。
        let replyCount = try item.select("span.info-comments-count > span").first()
            .flatMap { Int(try $0.text().trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0

        // `<time datetime="2026-08-26T07:11:09.000Z">`，页面上显示的是「5s ago」这种相对时间，
        // 不能用 —— 取属性里的绝对时间。
        let lastReplyAt = try item.select("time[datetime]").first()
            .flatMap { Self.date(fromISO8601: try $0.attr("datetime")) }

        // 分类可能和当前列表不同：综合首页会混着各分类的帖子。
        let categoryLink = try item.select("a.post-category[href]").first()
        let forumID = try categoryLink
            .flatMap { Self.forumID(fromPath: try $0.attr("href")) } ?? fallbackForumID
        let categoryName = try categoryLink?.text().trimmingCharacters(in: .whitespacesAndNewlines)

        return Topic(
            id: topicID,
            forumID: forumID,
            subject: subject,
            author: author,
            authorUID: authorUID,
            replyCount: replyCount,
            lastReplyAt: lastReplyAt,
            // 置顶只以那个图标的 title 出现，没有别的标记。
            isPinned: !(try item.select("span[title=置顶]").isEmpty()),
            sourceForumName: categoryName
        )
    }

    /// 从分页条读总页数。
    ///
    /// 取 `.pager-pos` 里最大的页码。末页那颗按钮长成 `..100` 的样子，页码在 href 里，
    /// 从文字里读会得到 `..100`。
    private func totalPages(in document: Document, currentPage: Int) throws -> Int {
        var maximum = max(1, currentPage)
        for link in try document.select(".nsk-pager .pager-pos") {
            let href = try link.attr("href")
            if let page = Self.page(fromPath: href) { maximum = max(maximum, page) }
        }
        return maximum
    }

    /// 一页帖子。
    ///
    /// 主楼和回复在页面上分处两块 —— 主楼在 `.nsk-post` 里，回复在 `.comment-container` 里 ——
    /// 但两者用同一个 `.content-item` 类，`id` 属性就是楼层号（主楼是 `0`）。所以一次选完，
    /// 不必分别处理。
    func threadPage(html: String, topicID: TopicID, page: Int) throws -> ThreadPage {
        // 内嵌状态里什么都有，优先用它；解不开再退回抓 HTML。
        if let state = Self.embeddedState(inHTML: html),
           let page = try? threadPage(state: state, html: html, topicID: topicID, page: page) {
            return page
        }
        let document = try SwiftSoup.parse(html, ForumSiteDescriptor.nodeseek.baseURL.absoluteString)
        let items = try document.select(".content-item")
        guard !items.isEmpty() else {
            throw ForumServiceError.unexpectedPage("未找到帖子楼层")
        }

        var posts: [Post] = []
        for item in items {
            guard let post = try self.post(from: item, topicID: topicID) else { continue }
            posts.append(post)
        }
        guard !posts.isEmpty else {
            throw ForumServiceError.unexpectedPage("帖子楼层为空")
        }

        let totalPages = try self.totalPages(in: document, currentPage: page)
        return ThreadPage(
            topic: try self.topic(of: document, topicID: topicID, opening: posts.first),
            posts: posts,
            page: page,
            hasMore: page < totalPages,
            totalPages: totalPages
        )
    }

    /// 用内嵌状态构造一页帖子。
    ///
    /// 正文取渲染好的 HTML（内嵌状态里给的是 Markdown 原文，应用还没有渲染器），
    /// 其余一律取内嵌状态 —— 反应计数、我反应过没有、楼主标记、编辑时间都只有它有。
    private func threadPage(
        state: [String: Any],
        html: String,
        topicID: TopicID,
        page: Int
    ) throws -> ThreadPage {
        guard let postData = state["postData"] as? [String: Any],
              let comments = postData["comments"] as? [[String: Any]],
              !comments.isEmpty else {
            throw ForumServiceError.unexpectedPage("内嵌状态里没有楼层")
        }
        let renderedBodies = try self.renderedBodies(inHTML: html)

        var posts: [Post] = []
        for comment in comments {
            guard let commentID = (comment["commentId"] as? NSNumber)?.int64Value else { continue }
            let poster = comment["poster"] as? [String: Any] ?? [:]
            let uid = (poster["uid"] as? NSNumber)?.int64Value
            func count(_ key: String) -> Int { (comment[key] as? NSNumber)?.intValue ?? 0 }
            let times = comment["time"] as? [String: Any] ?? [:]

            posts.append(Post(
                id: PostID(rawValue: commentID),
                topicID: topicID,
                floor: (comment["floorIndex"] as? NSNumber)?.intValue ?? posts.count,
                author: poster["name"] as? String ?? "",
                authorUID: uid,
                avatarURL: uid.flatMap(Self.avatarURL(uid:)),
                postedAt: (times["createdDate"] as? String).flatMap(Self.date(fromISO8601:)),
                html: renderedBodies[commentID] ?? "",
                // 投喂是免费的那个，所以它对应界面上的赞；加鸡腿和反对都要花钱，
                // 不在这里露出来。见 `NodeSeekReaction`。
                upvoteCount: count("upvoteCount"),
                userVote: (comment["upvoted"] as? NSNumber)?.boolValue == true ? .up : nil
            ))
        }
        guard !posts.isEmpty else {
            throw ForumServiceError.unexpectedPage("内嵌状态里的楼层都读不出来")
        }

        let totalPages = max(1, (postData["postPageCount"] as? NSNumber)?.intValue ?? 1)
        let categoryKey = postData["category"] as? String
        return ThreadPage(
            topic: Topic(
                id: topicID,
                forumID: NodeSeekEndpoint.forumID(key: categoryKey ?? NodeSeekEndpoint.homeKey),
                subject: postData["title"] as? String ?? "",
                author: posts.first?.author ?? "",
                authorUID: posts.first?.authorUID,
                replyCount: max(0, comments.count - 1),
                publishedAt: posts.first?.postedAt,
                isLocked: (postData["locked"] as? NSNumber)?.intValue == 1,
                sourceForumName: postData["categoryWord"] as? String,
                isFavorite: (postData["collected"] as? NSNumber)?.boolValue ?? false
            ),
            posts: posts,
            page: page,
            hasMore: page < totalPages,
            totalPages: totalPages
        )
    }

    /// 楼层编号 → 渲染好的正文 HTML。
    private func renderedBodies(inHTML html: String) throws -> [Int64: String] {
        let document = try SwiftSoup.parse(html, ForumSiteDescriptor.nodeseek.baseURL.absoluteString)
        var bodies: [Int64: String] = [:]
        for item in try document.select(".content-item") {
            guard let raw = try? item.attr("data-comment-id"), let id = Int64(raw),
                  let body = try item.select("article.post-content").first() else { continue }
            bodies[id] = try Self.sanitized(body)
        }
        return bodies
    }

    private func post(from item: Element, topicID: TopicID) throws -> Post? {
        guard let rawID = try? item.attr("data-comment-id"), let commentID = Int64(rawID) else {
            return nil
        }
        // 楼层号在 id 属性上，主楼是 0。缺了就从 `#3` 那个锚点读。
        var floor = Int((try? item.attr("id")) ?? "") ?? -1
        if floor < 0, let link = try item.select("a.floor-link").first() {
            let text = try link.text().trimmingCharacters(in: CharacterSet(charactersIn: "# "))
            floor = Int(text) ?? 0
        }
        if floor < 0 { floor = 0 }

        let authorLink = try item.select("a.author-name").first()
        let author = try authorLink?.text().trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let authorUID = try authorLink.flatMap { Self.uid(fromPath: try $0.attr("href")) }

        let postedAt = try item.select("span.date-created time[datetime]").first()
            .flatMap { Self.date(fromISO8601: try $0.attr("datetime")) }

        let body = try item.select("article.post-content").first()
        let sanitized = try body.map { try Self.sanitized($0) } ?? ""

        return Post(
            id: PostID(rawValue: commentID),
            topicID: topicID,
            floor: floor,
            author: author,
            authorUID: authorUID,
            avatarURL: authorUID.flatMap(Self.avatarURL(uid:)),
            postedAt: postedAt,
            html: sanitized
        )
    }

    private func topic(of document: Document, topicID: TopicID, opening: Post?) throws -> Topic {
        let subject = try document.select("h1 a.post-title-link").first()
            .map { try $0.text().trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        // 分类只挂在主楼上。
        let categoryLink = try document.select(".content-category a[href]").first()
        let forumID = try categoryLink
            .flatMap { Self.forumID(fromPath: try $0.attr("href")) }
            ?? NodeSeekEndpoint.forumID(key: NodeSeekEndpoint.homeKey)
        return Topic(
            id: topicID,
            forumID: forumID,
            subject: subject,
            author: opening?.author ?? "",
            authorUID: opening?.authorUID,
            replyCount: 0,
            publishedAt: opening?.postedAt,
            sourceForumName: try categoryLink?.text().trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// 正文清洗：脚本、样式、iframe、表单、事件属性一律去掉。
    ///
    /// 楼层正文是别人写的，要进 `WKWebView`。SwiftSoup 的 relaxed 白名单已经挡掉了
    /// 脚本和事件属性，这里再显式去掉几类它允许但我们不想要的。
    private static func sanitized(_ element: Element) throws -> String {
        try replaceEmbedMarkers(in: element)
        let inner = try element.html()
        let cleaned = try SwiftSoup.clean(inner, Whitelist.relaxed()) ?? ""
        let document = try SwiftSoup.parseBodyFragment(cleaned)
        for tag in ["script", "style", "iframe", "form", "object", "embed"] {
            try document.select(tag).remove()
        }
        let body = try document.body()?.html() ?? cleaned
        // 光有一段清洗过的 body 不够：字体、配色、主题变量、CSP 全在这层外壳里。
        // 少了它，正文会用 WebKit 的默认字体，深色模式下还是白底黑字。
        return PostDocument.html(body: body, extraCSS: PostDocument.markdownStyleSheet)
    }

    /// 把正文里的 `nsapp://` 标记换成一句人话。
    ///
    /// 站点用自定义协议在正文里埋组件，投票就是这么来的：服务端渲染成
    /// `<a href="javascript://void(0)" data-href="nsapp://vote?id=3027">nsapp://vote?id=3027</a>`，
    /// 网页版的 JS 认出它、去 `/api/vote/info/{id}` 取数据、再画出投票面板。
    ///
    /// 我们既不认它也留不住它：清洗白名单会丢掉 `data-href`，也会丢掉
    /// `javascript:` 的 href，于是只剩锚点的**文字** —— 读者看到的就是一行
    /// `nsapp://vote?id=3027`。那对读者毫无意义，还像是页面坏了。
    ///
    /// 在清洗之前换掉。用 `blockquote` 是因为白名单只留这几个块级标签，而它已经有
    /// 现成的样式；换成带 class 的 div，class 会被同一个白名单丢掉。
    ///
    /// 真的把投票画出来还差两样：`/api/vote/info/{id}` 的响应字段，以及投票提交的
    /// 接口 —— 前者匿名请求一律 403（页面自己那次是 200），后者要登录才点得动。
    /// 拿到之前不假装支持，`.poll` 也不点亮。
    /// 测试用的入口：清洗本身是私有的，但「原始协议不能漏给读者」这件事值得直接测。
    static func sanitizedForTesting(_ element: Element) throws -> String {
        try sanitized(element)
    }

    private static func replaceEmbedMarkers(in element: Element) throws {
        for anchor in try element.select("a[data-href]") {
            let target = try anchor.attr("data-href")
            guard target.hasPrefix("nsapp://") else { continue }
            let what = embedName(forNSAppURL: target)
            let quote = try element.ownerDocument()?.createElement("blockquote")
                ?? Element(Tag.valueOf("blockquote"), "")
            try quote.text("\(what) · 在浏览器中打开本帖参与")
            try anchor.replaceWith(quote)
        }
    }

    /// `nsapp://vote?id=3027` → 「投票」。认不出来的说「内容」，不瞎猜。
    private static func embedName(forNSAppURL value: String) -> String {
        let host = value.dropFirst("nsapp://".count).prefix { $0 != "?" && $0 != "/" }
        switch host {
        case "vote": return "投票"
        default: return "站点内嵌内容"
        }
    }

    // MARK: - 页面里内嵌的初始状态

    /// 页面里那段 base64 的初始状态。
    ///
    /// 站点把渲染要用的数据整个塞在一个 base64 字符串里，客户端解开后拿它建页面 ——
    /// `window.user` 就是从这来的。它比抓 HTML 好得多：楼层的反应计数、我有没有反应过、
    /// 是不是楼主、编辑时间、正文的 Markdown 原文，HTML 里一个都没有，这里全有。
    ///
    /// 也解释了先前为什么怎么搜都搜不到身份 —— 它被 base64 编过，搜 `member_id` 当然搜不着。
    static func embeddedState(inHTML html: String) -> [String: Any]? {
        // 这段是 JS 里的一个字符串字面量，以 eyJ 开头（`{"` 的 base64）。
        //
        // 页面上不止这一处 base64，所以不能撞见第一个就用；也不按长度筛 —— 那是个
        // 拍脑袋的阈值。改成挨个试着解，认里面有没有站点自己那几个键。
        for match in html.matches(of: /(eyJ[A-Za-z0-9+\/=]{16,})/) {
            var encoded = String(match.1)
            encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
            guard let data = Data(base64Encoded: encoded),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            guard root["pageType"] != nil || root["postData"] != nil || root.keys.contains("user")
            else { continue }
            return root
        }
        return nil
    }

    /// 当前会话属于谁。匿名时 `user` 是 null。
    static func signedInUserID(inHTML html: String) -> Int64? {
        guard let user = embeddedState(inHTML: html)?["user"] as? [String: Any] else { return nil }
        for key in ["uid", "member_id", "memberId", "id"] {
            if let value = (user[key] as? NSNumber)?.int64Value { return value }
        }
        return nil
    }

    // MARK: - JSON

    /// `/api/account/getInfo/{uid}?readme=1` 的响应。
    ///
    /// 不带 `readme=1` 时 `bio` 不在响应里 —— 个人简介会整个消失。
    func profile(json data: Data) throws -> Profile {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let detail = root["detail"] as? [String: Any] else {
            throw ForumServiceError.unexpectedPage("无法读取用户资料")
        }
        guard let uid = (detail["member_id"] as? NSNumber)?.int64Value else {
            throw ForumServiceError.unexpectedPage("用户资料缺少编号")
        }
        let name = detail["member_name"] as? String ?? ""
        func number(_ key: String) -> Int? { (detail[key] as? NSNumber)?.intValue }

        return Profile(
            uid: uid,
            displayName: name.isEmpty ? "用户 \(uid)" : name,
            avatarURL: Self.avatarURL(uid: uid),
            // rank 是等级序号，站点在界面上按它显示等级。
            userGroup: number("rank").map { "Lv.\($0)" },
            registeredAt: (detail["created_at"] as? String).flatMap(Self.date(fromISO8601:)),
            postCount: number("nPost"),
            signature: (detail["bio"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            // 站点有两种货币：鸡腿（coin，用来加鸡腿和反对）和星辰（stardust，投喂得来）。
            fame: number("stardust"),
            money: number("coin"),
            followerCount: number("fans")
        )
    }

    /// 确认一次写操作成功了。
    ///
    /// 这个站的写接口把结论放在响应体里，状态码只是附带。失败时 `message` 就是该展示给
    /// 用户的那句话，所以原样抛出去，不要换成自己编的。
    func confirmWrite(json data: Data, what: String) throws {
        try confirmWrite(
            root: (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:],
            what: what
        )
    }

    fileprivate func confirmWrite(root: [String: Any], what: String) throws {
        if (root["success"] as? NSNumber)?.boolValue == true { return }
        let message = (root["message"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        throw ForumServiceError.restricted(message.isEmpty ? "\(what)未能提交" : message)
    }

    /// 签到的答复。
    ///
    /// 这个站的写接口把话写在响应体里，状态码只是个附带 —— 重复签到答的是 HTTP 500，
    /// 而正文里正是要展示给用户的那句话。所以判断成没成不看状态码，看 `success`。
    func checkInResult(json data: Data) throws -> CheckInResult {
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let message = (root?["message"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let succeeded = (root?["success"] as? NSNumber)?.boolValue ?? false

        if succeeded {
            return .success(message: message.isEmpty ? "签到成功" : message)
        }
        guard !message.isEmpty else {
            throw ForumServiceError.unexpectedPage("无法确认签到结果")
        }
        // 站点用同一个 success:false 表示「今天已经签过」和别的失败，只有文字能区分。
        // 认不出来的一律当成已签到而不是报错：多签一次的代价只是一句多余的提示，
        // 而把「已签到」报成错会让界面一直催用户去签。
        return .alreadyCheckedIn(message: message)
    }

    /// 今日是否已签到，以及连续与累计天数。
    ///
    /// 签到接口本身不给这些，要从签到榜的 `record` 里读。
    func checkInStatistics(json data: Data) throws -> CheckInStatistics {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ForumServiceError.unexpectedPage("无法读取签到状态")
        }
        let record = root["record"] as? [String: Any]
        return CheckInStatistics(
            // 榜上有今天这条记录就说明签过了。
            isCheckedInToday: record != nil,
            // 实测这个响应里没有连续和累计天数：`record` 只有 id、member_id、day_id、
            // gain、created_at，顶层的 `order` 和 `total` 说的是榜单本身，不是我的天数。
            // 先前那两行读的是并不存在的键，结果永远是 0。
            consecutiveDays: nil,
            totalDays: nil
        )
    }

    /// 一页用户动态。
    ///
    /// 主题和评论是两个接口，形状差一点：评论多 `floor_id` 和 `text`，主题只有标题。
    /// 两边都很瘦 —— 没有时间、没有分类，所以 `postedAt` 和 `forumName` 只能留空，
    /// 界面上那两行会自己不显示。
    ///
    /// 响应里没有总数也没有「还有没有」，只能按满页推断：站点每页固定 15 条，
    /// 不满一页就是最后一页。
    func userActivities(json data: Data, kind: UserActivityKind, page: Int) throws -> UserActivityPage {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ForumServiceError.unexpectedPage("无法读取用户动态")
        }
        try Self.rejectBulkGate(root)

        let key = kind == .topics ? "discussions" : "comments"
        guard let items = root[key] as? [[String: Any]] else {
            throw ForumServiceError.unexpectedPage("用户动态缺少 \(key)")
        }

        let activities = items.compactMap { item -> UserActivity? in
            guard let postID = (item["post_id"] as? NSNumber)?.int64Value else { return nil }
            let floor = (item["floor_id"] as? NSNumber)?.intValue
            let title = (item["title"] as? String) ?? ""
            let text = (item["text"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return UserActivity(
                // 同一个帖子可以回好几层，光用 post_id 会撞。
                id: "\(kind.rawValue)-\(postID)-\(floor ?? 0)",
                kind: kind,
                topicID: TopicID(rawValue: postID),
                // `floor_id` 是楼层序号，不是评论编号，塞进 PostID 会指向别的楼。
                // 打开动态时只用得到 topicID，缺这个不影响。
                postID: nil,
                subject: title.isEmpty ? "话题 \(postID)" : title,
                excerpt: (text?.isEmpty ?? true) ? nil : text
            )
        }

        let hasMore = items.count >= NodeSeekEndpoint.activitiesPerPage
        return UserActivityPage(
            kind: kind,
            activities: activities,
            page: page,
            hasMore: hasMore,
            // 站点不给总页数。给个下界，够「还能往下翻」用。
            totalPages: hasMore ? page + 1 : page
        )
    }

    /// 一次楼层反应之后的计数。
    ///
    /// 响应形如 `{success, current, coin, message}`：`current` 是这一层的新计数，
    /// `coin` 是操作完之后读者剩下的鸡腿。这里只用 `current` —— 走到这个方法的只有
    /// 免费的投喂，不花鸡腿，`coin` 没什么可说的。
    ///
    /// 站点没有反方向的计数，所以 `downvoteCount` 恒为 0；界面上那一半由
    /// `.postDownvote` 关着，不会显示。
    func reactionState(json data: Data) throws -> PostVoteState {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ForumServiceError.unexpectedPage("无法读取反应结果")
        }
        try confirmWrite(root: root, what: "投喂")
        guard let current = (root["current"] as? NSNumber)?.intValue else {
            // 站点说成了，却没说现在是多少 —— 硬编一个数会把界面上的计数写错。
            throw ForumServiceError.unexpectedPage("反应结果里没有新的计数")
        }
        return PostVoteState(upvoteCount: current, downvoteCount: 0, userVote: .up)
    }

    /// 私信列表。
    ///
    /// 这个接口给的是**会话**，不是单条消息：一个对话方一行，带着最后一条的正文和
    /// `max_id`。所以 `id` 里放的是**对方的编号**，不是消息编号 —— 打开会话要请求
    /// `/api/notification/message/with/{uid}`，手上没有对方编号就打不开。用 `max_id`
    /// 的话每来一条新消息这一行的身份就变了，列表会闪成新行。
    ///
    /// 谁是「对方」要看我是谁：我发出去的那条，对方是收件人；收到的那条，对方是发件人。
    func messages(json data: Data, page: Int, currentUserID: Int64) throws -> MessagePage {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ForumServiceError.unexpectedPage("无法读取私信列表")
        }
        try Self.rejectBulkGate(root)
        guard let rows = root["msgArray"] as? [[String: Any]] else {
            throw ForumServiceError.unexpectedPage("私信列表缺少 msgArray")
        }

        let messages = rows.compactMap { row -> ForumMessage? in
            let senderID = (row["sender_id"] as? NSNumber)?.int64Value
            let receiverID = (row["receiver_id"] as? NSNumber)?.int64Value
            let isMine = senderID == currentUserID
            guard let otherID = isMine ? receiverID : senderID else { return nil }
            let otherName = (row[isMine ? "receiver_name" : "sender_name"] as? String) ?? ""
            let content = (row["content"] as? String) ?? ""
            return ForumMessage(
                id: MessageID(rawValue: otherID),
                kind: .privateMessage,
                sender: otherName,
                // 私信没有标题，列表上显示的就是对方。
                subject: otherName.isEmpty ? "用户 \(otherID)" : otherName,
                preview: content,
                sentAt: (row["created_at"] as? String).flatMap(Self.date(fromISO8601:)),
                // viewed 是 0/1，0 表示还没看。我自己刚发出去的那条不该算未读。
                isUnread: !isMine && (row["viewed"] as? NSNumber)?.intValue == 0
            )
        }
        return MessagePage(
            folder: .privateMessages,
            messages: messages,
            page: page,
            hasMore: !rows.isEmpty
        )
    }

    /// 通知列表（`at-me` 和 `reply-to-me` 两个接口同一个形状）。
    ///
    /// 响应里没有正文，只有帖子标题和楼层，所以摘要只能自己拼一句。
    func notifications(json data: Data, kind: NodeSeekNotificationKind, page: Int) throws -> [ForumMessage] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ForumServiceError.unexpectedPage("无法读取通知列表")
        }
        try Self.rejectBulkGate(root)
        guard let rows = root["data"] as? [[String: Any]] else {
            throw ForumServiceError.unexpectedPage("通知列表缺少 data")
        }

        return rows.compactMap { row -> ForumMessage? in
            guard let postID = (row["post_id"] as? NSNumber)?.int64Value,
                  let id = (row["id"] as? NSNumber)?.int64Value else { return nil }
            let who = (row["commenter_name"] as? String) ?? ""
            let floor = (row["floor_id"] as? NSNumber)?.intValue
            let title = (row["title"] as? String) ?? ""
            let where_ = floor.map { "#\($0)" } ?? ""
            return ForumMessage(
                id: MessageID(rawValue: id),
                kind: kind.messageKind,
                sender: who,
                subject: title.isEmpty ? "话题 \(postID)" : title,
                preview: "\(who) 在 \(where_) \(kind.verb)",
                sentAt: (row["created_at"] as? String).flatMap(Self.date(fromISO8601:)),
                isUnread: (row["viewed"] as? NSNumber)?.intValue == 0,
                topicID: TopicID(rawValue: postID),
                replyURL: NodeSeekEndpoint.thread(
                    topicID: TopicID(rawValue: postID),
                    page: NodeSeekEndpoint.page(ofFloor: floor ?? 1)
                )
            )
        }
    }

    /// 收藏的话题。
    ///
    /// 响应只有编号、标题和一个 `rank`，没有作者、回复数、时间，也没有所属分类 ——
    /// 所以这些位置只能空着，界面上那几行会自己不显示。
    func favoriteTopics(json data: Data, page: Int) throws -> ForumPage {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ForumServiceError.unexpectedPage("无法读取收藏列表")
        }
        try Self.rejectBulkGate(root)
        guard let rows = root["collections"] as? [[String: Any]] else {
            throw ForumServiceError.unexpectedPage("收藏列表缺少 collections")
        }

        let topics = rows.compactMap { row -> Topic? in
            guard let postID = (row["post_id"] as? NSNumber)?.int64Value else { return nil }
            let title = (row["title"] as? String) ?? ""
            return Topic(
                id: TopicID(rawValue: postID),
                forumID: .placeholder(site: .nodeseek),
                subject: title.isEmpty ? "话题 \(postID)" : title,
                author: "",
                replyCount: 0,
                isFavorite: true
            )
        }
        return ForumPage(
            forum: nil,
            topics: topics,
            page: page,
            // 每页多少条没测出来（当时账号里只有一条收藏），所以不按「满页」判断。
            // 非空就再要一页，空了才停 —— 代价是末尾多发一次请求，好处是不管每页
            // 多少条都不会漏。
            hasMore: !rows.isEmpty,
            totalPages: rows.isEmpty ? page : page + 1
        )
    }

    /// `/api/vote/info/{id}` 的响应。
    ///
    /// 站点的投票是**一组扁平的选项**，没有 NGA 那种分组，所以这里只造一个组。
    /// `multiple` 是布尔值，不是「最多选几个」—— 允许多选时上限就是选项总数。
    ///
    /// 结束方式也不一样：站点给的是 `locked` 这个布尔值，没有截止时间，所以
    /// `endsAt` 只能空着（见 `TopicPoll.isLocked`）。
    ///
    /// `participantCount` 用票数之和顶替。单选时两者相等；允许多选时它会偏大 ——
    /// 站点没给参与人数，而这个字段只用来决定「要不要藏结果」，偏大不会藏错。
    func poll(json data: Data, topicID: TopicID) throws -> TopicPoll {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let vote = root["vote"] as? [String: Any] else {
            throw ForumServiceError.unexpectedPage("无法读取投票")
        }
        guard let items = vote["items"] as? [[String: Any]], !items.isEmpty else {
            throw ForumServiceError.unexpectedPage("投票没有选项")
        }

        let options = items.compactMap { item -> TopicPoll.Option? in
            guard let id = (item["vote_item_id"] as? NSNumber)?.int64Value else { return nil }
            return TopicPoll.Option(
                id: String(id),
                title: (item["text"] as? String) ?? "",
                voteCount: (item["count"] as? NSNumber)?.intValue ?? 0,
                isChosen: (item["voted"] as? NSNumber)?.boolValue == true
            )
        }
        guard !options.isEmpty else {
            throw ForumServiceError.unexpectedPage("投票选项都读不出来")
        }

        let allowsMultiple = (vote["multiple"] as? NSNumber)?.boolValue == true
        return TopicPoll(
            id: topicID,
            groups: [TopicPoll.Group(id: 0, title: vote["title"] as? String, options: options)],
            maximumSelectionsPerGroup: allowsMultiple ? options.count : 1,
            endsAt: nil,
            // 票数一直都在响应里，不用投完才给看。
            hidesResultsUntilVoting: false,
            hidesResultsUntilEnd: false,
            participantCount: options.reduce(0) { $0 + $1.voteCount },
            isLocked: (vote["locked"] as? NSNumber)?.boolValue == true
        )
    }

    /// 正文里那个投票标记指向的编号。没有投票就返回 nil。
    ///
    /// 投票不在帖子数据里，只有正文的 Markdown 里一行 `nsapp://vote?id=3027`。
    static func pollID(inPostHTML html: String) -> Int64? {
        guard let range = html.range(of: #"nsapp://vote\?id=(\d+)"#, options: .regularExpression)
        else { return nil }
        return Int64(html[range].drop { !$0.isNumber })
    }

    /// 认出站点挡下批量抓取时给的那个假答复。
    ///
    /// `list-discussions`、`list-comments`、`attendance/board` 这几个「带 page、批量吐公开
    /// 数据」的接口在边缘有防抓取。不放行时它不返回挑战页，而是回一句
    /// `{"success":false,"message":"wrong uid"}` —— 看起来像参数错了。
    ///
    /// 实测证明这是假的：把 `page` 故意写成 `abc`，浏览器会如实答 `wrong page`，
    /// 而被挡的客户端**无论传什么**都只回 `wrong uid`，连参数都没解析。
    ///
    /// 这些请求的参数是我们自己拼的，一定合法，所以收到 `wrong 某某` 只可能是被挡了。
    /// 不认出来的话，界面会把它当成一页空数据，显示「没有动态」——
    /// 把「拿不到」说成「没有」是最糟的那种错。
    private static func rejectBulkGate(_ root: [String: Any]) throws {
        guard (root["success"] as? NSNumber)?.boolValue != true else { return }
        let message = (root["message"] as? String) ?? ""

        // 没有会话时站点答的是这句（HTTP 500，正文里的 status 却写 404）。
        // 它和被挡是两回事：这个重新登录一定能解决，所以要分开报。
        if message == "USER NOT FOUND" { throw ForumServiceError.requiresLogin }

        guard message.hasPrefix("wrong ") else { return }
        throw ForumServiceError.restricted(
            "NodeSeek 挡下了这次请求。站点对批量接口有防抓取限制，重新登录后可能恢复。"
        )
    }

    static func avatarURL(uid: Int64) -> URL? {
        URL(string: "\(ForumSiteDescriptor.nodeseek.baseURL.absoluteString)/avatar/\(uid).png")
    }

    // MARK: - 路径

    /// `/post-857694-2` → 857694。
    static func topicID(fromPath path: String) -> TopicID? {
        guard let match = path.firstMatch(of: /\/post-(\d+)(?:-\d+)?/),
              let value = Int64(match.1) else { return nil }
        return TopicID(rawValue: value)
    }

    /// `/space/1769` → 1769。
    static func uid(fromPath path: String) -> Int64? {
        path.firstMatch(of: /\/space\/(\d+)/).flatMap { Int64($0.1) }
    }

    /// `/categories/daily` → 分类 daily；`/` → 综合。
    static func forumID(fromPath path: String) -> ForumID? {
        if let match = path.firstMatch(of: /\/categories\/([A-Za-z0-9-]+)/) {
            return NodeSeekEndpoint.forumID(key: String(match.1))
        }
        return nil
    }

    /// `/categories/daily/page-100` → 100。
    static func page(fromPath path: String) -> Int? {
        path.firstMatch(of: /\/page-(\d+)/).flatMap { Int($0.1) }
    }

    static func date(fromISO8601 value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}
