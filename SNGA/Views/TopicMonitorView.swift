import SwiftUI

/// 新帖监控：订阅里出现符合规则的标题时收一条，并提醒一声。
///
/// 它读的是一份**匿名**订阅，所以和小工具一样在账号门槛外面 —— 一个账号都没有时
/// 照样能用，也不该因为论坛那边没登录就整块消失。
struct TopicMonitorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.sngaTheme) private var theme
    @Environment(\.sngaFonts) private var fonts
    @State private var showsConfiguration = false
    @State private var showsClearConfirmation = false

    private enum Metrics {
        static let rowHorizontalPadding: CGFloat = 8
        static let rowVerticalPadding: CGFloat = 4
        static let ruleDotSize: CGFloat = 8
        static let statusSpacing: CGFloat = 6
        static let emptyStateMinimumHeight: CGFloat = 220
    }

    private var monitor: TopicMonitorStore { model.topicMonitor }

    var body: some View {
        Group {
            if monitor.hits.isEmpty {
                emptyState
            } else {
                List {
                    Section(resultsSectionTitle) {
                        ForEach(monitor.hits) { hit in
                            row(hit)
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .contentMargins(.horizontal, 0, for: .scrollContent)
            }
        }
        .background(theme.backgroundColor)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .contentColumnHeader { toolbar }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            BottomActionBar { bottomBar }
        }
        .sheet(isPresented: $showsConfiguration) {
            TopicMonitorConfigurationSheet()
        }
        .confirmationDialog(
            "清空监控结果？",
            isPresented: $showsClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("清空", role: .destructive) { monitor.clearHits() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("已经收录的 \(monitor.hits.count) 条会被删掉。监控规则和检查进度不受影响，之后出现的新帖照常收录。")
        }
        .task {
            // 轮询是在 `AppModel.bootstrap()` 里起的 —— 监控要在没人看着的时候
            // 干活。这里只补一种情况：用户刚设完规则、或者刚把它打开。
            // 不无条件 `start()`，那会掐掉一次正在飞的检查。
            monitor.startIfIdle()
        }
    }

    private var resultsSectionTitle: String {
        monitor.unreadCount > 0
            ? "命中的帖子（\(monitor.hits.count) 条，\(monitor.unreadCount) 条未读）"
            : "命中的帖子（\(monitor.hits.count) 条）"
    }

    // MARK: - 顶上那一栏

    private var toolbar: some View {
        HStack(spacing: 10) {
            statusLine
            Spacer()
            Button {
                showsConfiguration = true
            } label: {
                Label("配置", systemImage: "slider.horizontal.3")
            }
            .labelStyle(.iconOnly)
            .help("设置监控规则与检查间隔")
            .accessibilityIdentifier("topic-monitor-configure")
        }
    }

    /// 现在是个什么状态。
    ///
    /// 「还没检查过」和「查过了、没结果」分开说 —— 两者在列表上长得一模一样，但
    /// 前者意味着这东西还没开始干活，后者意味着它干过了。
    private var statusLine: some View {
        HStack(spacing: Metrics.statusSpacing) {
            if monitor.isChecking {
                ProgressView()
                    .controlSize(.small)
            }
            Text(statusText)
                .font(fonts.sidebar.caption)
                .foregroundStyle(
                    monitor.lastErrorMessage == nil
                        ? theme.secondaryForegroundColor
                        : Color.red
                )
                .lineLimit(1)
                .truncationMode(.tail)
                .accessibilityIdentifier("topic-monitor-status")
        }
    }

    private var statusText: String {
        if let error = monitor.lastErrorMessage { return error }
        if monitor.rules.isEmpty { return "还没有监控规则" }
        if !monitor.isEnabled { return "监控已停止" }
        if monitor.isChecking { return "正在检查…" }
        if monitor.hasNeverChecked { return "还没检查过" }
        return "已检查 \(monitor.checkedRounds) 轮，看过 \(monitor.examinedCount) 条，命中 \(monitor.matchedCount) 条"
    }

    // MARK: - 底下那一栏

    private var bottomBar: some View {
        HStack {
            Button {
                monitor.isEnabled.toggle()
            } label: {
                Label(
                    monitor.isEnabled ? "停止监控" : "开始监控",
                    systemImage: monitor.isEnabled ? "pause" : "play"
                )
            }
            .labelStyle(.iconOnly)
            .help(monitor.isEnabled ? "停止自动检查" : "开始自动检查")
            .disabled(monitor.rules.isEmpty)
            .accessibilityIdentifier("topic-monitor-toggle")

            Button {
                monitor.markAllHitsRead()
            } label: {
                Label("全部已读", systemImage: "checkmark")
            }
            .labelStyle(.iconOnly)
            .help(monitor.unreadCount == 0 ? "当前没有未读结果" : "全部标为已读")
            .disabled(monitor.unreadCount == 0)
            .accessibilityIdentifier("topic-monitor-mark-all-read")

            Button {
                showsClearConfirmation = true
            } label: {
                Label("清空", systemImage: "trash")
            }
            .labelStyle(.iconOnly)
            .help("清空已收录的结果")
            .disabled(monitor.hits.isEmpty)
            .accessibilityIdentifier("topic-monitor-clear")

            Spacer()

            Button {
                Task { await monitor.checkNow() }
            } label: {
                Label("立即检查", systemImage: "arrow.clockwise")
            }
            .labelStyle(.iconOnly)
            .help(monitor.rules.isEmpty ? "先设置监控规则" : "立即检查一次，不等下一轮")
            .disabled(monitor.rules.isEmpty || monitor.isChecking)
            .accessibilityIdentifier("topic-monitor-check-now")
        }
    }

    // MARK: - 行

    private func row(_ hit: TopicMonitorHit) -> some View {
        Button {
            model.openMonitoredTopic(hit)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                // 哪条规则命中的，用颜色说。多条规则一起跑时，光看标题猜不出来。
                Circle()
                    .fill(TopicMonitorRuleColor.color(forRuleIndex: hit.ruleIndex, theme: theme))
                    .frame(width: Metrics.ruleDotSize, height: Metrics.ruleDotSize)
                    .padding(.top, 5)
                    .help("命中规则：\(hit.ruleSource)")

                VStack(alignment: .leading, spacing: 4) {
                    Text(hit.title)
                        .font(fonts.topicList.body)
                        .foregroundStyle(
                            hit.isUnread
                                ? theme.foregroundColor
                                : theme.secondaryForegroundColor
                        )
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 8) {
                        if let author = hit.author, !author.isEmpty {
                            Text(author)
                        }
                        if let category = hit.category, !category.isEmpty {
                            Text(category)
                        }
                        if let publishedAt = hit.publishedAt {
                            Text(publishedAt, style: .relative)
                        }
                    }
                    .font(fonts.topicList.caption)
                    .foregroundStyle(theme.tertiaryForegroundColor)
                    .lineLimit(1)
                }

                Spacer(minLength: 0)

                if hit.isUnread {
                    Circle()
                        .fill(theme.accentColor)
                        .frame(width: Metrics.ruleDotSize, height: Metrics.ruleDotSize)
                        .padding(.top, 5)
                        .accessibilityLabel("未读")
                }
            }
            .padding(.horizontal, Metrics.rowHorizontalPadding)
            .padding(.vertical, Metrics.rowVerticalPadding)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("topic-monitor-hit-\(hit.id)")
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("新帖监控", systemImage: "bell.badge")
        } description: {
            Text(emptyStateDescription)
        } actions: {
            Button("设置监控规则") { showsConfiguration = true }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("topic-monitor-empty-configure")
        }
        .frame(minHeight: Metrics.emptyStateMinimumHeight)
    }

    private var emptyStateDescription: String {
        if monitor.rules.isEmpty {
            return "写几条关键词或正则，NodeSeek 的新帖标题命中时会收录并提醒。订阅是公开的，不需要登录。"
        }
        if monitor.hasNeverChecked {
            return "规则已经设好了，还没检查过。首次检查只记下当前位置，不会把已有的帖子当成新帖提醒。"
        }
        return "还没有命中的新帖。首次检查只记位置，之后出现的新帖才会收录。"
    }
}

/// 规则的分色。
///
/// 走主题的强调色系而不是硬写四个颜色：应用有六套主题，硬写的颜色在午夜蓝和
/// NGA 暖金下会和周围对不上。
enum TopicMonitorRuleColor {
    static func color(forRuleIndex index: Int, theme: ResolvedAppTheme) -> Color {
        let palette: [Color] = [
            theme.accentColor,
            theme.accentColor.opacity(0.62),
            theme.secondaryForegroundColor,
            theme.tertiaryForegroundColor
        ]
        return palette[abs(index) % palette.count]
    }
}
