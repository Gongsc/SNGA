import SwiftUI

/// 监控规则与检查间隔。
///
/// 独立一张表单而不是塞进设置面板：规则是这个功能的**主体**，不是它的偏好设置 ——
/// 一个还没写规则的监控什么都做不了，把它藏进设置里等于把入口藏起来。
struct TopicMonitorConfigurationSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.sngaTheme) private var theme
    @State private var draft = ""
    @State private var interval = TopicMonitorStore.defaultInterval
    @State private var sendsNotifications = true

    private enum Metrics {
        static let editorMinimumHeight: CGFloat = 150
        static let sheetWidth: CGFloat = 520
        static let sheetHeight: CGFloat = 520
        static let sectionSpacing: CGFloat = 18
        static let intervalFieldWidth: CGFloat = 90
    }

    private var monitor: TopicMonitorStore { model.topicMonitor }

    /// 这份草稿里有几条能用、几条写坏了。
    ///
    /// 边写边编译，而不是等按了保存再说 —— 写错一个括号，当场就该看见。
    private var compiled: TopicMonitorRules.Compiled {
        TopicMonitorRules.compile(draft)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
            header
            rulesEditor
            Divider()
            options
            Spacer(minLength: 0)
            footer
        }
        .padding(20)
        .frame(width: Metrics.sheetWidth, height: Metrics.sheetHeight)
        .background(theme.backgroundColor)
        .onAppear {
            draft = monitor.ruleText
            interval = monitor.intervalSeconds
            sendsNotifications = monitor.sendsNotifications
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("新帖监控")
                .font(.title2.bold())
                .foregroundStyle(theme.foregroundColor)
            // 说清楚数据从哪儿来。结果来自站外时要在界面上说出来，这一条和
            // SoV2EX 那一处是同一个道理。
            Text("读 NodeSeek 的公开订阅 rss.nodeseek.com，只匹配标题，不读摘要和正文。不带任何登录信息，没有账号也能用。")
                .font(.callout)
                .foregroundStyle(theme.secondaryForegroundColor)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var rulesEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("监控规则（每行一条，任意一条命中标题即收录）")
                .font(.callout)
                .foregroundStyle(theme.foregroundColor)
            TextEditor(text: $draft)
                .font(.body.monospaced())
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(minHeight: Metrics.editorMinimumHeight)
                .background(theme.fillColor, in: .rect(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(theme.controlBorderColor)
                }
                .accessibilityIdentifier("topic-monitor-rules-editor")
            Text("裸写一行按忽略大小写处理（`vmiss`）；要自己定标志就写成 `/香港.*(年付|月付)/i`。")
                .font(.caption)
                .foregroundStyle(theme.tertiaryForegroundColor)
            if !compiled.invalidLines.isEmpty {
                // 写坏的行必须说出来。一条编译不过的正则和一条永远匹配不上的正则，
                // 在结果列表上长得一模一样 —— 用户会以为「就是没有新帖」。
                Text("这几行写不成正则，不会生效：\(compiled.invalidLines.joined(separator: "、"))")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("topic-monitor-invalid-rules")
            }
        }
    }

    /// 一小组要对齐的表单用 `Grid`：两行的标签宽度必须对得齐，
    /// 一列 `LabeledContent` 各管各的，控件会各起各的头。
    private var options: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
            GridRow {
                Text("检查间隔")
                    .foregroundStyle(theme.foregroundColor)
                HStack(spacing: 8) {
                    TextField(
                        "",
                        value: $interval,
                        format: .number
                    )
                    .labelsHidden()
                    .frame(width: Metrics.intervalFieldWidth)
                    .accessibilityIdentifier("topic-monitor-interval")
                    Text("秒（\(TopicMonitorStore.intervalRange.lowerBound)–\(TopicMonitorStore.intervalRange.upperBound)）")
                        .foregroundStyle(theme.secondaryForegroundColor)
                }
            }
            GridRow {
                Text("系统通知")
                    .foregroundStyle(theme.foregroundColor)
                Toggle("发现新帖时发一条通知", isOn: $sendsNotifications)
                    .accessibilityIdentifier("topic-monitor-notifications")
            }
        }
        .font(.callout)
    }

    private var footer: some View {
        HStack {
            Text(summary)
                .font(.caption)
                .foregroundStyle(theme.secondaryForegroundColor)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("取消") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("保存并立即检查") {
                save()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("topic-monitor-save")
        }
    }

    /// 保存之后会发生什么，先说清楚 —— 尤其是「统计清零」和「首次不提醒」这两件，
    /// 不说的话看起来就像功能坏了。
    private var summary: String {
        compiled.rules.isEmpty
            ? "还没有能用的规则，保存后监控不会运行。"
            : "保存后清空旧的检查进度与统计，立刻检查一次；首次只记下当前位置，不把已有的帖子当新帖提醒。已收录的结果保留。"
    }

    private func save() {
        monitor.updateRules(draft)
        monitor.updateInterval(interval)
        monitor.sendsNotifications = sendsNotifications
        if !monitor.rules.isEmpty, !monitor.isEnabled {
            // 写了规则就是要它跑起来。保存完还得再去按一次「开始」，那一步没有意义。
            monitor.isEnabled = true
        }
        let shouldCheck = !monitor.rules.isEmpty
        dismiss()
        if shouldCheck {
            Task { await monitor.checkNow() }
        }
    }
}
