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
        let inner = try element.html()
        let cleaned = try SwiftSoup.clean(inner, Whitelist.relaxed()) ?? ""
        let document = try SwiftSoup.parseBodyFragment(cleaned)
        for tag in ["script", "style", "iframe", "form", "object", "embed"] {
            try document.select(tag).remove()
        }
        return try document.body()?.html() ?? cleaned
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
        func number(_ key: String) -> Int? { (record?[key] as? NSNumber)?.intValue }
        return CheckInStatistics(
            // 榜上有今天这条记录就说明签过了。
            isCheckedInToday: record != nil,
            consecutiveDays: number("continuous") ?? number("continuousDays") ?? 0,
            totalDays: number("total") ?? number("totalDays") ?? 0
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
