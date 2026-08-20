import AppKit
import SwiftUI
import XCTest
@testable import SNGA

/// 主题配色的对比度下限。
///
/// 这些数值不是审美偏好，是「看不看得清」的分界线：改主题取值时如果把某一对
/// 配色推到线下面，这里会先失败，而不是等用户在深色模式下盯着一段糊掉的界面。
/// 纯装饰的分隔线取 3:1（非文字控件）。
final class ThemeContrastTests: XCTestCase {

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
