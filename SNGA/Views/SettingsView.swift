import AppKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(AppTheme.storageKey) private var selectedThemeRaw = AppTheme.system.rawValue
    @AppStorage(AppTheme.customBackgroundKey)
    private var customBackgroundHex = AppTheme.defaultCustomBackgroundHex
    @AppStorage(AppTheme.customAccentKey)
    private var customAccentHex = AppTheme.defaultCustomAccentHex
    @AppStorage(BrowsingSettings.imageFreeModeKey) private var imageFreeMode = false
    @AppStorage(RecentForumSettings.maximumCountKey)
    private var recentForumMaximumCount = RecentForumSettings.defaultMaximumCount
    @AppStorage(ToolboxInstanceSettings.selectionKey)
    private var toolboxInstanceSelectionRaw = ToolboxInstanceChoice.automatic.rawValue
    @AppStorage(ToolboxInstanceSettings.customBaseURLKey)
    private var customToolboxBaseURL = ""
    @AppStorage(RuntimeLogSettings.enabledKey) private var runtimeLogEnabled = false
    @State private var loginRequest: SettingsLoginRequest?
    @State private var runtimeLogPath = RuntimeLogSettings.displayPath
    @State private var runtimeLogError: String?

    var body: some View {
        Form {
            Section("外观") {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 104), spacing: 10)],
                    spacing: 10
                ) {
                    ForEach(AppTheme.allCases) { theme in
                        ThemeChoiceCard(
                            theme: theme,
                            style: theme.resolved(
                                customBackgroundHex: customBackgroundHex,
                                customAccentHex: customAccentHex
                            ),
                            isSelected: selectedThemeRaw == theme.rawValue
                        ) {
                            selectedThemeRaw = theme.rawValue
                        }
                    }
                }
                Text(AppTheme.resolve(selectedThemeRaw).description)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if AppTheme.resolve(selectedThemeRaw) == .custom {
                    HStack(spacing: 18) {
                        ColorPicker(
                            "背景颜色",
                            selection: customBackgroundColor,
                            supportsOpacity: false
                        )
                        ColorPicker(
                            "突出颜色",
                            selection: customAccentColor,
                            supportsOpacity: false
                        )
                        Spacer()
                        Button("恢复默认") {
                            customBackgroundHex = AppTheme.defaultCustomBackgroundHex
                            customAccentHex = AppTheme.defaultCustomAccentHex
                        }
                    }
                    .padding(.top, 4)
                }
            }
            Section("浏览") {
                Toggle("无图模式", isOn: $imageFreeMode)
                Text("开启后，话题正文中的图片会显示为占位框，点击后才加载；表情仍正常显示。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Stepper(
                    "最近访问数量：\(recentForumMaximumCount)",
                    value: $recentForumMaximumCount,
                    in: RecentForumSettings.allowedRange
                )
                .accessibilityIdentifier("recent-forum-maximum-count")
                .onChange(of: recentForumMaximumCount) { _, maximumCount in
                    model.updateRecentForumLimit(maximumCount)
                }
                Text("最多保留指定数量的最近访问版面；减少数量会删除较早的记录。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("小工具") {
                Picker("API 实例", selection: $toolboxInstanceSelectionRaw) {
                    ForEach(ToolboxInstanceChoice.allCases) { choice in
                        Text(choice.title).tag(choice.rawValue)
                    }
                }
                .accessibilityIdentifier("toolbox-instance-picker")

                Text(selectedToolboxInstance.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                if selectedToolboxInstance == .custom {
                    TextField(
                        "https://example.com",
                        text: $customToolboxBaseURL,
                        prompt: Text("输入 60s API 基础地址")
                    )
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("toolbox-custom-instance-field")
                    .onSubmit {
                        if let url = normalizedCustomToolboxBaseURL {
                            customToolboxBaseURL = url.absoluteString
                        }
                    }

                    if customToolboxBaseURL.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ).isEmpty {
                        Text("请输入包含 http:// 或 https:// 的实例基础地址。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if let url = normalizedCustomToolboxBaseURL {
                        LabeledContent("当前地址") {
                            Text(url.absoluteString)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                        }
                    } else {
                        Label(
                            "地址格式无效，请检查协议、域名，且不要包含查询参数。",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.caption)
                        .foregroundStyle(.red)
                    }
                }

                Link(
                    destination: ToolboxInstanceSettings.documentationURL
                ) {
                    Label("查看 60s API 公共实例文档", systemImage: "arrow.up.right")
                }
                .accessibilityIdentifier("toolbox-instance-documentation")

                Text(toolboxInstanceBehaviorDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("账号") {
                if model.session.accounts.isEmpty {
                    Text("尚未添加账号")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.session.accounts) { account in
                    SettingsAccountRow(account: account) {
                        loginRequest = SettingsLoginRequest(
                            title: "重新登录 \(account.displayName)"
                        )
                    }
                }
                Button("添加账号", systemImage: "person.badge.plus") {
                    loginRequest = SettingsLoginRequest(title: "登录 NGA")
                }
            }
            Section("后台行为") {
                LabeledContent("消息检查", value: "应用运行时每 5 分钟")
                LabeledContent("每日签到", value: "启动、回到前台及跨日时")
                Text("退出 SNGA 后不会运行签到或消息轮询。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("运行日志") {
                Toggle("启用运行日志", isOn: $runtimeLogEnabled)
                    .onChange(of: runtimeLogEnabled) { _, isEnabled in
                        guard isEnabled else { return }
                        Task {
                            await RuntimeLogger.shared.log(
                                category: "configuration",
                                "Runtime logging enabled"
                            )
                        }
                    }

                LabeledContent("输出目录") {
                    Text(runtimeLogPath)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }

                HStack {
                    Button("选择目录…", systemImage: "folder") {
                        chooseRuntimeLogDirectory()
                    }
                    if RuntimeLogSettings.selectedDirectoryURL != nil {
                        Button("恢复默认") {
                            RuntimeLogSettings.useDefaultDirectory()
                            runtimeLogPath = RuntimeLogSettings.displayPath
                        }
                    }
                }

                Text("每天生成一个 SNGA-日期.log 文件。请求正文、Cookie 和登录令牌不会写入日志。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 660, height: 640)
        .sheet(item: $loginRequest) { request in
            LoginSheet(title: request.title)
                .environment(model)
        }
        .alert(
            "无法使用日志目录",
            isPresented: Binding(
                get: { runtimeLogError != nil },
                set: { if !$0 { runtimeLogError = nil } }
            )
        ) {
            Button("好") { runtimeLogError = nil }
        } message: {
            Text(runtimeLogError ?? "")
        }
    }

    private func chooseRuntimeLogDirectory() {
        let panel = NSOpenPanel()
        panel.title = "选择运行日志输出目录"
        panel.prompt = "选择"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = RuntimeLogSettings.outputDirectoryURL
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try RuntimeLogSettings.selectDirectory(url)
            runtimeLogPath = RuntimeLogSettings.displayPath
            if runtimeLogEnabled {
                Task {
                    await RuntimeLogger.shared.log(
                        category: "configuration",
                        "Log output directory changed"
                    )
                }
            }
        } catch {
            runtimeLogError = error.localizedDescription
        }
    }

    private var customBackgroundColor: Binding<Color> {
        Binding(
            get: {
                ThemeRGB(
                    hex: customBackgroundHex,
                    fallback: ThemeRGB(hex: AppTheme.defaultCustomBackgroundHex)!
                )!.color
            },
            set: {
                customBackgroundHex = colorHex(
                    $0,
                    fallback: AppTheme.defaultCustomBackgroundHex
                )
            }
        )
    }

    private var customAccentColor: Binding<Color> {
        Binding(
            get: {
                ThemeRGB(
                    hex: customAccentHex,
                    fallback: ThemeRGB(hex: AppTheme.defaultCustomAccentHex)!
                )!.color
            },
            set: {
                customAccentHex = colorHex(
                    $0,
                    fallback: AppTheme.defaultCustomAccentHex
                )
            }
        )
    }

    private var selectedToolboxInstance: ToolboxInstanceChoice {
        ToolboxInstanceChoice(rawValue: toolboxInstanceSelectionRaw) ?? .automatic
    }

    private var normalizedCustomToolboxBaseURL: URL? {
        ToolboxInstanceSettings.normalizedBaseURL(from: customToolboxBaseURL)
    }

    private var toolboxInstanceBehaviorDescription: String {
        if selectedToolboxInstance == .automatic {
            return "修改后在下次刷新小工具时生效；自动模式会在官方主实例与备用实例间故障切换。"
        }
        return "修改后在下次刷新小工具时生效；当前模式仅使用所选实例。"
    }

    private func colorHex(_ color: Color, fallback: String) -> String {
        guard let converted = NSColor(color).usingColorSpace(.sRGB) else {
            return fallback
        }
        return ThemeRGB(
            red: converted.redComponent,
            green: converted.greenComponent,
            blue: converted.blueComponent
        ).hex
    }
}

private struct SettingsAccountRow: View {
    @Environment(AppModel.self) private var model
    let account: AccountSummary
    let relogin: () -> Void
    @State private var showsRemoveConfirmation = false

    var body: some View {
        HStack(spacing: 10) {
            AsyncImage(url: account.avatarURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Image(systemName: "person.crop.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .frame(width: 28, height: 28)
            .clipShape(.circle)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(account.displayName)
                Text(account.sessionState.title)
                    .font(.caption)
                    .foregroundStyle(
                        account.sessionState == .valid ? Color.secondary : Color.red
                    )
            }
            Spacer()
            Button("重新登录", action: relogin)
                .controlSize(.small)
            Button("移除", role: .destructive) {
                showsRemoveConfirmation = true
            }
            .controlSize(.small)
            .confirmationDialog(
                "移除账号？",
                isPresented: $showsRemoveConfirmation,
                titleVisibility: .visible
            ) {
                Button("移除 \(account.displayName)", role: .destructive) {
                    Task { await model.removeAccount(account.id) }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("会删除此账号的本地会话、收藏和草稿，不能撤销。")
            }
        }
    }
}

private struct ThemeChoiceCard: View {
    let theme: AppTheme
    let style: ResolvedAppTheme
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Image(systemName: theme.systemImage)
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(style.accentColor)
                    }
                }
                .font(.title3)

                Text(theme.displayName)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Circle().fill(style.accentColor)
                    Circle().fill(style.foregroundColor.opacity(0.68))
                    Circle().fill(style.foregroundColor.opacity(0.25))
                }
                .frame(height: 8)
            }
            .foregroundStyle(style.foregroundColor)
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
            .background(style.backgroundColor, in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(
                        isSelected ? style.accentColor : Color.secondary.opacity(0.22),
                        lineWidth: isSelected ? 2 : 1
                    )
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(theme.displayName)
        .accessibilityValue(isSelected ? "已选择" : "")
    }
}

private struct SettingsLoginRequest: Identifiable {
    let id = UUID()
    var title: String
}
