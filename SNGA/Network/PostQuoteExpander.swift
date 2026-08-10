import Foundation

/// 把「Reply to [pid=…]」抬头展开成带被引正文的引用块。
///
/// NGA 有两种引用写法：真正的 `[quote]…[/quote]` 会把被引正文一并下发；而
/// 「Reply to」抬头只带一个 `[pid]` 回链，被引正文**不在数据里** —— 网页版是靠
/// 前端脚本另行拉取被引楼层再内联展示的。
///
/// 这里在 BBCode 层做改写，把抬头补成与真 `[quote]` 完全相同的形态，后续渲染、
/// 清洗、原生转换全部复用既有管线，`WKWebView` 与原生两条路径因此表现一致。
enum PostQuoteExpander {
    /// 被引正文的长度上限。NGA 自己生成 `[quote]` 时同样会截断，
    /// 否则长楼层会把引用块撑得比正文还长。
    private static let maximumQuotedLength = 300

    /// 「[b]Reply to [pid=…]…[/pid] Post by [uid=…]某人[/uid] (时间)[/b]」
    private static let headerPattern =
        #"^\s*\[b\]\s*Reply to\s*(\[pid=(\d+)[^\]]*\].*?\[/pid\])(.*?)\[/b\]"#

    /// 被引正文里自带的引用块。内联时必须去掉：`[quote]` 不支持嵌套，
    /// 套进去会让外层的非贪婪匹配错配，反而把标记漏成可见文字。
    private static let nestedQuotePattern = #"\[quote[^\]]*\].*?\[/quote\]"#

    /// 展开一批楼层里能就地解析的引用。
    ///
    /// - Parameters:
    ///   - posts: 尚未清洗的楼层，`html` 此时仍是原始 BBCode。
    ///   - resolve: 按 `PostID` 取被引楼层的原始内容。取不到时保持原样，
    ///     退回「只显示抬头」，也就是本功能上线前的表现。
    static func expandingReferences(
        in posts: [Post],
        resolve: (PostID) -> String?
    ) -> [Post] {
        posts.map { post in
            var post = post
            post.html = expanded(post.html, resolve: resolve)
            return post
        }
    }

    static func expanded(
        _ rawContent: String,
        resolve: (PostID) -> String?
    ) -> String {
        // 已经是真引用的楼层不需要处理。
        guard rawContent.range(of: "[quote", options: .caseInsensitive) == nil else {
            return rawContent
        }
        guard let expression = try? NSRegularExpression(
            pattern: headerPattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else {
            return rawContent
        }
        let source = rawContent as NSString
        guard let match = expression.firstMatch(
            in: rawContent,
            range: NSRange(location: 0, length: source.length)
        ), match.numberOfRanges == 4 else {
            return rawContent
        }

        let pidTag = source.substring(with: match.range(at: 1))
        guard let postID = Int64(source.substring(with: match.range(at: 2)))
            .map({ PostID(rawValue: $0) }),
            let referenced = resolve(postID) else {
            return rawContent
        }

        let quoted = quotedBody(from: referenced)
        guard !quoted.isEmpty else { return rawContent }

        let attribution = source.substring(with: match.range(at: 3))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let heading = attribution.isEmpty
            ? pidTag
            : "\(pidTag) [b]\(attribution.hasSuffix(":") ? attribution : attribution + ":")[/b]"
        let remainder = source.substring(from: match.range.location + match.range.length)

        return "[quote]\(heading)<br/><br/>\(quoted)[/quote]\(remainder)"
    }

    /// 取被引楼层可内联的正文：去掉它自己的引用块与「Reply to」抬头，再按长度截断。
    private static func quotedBody(from referenced: String) -> String {
        var body = referenced
        if let expression = try? NSRegularExpression(
            pattern: nestedQuotePattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) {
            body = expression.stringByReplacingMatches(
                in: body,
                range: NSRange(location: 0, length: (body as NSString).length),
                withTemplate: ""
            )
        }
        if let expression = try? NSRegularExpression(
            pattern: headerPattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) {
            body = expression.stringByReplacingMatches(
                in: body,
                range: NSRange(location: 0, length: (body as NSString).length),
                withTemplate: ""
            )
        }

        body = body
            .replacingOccurrences(
                of: #"^(?:\s|<br\s*/?>)+"#,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
            .replacingOccurrences(
                of: #"(?:\s|<br\s*/?>)+$"#,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )

        guard body.count > maximumQuotedLength else { return body }
        return String(body.prefix(maximumQuotedLength)) + "……"
    }
}
