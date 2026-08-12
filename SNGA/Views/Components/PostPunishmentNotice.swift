import SwiftUI

/// 被管理操作折叠的楼层。
///
/// NGA 不删除这类楼层，而是把正文收进一个带提示条的框里默认折叠，读者点「点击查看」
/// 才展开。这里保留同样的默认折叠语义：正文视图在折叠时根本不会实例化，被处罚的
/// 楼层因而也不会白白占一个 `WKWebView`。
struct PostPunishmentNotice<Content: View>: View {
    let punishment: PostPunishment
    @ViewBuilder var content: () -> Content

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .imageScale(.small)
                    Text(punishment.title)
                        .fontWeight(.medium)
                    Spacer(minLength: 8)
                    Text(isExpanded ? "收起" : "点击查看")
                    Image(systemName: "chevron.right")
                        .imageScale(.small)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .font(.callout)
                .foregroundStyle(tint)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(punishment.title)
            .accessibilityHint(isExpanded ? "收起被处罚的内容" : "展开被处罚的内容")

            if isExpanded {
                content()
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(tint.opacity(0.45))
        }
    }

    /// 与网页版的 `.crimson` / `.sienna` 对应：主题级处罚偏棕，其余偏红。
    private var tint: Color {
        switch punishment {
        case .topic: PostTextColor.sienna.swiftUIColor
        case .post, .lockedAccount: Color(red: 0.86, green: 0.08, blue: 0.24)
        }
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 12) {
        ForEach(PostPunishment.allCases, id: \.self) { punishment in
            PostPunishmentNotice(punishment: punishment) {
                Text("被折叠起来的楼层正文。")
            }
        }
    }
    .padding()
    .frame(width: 420)
}
