import SwiftUI

/// 写一段话，编成 Base64，插到光标那儿。
///
/// 和「插入链接」「插入图片」是同一个形状：弹层里填内容，确认之后插进正文 ——
/// **不是**把整条回复编掉。编整条的话，读的人得先把一整篇解开才知道值不值得读，
/// 而实际用法是「正文里藏一段」：前后仍是人话，中间那截要解一下。
///
/// 编出来的样子当场就摆在下面。Base64 是给机器看的，人一眼判断不了自己编对没有，
/// 而这一步之后它就进正文了 —— 让他先看见。
struct Base64InsertPopover: View {
    private enum Metrics {
        static let width: CGFloat = 380
        static let inputHeight: CGFloat = 90
        static let previewHeight: CGFloat = 64
        static let spacing: CGFloat = 10
        static let padding: CGFloat = 14
    }

    @Environment(\.sngaTheme) private var theme
    let insert: (String) -> Void

    @State private var text = ""

    private var encoded: String { Base64Text.encoded(text) }

    private var canInsert: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing) {
            Text("插入 Base64")
                .font(.headline)
            Text("这段话会编成 Base64 插进正文，读的人在楼层里右键就能解开。")
                .font(.caption)
                .foregroundStyle(theme.secondaryForegroundColor)

            TextEditor(text: $text)
                .font(.body)
                .frame(height: Metrics.inputHeight)
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(theme.controlBorderColor)
                }
                .accessibilityLabel("要编码的内容")
                .accessibilityIdentifier("base64-insert-input")

            if canInsert {
                VStack(alignment: .leading, spacing: 4) {
                    Text("编码后")
                        .font(.caption)
                        .foregroundStyle(theme.secondaryForegroundColor)
                    ScrollView {
                        Text(encoded)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: Metrics.previewHeight)
                }
                .accessibilityIdentifier("base64-insert-preview")
            }

            HStack {
                Spacer()
                Button("插入") { insert(encoded) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canInsert)
                    .accessibilityIdentifier("base64-insert-confirm")
            }
        }
        .padding(Metrics.padding)
        .frame(width: Metrics.width)
    }
}
