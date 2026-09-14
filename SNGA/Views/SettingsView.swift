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
    @AppStorage(FontArea.threadContent.familyKey) private var threadContentFontFamily = ""
    @AppStorage(FontArea.threadContent.sizeKey)
    private var threadContentFontSize = FontArea.threadContent.defaultSize
    @AppStorage(BrowsingSettings.imageFreeModeKey) private var imageFreeMode = false
    @AppStorage(BrowsingSettings.postSignatureKey) private var showsPostSignature = true
    @AppStorage(RecentForumSettings.maximumCountKey)
    private var recentForumMaximumCount = RecentForumSettings.defaultMaximumCount
    @AppStorage(SearchHistorySettings.maximumCountKey)
    private var searchHistoryMaximumCount = SearchHistorySettings.defaultMaximumCount
    @AppStorage(KeywordFilterSettings.enabledKey) private var keywordFilterEnabled = true
    @AppStorage(KeywordFilterSettings.rulesKey) private var keywordFilterRulesJSON = ""
    @AppStorage(TopicHistorySettings.enabledKey) private var topicHistoryEnabled = true
    @AppStorage(TopicHistorySettings.dimsVisitedKey) private var dimsVisitedTopics = true
    @AppStorage(TopicHistorySettings.maximumCountKey)
    private var topicHistoryMaximumCount = TopicHistorySettings.defaultMaximumCount
    @AppStorage(TopicHistorySettings.retentionDaysKey)
    private var topicHistoryRetentionDays = TopicHistorySettings.defaultRetentionDays
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
    @AppStorage(AISettings.topicSummaryPageLimitKey)
    private var aiTopicSummaryPageLimit = AISettings.defaultTopicSummaryPageLimit
    @AppStorage(AISettings.topicSummaryAllPagesKey)
    private var aiTopicSummaryAllPages = false
    @AppStorage(AISettings.historyLimitKey)
    private var aiHistoryLimit = AISettings.defaultHistoryLimit

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                Text("外观、浏览行为、关键字过滤、浏览历史、AI、小工具、日志与关于")
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
            let themeTitle = selected == .custom
                ? "自定义 · 强调色 \(customAccentHex.uppercased())"
                : selected.displayName
            // 三档只报正文那一档：副标题只有一行，三个字体名字加三个字号
            // 拼进去必然被中间截断，剩下的信息还不如不写。
            let family = FontSettings.normalizedFamily(threadContentFontFamily)
            let fontTitle = family.isEmpty ? "系统字体" : family
            let size = Int(FontSettings.normalizedSize(threadContentFontSize))
            return "\(themeTitle) · 正文 \(fontTitle) \(size) 点"
        case .browsing:
            let count = RecentForumSettings.normalizedMaximumCount(recentForumMaximumCount)
            let historyCount = SearchHistorySettings.normalizedMaximumCount(
                searchHistoryMaximumCount
            )
            return "无图模式\(imageFreeMode ? "已开" : "已关")"
                + " · 签名\(showsPostSignature ? "已开" : "已关")"
                + " · 最近访问 \(count) 条"
                + " · 搜索历史 \(historyCount) 条"
        case .keywordFilter:
            let rules = KeywordFilterSettings.decode(keywordFilterRulesJSON)
            let activeRules = rules.filter(\.isActive)
            guard !activeRules.isEmpty else { return "未设置关键字" }
            guard keywordFilterEnabled else { return "已关闭 · 留着 \(activeRules.count) 条规则" }
            let counts = KeywordFilterAction.allCases.compactMap { action -> String? in
                let count = activeRules.filter { $0.action == action }.count
                return count > 0 ? "\(action.title) \(count)" : nil
            }
            return counts.joined(separator: " · ")
        case .topicHistory:
            guard topicHistoryEnabled else { return "不记录" }
            let count = TopicHistorySettings.normalizedMaximumCount(topicHistoryMaximumCount)
            let days = TopicHistorySettings.normalizedRetentionDays(topicHistoryRetentionDays)
            return "\(count) 条 · \(days) 天 · 读过变灰\(dimsVisitedTopics ? "已开" : "已关")"
        case .ai:
            guard aiEnabled else { return "已关闭" }
            let model = aiModel.trimmingCharacters(in: .whitespacesAndNewlines)
            guard AISettings.normalizedBaseURL(from: aiBaseURL) != nil,
                  !model.isEmpty,
                  !aiInstruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !aiTopicSummaryInstruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return "OpenAI 兼容接口 · 待配置"
            }
            let pageScope = aiTopicSummaryAllPages
                ? "话题全部页"
                : "话题前 \(AISettings.normalizedTopicSummaryPageLimit(aiTopicSummaryPageLimit)) 页"
            return "\(model) · \(pageScope) · 最近 \(AISettings.normalizedHistoryLimit(aiHistoryLimit)) 人"
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
                case .keywordFilter: SettingsKeywordFilterPane()
                case .topicHistory: SettingsTopicHistoryPane()
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
    @Environment(\.sngaTheme) private var theme
    @AppStorage(AppTheme.storageKey) private var selectedThemeRaw = AppTheme.system.rawValue
    @AppStorage(AppTheme.customBackgroundKey)
    private var customBackgroundHex = AppTheme.defaultCustomBackgroundHex
    @AppStorage(AppTheme.customAccentKey)
    private var customAccentHex = AppTheme.defaultCustomAccentHex
    // 三段字体各一对。键是拼出来的（`FontArea.familyKey`），但存取仍旧一处一个
    // 属性 —— `@AppStorage` 的键要在初始化时定死，动态取键就得给每一段再套一层
    // 子视图，而那一层除了转发什么都不做。
    @AppStorage(FontArea.sidebar.familyKey) private var sidebarFontFamily = ""
    @AppStorage(FontArea.sidebar.sizeKey)
    private var sidebarFontSize = FontArea.sidebar.defaultSize
    @AppStorage(FontArea.topicList.familyKey) private var topicListFontFamily = ""
    @AppStorage(FontArea.topicList.sizeKey)
    private var topicListFontSize = FontArea.topicList.defaultSize
    @AppStorage(FontArea.threadContent.familyKey) private var threadContentFontFamily = ""
    @AppStorage(FontArea.threadContent.sizeKey)
    private var threadContentFontSize = FontArea.threadContent.defaultSize
    @AppStorage(FontArea.postAuthor.familyKey) private var postAuthorFontFamily = ""
    @AppStorage(FontArea.postAuthor.sizeKey)
    private var postAuthorFontSize = FontArea.postAuthor.defaultSize

    private enum Metrics {
        /// 选择器给死宽度：字体名字从「宋体-简」到「Helvetica Neue」差着一倍，
        /// 贴着内容会让三行的字号步进器各起各的头。
        static let familyPickerWidth: CGFloat = 210
        /// 步进器的读数也给死宽度。当前范围里都是两位数，看不出区别 —— 但宽度
        /// 一旦跟着内容走，改一次范围就会让三行的箭头各站各的位置。
        static let sizeValueWidth: CGFloat = 46
    }

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

            fontCard
            fontPreviewCard
        }
    }

    /// 三段字体的设置。
    ///
    /// 用 `Grid` 而不是三组 `LabeledContent`：后者每一行各管各的，标签宽度对不齐，
    /// 三个选择器会各起各的头。
    private var fontCard: some View {
        SettingsCard(label: "字体") {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
                ForEach(FontArea.allCases) { area in
                    GridRow(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(area.title)
                            Text(area.detail)
                                .font(.caption)
                                .foregroundStyle(theme.secondaryForegroundColor)
                        }

                        Picker("字体", selection: familyBinding(for: area)) {
                            Text("系统字体").tag(FontSettings.systemFamilyName)
                            Divider()
                            ForEach(FontSettings.availableFamilies, id: \.self) { family in
                                Text(family).tag(family)
                            }
                        }
                        .labelsHidden()
                        .frame(width: Metrics.familyPickerWidth)
                        .accessibilityLabel("\(area.title)字体")
                        .accessibilityIdentifier("appearance-font-family-\(area.rawValue)")

                        Stepper(
                            value: sizeBinding(for: area),
                            in: FontSettings.allowedSizeRange,
                            step: 1
                        ) {
                            Text("\(Int(sizeBinding(for: area).wrappedValue)) 点")
                                .monospacedDigit()
                                .frame(width: Metrics.sizeValueWidth, alignment: .leading)
                        }
                        .accessibilityLabel("\(area.title)字号")
                        .accessibilityIdentifier("appearance-font-size-\(area.rawValue)")
                    }
                }
            }

            Text("只改这三处的文字。按钮、输入框和选择器仍按系统尺寸 —— 它们的大小归 macOS 管，跟着字号缩会把整块面板挤变形。")
                .font(.caption)
                .foregroundStyle(theme.secondaryForegroundColor)

            HStack {
                Spacer()
                Button("恢复默认字体") {
                    for area in FontArea.allCases {
                        familyBinding(for: area).wrappedValue = FontSettings.systemFamilyName
                        sizeBinding(for: area).wrappedValue = area.defaultSize
                    }
                }
                .disabled(resolvedFonts.isDefault)
                .accessibilityIdentifier("appearance-font-reset")
            }
        }
    }

    /// 改完当场能看见。三段的正文和小字各画一行 —— 小字（徽章、作者、楼层号）
    /// 跟着同一个比例缩放，只看正文那一行是看不出来的。
    private var fontPreviewCard: some View {
        SettingsCard(label: "预览") {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(FontArea.allCases) { area in
                    let set = resolvedFonts[area]
                    VStack(alignment: .leading, spacing: 3) {
                        Label(area.title, systemImage: area.systemImage)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(theme.secondaryForegroundColor)
                        Text(area.sampleText)
                            .font(set.body)
                            .lineLimit(1)
                        Text(area.sampleDetail)
                            .font(set.caption)
                            .foregroundStyle(theme.secondaryForegroundColor)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("appearance-font-preview-\(area.rawValue)")
                }
            }
        }
    }

    private var resolvedFonts: ResolvedAppFonts {
        ResolvedAppFonts(
            sidebar: ScopedFontSet(
                area: .sidebar,
                familyName: FontSettings.normalizedFamily(sidebarFontFamily),
                size: sidebarFontSize
            ),
            topicList: ScopedFontSet(
                area: .topicList,
                familyName: FontSettings.normalizedFamily(topicListFontFamily),
                size: topicListFontSize
            ),
            threadContent: ScopedFontSet(
                area: .threadContent,
                familyName: FontSettings.normalizedFamily(threadContentFontFamily),
                size: threadContentFontSize
            ),
            postAuthor: ScopedFontSet(
                area: .postAuthor,
                familyName: FontSettings.normalizedFamily(postAuthorFontFamily),
                size: postAuthorFontSize
            )
        )
    }

    /// 取值时过一道 `normalizedFamily`：选过的字体可能已经被卸载了，直接把存下来
    /// 的名字交给选择器，它会显示成一个谁也选不中的空行。
    private func familyBinding(for area: FontArea) -> Binding<String> {
        let stored = storedFamilyBinding(for: area)
        return Binding(
            get: { FontSettings.normalizedFamily(stored.wrappedValue) },
            set: { stored.wrappedValue = $0 }
        )
    }

    private func storedFamilyBinding(for area: FontArea) -> Binding<String> {
        switch area {
        case .sidebar: $sidebarFontFamily
        case .topicList: $topicListFontFamily
        case .threadContent: $threadContentFontFamily
        case .postAuthor: $postAuthorFontFamily
        }
    }

    private func sizeBinding(for area: FontArea) -> Binding<Double> {
        switch area {
        case .sidebar: $sidebarFontSize
        case .topicList: $topicListFontSize
        case .threadContent: $threadContentFontSize
        case .postAuthor: $postAuthorFontSize
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
        ThemeRGB(color)?.hex ?? fallback
    }
}

private struct SettingsBrowsingPane: View {
    @Environment(AppModel.self) private var model
    @AppStorage(BrowsingSettings.imageFreeModeKey) private var imageFreeMode = false
    @AppStorage(BrowsingSettings.postSignatureKey) private var showsPostSignature = true
    @AppStorage(RecentForumSettings.maximumCountKey)
    private var recentForumMaximumCount = RecentForumSettings.defaultMaximumCount
    @AppStorage(SearchHistorySettings.maximumCountKey)
    private var searchHistoryMaximumCount = SearchHistorySettings.defaultMaximumCount

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
                Toggle(isOn: $showsPostSignature) {
                    Text("在话题中显示签名")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .toggleStyle(.switch)
                .accessibilityIdentifier("browsing-post-signature")

                Text("楼层末尾用一条分割线隔开作者的签名。没写签名的作者不占位置。")
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

            SettingsCard {
                Stepper(
                    value: $searchHistoryMaximumCount,
                    in: SearchHistorySettings.allowedRange
                ) {
                    Text("搜索历史数量：\(searchHistoryMaximumCount)")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityIdentifier("search-history-maximum-count")
                .onChange(of: searchHistoryMaximumCount) { _, maximumCount in
                    model.searchHistory.updateLimit(maximumCount)
                }

                Text("点搜索框会列出最近搜过的关键词；只记关键词，不记搜索结果。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("清除全部搜索历史") {
                    model.searchHistory.clear()
                }
                .disabled(model.searchHistory.entries.isEmpty)
                .accessibilityIdentifier("search-history-clear-all")
            }
        }
    }
}

/// 浏览历史。
///
/// 「记不记」和「变不变灰」是两个开关，因为它们是两件事：一个是留不留记录，
/// 一个是列表上体不体现。嫌列表花的人不必为此把历史也一起关掉。
private struct SettingsTopicHistoryPane: View {
    @Environment(AppModel.self) private var model
    @Environment(\.sngaTheme) private var theme
    @AppStorage(TopicHistorySettings.enabledKey) private var isEnabled = true
    @AppStorage(TopicHistorySettings.dimsVisitedKey) private var dimsVisitedTopics = true
    @AppStorage(TopicHistorySettings.maximumCountKey)
    private var maximumCount = TopicHistorySettings.defaultMaximumCount
    @AppStorage(TopicHistorySettings.retentionDaysKey)
    private var retentionDays = TopicHistorySettings.defaultRetentionDays
    @State private var showsClearConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsCard {
                Toggle(isOn: $isEnabled) {
                    Text("记录浏览历史")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .toggleStyle(.switch)
                .accessibilityIdentifier("topic-history-enabled")
                .onChange(of: isEnabled) { _, isEnabled in
                    model.topicHistory.applyEnabledChange(isEnabled)
                }

                Text("打开过的话题记在侧栏的「浏览历史」里，按天分组。关掉之后不再记录，**已经记下的也会全部删掉** —— 所有账号的都删。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            SettingsCard {
                Toggle(isOn: $dimsVisitedTopics) {
                    Text("读过的话题在列表里变灰")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .toggleStyle(.switch)
                .disabled(!isEnabled)
                .accessibilityIdentifier("topic-history-dims-visited")

                Text("和浏览器里访问过的链接一个意思：标题淡一档，站点自己给标题上的颜色保留。版面列表、搜索结果和收藏夹都算。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !isEnabled {
                    Text("需要先打开「记录浏览历史」—— 不记录就无从知道哪些读过。")
                        .font(.caption)
                        .foregroundStyle(theme.tertiaryForegroundColor)
                }
            }

            SettingsCard {
                Stepper(
                    value: $maximumCount,
                    in: TopicHistorySettings.maximumCountRange,
                    step: TopicHistorySettings.maximumCountStep
                ) {
                    Text("每个账号最多保留：\(maximumCount) 条")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .disabled(!isEnabled)
                .accessibilityIdentifier("topic-history-maximum-count")
                .onChange(of: maximumCount) { _, maximumCount in
                    model.topicHistory.updateMaximumCount(maximumCount)
                }

                Stepper(
                    value: $retentionDays,
                    in: TopicHistorySettings.retentionDaysRange
                ) {
                    Text("保留天数：\(retentionDays) 天")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .disabled(!isEnabled)
                .accessibilityIdentifier("topic-history-retention-days")
                .onChange(of: retentionDays) { _, retentionDays in
                    model.topicHistory.updateRetentionDays(retentionDays)
                }

                Text("上限是按账号算的，不是所有账号合起来 —— 否则常用的那个账号会把别的账号的历史挤光。调小会立刻删掉多出来的记录。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("到期和超额的记录一并不再变灰：一个月前读过的帖子会重新显示成没读过。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            SettingsCard {
                Button("清空当前账号的浏览历史") {
                    showsClearConfirmation = true
                }
                .disabled(model.topicHistory.entries.isEmpty)
                .accessibilityIdentifier("topic-history-clear-all")

                Text("只清当前账号。别的账号读过什么不受影响。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .confirmationDialog(
            "清空浏览历史？",
            isPresented: $showsClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("清空", role: .destructive) { model.topicHistory.clear() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("当前账号读过的 \(model.topicHistory.entries.count) 条记录会被删掉，列表里的话题也不再显示成读过。")
        }
    }
}

/// 关键字过滤。
///
/// 一条规则一行：开关、词、档位、颜色、删除。用 `Grid` 而不是一列 `HStack`，
/// 是因为每一行的词长短不一 —— 各管各的话，档位选择器会在每一行落在不同的位置。
private struct SettingsKeywordFilterPane: View {
    @Environment(\.sngaTheme) private var theme
    @AppStorage(KeywordFilterSettings.enabledKey) private var isEnabled = true
    @AppStorage(KeywordFilterSettings.rulesKey) private var rulesJSON = ""
    /// 试打一条标题，看看现有规则会把它怎么样。关键字过滤最常见的毛病是误伤，
    /// 而误伤只有在列表里少了东西之后才会被发现 —— 这里让它当场就能验。
    @State private var trialSubject = ""
    @State private var trialAuthor = ""

    private enum Metrics {
        /// 范围和档位两个选择器都给死宽度：标题都是两个字，但选择器自带的箭头和
        /// 内边距会让它贴着内容变形，行与行之间对不齐。
        static let scopePickerWidth: CGFloat = 82
        static let actionPickerWidth: CGFloat = 92
        /// 颜色那一格的宽度。非高亮档不画取色盘，但格子留着 ——
        /// 换个档位整行的列宽跟着跳，比留一块空白难看得多。
        static let colorColumnWidth: CGFloat = 44
        static let rowSpacing: CGFloat = 8
        static let columnSpacing: CGFloat = 10
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsCard {
                Toggle(isOn: $isEnabled) {
                    Text("启用关键字过滤")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .toggleStyle(.switch)
                .accessibilityIdentifier("keyword-filter-enabled")

                Text("按话题标题里的词、或者发帖人是谁，把话题高亮、折叠或隐藏。关掉之后规则原样留着，只是不起作用。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("只作用于版面的话题列表。搜索结果和收藏夹不过滤 —— 那两处是你自己点名要看的东西。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            rulesCard
            trialCard
        }
    }

    private var rulesCard: some View {
        SettingsCard(label: "规则") {
            if rules.isEmpty {
                Text("还没有规则。一条规则里可以并列多个词，用逗号隔开，命中任意一个就算。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Grid(
                    alignment: .leading,
                    horizontalSpacing: Metrics.columnSpacing,
                    verticalSpacing: Metrics.rowSpacing
                ) {
                    ForEach(ruleBindings) { $rule in
                        GridRow {
                            Toggle("启用规则", isOn: $rule.isEnabled)
                                .labelsHidden()
                                .help(rule.isEnabled ? "这条规则生效中" : "这条规则已停用")

                            Picker("比哪一面", selection: $rule.scope) {
                                ForEach(KeywordFilterScope.allCases) { scope in
                                    Text(scope.title).tag(scope)
                                }
                            }
                            .labelsHidden()
                            .frame(width: Metrics.scopePickerWidth)
                            .help(rule.scope == .subject ? "在话题标题里找" : "比发帖人的名字")

                            TextField(rule.scope.prompt, text: $rule.keywords)
                                .textFieldStyle(.roundedBorder)
                                .accessibilityLabel(rule.scope.title)

                            Picker("命中后怎么办", selection: $rule.action) {
                                ForEach(KeywordFilterAction.allCases) { action in
                                    Text(action.title).tag(action)
                                }
                            }
                            .labelsHidden()
                            .frame(width: Metrics.actionPickerWidth)

                            Group {
                                if rule.action == .highlight {
                                    ColorPicker(
                                        "高亮底色",
                                        selection: color(for: $rule),
                                        supportsOpacity: false
                                    )
                                    .labelsHidden()
                                    .help("高亮底色")
                                }
                            }
                            .frame(width: Metrics.colorColumnWidth, alignment: .leading)

                            Button {
                                remove(rule.id)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("删除这条规则")
                            .accessibilityLabel("删除规则")
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("keyword-filter-rules")
            }

            HStack {
                Button("添加规则", action: addRule)
                    .disabled(rules.count >= KeywordFilterSettings.maximumRuleCount)
                    .accessibilityIdentifier("keyword-filter-add-rule")

                Spacer()

                if !rules.isEmpty {
                    Text("\(rules.count) / \(KeywordFilterSettings.maximumRuleCount)")
                        .font(.caption)
                        .foregroundStyle(theme.tertiaryForegroundColor)
                }
            }

            Text("标题按「含有」比，作者按「就是这个人」比 —— 屏蔽的是某一个人，按片段比会连坐名字相近的人。")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("同一条话题命中多条规则时，隐藏盖过折叠，折叠盖过高亮；同一档里以排在前面的那条为准。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// 试一条话题。标题和作者分两格，因为规则也是按这两面分的 ——
    /// 只给一个输入框的话，作者那一档根本试不出来。
    private var trialCard: some View {
        SettingsCard(label: "试一条话题") {
            Grid(
                alignment: .leading,
                horizontalSpacing: Metrics.columnSpacing,
                verticalSpacing: Metrics.rowSpacing
            ) {
                GridRow {
                    Text("标题")
                        .gridColumnAlignment(.trailing)
                    TextField("粘一条话题标题进来看看", text: $trialSubject)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("keyword-filter-trial-subject")
                }
                GridRow {
                    Text("作者")
                        .gridColumnAlignment(.trailing)
                    TextField("发帖人的名字", text: $trialAuthor)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("keyword-filter-trial-author")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                Image(systemName: trialSymbol)
                Text(trialDescription)
            }
            .font(.caption)
            .foregroundStyle(trialIsFiltered ? theme.accentColor : theme.secondaryForegroundColor)
            .accessibilityIdentifier("keyword-filter-trial-result")
        }
    }

    // MARK: - 试一条标题的结果

    private var trialVerdict: KeywordFilterVerdict {
        ResolvedKeywordFilter(isEnabled: isEnabled, rules: rules)
            .verdict(forSubject: trialSubject, author: trialAuthor)
    }

    private var trialIsEmpty: Bool {
        trialSubject.isEmpty && trialAuthor.isEmpty
    }

    private var trialIsFiltered: Bool {
        !trialIsEmpty && trialVerdict != .show
    }

    private var trialSymbol: String {
        switch trialVerdict {
        case .show: "checkmark.circle"
        case .highlight: KeywordFilterAction.highlight.systemImage
        case .fold: KeywordFilterAction.fold.systemImage
        case .hide: KeywordFilterAction.hide.systemImage
        }
    }

    private var trialDescription: String {
        guard !trialIsEmpty else { return "填任意一格，这里会说它会被怎么处理。" }
        switch trialVerdict {
        case .show:
            return "没有规则命中，照常显示。"
        case .highlight(_, let match):
            return "\(match.description)，会在列表里高亮。"
        case .fold(let match):
            return "\(match.description)，会被折叠成一行。"
        case .hide(let match):
            return "\(match.description)，不会出现在列表里。"
        }
    }

    // MARK: - 规则的读写

    /// 规则存成一行 JSON，这里每次读都解一遍。
    ///
    /// 没有搬进 `@State` 缓存：那样就有两份真相，改完之后得自己往回同步，
    /// 而这个面板一共也就几十条规则，解析的代价比同步的风险小得多。
    private var rules: [KeywordFilterRule] {
        KeywordFilterSettings.decode(rulesJSON)
    }

    private var ruleBindings: Binding<[KeywordFilterRule]> {
        Binding(
            get: { KeywordFilterSettings.decode(rulesJSON) },
            set: { rulesJSON = KeywordFilterSettings.encode($0) }
        )
    }

    private func color(for rule: Binding<KeywordFilterRule>) -> Binding<Color> {
        Binding(
            get: {
                ThemeRGB(
                    hex: rule.wrappedValue.colorHex,
                    fallback: ThemeRGB(hex: KeywordFilterSettings.defaultHighlightHex)!
                )!.color
            },
            set: {
                rule.wrappedValue.colorHex =
                    ThemeRGB($0)?.hex ?? KeywordFilterSettings.defaultHighlightHex
            }
        )
    }

    /// 新规则的颜色按已有条数轮着取，而不是一律给默认的那支淡黄 ——
    /// 几条规则同色的话，高亮就只剩「这行被标了」，说不出是被哪条标的。
    private func addRule() {
        var updated = rules
        guard updated.count < KeywordFilterSettings.maximumRuleCount else { return }
        let palette = KeywordFilterSettings.presetHighlightHexes
        updated.append(
            KeywordFilterRule(colorHex: palette[updated.count % palette.count])
        )
        rulesJSON = KeywordFilterSettings.encode(updated)
    }

    private func remove(_ id: KeywordFilterRule.ID) {
        rulesJSON = KeywordFilterSettings.encode(rules.filter { $0.id != id })
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
    @AppStorage(AISettings.topicSummaryPageLimitKey)
    private var topicSummaryPageLimit = AISettings.defaultTopicSummaryPageLimit
    @AppStorage(AISettings.topicSummaryAllPagesKey)
    private var topicSummaryAllPages = false
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
                            ? "已保存；输入新值可替换"
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

                Text("API Key 只保存在应用沙盒内一个仅本人可读写的文件里，不会写入偏好设置、画像历史或运行日志。")
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
                        Text("标题与楼层会作为独立 JSON 数据发送，正文中的文字不会被当成指令执行。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("恢复默认") {
                            topicSummaryInstruction = AISettings.defaultTopicSummaryInstruction
                        }
                        .accessibilityIdentifier("ai-reset-topic-summary-instruction")
                    }
                }

                SettingsCard(label: "话题总结范围") {
                    Toggle("总结全部页面", isOn: $topicSummaryAllPages)
                        .toggleStyle(.switch)
                        .accessibilityHint("开启后，每次总结都会读取话题的全部页面")
                        .accessibilityIdentifier("ai-topic-summary-all-pages")

                    if !topicSummaryAllPages {
                        Stepper(
                            value: $topicSummaryPageLimit,
                            in: 1...Int.max
                        ) {
                            Text("覆盖前 \(AISettings.normalizedTopicSummaryPageLimit(topicSummaryPageLimit)) 页")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .accessibilityIdentifier("ai-topic-summary-page-limit")
                        .onChange(of: topicSummaryPageLimit) { _, value in
                            let normalized = AISettings.normalizedTopicSummaryPageLimit(value)
                            if normalized != value { topicSummaryPageLimit = normalized }
                        }
                    }

                    Text(topicSummaryAllPages
                         ? "总结前会串行读取全部页面；大型话题可能耗时较长，可随时取消。"
                         : "总结前会串行读取话题开头的指定页数；不足时读取实际全部页面。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                Text("生成画像时会发送公开用户资料与已加载的发布记录；总结话题时会按上方范围读取并发送标题和楼层文字。AI 结果仅供参考。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .task { await loadKeyStatus() }
        .onAppear {
            let normalizedPageLimit = AISettings.normalizedTopicSummaryPageLimit(
                topicSummaryPageLimit
            )
            if topicSummaryPageLimit != normalizedPageLimit {
                topicSummaryPageLimit = normalizedPageLimit
            }
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
