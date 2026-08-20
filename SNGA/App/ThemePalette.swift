import SwiftUI

/// 一套主题的全部语义颜色。
///
/// 改动前 `ResolvedAppTheme` 只有背景色和强调色两个输入，其余全靠推导：
/// `surfaceColor` 把背景朝黑或白混入 4.5%～7% 当卡片色，边框、悬停底、次级文字
/// 则散落在各个视图里用 `Color.primary.opacity(...)` 现场凑 —— 全项目八个不同的
/// 透明度值（0.035／0.055／0.065／0.07／0.08／0.14／0.45／0.5），对应的其实只有
/// 三四种角色。
///
/// 推导还把浅色主题的层级弄反了。混色方向是「朝对比色靠」，于是浅色主题的卡片
/// 比窗口**更暗**（明亮 1.10:1、暖金 1.10:1），和 macOS「内容浮在窗口之上」的
/// 惯例正相反；深色主题方向对，但只有 1.20 上下，卡片边界几乎看不出来。
///
/// 现在每套主题各写一张表，取值都过了 `ThemePaletteTests` 里的下限。
struct ThemePalette: Equatable, Sendable {
    /// 窗口底色。
    var background: ThemeRGB
    /// 卡片、列表行的主表面。始终比 `background` 亮 —— 内容浮在窗口之上。
    var surface: ThemeRGB
    /// 抬起的表面：卡片悬停、需要再高一层的容器。
    var elevatedSurface: ThemeRGB
    /// 直接铺在窗口上的块（磁贴、边栏行）的底色。
    var fill: ThemeRGB
    /// 同上的悬停态。
    var hoverFill: ThemeRGB
    /// 分隔线、卡片描边。
    var separator: ThemeRGB
    /// 控件描边（搜索框这类）。比 `separator` 重得多：WCAG 要求控件边界对相邻
    /// 颜色 3:1，而原先那个 `Color.primary.opacity(0.14)` 只有 1.4 上下。
    var controlBorder: ThemeRGB
    /// 正文。
    var primaryText: ThemeRGB
    /// 次级文字：时间戳、作者名。
    var secondaryText: ThemeRGB
    /// 三级文字：楼层号、设备标记。仍然过 AA，可以放心压暗。
    var tertiaryText: ThemeRGB
    /// 强调色。沿用各主题原有的取值，这次不动品牌色。
    var accent: ThemeRGB

    /// 热点回复的标记色。
    ///
    /// 就是强调色本身，必要时调一调明度，保证压在卡片上还读得出来（楼层号
    /// 拿它当文字色，要 4.5:1）。
    ///
    /// 这里一度改成固定的暖色，理由是「暖色本身就是热的意思，跟着强调色转会
    /// 把语义转没了」。放到界面上不成立：午夜蓝的「热点回复」标题是青色的，
    /// 下面的卡片却镶一圈橙边，同一个功能里自己就不一致，橙色在整片冷色里
    /// 也只是一块外来色。热点是这个版面自己的强调，不是一个跨主题的通用状态，
    /// 跟着主题走才对。
    var hotReply: ThemeRGB {
        Self.fittingContrast(accent, on: surface, atLeast: 4.5)
    }

    /// 保住色相和饱和度，只调明度，把 `color` 推到对 `surface` 至少 `minimum`。
    /// 明度到头还不够就接着降饱和度 —— 深色卡片上的深蓝就是这么救回来的。
    static func fittingContrast(
        _ color: ThemeRGB,
        on surface: ThemeRGB,
        atLeast minimum: Double
    ) -> ThemeRGB {
        guard color.contrastRatio(with: surface) < minimum else { return color }

        let hue = color.hueDegrees
        let saturation = color.saturation
        let step = surface.relativeLuminance >= 0.18 ? -0.02 : 0.02
        var brightness = color.brightness

        while brightness + step > 0.02, brightness + step < 1 {
            brightness += step
            let candidate = ThemeRGB(
                hueDegrees: hue, saturation: saturation, brightness: brightness
            )
            if candidate.contrastRatio(with: surface) >= minimum { return candidate }
        }

        var fading = saturation
        while fading > 0 {
            fading -= 0.02
            let candidate = ThemeRGB(
                hueDegrees: hue, saturation: max(fading, 0), brightness: brightness
            )
            if candidate.contrastRatio(with: surface) >= minimum { return candidate }
        }
        return ThemeRGB(hueDegrees: hue, saturation: 0, brightness: brightness)
    }

    static let light = ThemePalette(
        background: ThemeRGB(hex: "#EEEEF0")!,
        surface: ThemeRGB(hex: "#FFFFFF")!,
        elevatedSurface: ThemeRGB(hex: "#F5F5F8")!,
        fill: ThemeRGB(hex: "#E4E4E9")!,
        hoverFill: ThemeRGB(hex: "#DADAE1")!,
        separator: ThemeRGB(hex: "#D5D5DB")!,
        controlBorder: ThemeRGB(hex: "#8E8E96")!,
        primaryText: ThemeRGB(hex: "#16171A")!,
        secondaryText: ThemeRGB(hex: "#5B5F66")!,
        tertiaryText: ThemeRGB(hex: "#72767D")!,
        accent: ThemeRGB(hex: "#0869C9")!
    )

    static let dark = ThemePalette(
        background: ThemeRGB(hex: "#131316")!,
        surface: ThemeRGB(hex: "#202024")!,
        elevatedSurface: ThemeRGB(hex: "#2A2A31")!,
        fill: ThemeRGB(hex: "#1D1D21")!,
        hoverFill: ThemeRGB(hex: "#26262C")!,
        separator: ThemeRGB(hex: "#38383F")!,
        controlBorder: ThemeRGB(hex: "#6E6E78")!,
        primaryText: ThemeRGB(hex: "#E9E8EC")!,
        secondaryText: ThemeRGB(hex: "#A2A1A9")!,
        tertiaryText: ThemeRGB(hex: "#8B8A93")!,
        accent: ThemeRGB(hex: "#C49CFF")!
    )

    /// 暖金的卡片色定成比窗口更亮的 `#FDF7E9` —— 纸摆在桌面上，不是陷进桌面里。
    static let ngaClassic = ThemePalette(
        background: ThemeRGB(hex: "#F0E3C4")!,
        surface: ThemeRGB(hex: "#FDF7E9")!,
        elevatedSurface: ThemeRGB(hex: "#F8F1DD")!,
        fill: ThemeRGB(hex: "#E9DBB8")!,
        hoverFill: ThemeRGB(hex: "#E1D0A6")!,
        separator: ThemeRGB(hex: "#DCCBA2")!,
        controlBorder: ThemeRGB(hex: "#9A8558")!,
        primaryText: ThemeRGB(hex: "#2A2117")!,
        secondaryText: ThemeRGB(hex: "#6B5A3E")!,
        tertiaryText: ThemeRGB(hex: "#7D6C4C")!,
        accent: ThemeRGB(hex: "#A8570D")!
    )

    static let midnight = ThemePalette(
        background: ThemeRGB(hex: "#080E1A")!,
        surface: ThemeRGB(hex: "#131C2E")!,
        elevatedSurface: ThemeRGB(hex: "#1D2A44")!,
        fill: ThemeRGB(hex: "#0F1726")!,
        hoverFill: ThemeRGB(hex: "#182338")!,
        separator: ThemeRGB(hex: "#2A3A57")!,
        controlBorder: ThemeRGB(hex: "#5C7096")!,
        primaryText: ThemeRGB(hex: "#E2E9F2")!,
        secondaryText: ThemeRGB(hex: "#93A3BC")!,
        tertiaryText: ThemeRGB(hex: "#7C8BA6")!,
        accent: ThemeRGB(hex: "#52D6E8")!
    )

    /// 自定义主题只有背景和强调两个输入，其余仍然要推 —— 但推法和原先不同：
    /// 每一档都朝「能拿到目标对比度」的方向走，拿不到就换个方向再试，
    /// 而不是固定朝黑或朝白混一个写死的比例。
    static func custom(background: ThemeRGB, accent: ThemeRGB) -> ThemePalette {
        let isDark = background.isDark

        // 卡片要比窗口亮。背景本来就接近纯白时朝亮走已经没有余量，退回压暗一档
        // —— 那种情况下唯一能拉开层次的方向就是它。
        let lighter = background.mixed(with: .white, amount: isDark ? 0.09 : 0.5)
        var surface = lighter
        var elevation = ThemeRGB.white
        if lighter.contrastRatio(with: background) < 1.1 {
            surface = background.mixed(with: .black, amount: 0.07)
            elevation = .black
        }

        // 中间调背景推不出能承载文字层级的卡片色：纯黑压在中性灰上也只有 6:1
        // 出头，三级文字更是无从谈起。窗口色是用户选的，卡片色是我们的 ——
        // 继续朝原来的方向推，直到这张卡片撑得起正文为止。
        var pushes = 0
        while pushes < 14,
              Self.bestAchievableTextContrast(on: surface) < 7.5 {
            surface = surface.mixed(with: elevation, amount: 0.045)
            pushes += 1
        }

        let awayFromSurface: ThemeRGB = surface.isDark ? .white : .black

        /// 从卡片色朝对面推到刚够 `target`。
        ///
        /// `preferredCap` 是「别推到纯黑纯白」的偏好，不是硬上限 —— 推不动就
        /// 换方向，还推不动就放开上限。宁可用到纯白，也不能留一段读不出来的字。
        func text(_ target: Double, preferredCap cap: Double) -> ThemeRGB {
            let opposite: ThemeRGB = awayFromSurface == .white ? .black : .white
            func towards(_ goal: ThemeRGB, limit: Double) -> ThemeRGB? {
                var step = 0.0
                while step <= limit + 0.0001 {
                    let candidate = surface.mixed(with: goal, amount: step)
                    if candidate.contrastRatio(with: surface) >= target { return candidate }
                    step += 0.02
                }
                return nil
            }
            if let hit = towards(awayFromSurface, limit: cap) { return hit }
            if let hit = towards(opposite, limit: cap) { return hit }
            if let hit = towards(awayFromSurface, limit: 1) { return hit }
            if let hit = towards(opposite, limit: 1) { return hit }
            return awayFromSurface.contrastRatio(with: surface)
                >= opposite.contrastRatio(with: surface) ? awayFromSurface : opposite
        }

        return ThemePalette(
            background: background,
            surface: surface,
            elevatedSurface: surface.mixed(with: awayFromSurface, amount: 0.07),
            fill: background.mixed(with: awayFromSurface, amount: 0.06),
            hoverFill: background.mixed(with: awayFromSurface, amount: 0.13),
            separator: surface.mixed(with: awayFromSurface, amount: 0.16),
            controlBorder: text(3, preferredCap: 0.55),
            primaryText: text(9.5, preferredCap: 0.9),
            secondaryText: text(5.5, preferredCap: 0.72),
            tertiaryText: text(4.6, preferredCap: 0.6),
            accent: accent
        )
    }

    /// 这张卡片色上，文字最多能拿到多少对比度。中间调的卡片两个方向都推不动，
    /// 这个值就是它的天花板。
    private static func bestAchievableTextContrast(on surface: ThemeRGB) -> Double {
        max(
            surface.contrastRatio(with: .white),
            surface.contrastRatio(with: .black)
        )
    }
}
