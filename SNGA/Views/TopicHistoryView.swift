import SwiftUI

/// 浏览历史：读过哪些话题，按天分组，从新到旧。
///
/// 按天分组而不是拉一条长列表：找一条读过的帖子时，脑子里记得的多半是「前天那条」
/// 而不是「第 37 条」。分组的抬头顺便把「今天」「昨天」写出来，省得读者自己
/// 拿日期去算。
struct TopicHistoryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.sngaTheme) private var theme
    @Environment(\.sngaFonts) private var fonts
    @State private var query = ""
    @State private var showsClearConfirmation = false

    private enum Metrics {
        static let rowHorizontalPadding: CGFloat = 8
        static let rowVerticalPadding: CGFloat = 3
        static let searchFieldWidth: CGFloat = 220
        static let emptyStateMinimumHeight: CGFloat = 220
    }

    var body: some View {
        Group {
            if model.topicHistory.entries.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(groups) { group in
                        Section(group.title) {
                            ForEach(group.visits) { visit in
                                row(visit)
                            }
                        }
                    }
                    if groups.isEmpty {
                        noMatchRow
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .contentMargins(.horizontal, 0, for: .scrollContent)
            }
        }
        .background(theme.backgroundColor)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .safeAreaInset(edge: .top, spacing: 0) { toolbar }
        .task { model.topicHistory.reload() }
        .confirmationDialog(
            "清空浏览历史？",
            isPresented: $showsClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("清空", role: .destructive) { model.topicHistory.clear() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("当前账号读过的 \(model.topicHistory.entries.count) 条记录会被删掉，列表里的话题也不再显示成读过。其他账号的历史不受影响。")
        }
        .accessibilityIdentifier("topic-history")
    }

    // MARK: - 顶上那一栏

    private var toolbar: some View {
        HStack(spacing: 10) {
            Text("浏览历史")
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)

            Spacer(minLength: 12)

            // 定宽：跟着内容走的话，历史从空到满的那一刻搜索框会自己变一次宽。
            TextField("搜索标题或作者", text: $query)
                .textFieldStyle(.roundedBorder)
                .frame(width: Metrics.searchFieldWidth)
                .accessibilityIdentifier("topic-history-search")

            Button {
                showsClearConfirmation = true
            } label: {
                Label("清空", systemImage: "trash")
            }
            .labelStyle(.iconOnly)
            .help("清空当前账号的浏览历史")
            .disabled(model.topicHistory.entries.isEmpty)
            .accessibilityIdentifier("topic-history-clear")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.regularMaterial)
    }

    // MARK: - 行

    private func row(_ visit: TopicVisit) -> some View {
        HStack(spacing: 10) {
            Button {
                Task { await model.openTopic(visit.topic) }
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(visit.subject.isEmpty ? "无标题话题" : visit.subject)
                        .font(fonts.topicList.body)
                        .foregroundStyle(theme.foregroundColor)
                        .lineLimit(2)
                    HStack(spacing: 8) {
                        if !visit.author.isEmpty {
                            Text(visit.author)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        Spacer(minLength: 8)
                        // 只报时刻：日期已经写在这一组的抬头上了。
                        Text(visit.visitedAt, format: .dateTime.hour().minute())
                            .fixedSize()
                    }
                    .font(fonts.topicList.caption)
                    .foregroundStyle(theme.secondaryForegroundColor)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            Button {
                model.topicHistory.remove(visit.id)
            } label: {
                Label("从历史中删除", systemImage: "xmark")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help("把《\(visit.subject)》从历史里删掉")
            .accessibilityIdentifier("topic-history-remove-\(visit.id.rawValue)")
        }
        .padding(.horizontal, Metrics.rowHorizontalPadding)
        .padding(.vertical, Metrics.rowVerticalPadding)
        .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 6))
        .listRowBackground(Color.clear)
        .accessibilityIdentifier("topic-history-\(visit.id.rawValue)")
    }

    // MARK: - 空的时候

    private var emptyState: some View {
        ContentUnavailableView {
            Label("还没有浏览历史", systemImage: "clock")
        } description: {
            if TopicHistorySettings.isEnabled {
                Text("打开过的话题会记在这里，列表里也会显示成读过。")
            } else {
                Text("浏览历史已在设置里关掉，打开过的话题不会被记下来。")
            }
        } actions: {
            if !TopicHistorySettings.isEnabled {
                Button("前往设置") {
                    model.openSettings(section: .browsing)
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var noMatchRow: some View {
        ContentUnavailableView.search(text: query)
            .frame(maxWidth: .infinity, minHeight: Metrics.emptyStateMinimumHeight)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }

    // MARK: - 分组

    private var groups: [TopicVisitDayGroup] {
        let calendar = Calendar.current
        var order: [Date] = []
        var grouped: [Date: [TopicVisit]] = [:]
        for visit in model.topicHistory.entries where visit.matches(query) {
            let day = calendar.startOfDay(for: visit.visitedAt)
            if grouped[day] == nil { order.append(day) }
            grouped[day, default: []].append(visit)
        }
        // `entries` 本来就是从新到旧，分到组里仍然保着序，不必再排一次。
        return order.map { day in
            TopicVisitDayGroup(
                id: day,
                title: Self.dayTitle(day, calendar: calendar),
                visits: grouped[day] ?? []
            )
        }
    }

    /// 抬头写「今天」「昨天」，再往前写日期带星期。
    ///
    /// 带上星期是因为找一条读过的帖子时，记得住的常常是「上周三看的」而不是
    /// 具体哪一号。
    private static func dayTitle(_ day: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(day) { return "今天" }
        if calendar.isDateInYesterday(day) { return "昨天" }
        return day.formatted(
            .dateTime.year().month(.wide).day().weekday(.wide)
        )
    }
}

private struct TopicVisitDayGroup: Identifiable {
    let id: Date
    let title: String
    let visits: [TopicVisit]
}
