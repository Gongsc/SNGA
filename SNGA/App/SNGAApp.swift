import AppKit
import SwiftData
import SwiftUI
@preconcurrency import UserNotifications

enum BrowsingSettings {
    static let imageFreeModeKey = "browsing.imageFreeMode"
}

enum RecentForumSettings {
    static let maximumCountKey = "browsing.recentForums.maximumCount"
    static let defaultMaximumCount = 10
    static let allowedRange = 1...30

    static var maximumCount: Int {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: maximumCountKey) != nil else {
            return defaultMaximumCount
        }
        return normalizedMaximumCount(defaults.integer(forKey: maximumCountKey))
    }

    static func normalizedMaximumCount(_ value: Int) -> Int {
        min(max(value, allowedRange.lowerBound), allowedRange.upperBound)
    }
}

enum AppTheme: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark
    case ngaClassic
    case midnight
    case custom

    static let storageKey = "appearance.theme"
    static let customBackgroundKey = "appearance.custom.background"
    static let customAccentKey = "appearance.custom.accent"
    static let defaultCustomBackgroundHex = "#263238"
    static let defaultCustomAccentHex = "#80CBC4"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: "跟随系统"
        case .light: "明亮"
        case .dark: "深色"
        case .ngaClassic: "NGA 暖金"
        case .midnight: "午夜蓝"
        case .custom: "自定义"
        }
    }

    var description: String {
        switch self {
        case .system: "随 macOS 外观自动切换"
        case .light: "明亮背景与蓝色强调色"
        case .dark: "深色背景与紫色强调色"
        case .ngaClassic: "接近 NGA 网页的暖色风格"
        case .midnight: "深色背景与青蓝强调色"
        case .custom: "自行设置背景色与突出色"
        }
    }

    var systemImage: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max.fill"
        case .dark: "moon.fill"
        case .ngaClassic: "flame.fill"
        case .midnight: "sparkles"
        case .custom: "paintpalette.fill"
        }
    }

    var preferredColorScheme: ColorScheme? {
        resolved().preferredColorScheme
    }

    var accentColor: Color {
        resolved().accentColor
    }

    var previewBackground: Color {
        resolved().backgroundColor
    }

    var previewForeground: Color {
        resolved().foregroundColor
    }

    func resolved(
        customBackgroundHex: String = AppTheme.defaultCustomBackgroundHex,
        customAccentHex: String = AppTheme.defaultCustomAccentHex
    ) -> ResolvedAppTheme {
        ResolvedAppTheme(
            selection: self,
            customBackgroundHex: customBackgroundHex,
            customAccentHex: customAccentHex
        )
    }

    static func resolve(_ rawValue: String) -> AppTheme {
        AppTheme(rawValue: rawValue) ?? .system
    }

    func applying(to html: String) -> String {
        resolved().applying(to: html)
    }
}

struct ResolvedAppTheme: Equatable, Sendable {
    let selection: AppTheme
    let customBackgroundHex: String
    let customAccentHex: String

    static let system = AppTheme.system.resolved()

    /// 跟随系统那一档的热点色。这一档没有调色板可查，只能自己备两个值 ——
    /// 都是把系统蓝按 4.5:1 压在对应外观的 `controlBackgroundColor` 上拟合出来的
    /// （系统蓝原样压在白底上只有 3.5:1，楼层号读不出来）。
    static let systemHotReplyLight = ThemeRGB(hex: "#0070EB")!
    static let systemHotReplyDark = ThemeRGB(hex: "#1485FF")!

    var preferredColorScheme: ColorScheme? {
        switch selection {
        case .system: nil
        case .light, .ngaClassic: .light
        case .dark, .midnight: .dark
        case .custom: customBackgroundRGB.isDark ? .dark : .light
        }
    }

    var accentColor: Color {
        if selection == .system { return .blue }
        return accentRGB.color
    }

    var backgroundColor: Color {
        palette.map(\.background.color) ?? Color(nsColor: .windowBackgroundColor)
    }

    var surfaceColor: Color {
        palette.map(\.surface.color) ?? Color(nsColor: .controlBackgroundColor)
    }

    /// 抬起的表面：卡片悬停、需要再高一层的容器。
    var elevatedSurfaceColor: Color {
        palette.map(\.elevatedSurface.color) ?? Color(nsColor: .underPageBackgroundColor)
    }

    /// 直接铺在窗口上的块（磁贴、边栏行）的底色。
    var fillColor: Color {
        palette.map(\.fill.color) ?? Color.primary.opacity(0.035)
    }

    var hoverFillColor: Color {
        palette.map(\.hoverFill.color) ?? Color.primary.opacity(0.08)
    }

    /// 分隔线、卡片描边。
    var separatorColor: Color {
        palette.map(\.separator.color) ?? Color(nsColor: .separatorColor)
    }

    /// 控件描边（搜索框这类）。WCAG 要求控件边界对相邻颜色 3:1。
    var controlBorderColor: Color {
        palette.map(\.controlBorder.color) ?? Color(nsColor: .tertiaryLabelColor)
    }

    var foregroundColor: Color {
        palette.map(\.primaryText.color) ?? .primary
    }

    var secondaryForegroundColor: Color {
        palette.map(\.secondaryText.color) ?? .secondary
    }

    var tertiaryForegroundColor: Color {
        palette.map(\.tertiaryText.color) ?? Color(nsColor: .tertiaryLabelColor)
    }

    /// 强调色的淡底：胶囊标签、选中行这类需要「有强调色但不能盖住文字」的地方。
    var accentSoftColor: Color {
        accentColor.opacity(0.12)
    }

    /// 热点回复的标记色：跟着主题的强调色走，必要时调明度保证读得出来。
    ///
    /// 跟随系统这一档不能直接用 `.blue`：它压在浅色外观的
    /// `controlBackgroundColor` 上只有 3.5:1，楼层号读不出来。改成一个自己的
    /// 动态色，两档都按 4.5:1 拟合过，仍旧跟着 macOS 明暗切换。
    var hotReplyColor: Color {
        if let palette { return palette.hotReply.color }
        return Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let rgb = isDark
                ? ResolvedAppTheme.systemHotReplyDark
                : ResolvedAppTheme.systemHotReplyLight
            return NSColor(
                srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1
            )
        })
    }

    /// 铺满强调色的底上应该用什么颜色写字。
    ///
    /// 写死白色是不行的：`accentColor` 在深色（#C49CFF）、午夜蓝（#52D6E8）和
    /// 自定义默认（#80CBC4）里都是亮色，白字压上去只有 1.7–2.2:1，未读数字基本
    /// 看不出来。这里在白色和一个压暗到近黑的同色之间取对比度高的那个，用户把
    /// 自定义突出色调成任何颜色都能自己纠正过来。
    var onAccentColor: Color {
        // 跟随系统时强调色就是 SwiftUI 的 `.blue`。按对比度算该用暗字（4.8 对
        // 4.0），但 macOS 自己的徽章和选中行一律是蓝底白字，这里跟平台走 ——
        // 一个反过来的徽章摆在原生控件旁边只会显得是画错了。
        if selection == .system { return .white }
        let dimmed = accentRGB.mixed(with: .black, amount: 0.88)
        return accentRGB.contrastRatio(with: .white)
            >= accentRGB.contrastRatio(with: dimmed)
            ? .white
            : dimmed.color
    }

    /// 引用块左侧的竖线。
    ///
    /// 刻意避开强调色：楼层里链接、选中行和热门回复都已经在用它，引用属于从属
    /// 内容，再占用同一个颜色只会稀释「这里可以点」的信号。这里取一个跟着主题
    /// 走的中性色，六套主题下对引用底色都在 3:1 以上。
    var quoteRailColor: Color {
        if selection == .system { return Color(nsColor: .tertiaryLabelColor) }
        return quoteRailRGB.color
    }

    /// 引用块的底色。用半透明叠加而不是实色：楼层卡片本身可能带着热门回复的
    /// 强调色底，铺一层实色会把它盖掉。
    var quoteBackgroundColor: Color {
        foregroundColor.opacity(0.06)
    }

    func applying(to html: String) -> String {
        html
            .replacingOccurrences(
                of: "color-scheme:light dark",
                with: "color-scheme:\(webColorScheme)"
            )
            .replacingOccurrences(
                of: "color-scheme: light dark",
                with: "color-scheme: \(webColorScheme)"
            )
            .replacingOccurrences(
                of: "--snga-accent:#b06d00",
                with: "--snga-accent:\(webAccentHex)"
            )
            .replacingOccurrences(
                of: "--snga-highlight:#d59b3a",
                with: "--snga-highlight:\(webHighlightHex)"
            )
            .replacingOccurrences(
                of: "--snga-smile-backdrop:var(--snga-smile-backdrop-system)",
                with: "--snga-smile-backdrop:\(webSmileBackdrop)"
            )
            .replacingOccurrences(
                of: "--snga-quote-rail:\(ResolvedAppTheme.webQuoteRailDefault)",
                with: "--snga-quote-rail:\(webQuoteRail)"
            )
    }

    /// 跟随系统没有自己的调色板 —— 那一套要的就是 AppKit 的动态语义色，
    /// 写死任何一组十六进制值都会让它不再跟着 macOS 明暗切换。
    var palette: ThemePalette? {
        switch selection {
        case .system: nil
        case .light: .light
        case .dark: .dark
        case .ngaClassic: .ngaClassic
        case .midnight: .midnight
        case .custom: .custom(background: customBackgroundRGB, accent: accentRGB)
        }
    }

    private var customBackgroundRGB: ThemeRGB {
        ThemeRGB(
            hex: customBackgroundHex,
            fallback: ThemeRGB(hex: AppTheme.defaultCustomBackgroundHex)!
        )!
    }

    /// 网页侧要的是十六进制，跟随系统时按浅色算 —— 那条路径下真正生效的是
    /// `color-scheme:light dark`，这个值只作兜底。
    private var backgroundRGB: ThemeRGB {
        palette?.background ?? ThemeRGB(red: 0.95, green: 0.95, blue: 0.95)
    }

    /// 竖线朝背景的反方向推，浅色主题推得多一些 —— 同样的混合比例下，
    /// 深色背景上的浅色比浅色背景上的深色更显眼。
    private var quoteRailRGB: ThemeRGB {
        let target = backgroundRGB.isDark ? ThemeRGB.white : ThemeRGB.black
        return backgroundRGB.mixed(
            with: target,
            amount: backgroundRGB.isDark ? 0.52 : 0.58
        )
    }

    private var accentRGB: ThemeRGB {
        switch selection {
        case .system, .light: ThemeRGB(red: 0.03, green: 0.41, blue: 0.79)
        case .dark: ThemeRGB(red: 0.77, green: 0.61, blue: 1)
        case .ngaClassic: ThemeRGB(red: 0.66, green: 0.34, blue: 0.05)
        case .midnight: ThemeRGB(red: 0.32, green: 0.84, blue: 0.91)
        case .custom:
            ThemeRGB(
                hex: customAccentHex,
                fallback: ThemeRGB(hex: AppTheme.defaultCustomAccentHex)!
            )!
        }
    }

    private var webColorScheme: String {
        switch preferredColorScheme {
        case .dark: "dark"
        case .light: "light"
        case nil: "light dark"
        @unknown default: "light dark"
        }
    }

    private var webAccentHex: String {
        switch selection {
        case .system, .ngaClassic: "#b06d00"
        case .light: "#0869c9"
        case .dark: "#c49cff"
        case .midnight: "#52d6e8"
        case .custom: accentRGB.hex
        }
    }

    private var webHighlightHex: String {
        switch selection {
        case .system, .ngaClassic: "#d59b3a"
        case .light: "#5ca8ef"
        case .dark: "#9b72cf"
        case .midnight: "#278fa5"
        case .custom:
            accentRGB
                .mixed(
                    with: backgroundRGB.isDark ? .white : .black,
                    amount: backgroundRGB.isDark ? 0.24 : 0.14
                )
                .hex
        }
    }

    /// 楼层样式表里 `--snga-quote-rail` 的初值。跟随系统时保持不变 ——
    /// `CanvasText` 会自己跟着明暗切换，换成固定色反而不会变了。
    static let webQuoteRailDefault = "color-mix(in srgb,CanvasText 42%,transparent)"

    private var webQuoteRail: String {
        selection == .system ? ResolvedAppTheme.webQuoteRailDefault : quoteRailRGB.hex
    }

    private var webSmileBackdrop: String {
        switch selection {
        case .system: "var(--snga-smile-backdrop-system)"
        case .light, .ngaClassic: "transparent"
        case .dark, .midnight: "rgba(255,255,255,.88)"
        case .custom:
            backgroundRGB.isDark ? "rgba(255,255,255,.88)" : "transparent"
        }
    }
}

struct ThemeRGB: Equatable, Sendable {
    var red: Double
    var green: Double
    var blue: Double

    static let black = ThemeRGB(red: 0, green: 0, blue: 0)
    static let white = ThemeRGB(red: 1, green: 1, blue: 1)

    init(red: Double, green: Double, blue: Double) {
        self.red = min(1, max(0, red))
        self.green = min(1, max(0, green))
        self.blue = min(1, max(0, blue))
    }

    init?(hex: String, fallback: ThemeRGB? = nil) {
        let normalized = hex
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard normalized.count == 6,
              let value = Int(normalized, radix: 16) else {
            guard let fallback else { return nil }
            self = fallback
            return
        }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    var color: Color {
        Color(red: red, green: green, blue: blue)
    }

    var hex: String {
        String(
            format: "#%02X%02X%02X",
            Int((red * 255).rounded()),
            Int((green * 255).rounded()),
            Int((blue * 255).rounded())
        )
    }

    /// WCAG 相对亮度。
    var relativeLuminance: Double {
        0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    var isDark: Bool { relativeLuminance < 0.42 }

    /// WCAG 对比度，1（两色相同）到 21（纯黑对纯白）。正文要 4.5，
    /// 非文字的控件边界要 3。
    func contrastRatio(with other: ThemeRGB) -> Double {
        let lighter = max(relativeLuminance, other.relativeLuminance)
        let darker = min(relativeLuminance, other.relativeLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    /// 色相，0–360 度。
    var hueDegrees: Double {
        let highest = max(red, green, blue)
        let lowest = min(red, green, blue)
        let delta = highest - lowest
        guard delta > 0 else { return 0 }
        let hue: Double
        if highest == red {
            hue = 60 * ((green - blue) / delta)
        } else if highest == green {
            hue = 60 * ((blue - red) / delta + 2)
        } else {
            hue = 60 * ((red - green) / delta + 4)
        }
        return (hue + 360).truncatingRemainder(dividingBy: 360)
    }

    /// 饱和度，0–1。
    var saturation: Double {
        let highest = max(red, green, blue)
        guard highest > 0 else { return 0 }
        return (highest - min(red, green, blue)) / highest
    }

    /// 明度，0–1。
    var brightness: Double {
        max(red, green, blue)
    }

    /// 两个色相之间的夹角，0–180 度。
    static func hueGap(_ first: Double, _ second: Double) -> Double {
        let raw = abs(first - second).truncatingRemainder(dividingBy: 360)
        return min(raw, 360 - raw)
    }

    /// 按色相／饱和度／明度构造。语义色（热门、危险、成功）要保住色相、只调
    /// 明度和饱和度，用 RGB 混色做不到这件事。
    init(hueDegrees: Double, saturation: Double, brightness: Double) {
        let sector = ((hueDegrees.truncatingRemainder(dividingBy: 360) + 360)
            .truncatingRemainder(dividingBy: 360)) / 60
        let saturation = min(max(saturation, 0), 1)
        let brightness = min(max(brightness, 0), 1)
        let index = floor(sector)
        let fraction = sector - index
        let p = brightness * (1 - saturation)
        let q = brightness * (1 - saturation * fraction)
        let t = brightness * (1 - saturation * (1 - fraction))
        switch Int(index) % 6 {
        case 0: self.init(red: brightness, green: t, blue: p)
        case 1: self.init(red: q, green: brightness, blue: p)
        case 2: self.init(red: p, green: brightness, blue: t)
        case 3: self.init(red: p, green: q, blue: brightness)
        case 4: self.init(red: t, green: p, blue: brightness)
        default: self.init(red: brightness, green: p, blue: q)
        }
    }

    func mixed(with other: ThemeRGB, amount: Double) -> ThemeRGB {
        let fraction = min(1, max(0, amount))
        return ThemeRGB(
            red: red + (other.red - red) * fraction,
            green: green + (other.green - green) * fraction,
            blue: blue + (other.blue - blue) * fraction
        )
    }

    private func linear(_ component: Double) -> Double {
        component <= 0.04045
            ? component / 12.92
            : pow((component + 0.055) / 1.055, 2.4)
    }
}

extension EnvironmentValues {
    @Entry var sngaTheme: ResolvedAppTheme = .system
}

@main
struct SNGAApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage(AppTheme.storageKey) private var selectedThemeRaw = AppTheme.system.rawValue
    @AppStorage(AppTheme.customBackgroundKey)
    private var customBackgroundHex = AppTheme.defaultCustomBackgroundHex
    @AppStorage(AppTheme.customAccentKey)
    private var customAccentHex = AppTheme.defaultCustomAccentHex
    @State private var model: AppModel
    private let container: ModelContainer

    private var selectedTheme: ResolvedAppTheme {
        AppTheme.resolve(selectedThemeRaw).resolved(
            customBackgroundHex: customBackgroundHex,
            customAccentHex: customAccentHex
        )
    }

    init() {
        let schema = Schema([
            AccountRecord.self,
            FavoriteRecord.self,
            DraftRecord.self,
            SubforumPreferenceRecord.self,
            RecentForumRecord.self
        ])
        let configuration = ModelConfiguration(
            "SNGA",
            schema: schema,
            isStoredInMemoryOnly: ProcessInfo.processInfo.arguments.contains("--uitesting")
        )
        do {
            let container = try ModelContainer(for: schema, configurations: [configuration])
            self.container = container
            _model = State(initialValue: AppModel(container: container))
        } catch {
            fatalError("无法创建 SNGA 数据库：\(error.localizedDescription)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(\.sngaTheme, selectedTheme)
                .modelContainer(container)
                .preferredColorScheme(selectedTheme.preferredColorScheme)
                .tint(selectedTheme.accentColor)
        }
        .defaultSize(width: 1180, height: 780)
        .windowStyle(.hiddenTitleBar)
        .commands {
            AboutCommands { model.openSettings(section: .about) }
            SettingsCommands { model.openSettings() }

            CommandGroup(after: .sidebar) {
                Button(model.thread.selectedTopicID == nil ? "刷新" : "刷新话题内容") {
                    Task { await model.refreshCurrentSelection() }
                }
                .keyboardShortcut("r", modifiers: .command)

                Button("刷新话题列表") {
                    Task { await model.browsing.refreshTopicList() }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(model.selectedForumID == nil)
            }
        }
    }
}

/// 「关于」和「设置…」都落在主窗口里，菜单命令触发时得保证它在前面。
///
/// 主窗口整个被关掉的情况这里管不了：`WindowGroup` 没有能就地重开的入口，
/// 但状态照样设好了，用户从 Dock 重开窗口就停在对应的页面上。
@MainActor
enum MainWindow {
    static func bringToFront() {
        NSApp.activate()
        NSApp.windows
            .first { $0.isVisible && $0.canBecomeMain }?
            .makeKeyAndOrderFront(nil)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        Task {
            await RuntimeLogger.shared.log(category: "lifecycle", "SNGA launched")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Task {
            await RuntimeLogger.shared.log(category: "lifecycle", "SNGA will terminate")
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let accountID = response.notification.request.content.userInfo["accountID"] as? String
        let messageID = response.notification.request.content.userInfo["messageID"] as? String
        let messageFolder = response.notification.request.content.userInfo["messageFolder"] as? String
        Task { @MainActor in
            NotificationCenter.default.post(
                name: .sngaOpenMessage,
                object: nil,
                userInfo: [
                    "accountID": accountID ?? "",
                    "messageID": messageID ?? "",
                    "messageFolder": messageFolder ?? ""
                ]
            )
        }
        completionHandler()
    }
}
