import AppKit
import SwiftUI

/// 接管应用菜单里的「设置…」。
///
/// `Settings` 场景删掉之后，系统不再自动提供这一项，⌘, 也就跟着没了。菜单位置
/// 和快捷键在这里原样补回来，只是动作从「弹一扇新窗」改成「切换主窗口里的页面」。
struct SettingsCommands: Commands {
    let openSettings: () -> Void

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("设置…") {
                openSettings()
                MainWindow.bringToFront()
            }
            .keyboardShortcut(",", modifiers: .command)
        }
    }
}

/// 设置的中栏：分类列表。
///
/// 每行的副标题读的是当前值，右栏改完这里立刻跟着变 —— 不点进去也知道现在是
/// 什么状态。`@AppStorage` 本身就会触发重绘，不需要额外的通知或订阅。
///
/// 账号不在这里。边栏顶上的账号区已经能切换、添加、重新登录和移除，设置里
/// 再写一份只会让两处的文案对不上。
struct SettingsMenuView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.sngaTheme) private var theme

    @AppStorage(AppTheme.storageKey) private var selectedThemeRaw = AppTheme.system.rawValue
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
    @AppStorage(RuntimeLogSettings.directoryPathKey) private var runtimeLogDirectoryPath = ""
    @AppStorage(AISettings.enabledKey) private var aiEnabled = true
    @AppStorage(AISettings.baseURLKey) private var aiBaseURL = AISettings.defaultBaseURL
    @AppStorage(AISettings.modelKey) private var aiModel = ""
    @AppStorage(AISettings.instructionKey)
    private var aiInstruction = AISettings.defaultInstruction
    @AppStorage(AISettings.topicSummaryInstructionKey)
    private var aiTopicSummaryInstruction = AISettings.defaultTopicSummaryInstruction
    @AppStorage(AISettings.historyLimitKey)
    private var aiHistoryLimit = AISettings.defaultHistoryLimit

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                Text("外观、浏览行为、AI、小工具、日志与关于")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.bottom, 4)

                ForEach(SettingsSection.allCases) { section in
                    Button {
                        model.selectedSettingsSection = section
                    } label: {
                        SettingsMenuRow(
                            section: section,
                            subtitle: subtitle(for: section),
                            isSelected: model.selectedSettingsSection == section
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("settings-section-\(section.rawValue)")
                }
            }
            .padding(18)
        }
        .accessibilityIdentifier("settings-menu-scroll")
        .background(theme.backgroundColor)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle("")
    }

    private func subtitle(for section: SettingsSection) -> String {
        switch section {
        case .appearance:
            let selected = AppTheme.resolve(selectedThemeRaw)
            return selected == .custom
                ? "自定义 · 强调色 \(customAccentHex.uppercased())"
                : selected.displayName
        case .browsing:
            let count = RecentForumSettings.normalizedMaximumCount(recentForumMaximumCount)
            return "无图模式\(imageFreeMode ? "已开" : "已关") · 最近访问 \(count) 条"
        case .ai:
            guard aiEnabled else { return "已关闭" }
            let model = aiModel.trimmingCharacters(in: .whitespacesAndNewlines)
            guard AISettings.normalizedBaseURL(from: aiBaseURL) != nil,
                  !model.isEmpty,
                  !aiInstruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !aiTopicSummaryInstruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return "OpenAI 兼容接口 · 待配置"
            }
            return "\(model) · 最近 \(AISettings.normalizedHistoryLimit(aiHistoryLimit)) 人"
        case .toolbox:
            let choice = ToolboxInstanceChoice(rawValue: toolboxInstanceSelectionRaw)
                ?? .automatic
            guard choice == .custom else { return "60s API · \(choice.title)" }
            guard let url = ToolboxInstanceSettings.normalizedBaseURL(
                from: customToolboxBaseURL
            ) else {
                return "自定义实例 · 地址待填写"
            }
            return "自定义实例 · \(url.host() ?? url.absoluteString)"
        case .background:
            return "消息轮询与签到状态"
        case .runtimeLog:
            guard runtimeLogEnabled else { return "已关闭" }
            return "已启用 · \(runtimeLogDirectoryPath.isEmpty ? "默认目录" : runtimeLogDirectoryPath)"
        case .about:
            return "版本 \(AboutView.displayVersion) · 项目与联系方式"
        }
    }
}

private struct SettingsMenuRow: View {
    @Environment(\.sngaTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let section: SettingsSection
    let subtitle: String
    let isSelected: Bool
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: section.systemImage)
                .font(.title3)
                .foregroundStyle(isSelected ? theme.onAccentColor : theme.accentColor)
                .frame(width: 34, height: 34)
                .background(
                    isSelected ? theme.onAccentColor.opacity(0.2) : theme.accentSoftColor,
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(section.title)
                    .font(.body.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(
                        isSelected ? theme.onAccentColor.opacity(0.78) : Color.secondary
                    )
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(
                    isSelected ? theme.onAccentColor.opacity(0.8) : Color.secondary
                )
        }
        .foregroundStyle(isSelected ? theme.onAccentColor : theme.foregroundColor)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isSelected
                ? theme.accentColor
                : (isHovered ? theme.hoverFillColor : theme.fillColor),
            in: RoundedRectangle(cornerRadius: 13, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(isSelected ? Color.clear : theme.separatorColor)
        }
        .contentShape(.rect)
        .onHover { isHovered = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: isHovered)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: isSelected)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(section.title)
        .accessibilityValue(subtitle)
    }
}

/// 设置的右栏：选中那一类的面板。
struct SettingsDetailView: View {
    @Environment(\.sngaTheme) private var theme
    let section: SettingsSection

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(section.title)
                    .font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)

                switch section {
                case .appearance: SettingsAppearancePane()
                case .browsing: SettingsBrowsingPane()
                case .ai: SettingsAIPane()
                case .toolbox: SettingsToolboxPane()
                case .background: SettingsBackgroundPane()
                case .runtimeLog: SettingsRuntimeLogPane()
                case .about: AboutView()
                }
            }
            // 设置项不该跟着窗口一路拉宽：主题卡会排成一长条，
            // `LabeledContent` 的值也会被甩到很远的右边。
            .frame(maxWidth: 620, alignment: .leading)
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(theme.backgroundColor)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityIdentifier("settings-detail-\(section.rawValue)")
    }
}

// MARK: - 面板

private struct SettingsAppearancePane: View {
    @AppStorage(AppTheme.storageKey) private var selectedThemeRaw = AppTheme.system.rawValue
    @AppStorage(AppTheme.customBackgroundKey)
    private var customBackgroundHex = AppTheme.defaultCustomBackgroundHex
    @AppStorage(AppTheme.customAccentKey)
    private var customAccentHex = AppTheme.defaultCustomAccentHex

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsCard(label: "主题") {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 150), spacing: 10)],
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
            }

            if AppTheme.resolve(selectedThemeRaw) == .custom {
                SettingsCard(label: "自定义配色") {
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
                }
            }
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

private struct SettingsBrowsingPane: View {
    @Environment(AppModel.self) private var model
    @AppStorage(BrowsingSettings.imageFreeModeKey) private var imageFreeMode = false
    @AppStorage(RecentForumSettings.maximumCountKey)
    private var recentForumMaximumCount = RecentForumSettings.defaultMaximumCount

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsCard {
                Toggle(isOn: $imageFreeMode) {
                    Text("无图模式")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .toggleStyle(.switch)

                Text("开启后，话题正文中的图片会显示为占位框，点击后才加载；表情仍正常显示。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            SettingsCard {
                Stepper(
                    value: $recentForumMaximumCount,
                    in: RecentForumSettings.allowedRange
                ) {
                    Text("最近访问数量：\(recentForumMaximumCount)")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityIdentifier("recent-forum-maximum-count")
                .onChange(of: recentForumMaximumCount) { _, maximumCount in
                    model.browsing.updateRecentForumLimit(maximumCount)
                }

                Text("最多保留指定数量的最近访问版面；减少数量会删除较早的记录。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct SettingsAIPane: View {
    @Environment(AppModel.self) private var model
    @Environment(\.sngaTheme) private var theme
    @AppStorage(AISettings.enabledKey) private var aiEnabled = true
    @AppStorage(AISettings.baseURLKey) private var baseURL = AISettings.defaultBaseURL
    @AppStorage(AISettings.modelKey) private var aiModel = ""
    @AppStorage(AISettings.instructionKey)
    private var profileInstruction = AISettings.defaultInstruction
    @AppStorage(AISettings.topicSummaryInstructionKey)
    private var topicSummaryInstruction = AISettings.defaultTopicSummaryInstruction
    @AppStorage(AISettings.historyLimitKey)
    private var historyLimit = AISettings.defaultHistoryLimit

    @State private var newAPIKey = ""
    @State private var hasSavedAPIKey = false
    @State private var keyStatusMessage: String?
    @State private var keyStatusIsError = false
    @State private var isUpdatingKey = false
    @State private var connectionStatusMessage: String?
    @State private var connectionStatusIsError = false
    @State private var isTestingConnection = false
    @State private var connectionTestTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsCard(label: "AI 功能") {
                Toggle(isOn: $aiEnabled) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("启用 AI")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("关闭后隐藏 AI 用户画像、画像历史入口和话题总结。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .accessibilityIdentifier("ai-enabled-toggle")
                .onChange(of: aiEnabled) { _, isEnabled in
                    clearConnectionStatus()
                    model.applyAIEnabledState(isEnabled)
                }
            }

            if aiEnabled {
                SettingsCard(label: "OpenAI 兼容接口") {
                TextField("Base URL", text: $baseURL, prompt: Text(AISettings.defaultBaseURL))
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("ai-base-url-field")
                    .onChange(of: baseURL) { _, _ in clearConnectionStatus() }

                if !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   AISettings.normalizedBaseURL(from: baseURL) == nil {
                    Label(
                        "仅允许 HTTPS；本机 localhost、127.0.0.1 和 ::1 可使用 HTTP。",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.red)
                } else {
                    Text("应用会在 Base URL 后追加 /chat/completions。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                TextField("模型", text: $aiModel, prompt: Text("例如 gpt-4.1-mini"))
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("ai-model-field")
                    .onChange(of: aiModel) { _, _ in clearConnectionStatus() }

                SecureField(
                    "API Key",
                    text: $newAPIKey,
                    prompt: Text(
                        hasSavedAPIKey
                            ? "已保存在系统钥匙串；输入新值可替换"
                            : "无需鉴权的本机服务可留空"
                    )
                )
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("ai-api-key-field")
                .onChange(of: newAPIKey) { _, _ in clearConnectionStatus() }

                HStack {
                    Button(hasSavedAPIKey ? "更新密钥" : "保存密钥") {
                        saveAPIKey()
                    }
                    .disabled(
                        newAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || isUpdatingKey
                    )
                    .accessibilityIdentifier("ai-save-key-button")

                    if hasSavedAPIKey {
                        Button("移除密钥", role: .destructive) {
                            removeAPIKey()
                        }
                        .disabled(isUpdatingKey)
                        .accessibilityIdentifier("ai-remove-key-button")
                    }

                    if isUpdatingKey {
                        ProgressView().controlSize(.small)
                    }
                }

                if let keyStatusMessage {
                    Label(
                        keyStatusMessage,
                        systemImage: keyStatusIsError
                            ? "exclamationmark.triangle"
                            : "checkmark.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(keyStatusIsError ? Color.red : Color.secondary)
                }

                HStack(spacing: 10) {
                    Button {
                        testConnection()
                    } label: {
                        Label("测试连接", systemImage: "network")
                    }
                    .disabled(isTestingConnection)
                    .accessibilityHint("发送最小请求，验证地址、模型、鉴权和响应格式")
                    .accessibilityIdentifier("ai-test-connection-button")

                    if isTestingConnection {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("正在测试 AI 接口连接")
                    }
                }

                if let connectionStatusMessage {
                    Label(
                        connectionStatusMessage,
                        systemImage: connectionStatusIsError
                            ? "xmark.circle.fill"
                            : "checkmark.circle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(connectionStatusIsError ? Color.red : Color.green)
                    .textSelection(.enabled)
                    .accessibilityLabel(connectionStatusIsError ? "连接失败" : "连接成功")
                    .accessibilityValue(connectionStatusMessage)
                    .accessibilityIdentifier("ai-connection-status")
                }

                Text("测试会调用 /chat/completions 并发送一条最小消息，可能产生少量模型费用；输入框中的新密钥会优先用于本次测试。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("API Key 只保存在 macOS 系统钥匙串，不会写入偏好设置、画像历史或运行日志。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

                SettingsCard(label: "用户画像提示词") {
                TextEditor(text: $profileInstruction)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 220)
                    .padding(7)
                    .background(theme.fillColor, in: RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(theme.controlBorderColor)
                    }
                    .accessibilityLabel("AI 用户画像分析指令")
                    .accessibilityIdentifier("ai-instruction-editor")

                HStack {
                    Text("资料会作为独立 JSON 消息附加，帖子中的文本不会被当成指令执行。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("恢复默认") {
                        profileInstruction = AISettings.defaultInstruction
                    }
                    .accessibilityIdentifier("ai-reset-instruction")
                }
            }

                SettingsCard(label: "话题总结提示词") {
                    TextEditor(text: $topicSummaryInstruction)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 220)
                        .padding(7)
                        .background(theme.fillColor, in: RoundedRectangle(cornerRadius: 8))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(theme.controlBorderColor)
                        }
                        .accessibilityLabel("AI 话题总结指令")
                        .accessibilityIdentifier("ai-topic-summary-instruction-editor")

                    HStack {
                        Text("仅发送当前页面已经加载的标题与楼层文本，不会额外请求 NGA。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("恢复默认") {
                            topicSummaryInstruction = AISettings.defaultTopicSummaryInstruction
                        }
                        .accessibilityIdentifier("ai-reset-topic-summary-instruction")
                    }
                }

                SettingsCard(label: "画像历史") {
                Stepper(value: $historyLimit, in: AISettings.allowedHistoryLimit) {
                    Text("最多保留 \(AISettings.normalizedHistoryLimit(historyLimit)) 位用户")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityIdentifier("ai-history-limit")
                .onChange(of: historyLimit) { _, value in
                    let normalized = AISettings.normalizedHistoryLimit(value)
                    if normalized != value { historyLimit = normalized }
                    model.aiProfiles.trimToHistoryLimit(normalized)
                }

                Text("每个 UID 只保留最新一次成功结果；减少数量会立即删除最旧画像。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

                SettingsCard {
                Label("隐私提示", systemImage: "hand.raised")
                    .font(.headline)
                Text("生成画像时会发送公开用户资料与已加载的发布记录；总结话题时会发送当前页标题和楼层文字。AI 结果仅供参考。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .task { await loadKeyStatus() }
        .onAppear {
            let normalized = AISettings.normalizedHistoryLimit(historyLimit)
            if historyLimit != normalized { historyLimit = normalized }
            model.aiProfiles.trimToHistoryLimit(normalized)
        }
        .onDisappear {
            connectionTestTask?.cancel()
            connectionTestTask = nil
            isTestingConnection = false
        }
    }

    private func loadKeyStatus() async {
        do {
            hasSavedAPIKey = try await model.aiProfiles.keyStore.apiKey() != nil
        } catch {
            keyStatusIsError = true
            keyStatusMessage = error.localizedDescription
        }
    }

    private func saveAPIKey() {
        let key = newAPIKey
        isUpdatingKey = true
        Task {
            do {
                try await model.aiProfiles.keyStore.save(apiKey: key)
                hasSavedAPIKey = true
                newAPIKey = ""
                keyStatusIsError = false
                keyStatusMessage = "密钥已保存"
            } catch {
                keyStatusIsError = true
                keyStatusMessage = error.localizedDescription
            }
            isUpdatingKey = false
        }
    }

    private func testConnection() {
        connectionTestTask?.cancel()
        connectionStatusMessage = nil
        connectionStatusIsError = false
        isTestingConnection = true

        let testedBaseURL = baseURL
        let testedModel = aiModel
        let testedInstruction = profileInstruction
        let testedAPIKey = newAPIKey
        connectionTestTask = Task {
            do {
                let result = try await model.aiProfiles.testConnection(
                    baseURLString: testedBaseURL,
                    model: testedModel,
                    instruction: testedInstruction,
                    apiKeyOverride: testedAPIKey
                )
                try Task.checkCancellation()
                var message = "连接成功 · \(result.model) · \(result.latencyMilliseconds) ms"
                if let requestID = result.requestID, !requestID.isEmpty {
                    message += "\n请求 ID：\(requestID)"
                }
                connectionStatusIsError = false
                connectionStatusMessage = message
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                connectionStatusIsError = true
                connectionStatusMessage = "连接失败\n\(error.localizedDescription)"
            }
            isTestingConnection = false
            connectionTestTask = nil
        }
    }

    private func clearConnectionStatus() {
        connectionTestTask?.cancel()
        connectionTestTask = nil
        isTestingConnection = false
        connectionStatusMessage = nil
        connectionStatusIsError = false
    }

    private func removeAPIKey() {
        clearConnectionStatus()
        isUpdatingKey = true
        Task {
            do {
                try await model.aiProfiles.keyStore.removeAPIKey()
                hasSavedAPIKey = false
                newAPIKey = ""
                keyStatusIsError = false
                keyStatusMessage = "密钥已移除；无需鉴权的接口仍可使用"
            } catch {
                keyStatusIsError = true
                keyStatusMessage = error.localizedDescription
            }
            isUpdatingKey = false
        }
    }
}

private struct SettingsToolboxPane: View {
    @AppStorage(ToolboxInstanceSettings.selectionKey)
    private var toolboxInstanceSelectionRaw = ToolboxInstanceChoice.automatic.rawValue
    @AppStorage(ToolboxInstanceSettings.customBaseURLKey)
    private var customToolboxBaseURL = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsCard(label: "60s API 实例") {
                Picker("API 实例", selection: $toolboxInstanceSelectionRaw) {
                    ForEach(ToolboxInstanceChoice.allCases) { choice in
                        Text(choice.title).tag(choice.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("toolbox-instance-picker")

                Text(selectedInstance.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                if selectedInstance == .custom {
                    TextField(
                        "https://example.com",
                        text: $customToolboxBaseURL,
                        prompt: Text("输入 60s API 基础地址")
                    )
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("toolbox-custom-instance-field")
                    .onSubmit {
                        if let url = normalizedCustomBaseURL {
                            customToolboxBaseURL = url.absoluteString
                        }
                    }

                    if customToolboxBaseURL.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ).isEmpty {
                        Text("请输入包含 http:// 或 https:// 的实例基础地址。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if let url = normalizedCustomBaseURL {
                        SettingsFieldRow("当前地址") {
                            Text(url.absoluteString)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                                .foregroundStyle(.secondary)
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

                Link(destination: ToolboxInstanceSettings.documentationURL) {
                    Label("查看 60s API 公共实例文档", systemImage: "arrow.up.right")
                }
                .accessibilityIdentifier("toolbox-instance-documentation")

                Text(behaviorDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var selectedInstance: ToolboxInstanceChoice {
        ToolboxInstanceChoice(rawValue: toolboxInstanceSelectionRaw) ?? .automatic
    }

    private var normalizedCustomBaseURL: URL? {
        ToolboxInstanceSettings.normalizedBaseURL(from: customToolboxBaseURL)
    }

    private var behaviorDescription: String {
        if selectedInstance == .automatic {
            return "修改后在下次刷新小工具时生效；自动模式会在官方主实例与备用实例间故障切换。"
        }
        return "修改后在下次刷新小工具时生效；当前模式仅使用所选实例。"
    }
}

private struct SettingsBackgroundPane: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsCard {
                SettingsFieldRow("消息检查", value: "应用运行时每 5 分钟")
                SettingsFieldRow("签到状态", value: "启动、回到前台及跨日时查询")

                Text("签到仅在用户中心手动执行；退出 SNGA 后不会查询状态或运行消息轮询。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct SettingsRuntimeLogPane: View {
    @AppStorage(RuntimeLogSettings.enabledKey) private var runtimeLogEnabled = false
    @State private var runtimeLogPath = RuntimeLogSettings.displayPath
    @State private var runtimeLogError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsCard {
                Toggle(isOn: $runtimeLogEnabled) {
                    Text("启用运行日志")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .toggleStyle(.switch)
                .onChange(of: runtimeLogEnabled) { _, isEnabled in
                    guard isEnabled else { return }
                    Task {
                        await RuntimeLogger.shared.log(
                            category: "configuration",
                            "Runtime logging enabled"
                        )
                    }
                }

                SettingsFieldRow("输出目录") {
                    Text(runtimeLogPath)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Button("选择目录…", systemImage: "folder") {
                        chooseDirectory()
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

    private func chooseDirectory() {
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
}

// MARK: - 组件

/// 面板里的一张卡片。和小工具详情、话题楼层用的是同一套：卡片浮在窗口之上，
/// 描边取 `separatorColor`。
struct SettingsCard<Content: View>: View {
    @Environment(\.sngaTheme) private var theme
    var label: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            if let label {
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.secondaryForegroundColor)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(15)
        .background(
            theme.surfaceColor,
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(theme.separatorColor)
        }
    }
}

/// 「标签 —— 值」一行。
///
/// `LabeledContent` 只有摆进 `Form` 里才会把值推到行尾；卡片里它退化成两段
/// 紧挨着的文字，「输出目录 /Users/…」读起来像一句话。
struct SettingsFieldRow<Value: View>: View {
    @Environment(\.sngaTheme) private var theme
    private let title: String
    private let value: Value
    /// 只有纯文本的值才压成次级色。链接这类内容自己有颜色，压灰就看不出能点了。
    private let dimsValue: Bool

    init(_ title: String, @ViewBuilder value: () -> Value) {
        self.title = title
        self.value = value()
        self.dimsValue = false
    }

    fileprivate init(_ title: String, dimmed value: Value) {
        self.title = title
        self.value = value
        self.dimsValue = true
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(title)
            Spacer(minLength: 0)
            Group {
                if dimsValue {
                    value.foregroundStyle(theme.secondaryForegroundColor)
                } else {
                    value
                }
            }
            .multilineTextAlignment(.trailing)
        }
    }
}

extension SettingsFieldRow where Value == Text {
    init(_ title: String, value: String) {
        self.init(title, dimmed: Text(value))
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
                        isSelected ? style.accentColor : style.separatorColor,
                        lineWidth: isSelected ? 2 : 1
                    )
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(theme.displayName)
        .accessibilityValue(isSelected ? "已选择" : "")
    }
}
