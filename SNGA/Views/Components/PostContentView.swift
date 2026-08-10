import AppKit
import SwiftUI

/// 楼层正文的原生渲染。
///
/// 只负责 `PostContentBuilder` 能够完整还原的内容（文字样式、链接、表情、引用）。
/// 复杂楼层不会走到这里，而是继续由 `PostWebView` 渲染。
struct PostContentView: View {
    let content: PostContent
    var onOpenLink: @MainActor (URL) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PostBlockListView(blocks: content.blocks, onOpenLink: onOpenLink)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }
}

private struct PostBlockListView: View {
    @Environment(\.sngaTheme) private var theme
    let blocks: [PostBlock]
    let onOpenLink: @MainActor (URL) -> Void

    var body: some View {
        ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
            switch block {
            case let .paragraph(paragraph):
                PostParagraphView(paragraph: paragraph, onOpenLink: onOpenLink)
            case let .quote(nested):
                quote(nested)
            }
        }
    }

    private func quote(_ nested: [PostBlock]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            PostBlockListView(blocks: nested, onOpenLink: onOpenLink)
        }
        .padding(.vertical, 6)
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.07))
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(theme.accentColor)
                .frame(width: 3)
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

private struct PostParagraphView: View {
    @Environment(\.sngaTheme) private var theme
    let paragraph: PostParagraph
    let onOpenLink: @MainActor (URL) -> Void

    private static let baseFontSize: CGFloat = 14

    var body: some View {
        // 读取 shared store 的属性发生在 body 求值期间，@Observable 会据此登记依赖，
        // 表情下载完成后这里会自动重绘。
        let emoticons = EmoticonImageStore.shared
        text(emoticons: emoticons)
            .lineSpacing(2)
            .multilineTextAlignment(textAlignment)
            .frame(maxWidth: .infinity, alignment: frameAlignment)
            .environment(\.openURL, OpenURLAction { url in
                onOpenLink(url)
                return .handled
            })
    }

    /// 把所有片段拼成一个 `Text`，让换行与排版和整段文字保持一致。
    private func text(emoticons: EmoticonImageStore) -> Text {
        paragraph.segments.reduce(Text(verbatim: "")) { result, segment in
            result + rendered(segment, emoticons: emoticons)
        }
    }

    private func rendered(
        _ segment: PostSegment,
        emoticons: EmoticonImageStore
    ) -> Text {
        switch segment {
        case let .text(value, style):
            Text(attributed(value, style: style))
        case let .emoticon(url):
            emoticon(url, emoticons: emoticons)
        }
    }

    private func attributed(
        _ value: String,
        style: PostTextStyle
    ) -> AttributedString {
        var attributed = AttributedString(value)
        let size = Self.baseFontSize * sizeScale(style)
        var font = Font.system(
            size: size,
            design: style.isMonospaced ? .monospaced : .default
        )
        if style.isBold { font = font.bold() }
        if style.isItalic { font = font.italic() }
        attributed.font = font

        if let link = style.link {
            attributed.link = link
            attributed.foregroundColor = theme.accentColor
            attributed.underlineStyle = .single
        } else if let color = style.color {
            attributed.foregroundColor = color.swiftUIColor
        }
        if style.isUnderlined { attributed.underlineStyle = .single }
        if style.isStruckThrough { attributed.strikethroughStyle = .single }
        return attributed
    }

    private func sizeScale(_ style: PostTextStyle) -> CGFloat {
        guard let percent = style.sizePercent else { return 1 }
        return CGFloat(min(max(percent, 50), 200)) / 100
    }

    private func emoticon(
        _ url: URL,
        emoticons: EmoticonImageStore
    ) -> Text {
        guard let image = emoticons.image(for: url) else {
            // 还没下载完时先留一个空位，避免图片到达时整段文字重排跳动。
            return Text(verbatim: " ")
        }
        return Text(Image(nsImage: image))
    }

    private var textAlignment: TextAlignment {
        switch paragraph.alignment {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    private var frameAlignment: Alignment {
        switch paragraph.alignment {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
}

extension PostTextColor {
    var swiftUIColor: Color {
        switch self {
        case .red: Color(nsColor: .systemRed)
        case .orange: Color(nsColor: .systemOrange)
        case .orangered: Color(red: 1, green: 0.27, blue: 0)
        case .green: Color(nsColor: .systemGreen)
        case .teal: Color(nsColor: .systemTeal)
        case .blue: Color(nsColor: .systemBlue)
        case .skyblue: Color(red: 0.53, green: 0.81, blue: 0.92)
        case .darkblue: Color(red: 0, green: 0, blue: 0.55)
        case .royalblue: Color(red: 0.25, green: 0.41, blue: 0.88)
        case .purple: Color(nsColor: .systemPurple)
        case .deeppink: Color(red: 1, green: 0.08, blue: 0.58)
        case .chocolate: Color(red: 0.82, green: 0.41, blue: 0.12)
        case .sienna: Color(red: 0.63, green: 0.32, blue: 0.18)
        case .gray: Color(nsColor: .systemGray)
        case .silver: Color(red: 0.75, green: 0.75, blue: 0.75)
        case .white: Color.white
        }
    }
}
