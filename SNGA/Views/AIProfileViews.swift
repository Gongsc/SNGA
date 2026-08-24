import AppKit
import SwiftUI

struct AIProfileMarkdownBlock: Equatable {
    enum Kind: Equatable {
        case heading(level: Int)
        case paragraph
        case unorderedListItem(depth: Int)
        case orderedListItem(marker: String, depth: Int)
        case quote
        case code(language: String?)
        case divider
    }

    let kind: Kind
    let content: String
}

enum AIProfileMarkdown {
    static func blocks(from markdown: String) -> [AIProfileMarkdownBlock] {
        let lines = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        var result: [AIProfileMarkdownBlock] = []
        var paragraphLines: [String] = []
        var quoteLines: [String] = []
        var codeLines: [String] = []
        var codeLanguage: String?
        var codeFence: String?

        func flushParagraph() {
            guard !paragraphLines.isEmpty else { return }
            result.append(.init(kind: .paragraph, content: paragraphLines.joined(separator: "\n")))
            paragraphLines.removeAll(keepingCapacity: true)
        }

        func flushQuote() {
            guard !quoteLines.isEmpty else { return }
            result.append(.init(kind: .quote, content: quoteLines.joined(separator: "\n")))
            quoteLines.removeAll(keepingCapacity: true)
        }

        func flushTextBlocks() {
            flushParagraph()
            flushQuote()
        }

        func flushCode() {
            result.append(.init(
                kind: .code(language: codeLanguage),
                content: codeLines.joined(separator: "\n")
            ))
            codeLines.removeAll(keepingCapacity: true)
            codeLanguage = nil
            codeFence = nil
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if let codeFence {
                if trimmed.hasPrefix(codeFence) {
                    flushCode()
                } else {
                    codeLines.append(line)
                }
                continue
            }

            if let fence = fencePrefix(in: trimmed) {
                flushTextBlocks()
                codeFence = fence
                let language = trimmed.dropFirst(fence.count).trimmingCharacters(in: .whitespaces)
                codeLanguage = language.isEmpty ? nil : language
                continue
            }

            if trimmed.isEmpty {
                flushTextBlocks()
                continue
            }

            if let heading = heading(in: trimmed) {
                flushTextBlocks()
                result.append(.init(
                    kind: .heading(level: heading.level),
                    content: heading.content
                ))
                continue
            }

            if isDivider(trimmed) {
                flushTextBlocks()
                result.append(.init(kind: .divider, content: ""))
                continue
            }

            if trimmed == ">" || trimmed.hasPrefix("> ") {
                flushParagraph()
                quoteLines.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
                continue
            }

            if let item = unorderedListItem(in: line) {
                flushTextBlocks()
                result.append(.init(
                    kind: .unorderedListItem(depth: item.depth),
                    content: item.content
                ))
                continue
            }

            if let item = orderedListItem(in: line) {
                flushTextBlocks()
                result.append(.init(
                    kind: .orderedListItem(marker: item.marker, depth: item.depth),
                    content: item.content
                ))
                continue
            }

            flushQuote()
            paragraphLines.append(trimmed)
        }

        flushTextBlocks()
        if codeFence != nil { flushCode() }
        return result
    }

    static func attributedText(from markdown: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        return (try? AttributedString(markdown: markdown, options: options))
            ?? AttributedString(markdown)
    }

    static func preview(from markdown: String) -> String {
        blocks(from: markdown)
            .filter { $0.kind != .divider }
            .map { String(attributedText(from: $0.content).characters) }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func fencePrefix(in line: String) -> String? {
        if line.hasPrefix("```") { return "```" }
        if line.hasPrefix("~~~") { return "~~~" }
        return nil
    }

    private static func heading(in line: String) -> (level: Int, content: String)? {
        let level = line.prefix { $0 == "#" }.count
        guard (1...6).contains(level) else { return nil }
        let remainder = line.dropFirst(level)
        guard remainder.first?.isWhitespace == true else { return nil }
        return (level, remainder.trimmingCharacters(in: .whitespaces))
    }

    private static func isDivider(_ line: String) -> Bool {
        let characters = line.filter { !$0.isWhitespace }
        guard characters.count >= 3, let first = characters.first,
              first == "-" || first == "*" || first == "_" else { return false }
        return characters.allSatisfy { $0 == first }
    }

    private static func indentationDepth(in line: String) -> Int {
        var spaces = 0
        for character in line {
            if character == " " {
                spaces += 1
            } else if character == "\t" {
                spaces += 2
            } else {
                break
            }
        }
        return min(spaces / 2, 4)
    }

    private static func unorderedListItem(in line: String) -> (depth: Int, content: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2,
              let marker = trimmed.first,
              marker == "-" || marker == "*" || marker == "+" else { return nil }
        let remainder = trimmed.dropFirst()
        guard remainder.first?.isWhitespace == true else { return nil }
        return (
            indentationDepth(in: line),
            remainder.trimmingCharacters(in: .whitespaces)
        )
    }

    private static func orderedListItem(
        in line: String
    ) -> (marker: String, depth: Int, content: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let characters = Array(trimmed)
        var digitCount = 0
        while digitCount < characters.count, characters[digitCount].isNumber {
            digitCount += 1
        }
        guard digitCount > 0, digitCount + 1 < characters.count,
              characters[digitCount] == "." || characters[digitCount] == ")",
              characters[digitCount + 1].isWhitespace else { return nil }

        return (
            String(characters.prefix(digitCount + 1)),
            indentationDepth(in: line),
            String(characters.dropFirst(digitCount + 2))
        )
    }
}

private struct AIProfileMarkdownView: View {
    @Environment(\.sngaTheme) private var theme
    let markdown: String

    private var blocks: [AIProfileMarkdownBlock] {
        AIProfileMarkdown.blocks(from: markdown)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(blocks.indices, id: \.self) { index in
                blockView(blocks[index])
            }
        }
        .frame(maxWidth: 760, alignment: .leading)
        .textSelection(.enabled)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ai-profile-summary")
    }

    @ViewBuilder
    private func blockView(_ block: AIProfileMarkdownBlock) -> some View {
        switch block.kind {
        case let .heading(level):
            Text(AIProfileMarkdown.attributedText(from: block.content))
                .font(headingFont(level))
                .foregroundStyle(theme.foregroundColor)
                .padding(.top, level <= 2 ? 7 : 3)
                .accessibilityAddTraits(.isHeader)

        case .paragraph:
            Text(AIProfileMarkdown.attributedText(from: block.content))
                .font(.body)
                .lineSpacing(5)
                .foregroundStyle(theme.foregroundColor)

        case let .unorderedListItem(depth):
            listRow(marker: "•", depth: depth, content: block.content)

        case let .orderedListItem(marker, depth):
            listRow(marker: marker, depth: depth, content: block.content)

        case .quote:
            Text(AIProfileMarkdown.attributedText(from: block.content))
                .font(.body)
                .lineSpacing(4)
                .foregroundStyle(theme.secondaryForegroundColor)
                .padding(.leading, 13)
                .padding(.vertical, 3)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(theme.accentColor.opacity(0.65))
                        .frame(width: 3)
                }

        case let .code(language):
            VStack(alignment: .leading, spacing: 7) {
                if let language, !language.isEmpty {
                    Text(language.uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(theme.secondaryForegroundColor)
                }
                Text(block.content)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(theme.foregroundColor)
                    .lineSpacing(3)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.fillColor, in: RoundedRectangle(cornerRadius: 9))
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .stroke(theme.separatorColor)
            }

        case .divider:
            Divider()
                .padding(.vertical, 5)
        }
    }

    private func listRow(marker: String, depth: Int, content: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(marker)
                .font(.body.monospacedDigit())
                .foregroundStyle(theme.secondaryForegroundColor)
                .frame(minWidth: 17, alignment: .trailing)
                .accessibilityHidden(true)
            Text(AIProfileMarkdown.attributedText(from: content))
                .font(.body)
                .lineSpacing(4)
                .foregroundStyle(theme.foregroundColor)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, CGFloat(depth) * 18)
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .title2.bold()
        case 2: .title3.bold()
        case 3: .headline
        default: .subheadline.weight(.semibold)
        }
    }
}

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
                Text(AIProfileMarkdown.preview(from: record.summary))
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
                    AIProfileMarkdownView(markdown: displayedText)
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
        model.regenerateSelectedAIProfile()
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
                    Text("分析公开资料以及用户中心已加载的发布记录")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Text("生成不会额外请求 NGA；已加载的资料会发送到你配置的 AI 服务，结果仅供参考。")
                .font(.callout)
                .foregroundStyle(.secondary)

            let counts = model.cachedAIProfileSampleCounts(uid: profile.uid)
            Text("当前样本：\(counts.topics) 个话题、\(counts.replies) 条回复")
                .font(.caption)
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
                        model.generateAIProfile(for: profile)
                    }
                    .accessibilityIdentifier("user-center-ai-regenerate")
                } else {
                    Button("生成 AI 画像", systemImage: "sparkles") {
                        model.generateAIProfile(for: profile)
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
