import Foundation

/// 认出正文里指向 NodeSeek 站内的链接，交给原生导航而不是浏览器。
///
/// 域名判断由 `ForumSiteDescriptor.internalDestination(for:)` 统一做过了，这里只管解析路径。
enum NodeSeekInternalLink {
    // 正则直接写在用它的地方：`Regex` 不是 Sendable，存成静态属性过不了严格并发检查。
    //   /post-857694-2  → 话题 857694 第 2 页，页码可省
    //   /space/12345    → 用户 12345
    //   /categories/daily → 分类 daily

    static func destination(for url: URL) -> NGAInternalDestination? {
        let path = url.path()
        if let match = path.wholeMatch(of: /^\/post-(\d+)(?:-(\d+))?\/?$/) {
            guard let tid = Int64(match.1) else { return nil }
            let page = match.2.flatMap { Int($0) }
            // 楼层锚点（`#4`）给的是楼层号不是页码，站点每页 10 层。
            let floor = url.fragment().flatMap { Int($0) }
            return .topic(
                topicID: TopicID(rawValue: tid),
                page: page ?? floor.map(NodeSeekEndpoint.page(ofFloor:)),
                postID: nil
            )
        }
        if let match = path.wholeMatch(of: /^\/space\/(\d+)\/?$/), let uid = Int64(match.1) {
            return .user(uid: uid)
        }
        if let match = path.wholeMatch(of: /^\/categories\/([A-Za-z0-9-]+)\/?$/) {
            return .forum(NodeSeekEndpoint.forumID(key: String(match.1)))
        }
        // 综合首页。
        if path == "/" || path.isEmpty {
            return .forum(NodeSeekEndpoint.forumID(key: NodeSeekEndpoint.homeKey))
        }
        return nil
    }
}

/// Markdown 相关的临时落脚点。
///
/// 站点的正文是 Markdown，而应用手上还没有渲染器。在渲染器写出来之前，预览把源码原样显示 ——
/// 显示一段假的富文本会让人以为发出去就是那个样子。
enum NodeSeekMarkdown {
    static func plainPreviewHTML(_ source: String) -> String {
        let escaped = source
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return "<pre style=\"white-space: pre-wrap; word-break: break-word;\">\(escaped)</pre>"
    }
}
