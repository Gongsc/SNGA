import AppKit
import SwiftUI

/// 解码结果弹在选中的位置旁边。
///
/// 不用弹窗（`NSAlert`）：解出来的东西是要读、要复制、可能还挺长的，而弹窗会
/// 打断整个窗口，读完还得点一下「好」。浮层贴着选中的那段出现，点别处就消失，
/// 和「查一下这段是什么」这件事的分量相称。
///
/// 正文的两条渲染路（原生段落的 `NSTextView` 和楼层的 `WKWebView`）都从这里过 ——
/// 两边各写一份的话，弹层的宽度、圆角、复制按钮迟早会长得不一样。
@MainActor
enum Base64DecodePopover {
    /// 同一时刻只留一个。不关掉旧的，连点几次会摞出好几层。
    private static var current: NSPopover?

    static func present(
        decoded: String,
        theme: ResolvedAppTheme,
        relativeTo rect: NSRect,
        of view: NSView
    ) {
        current?.close()
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(
            rootView: Base64DecodeResultView(decoded: decoded, theme: theme)
        )
        popover.show(relativeTo: rect, of: view, preferredEdge: .maxY)
        current = popover
    }

    static func dismiss() {
        current?.close()
        current = nil
    }
}

private struct Base64DecodeResultView: View {
    private enum Metrics {
        static let width: CGFloat = 380
        static let maximumHeight: CGFloat = 260
        static let padding: CGFloat = 12
        static let spacing: CGFloat = 8
    }

    let decoded: String
    let theme: ResolvedAppTheme

    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing) {
            HStack(spacing: Metrics.spacing) {
                Label("Base64 解码", systemImage: "characters.uppercase")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.secondaryForegroundColor)
                Spacer()
                Button(didCopy ? "已复制" : "复制") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(decoded, forType: .string)
                    didCopy = true
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .disabled(didCopy)
                .accessibilityIdentifier("base64-decode-copy")
            }

            // 解出来的可能是一整段。给它一个上限再滚，别让浮层长到屏幕外面去。
            ScrollView {
                Text(decoded)
                    .font(.callout)
                    .foregroundStyle(theme.foregroundColor)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: Metrics.maximumHeight)
        }
        .padding(Metrics.padding)
        .frame(width: Metrics.width)
        .background(theme.surfaceColor)
        .accessibilityIdentifier("base64-decode-result")
    }
}

/// 两条渲染路共用的那一条菜单项。
///
/// 标题写「解码选中的 Base64」而不是「Base64 解码」：菜单里那一排都是「拷贝」
/// 「查询」这种动宾短语，而且得说清楚它作用在选中的那段上，不是整层楼。
enum Base64DecodeMenuItem {
    static let title = "解码选中的 Base64"
}
