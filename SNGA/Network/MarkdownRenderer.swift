import Foundation

/// 把 Markdown 源码渲染成预览用的 HTML。
///
/// 只覆盖论坛正文里常见的那一小撮语法。不追求完整 —— 这是**预览**，用来回答
/// 「我打的这段发出去大概长什么样」，不是要和站点的渲染器逐字节对齐。
///
/// 安全上只有一条规矩，但它决定了整段代码的顺序：**先把源码整个转义，再往里放标记**。
/// 预览的产物要交给 `WKWebView` 显示，源码是用户（或被引用的楼层）写的，中间任何
/// 一处让原始 HTML 漏过去，都是在自己的进程里执行别人的脚本。所以这里不支持
/// 内联 HTML —— 写 `<u>` 就显示 `<u>`。代价是少一点表现力，换的是没有缺口。
enum MarkdownRenderer {

    /// - Parameter emoticons: 短代码名 → 表情图。站点把表情写成 ` :ac01: ` 这样的
    ///   短代码，名单是站点资料（见 `NodeSeekStickers`），所以由调用方给。
    ///   查不到的短代码原样留着 —— 正文里本来就可能出现别的冒号。
    static func previewHTML(_ source: String, emoticons: [String: URL] = [:]) -> String {
        var blocks: [String] = []
        var paragraph: [String] = []
        var listItems: [String] = []
        var listIsOrdered = false
        var quoted: [String] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append("<p>\(inline(paragraph.joined(separator: "<br>"), emoticons: emoticons))</p>")
            paragraph = []
        }
        func flushList() {
            guard !listItems.isEmpty else { return }
            let tag = listIsOrdered ? "ol" : "ul"
            let items = listItems.map { "<li>\(inline($0, emoticons: emoticons))</li>" }.joined()
            blocks.append("<\(tag)>\(items)</\(tag)>")
            listItems = []
        }
        func flushQuote() {
            guard !quoted.isEmpty else { return }
            // 引用块里可以再有别的东西，所以整段递归渲染一次。
            blocks.append("<blockquote>\(previewHTML(quoted.joined(separator: "\n"), emoticons: emoticons))</blockquote>")
            quoted = []
        }
        func flushAll() {
            flushParagraph()
            flushList()
            flushQuote()
        }

        var lines = source.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")[...]

        while let line = lines.first {
            lines = lines.dropFirst()
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // 围栏代码块。里面的内容一概不当标记看 —— 这正是写代码块的用意。
            if trimmed.hasPrefix("```") {
                flushAll()
                var body: [String] = []
                while let next = lines.first, !next.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    body.append(next)
                    lines = lines.dropFirst()
                }
                if lines.first != nil { lines = lines.dropFirst() }   // 收尾的围栏
                blocks.append("<pre><code>\(escaped(body.joined(separator: "\n")))</code></pre>")
                continue
            }

            if trimmed.isEmpty {
                flushAll()
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                flushList()
                quoted.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
                continue
            }
            flushQuote()

            if let heading = heading(trimmed, emoticons: emoticons) {
                flushAll()
                blocks.append(heading)
                continue
            }

            if trimmed.count >= 3, trimmed.allSatisfy({ $0 == "-" || $0 == "*" }) {
                flushAll()
                blocks.append("<hr>")
                continue
            }

            if let item = bulletItem(trimmed) {
                flushParagraph()
                if listIsOrdered { flushList() }
                listIsOrdered = false
                listItems.append(item)
                continue
            }
            if let item = orderedItem(trimmed) {
                flushParagraph()
                if !listIsOrdered { flushList() }
                listIsOrdered = true
                listItems.append(item)
                continue
            }
            flushList()

            paragraph.append(line)
        }
        flushAll()

        return blocks.joined()
    }

    // MARK: - 块

    private static func heading(_ line: String, emoticons: [String: URL]) -> String? {
        let hashes = line.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes) else { return nil }
        let rest = String(line.dropFirst(hashes))
        // `#标签` 不是标题，井号后面得有空格。
        guard rest.hasPrefix(" ") else { return nil }
        return "<h\(hashes)>\(inline(rest.trimmingCharacters(in: .whitespaces), emoticons: emoticons))</h\(hashes)>"
    }

    private static func bulletItem(_ line: String) -> String? {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count))
        }
        return nil
    }

    private static func orderedItem(_ line: String) -> String? {
        let digits = line.prefix(while: \.isNumber)
        guard !digits.isEmpty else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") else { return nil }
        return String(rest.dropFirst(2))
    }

    // MARK: - 行内

    /// 转义在最前面，之后每一步放进去的都是这里自己写的标签。
    private static func inline(_ source: String, emoticons: [String: URL]) -> String {
        var text = escaped(source)

        // 行内代码得先从正文里摘出去，换成占位符。
        //
        // 只是「先把它变成 <code>」不够：后面的强调规则照样会扫过标签里的内容，
        // 把 `**这个**` 里的星号也吃掉。摘出去、全部处理完再放回来，里面就动不了了。
        var protectedSpans: [String] = []
        text = replacePairs(in: text, pattern: "`([^`\n]+)`") { body in
            protectedSpans.append("<code>\(body)</code>")
            return Self.placeholder(protectedSpans.count - 1)
        }
        // 表情和行内代码一样要摘出去：换出来的 `<img>` 里有斜杠和点，留在正文里
        // 会被后面的强调规则扫到。
        if !emoticons.isEmpty {
            text = replacePairs(in: text, pattern: Self.emoticonPattern) { name in
                guard let url = emoticons[name] else { return ":\(name):" }
                protectedSpans.append(
                    #"<img class="sticker" src="\#(escaped(url.absoluteString))" alt="\#(name)">"#
                )
                return Self.placeholder(protectedSpans.count - 1)
            }
        }
        text = replacePairs(in: text, pattern: #"!\[([^\]]*)\]\(([^)\s]+)\)"#, groups: 2) { parts in
            guard let url = safeURL(parts[1]) else { return parts[0] }
            return #"<img src="\#(url)" alt="\#(parts[0])">"#
        }
        text = replacePairs(in: text, pattern: #"\[([^\]]+)\]\(([^)\s]+)\)"#, groups: 2) { parts in
            guard let url = safeURL(parts[1]) else { return parts[0] }
            return #"<a href="\#(url)">\#(parts[0])</a>"#
        }
        // 三个星号是粗斜体，得排在两个和一个前面，否则会被拆错。
        text = replacePairs(in: text, pattern: #"\*\*\*([^*]+)\*\*\*"#) { "<strong><em>\($0)</em></strong>" }
        text = replacePairs(in: text, pattern: #"\*\*([^*]+)\*\*"#) { "<strong>\($0)</strong>" }
        text = replacePairs(in: text, pattern: #"(?<![\w*])\*([^*\n]+)\*(?![\w*])"#) { "<em>\($0)</em>" }
        text = replacePairs(in: text, pattern: "~~([^~\n]+)~~") { "<del>\($0)</del>" }

        for (index, span) in protectedSpans.enumerated() {
            text = text.replacingOccurrences(of: Self.placeholder(index), with: span)
        }
        return text
    }

    /// 短代码长成「字母 + 数字」，两侧不能贴着别的字母数字。
    ///
    /// 这样 `https://x:8080` 和 `12:30:45` 都不会被误认 —— 前者冒号后面没有字母，
    /// 后者整段没有字母。真正兜底的还是名单：查不到就原样退回。
    private static let emoticonPattern = "(?<![A-Za-z0-9_]):([A-Za-z]+[0-9]+):(?![A-Za-z0-9_])"

    /// 占位符用的是对象替换符（U+FFFC）。转义那一步会先把源码里的这个字符去掉，
    /// 所以正文里不可能出现和它撞车的东西。
    private static func placeholder(_ index: Int) -> String { "\u{FFFC}\(index)\u{FFFC}" }

    private static func replacePairs(
        in source: String,
        pattern: String,
        groups: Int = 1,
        transform: ([String]) -> String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return source }
        var result = ""
        var last = source.startIndex
        for match in regex.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
            guard let whole = Range(match.range, in: source) else { continue }
            var captures: [String] = []
            for index in 1...groups {
                guard let range = Range(match.range(at: index), in: source) else { break }
                captures.append(String(source[range]))
            }
            guard captures.count == groups else { continue }
            result += source[last..<whole.lowerBound] + transform(captures)
            last = whole.upperBound
        }
        return result + source[last...]
    }

    private static func replacePairs(
        in source: String,
        pattern: String,
        transform: (String) -> String
    ) -> String {
        replacePairs(in: source, pattern: pattern, groups: 1) { transform($0[0]) }
    }

    /// 只放行 http/https。`javascript:` 一类的伪协议在 `WKWebView` 里是能跑的，
    /// 一个链接就够把预览变成执行别人代码的地方。认不出来的原样退回成文字。
    private static func safeURL(_ value: String) -> String? {
        guard let scheme = URL(string: value)?.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        return value
    }

    private static func escaped(_ value: String) -> String {
        value
            // 占位符是用这个字符拼的，源码里带着它会和占位符撞车。
            .replacingOccurrences(of: "\u{FFFC}", with: "")
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
