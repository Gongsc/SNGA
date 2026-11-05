import SwiftUI

/// 一个话题标签的胶囊。能打开的标签（带 `forumID`）是一颗按钮，点了去那个标签的列表。
///
/// 话题列表的行和话题页的标题栏共用这一份：同一个标签在两处长得不一样、点起来
/// 一处能去一处不能去，读者会以为是两样东西。
struct TopicTagCapsule: View {
    @Environment(AppModel.self) private var model
    @Environment(\.sngaTheme) private var theme
    let tag: TopicTag
    let font: Font
    let accessibilityIdentifier: String
    @State private var isHovered = false

    private enum Metrics {
        static let horizontalPadding: CGFloat = 5
        static let verticalPadding: CGFloat = 1
    }

    var body: some View {
        if tag.forumID != nil {
            // 话题列表里，行本身是一颗「打开话题」的按钮；里面这颗按钮先接住点击，
            // 点标签就只去标签列表，不会顺带把话题也打开。
            Button {
                Task { await model.openTopicTag(tag) }
            } label: {
                capsule
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }
            .help("查看标签「\(tag.name)」下的话题")
            .accessibilityIdentifier(accessibilityIdentifier)
        } else {
            capsule
                .accessibilityIdentifier(accessibilityIdentifier)
        }
    }

    /// 悬停时换成 `hoverFillColor`，告诉用户这一小块是能单独点的 —— 否则它看上去
    /// 只是整行的一部分，点下去去了别处会让人意外。
    ///
    /// 字也跟着换成主文字色：次级文字压在悬停底上，NGA 暖金下只有 4.36:1，够不着 AA
    /// （`ThemeContrastTests` 量出来的）。
    private var capsule: some View {
        Text(tag.name)
            .font(font)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, Metrics.horizontalPadding)
            .padding(.vertical, Metrics.verticalPadding)
            .foregroundStyle(isHovered ? theme.foregroundColor : theme.secondaryForegroundColor)
            .background(isHovered ? theme.hoverFillColor : theme.fillColor, in: Capsule())
            .contentShape(Capsule())
    }
}

/// 从左往右排、排不下就折到下一行。
///
/// 话题页的标题栏要把标签一个不落地全画出来（列表行里放不下的折成了「+N」，读者
/// 点进来就是想看全）。`HStack` 只会一行挤到底再压出省略号，`LazyVGrid` 是等宽
/// 的格子 —— 长短差好几倍的标签放进去，短的周围全是空白。
struct FlowLayout: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews: subviews, maxWidth: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews: subviews, maxWidth: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    /// 一个比整行还宽的元素自己占一行，不硬塞、也不丢 —— 丢了就是悄悄少显示一个标签。
    private func arrange(subviews: Subviews, maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let proposedWidth = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if proposedWidth > maxWidth, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
