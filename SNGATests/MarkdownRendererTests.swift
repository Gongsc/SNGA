import XCTest
@testable import SNGA

/// Markdown 预览渲染器。
///
/// 这些用例分两拨：一拨管「看起来对不对」，一拨管「有没有缺口」。后者更要紧 ——
/// 预览的产物是交给 `WKWebView` 显示的。
final class MarkdownRendererTests: XCTestCase {

    private func render(_ source: String) -> String {
        MarkdownRenderer.previewHTML(source)
    }

    // MARK: - 转义：源码里的 HTML 一律当文字

    /// 预览要在 `WKWebView` 里显示。正文是用户写的，也可能是从别的楼层引过来的，
    /// 放任何一段原始 HTML 过去都等于在自己的进程里跑别人的脚本。
    func testRawHTMLInTheSourceIsShownAsTextNotExecuted() {
        let html = render("<script>alert(1)</script>")

        XCTAssertFalse(html.contains("<script"), "脚本标签漏过去了：\(html)")
        XCTAssertTrue(html.contains("&lt;script&gt;"))
    }

    func testAnImageTagInTheSourceDoesNotBecomeAnImage() {
        let html = render(#"<img src=x onerror="alert(1)">"#)

        XCTAssertFalse(html.contains("<img"), "标签漏过去了：\(html)")
        XCTAssertFalse(html.contains("onerror=\""), "事件处理器漏过去了：\(html)")
    }

    /// `javascript:` 在 `WKWebView` 里点得动。链接语法是合法 Markdown，
    /// 所以拦要拦在协议上，而不是指望源码里不出现方括号。
    func testAJavaScriptLinkIsNotTurnedIntoALink() {
        let html = render("[点我](javascript:alert(1))")

        XCTAssertFalse(html.contains("<a href"), "伪协议被做成链接了：\(html)")
        XCTAssertFalse(html.lowercased().contains("javascript:"))
        // 认不出来的退回成文字，而不是整段消失。
        XCTAssertTrue(html.contains("点我"))
    }

    func testAJavaScriptImageSourceIsNotTurnedIntoAnImage() {
        let html = render("![图](javascript:alert(1))")

        XCTAssertFalse(html.contains("<img"), "伪协议被做成图片了：\(html)")
    }

    func testAnOrdinaryLinkStillWorks() {
        let html = render("[文档](https://example.com/a)")

        XCTAssertTrue(html.contains(#"<a href="https://example.com/a">文档</a>"#), html)
    }

    // MARK: - 常见语法

    func testHeadingsBecomeHeadings() {
        XCTAssertTrue(render("## 标题").contains("<h2>标题</h2>"))
        // 井号后面没空格的是话题标签，不是标题。
        XCTAssertFalse(render("#标签").contains("<h1>"))
    }

    func testEmphasisNestsFromLongestMarkerFirst() {
        XCTAssertTrue(render("***重***").contains("<strong><em>重</em></strong>"))
        XCTAssertTrue(render("**粗**").contains("<strong>粗</strong>"))
        XCTAssertTrue(render("*斜*").contains("<em>斜</em>"))
        XCTAssertTrue(render("~~删~~").contains("<del>删</del>"))
    }

    func testBulletAndOrderedListsAreSeparateBlocks() {
        let html = render("- 甲\n- 乙\n\n1. 一\n2. 二")

        XCTAssertTrue(html.contains("<ul><li>甲</li><li>乙</li></ul>"), html)
        XCTAssertTrue(html.contains("<ol><li>一</li><li>二</li></ol>"), html)
    }

    func testQuotedLinesBecomeOneQuoteBlock() {
        let html = render("> 甲说\n> 乙说\n\n我说")

        XCTAssertEqual(html.components(separatedBy: "<blockquote>").count - 1, 1, html)
        XCTAssertTrue(html.contains("甲说"))
        XCTAssertTrue(html.contains("<p>我说</p>"), html)
    }

    /// 代码块里的星号和井号不该再被当成标记 —— 那正是写代码块的用意。
    func testAFencedBlockKeepsItsContentsLiteral() {
        let html = render("```\n**不是粗体**\n# 不是标题\n```")

        XCTAssertTrue(html.contains("<pre><code>"), html)
        XCTAssertFalse(html.contains("<strong>"), html)
        XCTAssertFalse(html.contains("<h1>"), html)
    }

    /// 围栏没闭合时，剩下的内容仍要显示出来，而不是被吃掉。
    func testAnUnclosedFenceStillShowsItsContents() {
        let html = render("```\n没写收尾")

        XCTAssertTrue(html.contains("没写收尾"), html)
    }

    func testInlineCodeProtectsItsContents() {
        let html = render("用 `**这个**` 表示粗体")

        XCTAssertTrue(html.contains("<code>**这个**</code>"), html)
    }

    func testAnEmptySourceRendersToNothing() {
        XCTAssertEqual(render(""), "")
        XCTAssertEqual(render("\n\n  \n"), "")
    }
}
