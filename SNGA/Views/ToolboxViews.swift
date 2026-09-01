import AppKit
import ImageIO
import SwiftUI

struct ToolboxMenuView: View {
    @Environment(ToolboxStore.self) private var toolbox
    @Environment(\.sngaTheme) private var theme

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                Text("每日简报、科技资讯与热门榜单")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.bottom, 4)

                ForEach(ToolboxFeed.allCases) { feed in
                    Button {
                        toolbox.selectedFeed = feed
                    } label: {
                        ToolboxMenuRow(
                            feed: feed,
                            isSelected: toolbox.selectedFeed == feed
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("toolbox-feed-\(feed.rawValue)")
                }
            }
            .padding(18)
        }
        .accessibilityIdentifier("toolbox-menu-scroll")
        .background(theme.backgroundColor)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle("")
    }
}

private struct ToolboxMenuRow: View {
    @Environment(\.sngaTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let feed: ToolboxFeed
    let isSelected: Bool
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: feed.systemImage)
                .font(.title3)
                .foregroundStyle(isSelected ? .white : theme.accentColor)
                .frame(width: 38, height: 38)
                .background(
                    isSelected ? theme.accentColor : theme.accentColor.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(feed.title)
                        .font(.body.weight(.semibold))
                    Text(feed.updateFrequency)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            isSelected ? Color.white.opacity(0.18) : theme.accentColor.opacity(0.12),
                            in: Capsule()
                        )
                }
                Text(feed.subtitle)
                    .font(.caption)
                    .foregroundStyle(isSelected ? Color.white.opacity(0.78) : Color.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(isSelected ? Color.white.opacity(0.8) : Color.secondary)
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isSelected
                ? theme.accentColor
                : (isHovered ? theme.hoverFillColor : theme.fillColor),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(
                    isSelected ? Color.clear : theme.separatorColor
                )
        }
        .contentShape(.rect)
        .onHover { isHovered = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: isHovered)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: isSelected)
    }
}

struct ToolboxFeedView: View {
    @Environment(ToolboxStore.self) private var toolbox
    @Environment(\.sngaTheme) private var theme
    @Environment(\.openURL) private var openURL

    let feed: ToolboxFeed
    private let service: ToolboxAPIService

    @State private var content: ToolboxContent?
    @State private var loadedFeed: ToolboxFeed?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var activeRequestID: UUID?

    init(
        feed: ToolboxFeed,
        service: ToolboxAPIService = ToolboxAPIService()
    ) {
        self.feed = feed
        self.service = service
    }

    var body: some View {
        Group {
            if let content, loadedFeed == feed {
                contentView(content)
            } else if let errorMessage, !isLoading {
                ContentUnavailableView {
                    Label("资讯加载失败", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("重试") {
                        toolbox.refresh()
                    }
                }
            } else {
                ProgressView("正在加载\(feed.title)…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.backgroundColor)
        .overlay(alignment: .top) {
            if isLoading, content != nil {
                ProgressView("正在刷新…")
                    .controlSize(.small)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, 10)
            } else if let errorMessage, content != nil {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, 10)
            }
        }
        .navigationTitle(feed.title)
        .task(id: "\(feed.rawValue)-\(toolbox.refreshRevision)") {
            await load()
        }
        .accessibilityIdentifier("toolbox-feed-detail-\(feed.rawValue)")
        .ignoresSafeArea(.container, edges: .top)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            BottomActionBar {
                HStack {
                    Spacer()
                    Button {
                        toolbox.refresh()
                    } label: {
                        Label("刷新\(feed.title)", systemImage: "arrow.clockwise")
                    }
                    .labelStyle(.iconOnly)
                    .help("刷新\(feed.title)")
                    .disabled(isLoading)
                    .accessibilityIdentifier("toolbox-refresh")
                }
            }
        }
    }

    @ViewBuilder
    private func contentView(_ content: ToolboxContent) -> some View {
        switch content {
        case let .worldBriefing(briefing):
            WorldBriefingView(briefing: briefing) {
                await load()
            }
        case let .articles(articles):
            if articles.isEmpty {
                ContentUnavailableView {
                    Label(emptyTitle, systemImage: feed.systemImage)
                } description: {
                    Text(emptyDescription)
                } actions: {
                    Button("重新获取") {
                        toolbox.refresh()
                    }
                }
            } else {
                articleList(articles)
            }
        }
    }

    private func articleList(_ articles: [ToolboxArticle]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ToolboxFeedHeader(feed: feed, itemCount: articles.count)

                ForEach(articles) { article in
                    Group {
                        if let link = article.link {
                            Button {
                                openURL(link)
                            } label: {
                                ToolboxArticleRow(
                                    article: article,
                                    summaryLineLimit: summaryLineLimit
                                )
                            }
                            .buttonStyle(.plain)
                            .help("在默认浏览器中打开")
                        } else {
                            ToolboxArticleRow(
                                article: article,
                                summaryLineLimit: summaryLineLimit
                            )
                        }
                    }
                    .accessibilityIdentifier("toolbox-article-\(article.id)")
                }

                Text("数据由 60s API 提供")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .padding(18)
        }
        .refreshable {
            await load()
        }
    }

    private var emptyTitle: String {
        switch feed {
        case .aiNews: "今日暂无重大 AI 资讯"
        case .itNews: "暂无实时 IT 资讯"
        case .worldBriefing: "今日简报尚未更新"
        case .douyinHot, .rednoteHot, .bilibiliHot, .weiboHot, .zhihuHot:
            "\(feed.title)暂无内容"
        }
    }

    private var emptyDescription: String {
        switch feed {
        case .aiNews: "AI 快报并非每天都有，可以稍后再来看看。"
        case .itNews: "实时资讯暂时为空，请稍后刷新。"
        case .worldBriefing: "每天 60 秒读懂世界尚未发布今日内容。"
        case .douyinHot, .rednoteHot, .bilibiliHot, .weiboHot, .zhihuHot:
            "榜单暂时不可用，请稍后刷新。"
        }
    }

    private var summaryLineLimit: Int? {
        switch feed {
        case .itNews: 5
        case .zhihuHot: 4
        default: nil
        }
    }

    private func load() async {
        let requestID = UUID()
        activeRequestID = requestID
        if loadedFeed != feed {
            content = nil
            loadedFeed = nil
        }
        isLoading = true
        errorMessage = nil
        defer {
            if activeRequestID == requestID {
                isLoading = false
            }
        }

        do {
            let result = try await service.load(feed)
            guard !Task.isCancelled, activeRequestID == requestID else { return }
            content = result
            loadedFeed = feed
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, activeRequestID == requestID else { return }
            errorMessage = error.localizedDescription
        }
    }
}

private struct ToolboxFeedHeader: View {
    @Environment(\.sngaTheme) private var theme
    let feed: ToolboxFeed
    let itemCount: Int

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: feed.systemImage)
                .font(.title2)
                .foregroundStyle(theme.accentColor)
                .frame(width: 46, height: 46)
                .background(theme.accentSoftColor, in: RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 3) {
                Text(feed.title)
                    .font(.title2.bold())
                Text("\(feed.updateFrequency) · \(itemCount) 条资讯")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.bottom, 4)
    }
}

private struct ToolboxArticleRow: View {
    @Environment(\.sngaTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let article: ToolboxArticle
    let summaryLineLimit: Int?
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if let rank = article.rank {
                    Text("\(rank)")
                        .font(.caption.bold().monospacedDigit())
                        .foregroundStyle(rank <= 3 ? Color.white : theme.accentColor)
                        .frame(width: 26, height: 22)
                        .background(
                            rank <= 3 ? theme.accentColor : theme.accentColor.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 6)
                        )
                }
                Text(article.title)
                    .font(.headline)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                if article.link != nil {
                    Image(systemName: "arrow.up.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }

            if !article.summary.isEmpty {
                Text(article.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(summaryLineLimit)
                    .multilineTextAlignment(.leading)
            }

            HStack(spacing: 8) {
                if let source = article.source {
                    Text(source)
                }
                if article.source != nil, article.publishedText != nil {
                    Text("·")
                }
                if let publishedText = article.publishedText {
                    Text(publishedText)
                }
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isHovered ? theme.elevatedSurfaceColor : theme.surfaceColor,
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(theme.separatorColor)
        }
        .contentShape(.rect)
        .onHover { isHovered = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovered)
    }
}

private struct WorldBriefingView: View {
    @Environment(\.sngaTheme) private var theme
    @Environment(\.openURL) private var openURL
    let briefing: WorldBriefing
    let refresh: () async -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 13) {
                    Image(systemName: ToolboxFeed.worldBriefing.systemImage)
                        .font(.title2)
                        .foregroundStyle(theme.accentColor)
                        .frame(width: 46, height: 46)
                        .background(
                            theme.accentColor.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 12)
                        )

                    VStack(alignment: .leading, spacing: 3) {
                        Text(ToolboxFeed.worldBriefing.title)
                            .font(.title2.bold())
                        Text(dateDescription)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                if let imageURL = briefing.imageURL ?? briefing.coverURL {
                    WorldBriefingImageCard(imageURL: imageURL)
                }

                VStack(alignment: .leading, spacing: 0) {
                    ForEach(briefing.news.enumerated(), id: \.offset) { index, item in
                        HStack(alignment: .top, spacing: 12) {
                            Text("\(index + 1)")
                                .font(.caption.bold().monospacedDigit())
                                .foregroundStyle(theme.onAccentColor)
                                .frame(width: 24, height: 24)
                                .background(theme.accentColor, in: Circle())
                            Text(item)
                                .font(.body)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)

                        if index < briefing.news.count - 1 {
                            Divider()
                                .padding(.leading, 50)
                        }
                    }
                }
                .background(theme.surfaceColor, in: RoundedRectangle(cornerRadius: 14))
                .overlay {
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(theme.separatorColor)
                }

                if let tip = briefing.tip {
                    Label {
                        Text(tip)
                            .italic()
                            .textSelection(.enabled)
                    } icon: {
                        Image(systemName: "quote.opening")
                            .foregroundStyle(theme.accentColor)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                }

                HStack {
                    Text("数据由 60s API 提供")
                    Spacer()
                    if let sourceURL = briefing.sourceURL {
                        Button("查看原文", systemImage: "arrow.up.right") {
                            openURL(sourceURL)
                        }
                        .buttonStyle(.link)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.vertical, 8)
            }
            .padding(18)
        }
        .refreshable {
            await refresh()
        }
    }

    private var dateDescription: String {
        [briefing.date, briefing.dayOfWeek, briefing.lunarDate]
            .compactMap { $0 }
            .joined(separator: " · ")
    }
}

private struct WorldBriefingImageCard: View {
    @Environment(\.sngaTheme) private var theme
    let imageURL: URL
    @State private var isCopying = false
    @State private var copyErrorMessage: String?

    var body: some View {
        ZStack {
            AsyncImage(url: imageURL) { phase in
                switch phase {
                case let .success(image):
                    image
                        .resizable()
                        .scaledToFit()
                case .failure:
                    Image(systemName: "photo")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 120)
                case .empty:
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 120)
                @unknown default:
                    EmptyView()
                }
            }
            .allowsHitTesting(false)
            .accessibilityLabel("每日 60 秒读懂世界图片")

            Color.clear
                .contentShape(Rectangle())
        }
        .frame(maxWidth: .infinity)
        .background(theme.surfaceColor)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contextMenu {
            Button(
                "复制图片",
                systemImage: "doc.on.doc",
                action: copyImage
            )
            .disabled(isCopying)
        }
        .alert(
            "无法复制图片",
            isPresented: Binding(
                get: { copyErrorMessage != nil },
                set: { if !$0 { copyErrorMessage = nil } }
            )
        ) {
            Button("好") { copyErrorMessage = nil }
        } message: {
            Text(copyErrorMessage ?? "")
        }
    }

    private func copyImage() {
        guard !isCopying else { return }
        isCopying = true
        Task { @MainActor in
            do {
                try await ToolboxImageClipboard.copy(from: imageURL)
                isCopying = false
            } catch {
                isCopying = false
                copyErrorMessage = error.localizedDescription
            }
        }
    }
}

enum ToolboxImageClipboardError: LocalizedError, Equatable {
    case invalidResponse
    case server(Int)
    case emptyImage
    case imageTooLarge
    case unsupportedImage
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "图片服务返回了无法识别的响应。"
        case let .server(status): "图片下载失败（HTTP \(status)）。"
        case .emptyImage: "下载到的图片为空。"
        case .imageTooLarge: "图片超过 25 MB，无法复制。"
        case .unsupportedImage: "下载内容不是受支持的图片格式。"
        case .writeFailed: "系统剪贴板暂时无法写入图片。"
        }
    }
}

enum ToolboxImageClipboard {
    private static let maximumImageByteCount = 25 * 1_024 * 1_024

    @MainActor
    static func copy(from url: URL) async throws {
        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        request.setValue("SNGA/1.0 (macOS; native client)", forHTTPHeaderField: "User-Agent")
        request.setValue("image/*", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw ToolboxImageClipboardError.invalidResponse
        }
        guard (200..<300).contains(response.statusCode) else {
            throw ToolboxImageClipboardError.server(response.statusCode)
        }
        guard !data.isEmpty else {
            throw ToolboxImageClipboardError.emptyImage
        }
        guard data.count <= maximumImageByteCount else {
            throw ToolboxImageClipboardError.imageTooLarge
        }
        guard let pasteboardType = pasteboardType(for: data) else {
            throw ToolboxImageClipboardError.unsupportedImage
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setData(data, forType: pasteboardType) else {
            throw ToolboxImageClipboardError.writeFailed
        }
    }

    static func pasteboardType(for data: Data) -> NSPasteboard.PasteboardType? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let typeIdentifier = CGImageSourceGetType(source) else {
            return nil
        }
        return NSPasteboard.PasteboardType(typeIdentifier as String)
    }
}
