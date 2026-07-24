import AppKit
import SwiftData
import SwiftUI
@preconcurrency import UserNotifications

enum AppTheme: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark
    case ngaClassic
    case midnight

    static let storageKey = "appearance.theme"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: "跟随系统"
        case .light: "明亮"
        case .dark: "深色"
        case .ngaClassic: "NGA 暖金"
        case .midnight: "午夜蓝"
        }
    }

    var description: String {
        switch self {
        case .system: "随 macOS 外观自动切换"
        case .light: "明亮背景与蓝色强调色"
        case .dark: "深色背景与紫色强调色"
        case .ngaClassic: "接近 NGA 网页的暖色风格"
        case .midnight: "深色背景与青蓝强调色"
        }
    }

    var systemImage: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max.fill"
        case .dark: "moon.fill"
        case .ngaClassic: "flame.fill"
        case .midnight: "sparkles"
        }
    }

    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light, .ngaClassic: .light
        case .dark, .midnight: .dark
        }
    }

    var accentColor: Color {
        switch self {
        case .system, .light: .blue
        case .dark: .purple
        case .ngaClassic: Color(red: 0.66, green: 0.34, blue: 0.05)
        case .midnight: .cyan
        }
    }

    var previewBackground: Color {
        switch self {
        case .system: Color(nsColor: .windowBackgroundColor)
        case .light: Color(white: 0.97)
        case .dark: Color(red: 0.12, green: 0.12, blue: 0.14)
        case .ngaClassic: Color(red: 0.98, green: 0.93, blue: 0.78)
        case .midnight: Color(red: 0.055, green: 0.09, blue: 0.15)
        }
    }

    var previewForeground: Color {
        switch self {
        case .dark, .midnight: .white
        case .system, .light, .ngaClassic: .black
        }
    }

    private var webColorScheme: String {
        switch self {
        case .system: "light dark"
        case .light, .ngaClassic: "light"
        case .dark, .midnight: "dark"
        }
    }

    private var webAccentHex: String {
        switch self {
        case .system, .ngaClassic: "#b06d00"
        case .light: "#0869c9"
        case .dark: "#c49cff"
        case .midnight: "#52d6e8"
        }
    }

    private var webHighlightHex: String {
        switch self {
        case .system, .ngaClassic: "#d59b3a"
        case .light: "#5ca8ef"
        case .dark: "#9b72cf"
        case .midnight: "#278fa5"
        }
    }

    private var webSmileBackdrop: String {
        switch self {
        case .system: "var(--snga-smile-backdrop-system)"
        case .light, .ngaClassic: "transparent"
        case .dark, .midnight: "rgba(255,255,255,.88)"
        }
    }

    static func resolve(_ rawValue: String) -> AppTheme {
        AppTheme(rawValue: rawValue) ?? .system
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
}

private struct AppThemeEnvironmentKey: EnvironmentKey {
    static let defaultValue = AppTheme.system
}

extension EnvironmentValues {
    var sngaTheme: AppTheme {
        get { self[AppThemeEnvironmentKey.self] }
        set { self[AppThemeEnvironmentKey.self] = newValue }
    }
}

@main
struct SNGAApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage(AppTheme.storageKey) private var selectedThemeRaw = AppTheme.system.rawValue
    @State private var model: AppModel
    private let container: ModelContainer

    private var selectedTheme: AppTheme {
        AppTheme.resolve(selectedThemeRaw)
    }

    init() {
        let schema = Schema([
            AccountRecord.self,
            FavoriteRecord.self,
            DraftRecord.self,
            SubforumPreferenceRecord.self
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
