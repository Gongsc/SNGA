import XCTest
@testable import SNGA

/// 每套主题的调色板必须自洽。
///
/// 改动前这些值是推出来的：卡片色 = 背景朝黑或白混入 4.5%～7%，其余散落在各个
/// 视图里用 `Color.primary.opacity(...)` 现场凑。推导把浅色主题的层级弄反了 ——
/// 卡片比窗口更暗，和 macOS「内容浮在窗口之上」的惯例相反。现在改成每套主题一
/// 张手写的表，这些下限就是那张表的依据；调色值时先在这里失败，而不是等用户
/// 看到一张糊在窗口里的卡片。
final class ThemePaletteTests: XCTestCase {

    private static let all: [(String, ThemePalette)] = [
        ("明亮", .light),
        ("深色", .dark),
        ("NGA 暖金", .ngaClassic),
        ("午夜蓝", .midnight)
    ]

    /// 卡片必须比窗口亮，而且拉得开。macOS 自己的窗口／内容区大约是 1.16:1，
    /// 这里取 1.12 作下限。
    func testSurfaceSitsAboveBackground() {
        for (name, palette) in Self.all {
            XCTAssertGreaterThan(
                palette.surface.relativeLuminance,
                palette.background.relativeLuminance,
                "\(name)：卡片没有比窗口亮，层级是反的"
            )
            assert(
                palette.surface.contrastRatio(with: palette.background),
                atLeast: 1.12, name, "卡片与窗口"
            )
        }
    }

    /// 三级文字都压在卡片上量：正文 7:1（AAA 正文），次级和三级 4.5:1（AA）。
    /// 三级仍然过 AA，楼层号、设备标记才能放心压暗。
    func testTextTiersClearContrastFloors() {
        for (name, palette) in Self.all {
            assert(palette.primaryText.contrastRatio(with: palette.surface),
                   atLeast: 7, name, "正文")
            assert(palette.secondaryText.contrastRatio(with: palette.surface),
                   atLeast: 4.5, name, "次级文字")
            assert(palette.tertiaryText.contrastRatio(with: palette.surface),
                   atLeast: 4.5, name, "三级文字")
        }
    }

    /// 分隔线只要看得见；控件描边按 WCAG 非文字对比度要 3:1 ——
    /// 原先搜索框那圈 `Color.primary.opacity(0.14)` 只有 1.4 上下。
    func testBordersAreVisible() {
        for (name, palette) in Self.all {
            assert(palette.separator.contrastRatio(with: palette.surface),
                   atLeast: 1.35, name, "分隔线")
            assert(palette.controlBorder.contrastRatio(with: palette.surface),
                   atLeast: 3, name, "控件描边")
        }
    }

    /// 悬停要和静止态分得出来，否则鼠标扫过去没有反馈。
    func testHoverIsDistinguishableFromRest() {
        for (name, palette) in Self.all {
            assert(palette.hoverFill.contrastRatio(with: palette.fill),
                   atLeast: 1.06, name, "悬停底色与静止底色")
        }
    }

    /// 热门回复得是自己的颜色。原先直接借强调色，而强调色同时还在标链接和选中
    /// 行 —— 三件事共用一个信号，哪一件都读不准。
    func testHotReplyIsItsOwnSignal() {
        for (name, palette) in Self.all {
            XCTAssertNotEqual(palette.hotReply, palette.accent, "\(name)：热门色仍然是强调色")
            assert(palette.hotReply.contrastRatio(with: palette.surface),
                   atLeast: 4.5, name, "热门色")
        }
    }

    /// 自定义主题只有背景和强调两个输入，其余仍要推 —— 推法必须对任何背景都成立，
    /// 包括纯黑、纯白和最难办的中间调。
    func testCustomPaletteHoldsForArbitraryBackgrounds() throws {
        for hex in ["#263238", "#FFFFFF", "#000000", "#8A7F6A", "#7F7F7F", "#FFF8E1", "#0B1220"] {
            let background = try XCTUnwrap(ThemeRGB(hex: hex))
            let palette = ThemePalette.custom(
                background: background,
                accent: try XCTUnwrap(ThemeRGB(hex: "#80CBC4"))
            )
            assert(palette.primaryText.contrastRatio(with: palette.surface),
                   atLeast: 7, hex, "正文")
            assert(palette.secondaryText.contrastRatio(with: palette.surface),
                   atLeast: 4.5, hex, "次级文字")
            assert(palette.tertiaryText.contrastRatio(with: palette.surface),
                   atLeast: 4.5, hex, "三级文字")
            assert(palette.controlBorder.contrastRatio(with: palette.surface),
                   atLeast: 3, hex, "控件描边")
        }
    }

    /// 跟随系统不能有调色板。写死任何一组十六进制值都会让它不再跟着 macOS
    /// 的明暗切换 —— 那一套要的就是 AppKit 的动态语义色。
    func testSystemThemeHasNoHardCodedPalette() {
        XCTAssertNil(
            AppTheme.system.resolved().palette,
            "跟随系统一旦有了自己的调色板，就不再跟随系统了"
        )
        for theme in [AppTheme.light, .dark, .ngaClassic, .midnight, .custom] {
            XCTAssertNotNil(theme.resolved().palette, "\(theme.displayName) 应当有调色板")
        }
    }

    private func assert(
        _ ratio: Double,
        atLeast floor: Double,
        _ subject: String,
        _ label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertGreaterThanOrEqual(
            ratio, floor,
            "\(subject)：\(label) 只有 \(String(format: "%.2f", ratio)):1，要求 \(floor):1",
            file: file, line: line
        )
    }
}
