import AppKit
import SwiftUI

/// 楼层正文的原生渲染。
///
/// 只负责 `PostContentBuilder` 能够完整还原的内容（文字样式、链接、表情、引用、
/// 配图）。含表格、折叠块、游戏卡片等复杂结构的楼层不会走到这里，而是继续由
/// `PostWebView` 渲染。
struct PostContentView: View {
    let content: PostContent
    var imageFreeMode = false
    var onOpenLink: @MainActor (URL) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PostBlockListView(
                blocks: content.blocks,
                imageFreeMode: imageFreeMode,
                onOpenLink: onOpenLink
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PostBlockListView: View {
    @Environment(\.sngaTheme) private var theme
    let blocks: [PostBlock]
    let imageFreeMode: Bool
    let onOpenLink: @MainActor (URL) -> Void

    var body: some View {
        ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
            switch block {
            case let .paragraph(paragraph):
                PostParagraphView(paragraph: paragraph, onOpenLink: onOpenLink)
            case let .quote(nested):
                quote(nested)
            case let .image(image):
                PostImageView(image: image, imageFreeMode: imageFreeMode)
            }
        }
    }

    private func quote(_ nested: [PostBlock]) -> some View {
        let split = QuoteAttribution.split(nested)
        return VStack(alignment: .leading, spacing: 6) {
            if let attribution = split.attribution {
                PostParagraphView(
                    paragraph: attribution,
                    emphasis: .quoteAttribution,
                    onOpenLink: onOpenLink
                )
            }
            PostBlockListView(
                blocks: split.body,
                imageFreeMode: imageFreeMode,
                onOpenLink: onOpenLink
            )
        }
        .padding(.vertical, 7)
        .padding(.leading, 11)
        .padding(.trailing, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.quoteBackgroundColor)
        // 圆角只给右边：左边整条留给竖线，跟着圆下去会把它削成一段弧。
        .clipShape(.rect(bottomTrailingRadius: 6, topTrailingRadius: 6))
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(theme.quoteRailColor)
                .frame(width: 3)
        }
        // 楼层里块与块之间是 6 点，引用上下各补一点，和网页版的
        // `margin:8px 0 12px` 对齐 —— 下方留得多一些，引用才不会和
        // 紧跟其后的回复正文黏成一段。
        .padding(.top, 2)
        .padding(.bottom, 6)
    }
}

/// 引用块的抬头与被引正文。
///
/// NGA 的引用抬头 —— 真 `[quote]` 自带的，和 `PostQuoteExpander` 展开出来的，
/// 形状一样 —— 是段首一串加粗片段，中间必有一个指向被引楼层的 `[pid]` 回链，
/// 被引正文以空行跟在同一个段落里。切开之后抬头才能压成次级样式；切不出来
/// （作者自己写的粗体开头，或者引用里压根没有抬头）就原样渲染。
enum QuoteAttribution {
    struct Split {
        var attribution: PostParagraph?
        var body: [PostBlock]
    }

    static func split(_ blocks: [PostBlock]) -> Split {
        guard case let .paragraph(first)? = blocks.first else {
            return Split(attribution: nil, body: blocks)
        }

        var heading: [PostSegment] = []
        var remainder: [PostSegment] = []
        var reachedBody = false
        for segment in first.segments {
            if !reachedBody, case let .text(_, style) = segment, style.isBold {
                heading.append(segment)
                continue
            }
            reachedBody = true
            remainder.append(segment)
        }

        // 回链是抬头唯一可靠的标志。没有它的加粗开头只是作者写的粗体，
        // 压成小字会把人家的正文吃掉一句。
        let referencesPost = heading.contains { segment in
            guard case let .text(_, style) = segment else { return false }
            return style.link != nil
        }
        guard referencesPost else {
            return Split(attribution: nil, body: blocks)
        }

        var body = Array(blocks.dropFirst())
        let trimmed = trimmingLeadingBreaks(remainder)
        if !trimmed.isEmpty {
            body.insert(
                .paragraph(PostParagraph(segments: trimmed, alignment: first.alignment)),
                at: 0
            )
        }
        return Split(
            attribution: PostParagraph(segments: heading, alignment: first.alignment),
            body: body
        )
    }

    /// 抬头和被引正文之间的空行只是分隔，切开之后不该留在正文段首。
    /// 只吃换行：全角空格是作者写的缩进，`PostContentBuilder` 特意保住了它。
    private static func trimmingLeadingBreaks(_ segments: [PostSegment]) -> [PostSegment] {
        var segments = segments
        while let first = segments.first {
            guard case let .text(value, style) = first else { break }
            let trimmed = value.drop { $0 == "\n" || $0 == "\r" }
            guard trimmed.isEmpty else {
                segments[0] = .text(String(trimmed), style)
                break
            }
            segments.removeFirst()
        }
        return segments
    }
}

/// 段落的排版档位。
///
/// 引用抬头要比正文小一号、用次级颜色、并且不跟着 `[b]` 加粗 —— 它是「谁在
/// 说话」的标注，和被引正文一样粗一样大时，整块引用读起来就像两段并排的正文。
enum PostParagraphEmphasis: Hashable {
    case body
    case quoteAttribution
}

/// 一个段落。
///
/// 这里不用 SwiftUI 的 `Text`：`Text` 排完版后自身的宽度就是最长那行的宽度，而
/// 开启 `.textSelection(.enabled)` 后，鼠标点击会让选择层按这个宽度把整段重新排
/// 一次 —— 量出来的宽度比最长的行真正画出来的还窄一两点，那一行于是多折一行，
/// 段落高度却已经定死，末尾的文字就被裁掉不见了。段落越长越容易撞上。
///
/// 换成 AppKit 的文本视图后，排版宽度就是 SwiftUI 给出的可用宽度，最长的行离
/// 边界还差得远，点击选中也不会重排；选择、复制、右键菜单都由 AppKit 提供。
private struct PostParagraphView: View {
    @Environment(\.sngaTheme) private var theme
    let paragraph: PostParagraph
    var emphasis: PostParagraphEmphasis = .body
    let onOpenLink: @MainActor (URL) -> Void

    var body: some View {
        // 表情图片在这里解析：读取 shared store 的属性发生在 body 求值期间，
        // @Observable 会据此登记依赖，图片下载完成后这一段会重新求值并重新测高。
        // 放进 NSViewRepresentable 里读就不算依赖了，图片到了也不会重排。
        let emoticons = EmoticonImageStore.shared
        let images = paragraph.segments.reduce(into: [URL: NSImage]()) { result, segment in
            guard case let .emoticon(url) = segment else { return }
            result[url] = emoticons.image(for: url)
        }
        let loaded = images.compactMapValues { $0 }
        PostParagraphText(
            paragraph: paragraph,
            theme: theme,
            emphasis: emphasis,
            images: loaded,
            onOpenLink: onOpenLink
        )
        // 表情到齐要算换了一份内容，而不只是刷新同一个视图。
        //
        // 表情是行内附件，一张 64×56 的图能把一行从 17 点撑到 56 点。而附件是在
        // `updateNSView` 里写进共享文本存储的 —— 那一刻本轮测量已经过去，SwiftUI
        // 手上还是「没有表情」时量出来的高度：框按 36 排，内容按 75 画，文字被压
        // 到框外、表情戳出楼层边框。拉一下窗口给出新宽度、逼它重量一次才恢复。
        //
        // 把已加载的表情并进视图标识，图片到达就是一次重建，测量和绘制必然用的是
        // 同一份内容。表情一旦缓存住就不再变，因此每段最多重建一次。
        .id(Set(loaded.keys))
    }
}

private struct PostParagraphText: NSViewRepresentable {
    let paragraph: PostParagraph
    let theme: ResolvedAppTheme
    let emphasis: PostParagraphEmphasis
    let images: [URL: NSImage]
    let onOpenLink: @MainActor (URL) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onOpenLink: onOpenLink)
    }

    func makeNSView(context: Context) -> PostParagraphTextView {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(
            size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        )
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)

        let textView = PostParagraphTextView(frame: .zero, textContainer: container)
        textView.delegate = context.coordinator
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = false
        textView.focusRingType = NSFocusRingType.none
        textView.usesFontPanel = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.textContainerInset = NSSize.zero
        // 链接的颜色和下划线由片段样式自己带，这里只补一个手型光标。
        textView.linkTextAttributes = [NSAttributedString.Key.cursor: NSCursor.pointingHand]
        textView.setAccessibilityRole(NSAccessibility.Role.staticText)
        apply(to: textView, coordinator: context.coordinator)
        return textView
    }

    func updateNSView(_ textView: PostParagraphTextView, context: Context) {
        context.coordinator.onOpenLink = onOpenLink
        apply(to: textView, coordinator: context.coordinator)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView textView: PostParagraphTextView,
        context: Context
    ) -> CGSize? {
        guard let width = proposal.width, width > 0, width.isFinite else { return nil }
        apply(to: textView, coordinator: context.coordinator)
        return CGSize(width: width, height: textView.height(fittingWidth: width))
    }

    /// 段落内容只在真正变化时才重建：`updateNSView` 每个更新周期都会跑一遍，而
    /// 重排一段富文本并不便宜。相同 `Post` 传下来的字符串是同一份存储，`==` 会走
    /// 常数时间快路径。
    private func apply(to textView: PostParagraphTextView, coordinator: Coordinator) {
        let key = Coordinator.ContentKey(
            paragraph: paragraph,
            theme: theme,
            emphasis: emphasis,
            loadedEmoticons: Set(images.keys)
        )
        guard coordinator.contentKey != key else { return }
        coordinator.contentKey = key
        textView.textStorage?.setAttributedString(
            PostParagraphAttributedText.attributedString(
                for: paragraph,
                theme: theme,
                emphasis: emphasis,
                images: images
            )
        )
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        struct ContentKey: Equatable {
            let paragraph: PostParagraph
            let theme: ResolvedAppTheme
            let emphasis: PostParagraphEmphasis
            let loadedEmoticons: Set<URL>
        }

        var onOpenLink: @MainActor (URL) -> Void
        var contentKey: ContentKey?

        init(onOpenLink: @escaping @MainActor (URL) -> Void) {
            self.onOpenLink = onOpenLink
        }

        func textView(
            _ textView: NSTextView,
            clickedOnLink link: Any,
            at charIndex: Int
        ) -> Bool {
            let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
            guard let url else { return false }
            MainActor.assumeIsolated { onOpenLink(url) }
            return true
        }
    }
}

/// 段落的文本视图。
final class PostParagraphTextView: NSTextView {
    /// 测高专用的排版栈：和渲染共用同一份 `NSTextStorage`，但有自己的
    /// `NSLayoutManager` 和 `NSTextContainer`。
    ///
    /// 测量不能碰渲染用的那个容器。SwiftUI 求一个视图的尺寸时，会拿多个候选宽度
    /// 反复调用 `sizeThatFits`（包括 10 点这种探测值），谁最后一个调用，谁留下的
    /// 宽度就成了这一段真正的排版宽度 —— 而那通常不是视图最终拿到的宽度。于是
    /// 文字按一个更窄的宽度折行：右边空出一大片，同时画出来比上报的高度更高，
    /// 压住下面的图片、把表情挤出楼层边框。
    ///
    /// `layout()` 会把排版宽度改回 `bounds.width`，但那要等 AppKit 真的重新布局
    /// 这个视图。楼层按需创建时，每层建好都紧跟一次布局，测量留下的宽度总会被
    /// 覆盖掉；整页一次性创建时则不一定，这个隐患才显出来。
    private let measuringLayoutManager = NSLayoutManager()
    private let measuringContainer = NSTextContainer(
        size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
    )

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        measuringContainer.lineFragmentPadding = 0
        measuringContainer.widthTracksTextView = false
        measuringLayoutManager.addTextContainer(measuringContainer)
        // 同一份文本存储可以挂多个排版栈，内容变化会同时通知两边，
        // 测高这边不必再复制一份文本。
        textStorage?.addLayoutManager(measuringLayoutManager)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func height(fittingWidth width: CGFloat) -> CGFloat {
        measuringContainer.size = NSSize(
            width: width,
            height: CGFloat.greatestFiniteMagnitude
        )
        measuringLayoutManager.ensureLayout(for: measuringContainer)
        return ceil(measuringLayoutManager.usedRect(for: measuringContainer).height)
    }

    override func layout() {
        // 排版宽度始终跟着视图走，`sizeThatFits` 量出来的高度才对得上实际绘制。
        textContainer?.size = NSSize(
            width: bounds.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        super.layout()
    }

    /// 楼层正文位于 SwiftUI 的滚动视图里，滚轮不应该停在这一段上。
    override func scrollWheel(with event: NSEvent) {
        var ancestor = superview
        while let view = ancestor {
            if let outerScrollView = view as? NSScrollView {
                outerScrollView.scrollWheel(with: event)
                return
            }
            ancestor = view.superview
        }
        super.scrollWheel(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let menu = super.menu(for: event) else { return nil }
        localize(menu)
        return menu
    }

    private func localize(_ menu: NSMenu) {
        for item in menu.items {
            item.title = PostContextMenuLocalization.localizedTitle(item.title)
            if let submenu = item.submenu {
                localize(submenu)
            }
        }
    }
}

/// 把段落片段翻译成 `NSAttributedString`。
private enum PostParagraphAttributedText {
    private static let baseFontSize: CGFloat = 14
    /// 和 SwiftUI 版本的 `.lineSpacing(2)` 保持一致。
    private static let lineSpacing: CGFloat = 2

    static func attributedString(
        for paragraph: PostParagraph,
        theme: ResolvedAppTheme,
        emphasis: PostParagraphEmphasis = .body,
        images: [URL: NSImage]
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for segment in paragraph.segments {
            switch segment {
            case let .text(value, style):
                result.append(
                    NSAttributedString(
                        string: value,
                        attributes: attributes(
                            for: style,
                            theme: theme,
                            emphasis: emphasis
                        )
                    )
                )
            case let .emoticon(url):
                guard let image = images[url] else {
                    // 还没下载完时先留一个空位，避免图片到达时整段文字重排跳动。
                    result.append(NSAttributedString(string: " "))
                    continue
                }
                result.append(attachment(for: image, emphasis: emphasis))
            }
        }
        result.addAttribute(
            .paragraphStyle,
            value: paragraphStyle(alignment: paragraph.alignment),
            range: NSRange(location: 0, length: result.length)
        )
        return result
    }

    private static func attributes(
        for style: PostTextStyle,
        theme: ResolvedAppTheme,
        emphasis: PostParagraphEmphasis
    ) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font(for: style, emphasis: emphasis)
        ]
        if let link = style.link {
            attributes[.link] = link
            attributes[.foregroundColor] = NSColor(theme.accentColor)
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        } else if let color = style.color {
            attributes[.foregroundColor] = NSColor(color.swiftUIColor)
        } else {
            // 抬头整行都是加粗的，颜色再和正文一样就完全分不出主次。
            attributes[.foregroundColor] = emphasis == .quoteAttribution
                ? NSColor.secondaryLabelColor
                : NSColor.labelColor
        }
        if style.isUnderlined {
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        if style.isStruckThrough {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        return attributes
    }

    private static func font(
        for style: PostTextStyle,
        emphasis: PostParagraphEmphasis
    ) -> NSFont {
        let size = fontSize(for: emphasis) * sizeScale(style)
        // 抬头本身整段就是 `[b]`，照着加粗只会让它比被引正文还抢眼。
        let weight: NSFont.Weight = emphasis == .body && style.isBold ? .bold : .regular
        var font = style.isMonospaced
            ? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
            : NSFont.systemFont(ofSize: size, weight: weight)
        if style.isItalic {
            font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        }
        return font
    }

    private static func fontSize(for emphasis: PostParagraphEmphasis) -> CGFloat {
        switch emphasis {
        case .body: baseFontSize
        case .quoteAttribution: 12
        }
    }

    private static func sizeScale(_ style: PostTextStyle) -> CGFloat {
        guard let percent = style.sizePercent else { return 1 }
        return CGFloat(min(max(percent, 50), 200)) / 100
    }

    /// 表情按 `vertical-align:middle` 对齐，和楼层样式表里的表现一致。
    private static func attachment(
        for image: NSImage,
        emphasis: PostParagraphEmphasis
    ) -> NSAttributedString {
        let attachment = NSTextAttachment()
        attachment.image = image
        let font = NSFont.systemFont(ofSize: fontSize(for: emphasis))
        attachment.bounds = CGRect(
            x: 0,
            y: (font.xHeight - image.size.height) / 2,
            width: image.size.width,
            height: image.size.height
        )
        return NSAttributedString(attachment: attachment)
    }

    private static func paragraphStyle(
        alignment: PostTextAlignment
    ) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        style.lineBreakMode = .byWordWrapping
        switch alignment {
        case .leading: style.alignment = .natural
        case .center: style.alignment = .center
        case .trailing: style.alignment = .right
        }
        return style
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
