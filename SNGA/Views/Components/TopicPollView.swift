import SwiftUI

struct TopicPollView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.sngaTheme) private var theme
    let poll: TopicPoll

    @State private var selection: Set<String> = []
    @State private var showsSubmissionConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("话题投票", systemImage: "chart.bar.doc.horizontal")
                .font(.headline)
                .foregroundStyle(theme.accentColor)

            ForEach(poll.groups) { group in
                VStack(alignment: .leading, spacing: 6) {
                    if let title = group.title {
                        Text(title)
                            .font(.subheadline)
                            .bold()
                    }

                    ForEach(group.options) { option in
                        Button {
                            toggleSelection(of: option, in: group)
                        } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: selectionImage(for: option))
                                    .foregroundStyle(
                                        selection.contains(option.id)
                                            ? theme.accentColor
                                            : Color.secondary
                                    )
                                    .imageScale(.large)

                                VStack(alignment: .leading, spacing: 5) {
                                    HStack(alignment: .firstTextBaseline) {
                                        Text(option.title)
                                            .foregroundStyle(.primary)
                                            .multilineTextAlignment(.leading)
                                        Spacer()
                                        if showsResults {
                                            Text("\(option.voteCount) 票")
                                                .font(.caption.monospacedDigit())
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    if showsResults {
                                        ProgressView(value: voteFraction(
                                            for: option,
                                            in: group
                                        ))
                                        .tint(theme.accentColor)
                                        .accessibilityLabel("\(option.title) 得票比例")
                                        .accessibilityValue("\(option.voteCount) 票")
                                    }
                                }
                            }
                            .padding(.horizontal, 10)
                            .frame(minHeight: 44)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .background(
                            selection.contains(option.id)
                                ? theme.accentColor.opacity(0.12)
                                : Color.clear,
                            in: RoundedRectangle(cornerRadius: 7)
                        )
                        .disabled(optionIsDisabled(option, in: group))
                        .accessibilityLabel(option.title)
                        .accessibilityValue(accessibilityValue(for: option))
                        .accessibilityAddTraits(
                            selection.contains(option.id) ? .isSelected : []
                        )
                    }
                }
            }

            if !showsResults {
                Label(hiddenResultsMessage, systemImage: "eye.slash")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text("\(poll.participantCount) 人参与 · 共 \(poll.totalVoteCount) 票")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(selectionLimitMessage)
                    if let endsAt = poll.endsAt {
                        Text(
                            endsAt,
                            format: .dateTime
                                .year()
                                .month(.twoDigits)
                                .day(.twoDigits)
                                .hour(.twoDigits(amPM: .omitted))
                                .minute(.twoDigits)
                        )
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                Spacer()

                if isAcceptingResponses {
                    Button {
                        showsSubmissionConfirmation = true
                    } label: {
                        if isSubmitting {
                            HStack {
                                ProgressView()
                                    .controlSize(.small)
                                Text("提交中")
                            }
                        } else {
                            Text("提交投票")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!poll.containsValidSelection(selection) || isSubmitting)
                    .accessibilityIdentifier("topic-poll-submit")
                } else {
                    Label("投票已结束", systemImage: "clock.badge.xmark")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .background(
            theme.accentColor.opacity(0.045),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(theme.accentColor.opacity(0.25))
        }
        .confirmationDialog(
            "确认提交投票？",
            isPresented: $showsSubmissionConfirmation,
            titleVisibility: .visible
        ) {
            Button("提交投票") {
                submitSelection()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("NGA 投票提交后通常不能修改。")
        }
    }

    private var showsResults: Bool {
        poll.showsResults(at: .now)
    }

    private var isAcceptingResponses: Bool {
        poll.isAcceptingResponses(at: .now)
    }

    private var isSubmitting: Bool {
        model.thread.submittingPollTopicIDs.contains(poll.id)
    }

    private var selectionLimitMessage: String {
        if poll.groups.count > 1 {
            "每组最多选择 \(poll.maximumSelectionsPerGroup) 项"
        } else {
            "最多选择 \(poll.maximumSelectionsPerGroup) 项"
        }
    }

    private var hiddenResultsMessage: String {
        if poll.hidesResultsUntilEnd {
            "结果将在投票结束后显示"
        } else {
            "结果将在提交后显示"
        }
    }

    private func selectionImage(for option: TopicPoll.Option) -> String {
        let isSelected = selection.contains(option.id)
        if poll.maximumSelectionsPerGroup == 1 {
            return isSelected ? "largecircle.fill.circle" : "circle"
        }
        return isSelected ? "checkmark.square.fill" : "square"
    }

    private func optionIsDisabled(
        _ option: TopicPoll.Option,
        in group: TopicPoll.Group
    ) -> Bool {
        guard isAcceptingResponses, !isSubmitting else { return true }
        guard poll.maximumSelectionsPerGroup > 1,
              !selection.contains(option.id) else {
            return false
        }
        let groupOptionIDs = Set(group.options.map(\.id))
        return selection.intersection(groupOptionIDs).count
            >= poll.maximumSelectionsPerGroup
    }

    private func accessibilityValue(for option: TopicPoll.Option) -> String {
        var values = [selection.contains(option.id) ? "已选择" : "未选择"]
        if showsResults {
            values.append("\(option.voteCount) 票")
        }
        return values.joined(separator: "，")
    }

    private func voteFraction(
        for option: TopicPoll.Option,
        in group: TopicPoll.Group
    ) -> Double {
        guard group.voteCount > 0 else { return 0 }
        return Double(option.voteCount) / Double(group.voteCount)
    }

    private func toggleSelection(
        of option: TopicPoll.Option,
        in group: TopicPoll.Group
    ) {
        if selection.remove(option.id) != nil {
            return
        }

        let groupOptionIDs = Set(group.options.map(\.id))
        if poll.maximumSelectionsPerGroup == 1 {
            selection.subtract(groupOptionIDs)
        } else if selection.intersection(groupOptionIDs).count
                    >= poll.maximumSelectionsPerGroup {
            return
        }
        selection.insert(option.id)
    }

    private func submitSelection() {
        let submittedSelection = selection
        Task {
            if await model.thread.submitTopicPollVote(
                topicID: poll.id,
                selection: submittedSelection
            ) {
                selection.removeAll()
            }
        }
    }
}
