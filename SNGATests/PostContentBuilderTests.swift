import Foundation
import SwiftSoup
import XCTest
@testable import SNGA

/// 原生渲染分支的核心安全属性：转换要么完整还原，要么整层回退到 WKWebView。
/// 绝不允许「转换成功但内容少了一块」——那会让用户看到和网页版不一样的帖子。
final class PostContentBuilderTests: XCTestCase {
    private let parser = NGAParser()

    // MARK: - 能够原生渲染的内容

    func testPlainTextBecomesNativeContent() throws {
        let content = try XCTUnwrap(nativeContent(for: "这是一段普通回复"))
        XCTAssertEqual(plainText(of: content), "这是一段普通回复")
    }

    func testInlineStylesArePreserved() throws {
        let content = try XCTUnwrap(
            nativeContent(for: "[b]粗[/b][i]斜[/i][u]下划线[/u][del]删除[/del]")
        )
        let styles = textStyles(of: content)
        XCTAssertTrue(styles.contains { $0.isBold })
        XCTAssertTrue(styles.contains { $0.isItalic })
        XCTAssertTrue(styles.contains { $0.isUnderlined })
        XCTAssertTrue(styles.contains { $0.isStruckThrough })
        XCTAssertEqual(plainText(of: content), "粗斜下划线删除")
    }

    func testColorAndSizeArePreserved() throws {
        let content = try XCTUnwrap(
            nativeContent(for: "[color=red]红字[/color][size=150%]大字[/size]")
        )
        let styles = textStyles(of: content)
        XCTAssertTrue(styles.contains { $0.color == .red })
        XCTAssertTrue(styles.contains { $0.sizePercent == 150 })
    }

    func testExternalLinkBecomesLinkStyle() throws {
        let content = try XCTUnwrap(
            nativeContent(for: "[url=https://example.com]站外链接[/url]")
        )
        let links = textStyles(of: content).compactMap(\.link)
        XCTAssertEqual(links.map(\.absoluteString), ["https://example.com"])
    }

    func testEmoticonBecomesEmoticonSegment() throws {
        let content = try XCTUnwrap(
            nativeContent(
                for: "开心<img src='https://img4.nga.178.com/ngabbs/post/smile/ac0.png'>"
            )
        )
        let emoticons = segments(of: content).compactMap { segment -> URL? in
            guard case let .emoticon(url) = segment else { return nil }
            return url
        }
        XCTAssertEqual(
            emoticons.map(\.absoluteString),
            ["https://img4.nga.cn/ngabbs/post/smile/ac0.png"]
        )
        XCTAssertEqual(plainText(of: content), "开心")
    }

    func testQuoteBecomesQuoteBlock() throws {
        let content = try XCTUnwrap(
            nativeContent(for: "[quote]被引用的话[/quote]我的回复")
        )
        let hasQuote = content.blocks.contains { block in
            if case .quote = block { return true }
            return false
        }
        XCTAssertTrue(hasQuote, "引用应当转成 quote 块")
        XCTAssertTrue(plainText(of: content).contains("被引用的话"))
        XCTAssertTrue(plainText(of: content).contains("我的回复"))
    }

    /// 引用块和正文之间的 `<br>` 在网页上不产生空行（`compactedPostSpacing` 会
    /// 清掉它们），原生分支也不能把它们留成段首换行：整段正文是一个 `Text`，
    /// 段首空行既凭空多出两行，又会让文字在鼠标点击后重排丢字。
    func testBreaksAroundQuoteDoNotBecomeBlankLines() throws {
        let content = try XCTUnwrap(
            nativeContent(for: "[quote]被引用的话[/quote]<br/><br/>我的回复<br/><br/>")
        )
        let body = content.blocks.compactMap { block -> PostParagraph? in
            guard case let .paragraph(paragraph) = block else { return nil }
            return paragraph
        }
        let text = body.flatMap(\.segments).reduce(into: "") {
            if case let .text(value, _) = $1 { $0 += value }
        }
        XCTAssertEqual(text, "我的回复", "段落首尾不应残留换行")
    }

    /// 段落内部的空行是作者写的排版，必须原样保留。
    func testBreaksInsideParagraphSurvive() throws {
        let content = try XCTUnwrap(
            nativeContent(for: "[quote]被引用的话[/quote]<br/>第一行<br/><br/>第二行")
        )
        XCTAssertTrue(
            plainText(of: content).contains("第一行\n\n第二行"),
            "段中空行属于正文排版"
        )
    }

    /// 全角空格是 NGA 正文里的缩进，清理换行时不能顺手吃掉。
    func testIdeographicIndentSurvivesBreakTrimming() throws {
        let content = try XCTUnwrap(
            nativeContent(for: "[quote]被引用的话[/quote]<br/>\u{3000}\u{3000}缩进正文")
        )
        XCTAssertTrue(plainText(of: content).contains("\u{3000}\u{3000}缩进正文"))
    }

    /// 引用套引用：内层必须成为外层的子块，而不是一段带着 `[quote]` 字样的文字。
    func testNestedQuoteBecomesNestedQuoteBlock() throws {
        let content = try XCTUnwrap(
            nativeContent(for: "[quote]外层开头[quote]最里面的话[/quote]外层结尾[/quote]我的回复")
        )
        let outer = content.blocks.compactMap { block -> [PostBlock]? in
            guard case let .quote(nested) = block else { return nil }
            return nested
        }
        XCTAssertEqual(outer.count, 1, "应当只有一个外层引用")
        let inner = (outer.first ?? []).compactMap { block -> [PostBlock]? in
            guard case let .quote(nested) = block else { return nil }
            return nested
        }
        XCTAssertEqual(inner.count, 1, "内层引用应当嵌在外层引用里")
        XCTAssertFalse(plainText(of: content).contains("[quote]"))
        XCTAssertFalse(plainText(of: content).contains("[/quote]"))
        XCTAssertTrue(plainText(of: content).contains("最里面的话"))
        XCTAssertTrue(plainText(of: content).contains("我的回复"))
    }

    // MARK: - 配图

    /// 独占一行的配图要走原生分支 —— 图多的楼层正是滚动最卡的地方，
    /// 让它们继续留在 `WKWebView` 里就等于没优化。
    func testStandaloneImageBecomesImageBlock() throws {
        let content = try XCTUnwrap(
            nativeContent(for: "看图<br/>[img]https://img.nga.cn/attachments/mon_202607/23/a.jpg[/img]")
        )
        XCTAssertEqual(
            images(of: content).map(\.url.absoluteString),
            ["https://img.nga.cn/attachments/mon_202607/23/a.jpg"]
        )
        XCTAssertEqual(plainText(of: content), "看图")
    }

    /// 连着贴的截图是最常见的重楼层形态，必须整层都能原生渲染。
    func testConsecutiveImagesBecomeSeparateBlocks() throws {
        let source = (1...3)
            .map { "[img]https://img.nga.cn/attachments/mon_202607/23/\($0).jpg[/img]" }
            .joined(separator: "<br/>")
        let content = try XCTUnwrap(nativeContent(for: source))
        XCTAssertEqual(images(of: content).count, 3)
    }

    func testImageInsideQuoteBecomesImageBlock() throws {
        let content = try XCTUnwrap(
            nativeContent(
                for: "[quote][img]https://img.nga.cn/attachments/mon_202607/23/a.jpg[/img][/quote]我的回复"
            )
        )
        let quoted = content.blocks.compactMap { block -> [PostBlock]? in
            guard case let .quote(nested) = block else { return nil }
            return nested
        }
        XCTAssertEqual(quoted.flatMap { $0 }.flatMap(images(of:)).count, 1)
        XCTAssertTrue(plainText(of: content).contains("我的回复"))
    }

    func testCenteredImageKeepsAlignment() throws {
        let content = try XCTUnwrap(
            nativeContent(
                for: "[align=center][img]https://img.nga.cn/attachments/mon_202607/23/a.jpg[/img][/align]"
            )
        )
        XCTAssertEqual(images(of: content).map(\.alignment), [.center])
    }

    /// 和文字挤在同一行的图片改成块会挪动版面，宁可整层回退。
    func testImageSharingALineWithTextFallsBackToWebView() {
        XCTAssertNil(
            nativeContent(
                for: "开头[img]https://img.nga.cn/attachments/mon_202607/23/a.jpg[/img]"
            ),
            "图片前面还有同一行的文字，应当回退"
        )
        XCTAssertNil(
            nativeContent(
                for: "[img]https://img.nga.cn/attachments/mon_202607/23/a.jpg[/img]结尾"
            ),
            "图片后面还有同一行的文字，应当回退"
        )
    }

    /// 动图原生分支只能画出静止的第一帧，必须回退。
    func testAnimatedImageFallsBackToWebView() {
        XCTAssertNil(
            nativeContent(for: "[img]https://img.nga.cn/attachments/mon_202607/23/a.gif[/img]")
        )
    }

    /// 图片被链接包着时，点击行为由 `WKWebView` 的导航拦截决定，原生分支还原不了。
    func testLinkedImageFallsBackToWebView() {
        XCTAssertNil(
            nativeContent(
                for: "[url=https://example.com][img]https://img.nga.cn/attachments/mon_202607/23/a.jpg[/img][/url]"
            )
        )
    }

    /// 原生结构里的图片必须和 HTML 分支一张不多、一张不少，顺序也要一致。
    func testNativeImagesMatchHTMLImages() throws {
        let sources = [
            "[img]https://img.nga.cn/attachments/mon_202607/23/a.jpg[/img]",
            "文字<br/>[img]https://img.nga.cn/attachments/mon_202607/23/a.jpg[/img]<br/>更多文字",
            "[img]https://img.nga.cn/attachments/mon_202607/23/a.jpg[/img]<br/>[img]https://img.nga.cn/attachments/mon_202607/23/b.png[/img]",
            "[quote][img]https://img.nga.cn/attachments/mon_202607/23/a.jpg[/img][/quote]回复"
        ]

        for source in sources {
            let sanitized = parser.sanitizedPost(source)
            let content = try XCTUnwrap(sanitized.nativeContent, "该内容应当原生渲染：\(source)")
            XCTAssertEqual(
                images(of: content).map(\.url.absoluteString),
                try htmlImageSources(of: sanitized.html),
                "原生结构与 HTML 的图片不一致：\(source)"
            )
        }
    }

    // MARK: - 必须回退到 WKWebView 的内容

    func testTableFallsBackToWebView() {
        XCTAssertNil(nativeContent(for: "[table][tr][td]单元格[/td][/tr][/table]"))
    }

    func testCollapsibleBlockFallsBackToWebView() {
        XCTAssertNil(nativeContent(for: "[collapse=标题]折叠内容[/collapse]"))
    }

    /// 楼层引用链接必须能原生渲染 —— 真实的引用块几乎都带一个 [pid=...] 回链，
    /// 这里若回退，绝大多数带引用的回复都会退回 WKWebView。
    func testInternalPostReferenceRendersNatively() throws {
        let content = try XCTUnwrap(
            nativeContent(for: "[quote][pid=123456,7890,1]Reply[/pid]被引用的话[/quote]我的回复")
        )
        let links = textStyles(of: content).compactMap(\.link)
        let internalLinks = links.filter { NGAInternalLink.destination(for: $0) != nil }
        XCTAssertFalse(
            internalLinks.isEmpty,
            "引用回链应当保留为可跳转的站内链接"
        )
        XCTAssertTrue(plainText(of: content).contains("被引用的话"))
        XCTAssertTrue(plainText(of: content).contains("我的回复"))
    }

    func testEmptyContentHasNoNativeRepresentation() {
        XCTAssertNil(nativeContent(for: "   "))
    }

    // MARK: - 内容完整性

    /// 只要产出了原生结构，它承载的可见文字就必须和交给 WKWebView 的 HTML 一致。
    ///
    /// 比较时剔除全部空白：SwiftSoup 的 `text()` 会在块级和 `<img>` 边界补空格，
    /// 而原生分支是靠 VStack 分块和内联表情来表达同样的排版，两者的空白必然不同。
    /// 这里要守住的是「一个可见字符都不能丢，且顺序一致」。
    func testNativeContentNeverDropsTextRelativeToHTML() throws {
        let sources = [
            "这是一段普通回复",
            "[b]粗体[/b]和普通文字混排",
            "[color=blue]蓝[/color][size=120%]大[/size][u]线[/u]",
            "第一行\n第二行\n第三行",
            "[quote]引用内容[/quote]引用后的正文",
            "[quote][b]嵌套[/b][quote]再嵌套[/quote][/quote]外层",
            "开心<img src='https://img4.nga.178.com/ngabbs/post/smile/ac0.png'>结束",
            "[url=https://example.com]链接文字[/url]后面还有字",
            "[align=center]居中文字[/align]"
        ]

        for source in sources {
            let sanitized = parser.sanitizedPost(source)
            guard let content = sanitized.nativeContent else { continue }
            XCTAssertEqual(
                normalized(plainText(of: content)),
                normalized(try renderedText(of: sanitized.html)),
                "原生结构与 HTML 的可见文字不一致：\(source)"
            )
        }
    }

    /// 回退时 HTML 分支必须仍然完好，否则该层就什么都渲染不出来了。
    func testFallbackStillProducesRenderableHTML() throws {
        let sources = [
            "[img]https://img.nga.cn/attachments/mon_202607/23/a.gif[/img]",
            "[table][tr][td]单元格[/td][/tr][/table]",
            "[collapse=标题]折叠内容[/collapse]"
        ]

        for source in sources {
            let sanitized = parser.sanitizedPost(source)
            XCTAssertNil(sanitized.nativeContent, "该内容应当回退：\(source)")
            XCTAssertTrue(
                sanitized.html.contains(#"<main id="snga-post-content">"#),
                "回退分支仍需产出可渲染的 HTML：\(source)"
            )
        }
    }

    // MARK: - 真实帖子结构（取自 tid=47337610）

    /// NGA 有两种「引用」写法，观感相近但数据完全不同：
    ///
    /// - 只有 `[pid=...]` 回链的「Reply to」抬头，正文里**不含**被引用的内容；
    ///   网页版是靠前端脚本另行拉取被引楼层再内联展示的。
    /// - 真正的 `[quote]...[/quote]`，被引用内容就在正文里。
    ///
    /// 这两种必须区分清楚，否则很容易把「原文本就没有引用内容」误判成渲染丢内容。
    /// 前一种由 `PostQuoteExpander` 在清洗前补成后一种；本测试验证的是**未展开**
    /// 的原始形态，也就是跨页引用取不到被引楼层时的兜底表现。
    func testReplyToHeaderCarriesNoQuotedBody() throws {
        // #5：[/b] 后紧跟正文
        let raw = "[b]Reply to [pid=877855034,47337610,1]Reply[/pid] Post by [uid=188297]zuldark[/uid] (2026-08-09 08:03)[/b]我一直没搞懂内马尔"
        let sanitized = parser.sanitizedPost(raw)
        let content = try XCTUnwrap(sanitized.nativeContent)

        let hasQuoteBlock = content.blocks.contains { block in
            if case .quote = block { return true }
            return false
        }
        XCTAssertFalse(hasQuoteBlock, "原文没有 [quote]，不应该凭空造出引用块")

        // 抬头加粗、正文不加粗，与 HTML 分支的 <strong>抬头</strong>正文 保持一致。
        let bodySegment = segments(of: content).last
        guard case let .text(value, style)? = bodySegment else {
            return XCTFail("末段应为正文文本")
        }
        XCTAssertTrue(value.contains("我一直没搞懂内马尔"))
        XCTAssertFalse(style.isBold, "[/b] 之后的正文不应继续加粗")
        XCTAssertTrue(
            textStyles(of: content).contains { $0.isBold },
            "抬头应当保持加粗"
        )
    }

    /// 端到端：展开 → 清洗 → 原生转换。#5 这类只有回链抬头的楼层，
    /// 经过展开后应当和真 [quote] 楼层表现一致。
    func testExpandedReplyToRendersAsQuoteBlock() throws {
        let referenced = "土耳其其也是伊斯兰国家，萨拉赫是伊斯兰世界的绝对巨星"
        let floor5 = "[b]Reply to [pid=877855034,47337610,1]Reply[/pid] Post by [uid=188297]zuldark[/uid] (2026-08-09 08:03)[/b]我一直没搞懂内马尔"

        let expandedRaw = PostQuoteExpander.expanded(floor5) { _ in referenced }
        let content = try XCTUnwrap(parser.sanitizedPost(expandedRaw).nativeContent)

        let quoted = content.blocks.compactMap { block -> [PostBlock]? in
            guard case let .quote(nested) = block else { return nil }
            return nested
        }
        XCTAssertEqual(quoted.count, 1, "展开后应当出现引用块")

        let quotedText = quoted.flatMap { $0 }.flatMap(segments(of:)).reduce(into: "") {
            if case let .text(value, _) = $1 { $0 += value }
        }
        XCTAssertTrue(quotedText.contains(referenced), "被引正文应在引用块内")
        XCTAssertTrue(quotedText.contains("zuldark"), "被引作者应在引用块内")

        // 本层正文必须留在引用块之外，且不带引用块的加粗抬头样式。
        let ownParagraphs = content.blocks.compactMap { block -> PostParagraph? in
            guard case let .paragraph(paragraph) = block else { return nil }
            return paragraph
        }
        let ownText = ownParagraphs.flatMap(\.segments).reduce(into: "") {
            if case let .text(value, _) = $1 { $0 += value }
        }
        XCTAssertTrue(ownText.contains("我一直没搞懂内马尔"))
        XCTAssertFalse(ownText.contains(referenced), "被引正文不应泄漏到本层正文")
    }

    func testRealQuoteKeepsQuotedBody() throws {
        // #8：真正带 [quote] 的楼层
        let raw = "[quote][pid=877855763,47337610,1]Reply[/pid] [b]Post by [uid=62442264]神似哀伤[/uid] (2026-08-09 08:22):[/b]<br/><br/>我一直没搞懂内马尔[/quote]<br/><br/>其实他们去豪门也可以当轮换"
        let content = try XCTUnwrap(parser.sanitizedPost(raw).nativeContent)

        let quoted = content.blocks.compactMap { block -> [PostBlock]? in
            guard case let .quote(nested) = block else { return nil }
            return nested
        }
        XCTAssertEqual(quoted.count, 1, "应当有且只有一个引用块")

        let quotedText = quoted.flatMap { $0 }.flatMap(segments(of:)).reduce(into: "") {
            if case let .text(value, _) = $1 { $0 += value }
        }
        XCTAssertTrue(
            quotedText.contains("我一直没搞懂内马尔"),
            "被引用的正文必须保留在引用块内"
        )
        XCTAssertTrue(
            plainText(of: content).contains("其实他们去豪门"),
            "引用块之后的正文也必须保留"
        )
    }

    // MARK: - 辅助

    private func nativeContent(for source: String) -> PostContent? {
        parser.sanitizedPost(source).nativeContent
    }

    private func segments(of content: PostContent) -> [PostSegment] {
        content.blocks.flatMap(segments(of:))
    }

    private func segments(of block: PostBlock) -> [PostSegment] {
        switch block {
        case let .paragraph(paragraph): paragraph.segments
        case let .quote(nested): nested.flatMap(segments(of:))
        case .image: []
        }
    }

    private func images(of content: PostContent) -> [PostImage] {
        content.blocks.flatMap(images(of:))
    }

    private func images(of block: PostBlock) -> [PostImage] {
        switch block {
        case .paragraph: []
        case let .quote(nested): nested.flatMap(images(of:))
        case let .image(image): [image]
        }
    }

    private func htmlImageSources(of html: String) throws -> [String] {
        let document = try SwiftSoup.parse(html)
        return try document.select("main#snga-post-content img")
            .filter { !$0.hasClass("nga-smile") }
            .map { try $0.attr("src") }
    }

    private func plainText(of content: PostContent) -> String {
        segments(of: content).reduce(into: "") { result, segment in
            if case let .text(value, _) = segment { result += value }
        }
    }

    private func textStyles(of content: PostContent) -> [PostTextStyle] {
        segments(of: content).compactMap { segment in
            guard case let .text(_, style) = segment else { return nil }
            return style
        }
    }

    private func renderedText(of html: String) throws -> String {
        let document = try SwiftSoup.parse(html)
        let main = try XCTUnwrap(try document.select("main#snga-post-content").first())
        return try main.text()
    }

    private func normalized(_ value: String) -> String {
        value.filter { !$0.isWhitespace }
    }
}
