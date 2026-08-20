import AppKit
import SwiftUI
import XCTest
@testable import SNGA

/// 主题配色的对比度下限。
///
/// 这些数值不是审美偏好，是「数字看不看得清」的分界线：改主题取值时如果把某一
/// 对配色推到线下面，这里会先失败，而不是等用户在深色模式下盯着一个糊掉的未读
/// 徽章。文字取 4.5:1（WCAG AA），纯装饰的竖线取 3:1（非文字控件）。
final class ThemeContrastTests: XCTestCase {

    /// 铺满强调色的底上写字 —— 未读徽章、小工具里的排名序号都是这个形状。
    ///
    /// 曾经这里写死 `.white`：深色主题的紫色强调色上只有 2.2:1，午夜蓝的青色上
    /// 1.7:1，自定义默认的青绿上 1.9:1，三套主题的数字基本看不出来。
    func testOnAccentClearsAAOnEveryBuiltInTheme() throws {
        for theme in [AppTheme.light, .dark, .ngaClassic, .midnight, .custom] {
            let style = theme.resolved()
            let ratio = try contrastRatio(style.onAccentColor, style.accentColor)
            XCTAssertGreaterThanOrEqual(
                ratio, 4.5,
                "\(theme.displayName)：强调色底上的文字只有 \(String(format: "%.2f", ratio)):1"
            )
        }
    }

    /// 跟随系统是有意的例外：强调色就是 SwiftUI 的 `.blue`，而 macOS 自己的
    /// 徽章和选中行一律蓝底白字。按对比度本该选暗字（4.8 对 4.0），但一个反过来
    /// 的徽章摆在原生控件旁边只会显得是画错了，所以这里跟平台走。
    func testSystemThemeFollowsPlatformWhiteOnBlue() throws {
        let components = try components(AppTheme.system.resolved().onAccentColor)
        XCTAssertEqual(components.red, 1, accuracy: 0.01)
        XCTAssertEqual(components.green, 1, accuracy: 0.01)
        XCTAssertEqual(components.blue, 1, accuracy: 0.01)
    }

    /// 自定义突出色是用户随便挑的，规则必须自己纠正过来：亮色配暗字、暗色配白字。
    func testOnAccentAdaptsToAnyCustomAccent() throws {
        for accent in ["#FFEE00", "#80CBC4", "#7A0010", "#0B1220", "#FFFFFF", "#000000"] {
            let style = AppTheme.custom.resolved(
                customBackgroundHex: "#263238",
                customAccentHex: accent
            )
            let ratio = try contrastRatio(style.onAccentColor, style.accentColor)
            XCTAssertGreaterThanOrEqual(
                ratio, 4.5,
                "突出色 \(accent) 上的文字只有 \(String(format: "%.2f", ratio)):1"
            )
        }
    }

    /// 引用块的竖线是纯装饰，按非文字控件的 3:1 要求，压在引用底色上量。
    func testQuoteRailStaysVisibleAgainstQuoteBackground() throws {
        for theme in [AppTheme.light, .dark, .ngaClassic, .midnight, .custom] {
            let style = theme.resolved()
            // 引用底色是 6% 前景压在楼层卡片上，得先合成出来再量。
            let quoteBackground = try blend(
                style.foregroundColor,
                over: style.surfaceColor,
                alpha: 0.06
            )
            let ratio = try contrastRatio(style.quoteRailColor, quoteBackground)
            XCTAssertGreaterThanOrEqual(
                ratio, 3,
                "\(theme.displayName)：引用竖线只有 \(String(format: "%.2f", ratio)):1"
            )
        }
    }

    // MARK: - 辅助

    private struct Components {
        var red: Double
        var green: Double
        var blue: Double
    }

    private func components(
        _ color: Color,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> Components {
        let resolved = try XCTUnwrap(
            NSColor(color).usingColorSpace(.sRGB),
            "取不到 sRGB 分量",
            file: file,
            line: line
        )
        return Components(
            red: Double(resolved.redComponent),
            green: Double(resolved.greenComponent),
            blue: Double(resolved.blueComponent)
        )
    }

    private func blend(_ top: Color, over bottom: Color, alpha: Double) throws -> Components {
        let top = try components(top)
        let bottom = try components(bottom)
        return Components(
            red: bottom.red + (top.red - bottom.red) * alpha,
            green: bottom.green + (top.green - bottom.green) * alpha,
            blue: bottom.blue + (top.blue - bottom.blue) * alpha
        )
    }

    private func contrastRatio(_ first: Color, _ second: Color) throws -> Double {
        try contrastRatio(components(first), components(second))
    }

    private func contrastRatio(_ first: Color, _ second: Components) throws -> Double {
        try contrastRatio(components(first), second)
    }

    private func contrastRatio(_ first: Components, _ second: Components) -> Double {
        let lighter = max(luminance(first), luminance(second))
        let darker = min(luminance(first), luminance(second))
        return (lighter + 0.05) / (darker + 0.05)
    }

    private func luminance(_ components: Components) -> Double {
        func linear(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(components.red)
            + 0.7152 * linear(components.green)
            + 0.0722 * linear(components.blue)
    }
}
