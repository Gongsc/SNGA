import AppKit
import SwiftUI
import XCTest
@testable import SNGA

/// 字体设置的三件事：档位表对不对得上系统、缩放算得对不对、以及网页那一侧的
/// 替换会不会漏。
final class FontSettingsTests: XCTestCase {

    // MARK: - 档位表

    /// `ScopedFontSet` 把各语义档位按比例缩放，比例的分母是抄下来的一张表。
    /// 系统哪天改了取值，这里会先红 —— 否则界面上的主次关系会悄悄走样。
    func testSemanticPointSizesMatchAppKit() {
        let pairs: [(Font.TextStyle, NSFont.TextStyle)] = [
            (.largeTitle, .largeTitle),
            (.title, .title1),
            (.title2, .title2),
            (.title3, .title3),
            (.headline, .headline),
            (.subheadline, .subheadline),
            (.body, .body),
            (.callout, .callout),
            (.footnote, .footnote),
            (.caption, .caption1),
            (.caption2, .caption2)
        ]
        for (swiftUIStyle, appKitStyle) in pairs {
            XCTAssertEqual(
                ScopedFontSet.systemPointSize(for: swiftUIStyle),
                Double(NSFont.preferredFont(forTextStyle: appKitStyle).pointSize),
                accuracy: 0.001,
                "\(appKitStyle) 的点数和表里对不上了"
            )
        }
    }

    /// 侧栏和话题列表的基准就是 `.body`：默认档下这两处画出来必须和改动前一样。
    func testDefaultSizesMatchTheStyleTheyStandFor() {
        let bodySize = ScopedFontSet.systemPointSize(for: .body)
        XCTAssertEqual(FontArea.sidebar.defaultSize, bodySize)
        XCTAssertEqual(FontArea.topicList.defaultSize, bodySize)
        // 用户信息那一栏的主行是作者名，也走 `.body`。
        XCTAssertEqual(FontArea.postAuthor.defaultSize, bodySize)
        // 话题内容的基准是楼层正文，网页那份 `--snga-font-size` 里也是这个数。
        XCTAssertTrue(
            PostDocument.webFontSizeDeclaration
                .hasSuffix(":\(Int(FontArea.threadContent.defaultSize))px"),
            "楼层正文的默认字号和样式表里的初值对不上：\(PostDocument.webFontSizeDeclaration)"
        )
    }

    // MARK: - 缩放

    func testScalingKeepsBodyAtTheChosenSizeAndPullsTheRestAlong() {
        let set = ScopedFontSet(area: .threadContent, size: 21)
        XCTAssertEqual(set.scale, 1.5, accuracy: 0.0001)
        XCTAssertEqual(set.postBodySize, 21)
        XCTAssertEqual(set.postSmallSize, 18, accuracy: 0.0001)
        XCTAssertEqual(set.pointSize(for: .caption), 15, accuracy: 0.0001)
    }

    func testSizeIsClampedAndRounded() {
        XCTAssertEqual(FontSettings.normalizedSize(3), FontSettings.allowedSizeRange.lowerBound)
        XCTAssertEqual(FontSettings.normalizedSize(99), FontSettings.allowedSizeRange.upperBound)
        XCTAssertEqual(FontSettings.normalizedSize(13.4), 13)
        // 读不出数时按「这一段」自己的默认回落，不是固定的某一段。
        for area in FontArea.allCases {
            XCTAssertEqual(FontSettings.normalizedSize(.nan, for: area), area.defaultSize)
        }
        // 存量库里那个 0（键从没写过又被谁读成整数）不能变成 0 点的字。
        XCTAssertEqual(
            ScopedFontSet(area: .sidebar, size: 0).size,
            FontSettings.allowedSizeRange.lowerBound
        )
    }

    /// 字体是可以被卸载的，设置里存的只是一个名字。
    func testUnknownFamilyFallsBackToTheSystemFont() {
        XCTAssertEqual(
            FontSettings.normalizedFamily("这个字体不可能装在任何一台机器上"),
            FontSettings.systemFamilyName
        )
        let installed = try? XCTUnwrap(FontSettings.availableFamilies.first)
        if let installed {
            XCTAssertEqual(FontSettings.normalizedFamily(installed), installed)
        }
        XCTAssertFalse(
            FontSettings.availableFamilies.contains { $0.hasPrefix(".") },
            "系统内部字体不该出现在选择器里"
        )
    }

    // MARK: - 网页那一侧

    private func document() -> String {
        PostDocument.html(
            body: "<p>楼层正文</p>",
            extraCSS: PostDocument.signatureStyleSheet
        )
    }

    /// 没改过设置的用户不该因为多了这个功能而看到任何区别。
    func testDefaultSettingsLeaveTheDocumentByteIdentical() {
        let html = document()
        for area in FontArea.allCases {
            XCTAssertEqual(
                ScopedFontSet.default(for: area).applying(to: html),
                html,
                "\(area.title) 的默认档改动了文档"
            )
        }
    }

    func testApplyingWritesEverySizeAndTheFamily() {
        let set = ScopedFontSet(
            area: .threadContent,
            familyName: "PingFang SC",
            size: 21
        )
        let applied = set.applying(to: document())

        XCTAssertTrue(applied.contains("--snga-font-size:21px"), applied.prefix(600).description)
        XCTAssertTrue(applied.contains("--snga-font-small:18px"))
        XCTAssertTrue(
            applied.contains("--snga-font-family:\"PingFang SC\",-apple-system"),
            "用户挑的家族要排在最前，系统那一串仍旧跟在后面兜底"
        )
        // 初值一个都不能剩下：剩下的那条就是没被替换到的那一条。
        XCTAssertFalse(applied.contains(PostDocument.webFontSizeDeclaration))
        XCTAssertFalse(applied.contains(PostDocument.webSmallFontSizeDeclaration))
        XCTAssertFalse(applied.contains(PostDocument.webFontFamilyDeclaration))
    }

    /// 12 × 15/14 是 12.857。四舍五入成整数会让签名和正文在某些档位上一样大。
    func testFractionalSmallSizeKeepsTwoDecimals() {
        let applied = ScopedFontSet(area: .threadContent, size: 15)
            .applying(to: document())
        XCTAssertTrue(applied.contains("--snga-font-small:12.86px"), "签名的字号被抹平了")
    }

    /// 家族名进的是 CSS 字符串。引号不转义的话，一个名字里带引号的字体就能把
    /// 后面的样式规则整段顶掉。
    func testFamilyNameIsEscapedForCSS() {
        let applied = ScopedFontSet(
            area: .threadContent,
            familyName: "Ev\"il}body{display:none",
            size: 16
        ).applying(to: document())
        XCTAssertTrue(applied.contains("\\\"il}body{display:none"))
        XCTAssertFalse(applied.contains("--snga-font-family:\"Ev\"il}"))
    }

    /// 主题和字体各替换各的，谁先谁后都不能把对方的记号吃掉。
    func testThemeAndFontSubstitutionsDoNotCollide() {
        let set = ScopedFontSet(area: .threadContent, familyName: "Menlo", size: 18)
        let themed = AppTheme.midnight.resolved().applying(to: document())
        let applied = set.applying(to: themed)

        XCTAssertTrue(applied.contains("--snga-accent:#52d6e8"), "主题被字体替换吃掉了")
        XCTAssertTrue(applied.contains("--snga-font-size:18px"))
        XCTAssertTrue(applied.contains("color-scheme:dark"))
    }

    // MARK: - 楼层头上那一栏的排版

    /// 头像的高度等于两行信息加一道行距。三者对不齐的话，头像会比名字和时间
    /// 高出或矮下半行 —— 默认档下看不出来，字号一调就摊开了。
    func testTheAvatarStaysAsTallAsTheTwoInformationRows() {
        for size in stride(from: FontSettings.allowedSizeRange.lowerBound,
                           through: FontSettings.allowedSizeRange.upperBound,
                           by: 1) {
            let set = ScopedFontSet(area: .postAuthor, size: size)
            XCTAssertEqual(
                PostAuthorHeaderLayout.avatarSize(for: set),
                PostAuthorHeaderLayout.rowHeight(for: set) * 2
                    + PostAuthorHeaderLayout.rowSpacing,
                "字号 \(size) 下头像和两行信息对不齐了"
            )
        }
    }

    /// 行高必须跟着字号长。写死的话，级别和声望会各被裁掉一截 —— 字确实变大了，
    /// 只是看不全，而那正是这一栏最容易被漏掉的地方。
    func testTheHeaderRowGrowsWithTheChosenSize() {
        let small = ScopedFontSet(area: .postAuthor, size: 11)
        let large = ScopedFontSet(area: .postAuthor, size: 20)
        XCTAssertLessThan(
            PostAuthorHeaderLayout.rowHeight(for: small),
            PostAuthorHeaderLayout.rowHeight(for: large)
        )
        // 行高要装得下这一档的正文，否则框比字矮。
        XCTAssertGreaterThanOrEqual(
            PostAuthorHeaderLayout.rowHeight(for: large),
            large.pointSize(for: .body)
        )
        XCTAssertEqual(
            PostAuthorHeaderLayout.rowHeight(for: .default(for: .postAuthor)),
            20,
            "默认档下这一栏的行高该和改动前一样"
        )
    }

    // MARK: - 字体本身

    func testSystemFamilyStillProducesTheSystemFont() {
        let set = ScopedFontSet(area: .threadContent)
        XCTAssertEqual(
            set.nsFont(ofSize: 14).fontName,
            NSFont.systemFont(ofSize: 14).fontName
        )
    }

    /// 设置里存的是**家族名**。`NSFont(name:)` 拿家族名多半得到 nil，所以这条路
    /// 走的是描述符 —— 换回去的话，挑了「PingFang SC」会静默地什么都不变。
    func testFamilyNameResolvesToThatFamily() throws {
        let family = try XCTUnwrap(
            ["PingFang SC", "Helvetica Neue", "Menlo"]
                .first { FontSettings.availableFamilies.contains($0) },
            "这台机器上一个预期的字体都没有"
        )
        let font = ScopedFontSet(area: .threadContent, familyName: family, size: 16)
            .nsFont(ofSize: 16)
        XCTAssertEqual(font.familyName, family)
        XCTAssertEqual(font.pointSize, 16)
    }

    func testMissingFamilyFallsBackInsteadOfCrashing() {
        let font = ScopedFontSet(
            area: .threadContent,
            familyName: "没有这个字体",
            size: 16
        ).nsFont(ofSize: 16)
        XCTAssertEqual(font.pointSize, 16)
    }

    /// 等宽那一份不跟着换家族：用户挑的多半是正文字体，拿它排代码会让对齐全塌。
    func testMonospacedFontIgnoresTheChosenFamily() {
        let set = ScopedFontSet(area: .threadContent, familyName: "Zapfino", size: 16)
        XCTAssertEqual(
            set.monospacedNSFont(ofSize: 13).fontName,
            NSFont.monospacedSystemFont(ofSize: 13, weight: .regular).fontName
        )
    }
}
