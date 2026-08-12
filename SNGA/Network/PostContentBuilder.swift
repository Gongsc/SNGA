import Foundation
import SwiftSoup

/// 把已清洗的楼层 DOM 转成原生渲染结构。
///
/// 转换是「全有或全无」的：只要遇到一个无法忠实还原的节点就返回 nil，让该楼层
///回退到 `WKWebView`。宁可多回退，也不要在原生分支里悄悄丢内容 —— 用户看到的
/// 帖子必须和网页版一致。
enum PostContentBuilder {
    /// 能够原生还原的块级标签。
    private static let blockTags: Set<String> = ["p", "div", "blockquote", "body"]

    /// 能够原生还原的内联标签。`img` 不在其列：表情在 `inlineSegments` 里单独处理，
    /// 正文配图则由 `blocks(in:style:)` 提成独立的块。
    private static let inlineTags: Set<String> = [
        "a", "b", "strong", "i", "em", "u",
        "strike", "s", "del", "span", "br", "code", "font"
    ]

    static func content(from body: Element) -> PostContent? {
        guard let blocks = blocks(in: body, style: PostTextStyle()) else {
            return nil
        }
        let meaningful = blocks.filter { block in
            switch block {
            case let .paragraph(paragraph): !paragraph.isEmpty
            case .quote, .image: true
            }
        }
        guard !meaningful.isEmpty else { return nil }
        return PostContent(blocks: meaningful)
    }

    /// 把一个容器的子节点切成块。连续的内联内容会被并成一个隐式段落 ——
    /// NGA 的正文经常把文字直接挂在容器下，并不总是包在 <p> 里。
    private static func blocks(
        in container: Element,
        style: PostTextStyle
    ) -> [PostBlock]? {
        var blocks: [PostBlock] = []
        var pendingSegments: [PostSegment] = []

        func flushPendingSegments(alignment: PostTextAlignment = .leading) {
            let paragraph = PostParagraph(
                segments: trimmingOuterBreaks(normalized(pendingSegments)),
                alignment: alignment
            )
            pendingSegments = []
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph))
        }

        for node in container.getChildNodes() {
            if let textNode = node as? TextNode {
                pendingSegments.append(.text(textNode.getWholeText(), style))
                continue
            }
            guard let element = node as? Element else {
                // 注释之类的节点没有可见内容，忽略即可。
                if node is Comment || node is DataNode { continue }
                return nil
            }

            let tag = element.tagName().lowercased()

            if tag == "blockquote" {
                flushPendingSegments()
                guard let nested = Self.blocks(in: element, style: style) else { return nil }
                blocks.append(.quote(nested))
                continue
            }

            if blockTags.contains(tag) {
                flushPendingSegments()
                guard let nested = Self.blocks(
                    in: element,
                    style: style
                ) else { return nil }
                // <p>/<div> 自身可能带对齐类，需要作用到它产生的段落上。
                let alignment = alignment(of: element)
                blocks.append(contentsOf: applying(alignment, to: nested))
                continue
            }

            if tag == "img" {
                if let emoticon = emoticonURL(of: element) {
                    pendingSegments.append(.emoticon(emoticon))
                    continue
                }
                // 正文配图自成一块，因此只接受本来就独占一行的图片；和文字挤在
                // 同一行的图片改成块会挪动版面，宁可整层退回 WKWebView。
                guard let image = image(of: element),
                      startsOnNewLine(pendingSegments),
                      endsLine(after: node) else {
                    return nil
                }
                flushPendingSegments()
                blocks.append(.image(image))
                continue
            }

            if inlineTags.contains(tag) {
                guard let segments = inlineSegments(of: element, style: style) else {
                    return nil
                }
                pendingSegments.append(contentsOf: segments)
                continue
            }

            return nil
        }

        flushPendingSegments()
        return blocks
    }

    /// 收集一个内联元素（及其子树）产生的片段。
    private static func inlineSegments(
        of element: Element,
        style: PostTextStyle
    ) -> [PostSegment]? {
        let tag = element.tagName().lowercased()

        if tag == "br" {
            return [.text("\n", style)]
        }

        if tag == "img" {
            guard let url = emoticonURL(of: element) else { return nil }
            return [.emoticon(url)]
        }

        guard let style = Self.style(applying: element, to: style) else { return nil }

        var segments: [PostSegment] = []
        for node in element.getChildNodes() {
            if let textNode = node as? TextNode {
                segments.append(.text(textNode.getWholeText(), style))
                continue
            }
            guard let child = node as? Element else {
                if node is Comment || node is DataNode { continue }
                return nil
            }
            let childTag = child.tagName().lowercased()
            guard inlineTags.contains(childTag) || childTag == "img" else {
                // 内联元素里出现块级内容（表格、折叠块等），交回 WKWebView。
                return nil
            }
            guard let nested = inlineSegments(of: child, style: style) else {
                return nil
            }
            segments.append(contentsOf: nested)
        }
        return segments
    }

    /// 叠加一个内联标签带来的样式。无法还原的标签返回 nil。
    private static func style(
        applying element: Element,
        to style: PostTextStyle
    ) -> PostTextStyle? {
        var style = style
        switch element.tagName().lowercased() {
        case "b", "strong":
            style.isBold = true
        case "i", "em":
            style.isItalic = true
        case "u":
            style.isUnderlined = true
        case "strike", "s", "del":
            style.isStruckThrough = true
        case "code":
            style.isMonospaced = true
        case "a":
            guard let href = try? element.attr("href"), !href.isEmpty,
                  let url = URL(string: href),
                  ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") else {
                // 站内跳转链接（引用楼层等）需要 WKWebView 的导航拦截，交回去。
                return nil
            }
            style.link = url
        case "span", "font", "div", "p":
            break
        default:
            return nil
        }

        for className in classNames(of: element) {
            if let color = PostTextColor(className: className) {
                style.color = color
                continue
            }
            if let percent = sizePercent(from: className) {
                style.sizePercent = percent
                continue
            }
            if className.hasPrefix("ubb-align-") { continue }
            if className == "nga-post-reference" {
                // 楼层引用链接（引用块里的「Post by ...」）。样式表里只是加粗加虚线下划线，
                // 而站内跳转由 `onOpenLink` 交给 NGAInternalLink 处理，与 WKWebView 分支一致。
                style.isBold = true
                style.isUnderlined = true
                continue
            }
            if className == "nga-smile" { continue }
            // 出现未知的样式类说明还有没覆盖到的排版，交回 WKWebView 更稳妥。
            return nil
        }

        // 内联样式（style 属性）不在原生分支的还原范围内。
        if let inlineStyle = try? element.attr("style"), !inlineStyle.isEmpty {
            return nil
        }
        return style
    }

    private static func alignment(of element: Element) -> PostTextAlignment {
        for className in classNames(of: element) {
            switch className {
            case "ubb-align-center": return .center
            case "ubb-align-right": return .trailing
            case "ubb-align-left": return .leading
            default: continue
            }
        }
        return .leading
    }

    private static func applying(
        _ alignment: PostTextAlignment,
        to blocks: [PostBlock]
    ) -> [PostBlock] {
        guard alignment != .leading else { return blocks }
        return blocks.map { block in
            switch block {
            case var .paragraph(paragraph):
                paragraph.alignment = alignment
                return .paragraph(paragraph)
            case var .image(image):
                image.alignment = alignment
                return .image(image)
            case .quote:
                return block
            }
        }
    }

    private static func classNames(of element: Element) -> [String] {
        guard let raw = try? element.className() else { return [] }
        return raw
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
    }

    private static func sizePercent(from className: String) -> Int? {
        let prefix = "ubb-size-"
        guard className.hasPrefix(prefix) else { return nil }
        return Int(className.dropFirst(prefix.count))
    }

    /// 动图的原生分支只能解出静止的第一帧，这类图片整层交回 `WKWebView`。
    private static let animatableImageExtensions: Set<String> = ["gif", "webp", "apng"]

    /// 一张可以原生渲染的正文配图。
    private static func image(of element: Element) -> PostImage? {
        guard let source = try? element.attr("src"), !source.isEmpty,
              let url = URL(string: source),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            return nil
        }
        guard !animatableImageExtensions.contains(url.pathExtension.lowercased()) else {
            return nil
        }
        // 带样式类的图片来自 `[style]`，它的定位和尺寸由生成的样式表决定，
        // 原生分支还原不了。
        guard classNames(of: element).isEmpty else { return nil }
        return PostImage(
            url: url,
            alt: (try? element.attr("alt")) ?? "",
            pixelWidth: positiveInteger(try? element.attr("width")),
            pixelHeight: positiveInteger(try? element.attr("height"))
        )
    }

    private static func positiveInteger(_ rawValue: String?) -> Int? {
        guard let value = rawValue.flatMap({ Int($0) }), value > 0 else { return nil }
        return value
    }

    /// 目前累积的内联内容是否停在行首 —— 也就是这张图片前面没有同一行的文字。
    private static func startsOnNewLine(_ segments: [PostSegment]) -> Bool {
        for segment in segments.reversed() {
            switch segment {
            case let .text(value, _):
                guard let character = value.reversed().drop(while: isBreakPadding).first else {
                    continue
                }
                return character.isNewline
            case .emoticon:
                return false
            }
        }
        return true
    }

    /// 该节点之后是否直接换行 —— 也就是这张图片后面没有同一行的文字。
    private static func endsLine(after node: Node) -> Bool {
        var sibling = node.nextSibling()
        while let current = sibling {
            if let textNode = current as? TextNode {
                if let character = textNode.getWholeText().drop(while: isBreakPadding).first {
                    return character.isNewline
                }
                sibling = current.nextSibling()
                continue
            }
            if let element = current as? Element {
                let tag = element.tagName().lowercased()
                if tag == "br" { return true }
                // 紧挨着的下一张配图同样自成一块。宽图在网页上本来也是各占一行，
                // 窄图会因此从并排变成上下排 —— 这是原生分支唯一放行的排版差异。
                if tag == "img" { return emoticonURL(of: element) == nil }
                return blockTags.contains(tag)
            }
            if current is Comment || current is DataNode {
                sibling = current.nextSibling()
                continue
            }
            return false
        }
        return true
    }

    /// 表情是固定集合里的小图，作为内联片段渲染；其余图片走 `image(of:)`。
    private static func emoticonURL(of element: Element) -> URL? {
        guard let source = try? element.attr("src"), !source.isEmpty else {
            return nil
        }
        let isEmoticon = element.hasClass("nga-smile")
            || source.localizedCaseInsensitiveContains("/ngabbs/post/smile/")
        guard isEmoticon, let url = URL(string: source) else { return nil }
        return url
    }

    /// 去掉段落首尾的换行。
    ///
    /// NGA 习惯用 `<br>` 把引用块和正文隔开，块级标签两侧的这些换行在网页上不
    /// 产生空行 —— `compactedPostSpacing` 正是为 `WKWebView` 分支这么清理的。
    /// 原生分支把 `<br>` 直接转成 "\n"，不清理就会在段落前后凭空多出空行，
    /// 而且整段正文是一个 `Text`，空行还会一并撑高它的版面。
    private static func trimmingOuterBreaks(_ segments: [PostSegment]) -> [PostSegment] {
        var segments = segments
        while let first = segments.first {
            guard case let .text(value, style) = first else { break }
            let trimmed = trimmingLeadingBreaks(value)
            guard trimmed != value else { break }
            if trimmed.isEmpty {
                segments.removeFirst()
            } else {
                segments[0] = .text(trimmed, style)
                break
            }
        }
        while let last = segments.last {
            guard case let .text(value, style) = last else { break }
            let trimmed = trimmingTrailingBreaks(value)
            guard trimmed != value else { break }
            if trimmed.isEmpty {
                segments.removeLast()
            } else {
                segments[segments.count - 1] = .text(trimmed, style)
                break
            }
        }
        return segments
    }

    private static func trimmingLeadingBreaks(_ value: String) -> String {
        var trimmed: Substring?
        var cursor = Substring(value)
        while true {
            let afterPadding = cursor.drop(while: isBreakPadding)
            guard afterPadding.first?.isNewline == true else { break }
            cursor = afterPadding.dropFirst()
            trimmed = cursor.drop(while: isBreakPadding)
        }
        return trimmed.map(String.init) ?? value
    }

    private static func trimmingTrailingBreaks(_ value: String) -> String {
        var trimmed: Substring?
        var cursor = Substring(value)
        while true {
            let beforePadding = droppingLast(from: cursor, while: isBreakPadding)
            guard beforePadding.last?.isNewline == true else { break }
            cursor = beforePadding.dropLast()
            trimmed = droppingLast(from: cursor, while: isBreakPadding)
        }
        return trimmed.map(String.init) ?? value
    }

    private static func droppingLast(
        from value: Substring,
        while predicate: (Character) -> Bool
    ) -> Substring {
        var value = value
        while let last = value.last, predicate(last) {
            value = value.dropLast()
        }
        return value
    }

    /// 只吃掉贴着换行的普通空格 —— `compactedPostSpacing` 里的 `\s` 同样不含全角
    /// 空格，而全角空格在 NGA 正文里是缩进，属于内容。
    private static func isBreakPadding(_ character: Character) -> Bool {
        character == " " || character == "\t"
    }

    /// 合并相邻的同样式文本，减少渲染时的 `Text` 拼接数量。
    private static func normalized(_ segments: [PostSegment]) -> [PostSegment] {
        var result: [PostSegment] = []
        for segment in segments {
            guard case let .text(value, style) = segment,
                  case let .text(previousValue, previousStyle)? = result.last,
                  previousStyle == style else {
                result.append(segment)
                continue
            }
            result[result.count - 1] = .text(previousValue + value, style)
        }
        return result
    }
}
