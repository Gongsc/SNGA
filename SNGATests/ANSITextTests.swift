import XCTest
@testable import SNGA

/// 终端输出里的 ANSI 颜色。
///
/// 站点把 ESC 渲染成一个空 span，其余部分（`[36m`）留成普通文字等脚本去解释。
/// 我们不跑脚本，所以在这里解释完 —— 不解释的话读者看到的是一份掺着
/// `[36m`、`[0m` 的报告：颜色没了，还多了一地噪声。
final class ANSITextTests: XCTestCase {

    private let esc = "\u{1B}"

    /// 剥掉宽度标记，只看颜色那一层。
    ///
    /// 汉字要补宽（见文件末尾那一组用例），于是每段汉字外面多一层 `ns-w`。
    /// 关心颜色的用例不该被它绊住 —— 但也不能改用纯拉丁样例绕过去：
    /// 那样这些用例就再也覆盖不到「中文 + 颜色」这个真实情形了。
    private func withoutWidthMarkup(_ html: String) -> String {
        html.replacingOccurrences(
            of: #"<span class="ns-w">([^<]*)</span>"#,
            with: "$1",
            options: .regularExpression
        )
    }

    func testAColourRunIsWrappedAndTheSequenceDisappears() {
        let html = withoutWidthMarkup(ANSIText.html(from: "\(esc)[36m青色\(esc)[0m之后"))

        XCTAssertEqual(html, #"<span class="ansi-fg-6">青色</span>之后"#)
        XCTAssertFalse(html.contains("["), "转义序列漏成了正文")
    }

    func testStylesCombine() {
        let html = withoutWidthMarkup(ANSIText.html(from: "\(esc)[1;4;31m重要\(esc)[0m"))

        XCTAssertTrue(html.contains("ansi-b"))
        XCTAssertTrue(html.contains("ansi-u"))
        XCTAssertTrue(html.contains("ansi-fg-1"))
    }

    /// 样式是有状态的：一段没收回的颜色要一直管到 reset。
    func testAStyleCarriesUntilItIsReset() {
        let html = withoutWidthMarkup(ANSIText.html(from: "\(esc)[32m甲\n乙\(esc)[0m丙"))

        XCTAssertTrue(html.contains("甲\n乙"), "同一段样式不该被换行打断")
        XCTAssertTrue(html.hasSuffix("丙"), "reset 之后不该还带着样式")
    }

    /// `ESC[m` 等同于 reset。
    func testAnEmptyParameterListResets() {
        XCTAssertEqual(
            withoutWidthMarkup(ANSIText.html(from: "\(esc)[31m红\(esc)[m白")),
            #"<span class="ansi-fg-1">红</span>白"#
        )
    }

    /// 扩展色上不了色，但**必须把参数一起吃掉** —— 漏掉的话，`5` 会被当成下一个
    /// SGR 码解释成别的样式，整段就花了。
    func testExtendedColoursAreConsumedNotMisread() {
        XCTAssertEqual(
            withoutWidthMarkup(ANSIText.html(from: "\(esc)[38;5;208m橙\(esc)[0m")),
            "橙",
            "扩展色不上色，也不该留下别的样式"
        )

        // 参数得挑一个「被误读就看得出来」的：1 会被当成粗体。
        // 用 208 那种测不出来 —— 它不对应任何样式，吃不吃掉结果都一样。
        XCTAssertEqual(
            withoutWidthMarkup(ANSIText.html(from: "\(esc)[38;5;1m字\(esc)[0m")),
            "字",
            "扩展色的参数没吃掉，1 被当成了粗体"
        )
        XCTAssertEqual(
            withoutWidthMarkup(ANSIText.html(from: "\(esc)[48;2;0;0;4m字\(esc)[0m")),
            "字",
            "真彩色的参数没吃掉，4 被当成了下划线"
        )
    }

    func testTrueColourIsAlsoConsumed() {
        XCTAssertEqual(withoutWidthMarkup(ANSIText.html(from: "\(esc)[38;2;255;128;0m橙\(esc)[0m")), "橙")
    }

    /// 光标移动之类的 CSI 也要吃掉，不能显示出来。
    func testNonStyleSequencesAreSwallowed() {
        XCTAssertEqual(withoutWidthMarkup(ANSIText.html(from: "\(esc)[2J清屏后")), "清屏后")
    }

    /// 正文里的尖括号仍然要转义 —— 这段文字来自别人贴的脚本输出。
    func testTextIsStillEscaped() {
        let html = ANSIText.html(from: "\(esc)[31m<script>alert(1)</script>\(esc)[0m")

        XCTAssertFalse(html.contains("<script"))
        XCTAssertTrue(html.contains("&lt;script&gt;"))
    }

    /// 换行和制表要留 —— 报告的排版全靠它们；别的控制字符留着只会变成乱码。
    func testLayoutWhitespaceSurvivesButOtherControlsDoNot() {
        let html = withoutWidthMarkup(ANSIText.html(from: "甲\t乙\n丙\u{08}丁"))

        XCTAssertTrue(html.contains("甲\t乙"))
        XCTAssertTrue(html.contains("乙\n丙"))
        XCTAssertFalse(html.contains("\u{08}"))
    }

    func testTextWithoutEscapesIsLeftAlone() {
        XCTAssertFalse(ANSIText.containsEscapes("普通文字"))
        XCTAssertEqual(withoutWidthMarkup(ANSIText.html(from: "普通文字")), "普通文字")
    }
}

/// 汉字在终端里占两列，在网页的等宽字体里只占 1.66 列。差的那截要补出来，
/// 不然报告里靠空格对齐的表格会随汉字数量越斜越远。
extension ANSITextTests {

    func testWideCharactersAreMarkedForWidening() {
        let html = ANSIText.html(from: "组织：VpsQuan")

        XCTAssertTrue(html.contains(#"<span class="ns-w">组织：</span>"#), html)
    }

    /// 拉丁部分本来就是对的，包进去会被补出多余的间距。
    func testNarrowCharactersAreLeftAlone() {
        let html = ANSIText.html(from: "AS62468")

        XCTAssertEqual(html, "AS62468")
    }

    /// 一行里中英交替时，只圈中文那几段。
    func testOnlyTheWideRunsAreWrapped() {
        let html = ANSIText.html(from: "城市：N/A, 香港")

        XCTAssertTrue(html.contains(#"<span class="ns-w">城市：</span>"#), html)
        XCTAssertTrue(html.contains("N/A, "), html)
        XCTAssertTrue(html.contains(#"<span class="ns-w">香港</span>"#), html)
    }

    /// 对齐用的空格是窄的，不能跟着被补宽 —— 那会把它撑成两倍。
    func testAlignmentSpacesAreNotWidened() {
        let html = ANSIText.html(from: "组织：    值")

        XCTAssertTrue(html.contains("</span>    <span"), "空格被圈进去了：\(html)")
    }

    /// 全角标点也占两列。
    func testFullWidthPunctuationCountsAsWide() {
        XCTAssertTrue(ANSIText.html(from: "（中）").contains(#"class="ns-w""#))
    }

    /// 上色和补宽要能叠在一起。
    func testColouredWideTextGetsBoth() {
        let html = ANSIText.html(from: "\(esc)[36m容器/虚拟化：\(esc)[0m")

        XCTAssertTrue(html.contains("ansi-fg-6"), html)
        XCTAssertTrue(html.contains("ns-w"), html)
    }

    /// 表情符号没收进来 —— 它的渲染宽度各家不一，补一个固定值只会补歪。
    func testEmojiIsNotWidened() {
        XCTAssertFalse(ANSIText.html(from: "🍗").contains("ns-w"))
    }
}
