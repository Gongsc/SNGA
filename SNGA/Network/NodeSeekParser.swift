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
