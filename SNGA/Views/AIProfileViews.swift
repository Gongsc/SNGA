import AppKit
import SwiftUI

struct AIProfileMenuView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.sngaTheme) private var theme
    @State private var showsClearConfirmation = false

    var body: some View {
        Group {
            if model.aiProfiles.records.isEmpty {
                ContentUnavailableView {
                    Label("还没有 AI 用户画像", systemImage: "sparkles")
                } description: {
                    Text("打开任意用户中心，手动生成后会保存在这里。")
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        Text("最近生成的用户画像")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.bottom, 4)
                            .accessibilityIdentifier("ai-profile-history-list")

                        ForEach(model.aiProfiles.records, id: \.id) { record in
                            HStack(spacing: 8) {
                                Button {
                                    model.aiProfiles.select(uid: record.uid)
                                } label: {
                                    AIProfileMenuRow(
                                        record: record,
                                        isSelected: model.aiProfiles.selectedUID == record.uid
                                    )
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button("删除画像", role: .destructive) {
                                        model.aiProfiles.delete(record)
                                    }
                                }
                                .accessibilityIdentifier("ai-profile-history-\(record.uid)")

                                Button("删除画像", systemImage: "trash", role: .destructive) {
                                    model.aiProfiles.delete(record)
                                }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.borderless)
                                .help("删除 \(record.displayName) 的画像")
                                .accessibilityIdentifier(
                                    "ai-profile-history-delete-\(record.uid)"
                                )
                            }
                        }
                    }
                    .padding(18)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.backgroundColor)
        .navigationTitle("")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            BottomActionBar {
                HStack {
                    Spacer()
                    Button("清空画像历史", systemImage: "trash", role: .destructive) {
                        showsClearConfirmation = true
                    }
                    .labelStyle(.iconOnly)
                    .help("清空画像历史")
                    .disabled(model.aiProfiles.records.isEmpty)
                    .accessibilityIdentifier("ai-profile-clear-all")
                }
            }
        }
        .confirmationDialog(
            "清空全部 AI 画像？",
            isPresented: $showsClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("清空全部画像", role: .destructive) {
                model.aiProfiles.clearAll()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("已保存的用户和画像结果都会从本机删除，不能撤销。")
        }
        .onAppear {
            model.aiProfiles.selectMostRecentIfNeeded()
        }
    }
}

private struct AIProfileMenuRow: View {
    @Environment(\.sngaTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let record: AIProfileSummaryRecord
    let isSelected: Bool
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: record.avatarURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .foregroundStyle(isSelected ? theme.onAccentColor.opacity(0.8) : .secondary)
            }
            .frame(width: 42, height: 42)
            .clipShape(.circle)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(record.displayName)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                Text("UID \(record.uid) · \(record.generatedAt.formatted(.relative(presentation: .named)))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(
                        isSelected ? theme.onAccentColor.opacity(0.78) : theme.secondaryForegroundColor
                    )
                    .lineLimit(1)
                Text(record.summary)
                    .font(.caption)
                    .foregroundStyle(
                        isSelected ? theme.onAccentColor.opacity(0.78) : theme.secondaryForegroundColor
                    )
                    .lineLimit(2)
            }

            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(
                    isSelected ? theme.onAccentColor.opacity(0.8) : theme.tertiaryForegroundColor
                )
                .accessibilityHidden(true)
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
        .accessibilityLabel(record.displayName)
        .accessibilityValue("UID \(record.uid)，生成于 \(record.generatedAt.formatted())")
    }
}

struct AIProfileDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.sngaTheme) private var theme
    @State private var showsDeleteConfirmation = false

    var body: some View {
        Group {
            if let uid = model.aiProfiles.selectedUID,
               model.aiProfiles.isShowingDetail {
                detail(uid: uid)
            } else {
                ContentUnavailableView(
                    "选择用户画像",
                    systemImage: "sparkles",
                    description: Text("从中栏选择最近用户，或在用户中心生成画像。")
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.backgroundColor)
        .confirmationDialog(
            "删除这条 AI 画像？",
            isPresented: $showsDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("删除画像", role: .destructive) {
                if let record { model.aiProfiles.delete(record) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只会删除本机保存的画像结果，不影响 NGA 用户资料。")
        }
    }

    private func detail(uid: Int64) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header(uid: uid)

                if isGenerating {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(model.aiProfiles.generationPhase?.title ?? "正在生成…")
                            .font(.callout.weight(.medium))
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("ai-profile-generating")
                }

                if let error = visibleError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                        .accessibilityIdentifier("ai-profile-error")
                }

                if !displayedText.isEmpty {
                    Text(displayedText)
                        .font(.body)
                        .lineSpacing(5)
                        .textSelection(.enabled)
                        .frame(maxWidth: 760, alignment: .leading)
                        .accessibilityLabel("AI 用户画像")
                        .accessibilityIdentifier("ai-profile-summary")
                } else if !isGenerating {
                    ContentUnavailableView(
                        "没有可显示的画像",
                        systemImage: "sparkles",
                        description: Text("可以检查设置后重新生成。")
                    )
                    .frame(maxWidth: .infinity, minHeight: 260)
                }

                if let record, !isGenerating {
                    metadata(record)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            BottomActionBar {
                HStack(spacing: 10) {
                    if !displayedText.isEmpty {
                        Button("复制画像", systemImage: "doc.on.doc") {
                            copySummary()
                        }
                        .accessibilityIdentifier("ai-profile-copy")
                    }
                    Spacer()
                    if isGenerating {
                        Button("取消生成", systemImage: "stop.circle") {
                            model.aiProfiles.cancelGeneration()
                        }
                        .accessibilityIdentifier("ai-profile-cancel")
                    } else {
                        Button("重新生成", systemImage: "arrow.clockwise") {
                            regenerate()
                        }
                        .disabled(model.session.activeService == nil)
                        .accessibilityIdentifier("ai-profile-regenerate")

                        if record != nil {
                            Button("删除画像", systemImage: "trash", role: .destructive) {
                                showsDeleteConfirmation = true
                            }
                            .accessibilityIdentifier("ai-profile-delete")
                        }
                    }
                }
            }
        }
    }

    private func header(uid: Int64) -> some View {
        HStack(spacing: 14) {
            AsyncImage(url: record?.avatarURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .foregroundStyle(.secondary)
            }
            .frame(width: 58, height: 58)
            .clipShape(.circle)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Label("AI 生成", systemImage: "sparkles")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.accentColor)
                Text(displayName(uid: uid))
                    .font(.title2.bold())
                Text("UID \(uid)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("ai-profile-detail")
    }

    private func metadata(_ record: AIProfileSummaryRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Text("由 \(record.model) 生成 · \(record.generatedAt.formatted())")
            Text("分析样本：\(record.topicCount) 个话题、\(record.replyCount) 条回复")
            if record.wasTruncated {
                Label("数据超过 64 KiB，已优先保留较新的记录", systemImage: "scissors")
            }
            Text("AI 结果可能存在错误，仅供参考。")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
    }

    private var record: AIProfileSummaryRecord? {
        model.aiProfiles.selectedRecord
    }

    private var isGenerating: Bool {
        model.aiProfiles.generatingUID == model.aiProfiles.selectedUID
    }

    private var displayedText: String {
        if isGenerating { return model.aiProfiles.streamedText }
        return record?.summary ?? model.aiProfiles.streamedText
    }

    private var visibleError: String? {
        guard model.aiProfiles.errorUID == model.aiProfiles.selectedUID else { return nil }
        return model.aiProfiles.errorMessage
    }

    private func displayName(uid: Int64) -> String {
        if let record { return record.displayName }
        if model.currentProfile?.uid == uid { return model.currentProfile?.displayName ?? "NGA \(uid)" }
        return "NGA \(uid)"
    }

    private func regenerate() {
        guard AISettings.isConfigured else {
            model.openSettings(section: .ai)
            return
        }
        model.aiProfiles.regenerateSelected()
    }

    private func copySummary() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(displayedText, forType: .string)
    }
}

struct AIProfileUserCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.sngaTheme) private var theme
    let profile: Profile

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.title2)
                    .foregroundStyle(theme.accentColor)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("AI 用户画像")
                        .font(.headline)
                        .accessibilityIdentifier("user-center-ai-profile-card")
                    Text("分析公开资料以及最近两页话题和回复")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Text("生成时会把这些资料发送到你在设置中配置的 AI 服务；结果仅供参考。")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                if isGenerating {
                    ProgressView().controlSize(.small)
                    Text(model.aiProfiles.generationPhase?.title ?? "正在生成…")
                        .font(.callout)
                    Spacer()
                    Button("查看") {
                        model.aiProfiles.select(uid: profile.uid)
                    }
                    Button("取消") {
                        model.aiProfiles.cancelGeneration()
                    }
                } else if !AISettings.isConfigured {
                    Button("前往 AI 设置", systemImage: "gearshape") {
                        model.openSettings(section: .ai)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("user-center-ai-settings")
                } else if model.aiProfiles.record(for: profile.uid) != nil {
                    Button("查看已有画像", systemImage: "sparkles") {
                        model.aiProfiles.select(uid: profile.uid)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("user-center-ai-view")
                    Button("重新生成", systemImage: "arrow.clockwise") {
                        model.aiProfiles.generate(uid: profile.uid, fallbackProfile: profile)
                    }
                    .accessibilityIdentifier("user-center-ai-regenerate")
                } else {
                    Button("生成 AI 画像", systemImage: "sparkles") {
                        model.aiProfiles.generate(uid: profile.uid, fallbackProfile: profile)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("user-center-ai-generate")
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surfaceColor, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(theme.separatorColor)
        }
    }

    private var isGenerating: Bool {
        model.aiProfiles.generatingUID == profile.uid
    }
}
