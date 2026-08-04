import AppKit
import SwiftData
import SwiftUI
@preconcurrency import UserNotifications

enum BrowsingSettings {
    static let imageFreeModeKey = "browsing.imageFreeMode"
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

    var preferredColorScheme: ColorScheme? {
        switch selection {
        case .system: nil
        case .light, .ngaClassic: .light
        case .dark, .midnight: .dark
        case .custom: backgroundRGB.isDark ? .dark : .light
        }
    }

    var accentColor: Color {
        if selection == .system { return .blue }
        return accentRGB.color
    }

    var backgroundColor: Color {
        if selection == .system {
            return Color(nsColor: .windowBackgroundColor)
        }
        return backgroundRGB.color
    }

    var surfaceColor: Color {
        if selection == .system {
            return Color(nsColor: .controlBackgroundColor)
        }
        let target = backgroundRGB.isDark ? ThemeRGB.white : ThemeRGB.black
        return backgroundRGB.mixed(with: target, amount: backgroundRGB.isDark ? 0.07 : 0.045).color
    }

    var foregroundColor: Color {
        if selection == .system { return .primary }
        return backgroundRGB.isDark ? .white : .black
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
    }

    private var backgroundRGB: ThemeRGB {
        switch selection {
        case .system: ThemeRGB(red: 0.95, green: 0.95, blue: 0.95)
        case .light: ThemeRGB(red: 0.97, green: 0.97, blue: 0.97)
        case .dark: ThemeRGB(red: 0.12, green: 0.12, blue: 0.14)
        case .ngaClassic: ThemeRGB(red: 0.98, green: 0.93, blue: 0.78)
        case .midnight: ThemeRGB(red: 0.055, green: 0.09, blue: 0.15)
        case .custom:
            ThemeRGB(
                hex: customBackgroundHex,
                fallback: ThemeRGB(hex: AppTheme.defaultCustomBackgroundHex)!
            )!
        }
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

    var isDark: Bool {
        let luminance = 0.2126 * linear(red)
            + 0.7152 * linear(green)
            + 0.0722 * linear(blue)
        return luminance < 0.42
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
            AboutCommands()

            CommandGroup(after: .sidebar) {
                Button(model.selectedTopicID == nil ? "刷新" : "刷新主题内容") {
                    Task { await model.refreshCurrentSelection() }
                }
                .keyboardShortcut("r", modifiers: .command)

                Button("刷新主题列表") {
                    Task { await model.refreshTopicList() }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(model.selectedForumID == nil)
            }
        }

        Window("关于 SNGA", id: AboutView.windowID) {
            AboutView()
                .environment(\.sngaTheme, selectedTheme)
                .preferredColorScheme(selectedTheme.preferredColorScheme)
                .tint(selectedTheme.accentColor)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Settings {
            SettingsView()
                .environment(model)
                .environment(\.sngaTheme, selectedTheme)
                .preferredColorScheme(selectedTheme.preferredColorScheme)
                .tint(selectedTheme.accentColor)
        }
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
