import SwiftUI

struct ThreadContentSkeletonView: View {
    @Environment(\.sngaTheme) private var theme
    @ScaledMetric(relativeTo: .body) private var avatarSize: CGFloat = 30
    @ScaledMetric(relativeTo: .body) private var nameHeight: CGFloat = 14
    @ScaledMetric(relativeTo: .caption) private var metadataHeight: CGFloat = 11
    @ScaledMetric(relativeTo: .body) private var bodyLineHeight: CGFloat = 14
    @ScaledMetric(relativeTo: .caption) private var nameWidth: CGFloat = 96
    @ScaledMetric(relativeTo: .caption) private var dateWidth: CGFloat = 132
    @ScaledMetric(relativeTo: .caption) private var floorWidth: CGFloat = 42
    @ScaledMetric(relativeTo: .body) private var shortLineInset: CGFloat = 24
    @ScaledMetric(relativeTo: .body) private var mediumLineInset: CGFloat = 64
    @ScaledMetric(relativeTo: .body) private var longLineInset: CGFloat = 112

    var body: some View {
        SkeletonShimmerView {
            VStack(spacing: 12) {
                ForEach(0..<3, id: \.self) { index in
                    VStack(alignment: .leading, spacing: 13) {
                        HStack(spacing: 9) {
                            Circle()
                                .frame(width: avatarSize, height: avatarSize)

                            VStack(alignment: .leading, spacing: 5) {
                                Capsule()
                                    .frame(width: nameWidth, height: nameHeight)
                                Capsule()
                                    .frame(width: dateWidth, height: metadataHeight)
                            }

                            Spacer()

                            Capsule()
                                .frame(width: floorWidth, height: metadataHeight)
                        }

                        VStack(alignment: .leading, spacing: 9) {
                            ForEach(0..<bodyLineCount(for: index), id: \.self) { line in
                                HStack(spacing: 0) {
                                    RoundedRectangle(cornerRadius: 4)
                                        .frame(maxWidth: .infinity)
                                        .frame(height: bodyLineHeight)
                                    Spacer()
                                        .frame(
                                            width: bodyLineTrailingInset(
                                                card: index,
                                                line: line
                                            )
                                        )
                                }
                            }
                        }

                        HStack {
                            Spacer()
                            Capsule()
                                .frame(width: 46, height: metadataHeight)
                            Capsule()
                                .frame(width: 46, height: metadataHeight)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        theme.surfaceColor,
                        in: RoundedRectangle(cornerRadius: 10)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color(nsColor: .separatorColor).opacity(0.5))
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("正在加载主题内容")
        .accessibilityIdentifier("thread-content-skeleton")
    }

    private func bodyLineCount(for index: Int) -> Int {
        index == 0 ? 4 : 3
    }

    private func bodyLineTrailingInset(card: Int, line: Int) -> CGFloat {
        switch (card, line) {
        case (0, 0), (1, 0), (2, 0):
            shortLineInset
        case (0, 1), (1, 1), (2, 1):
            mediumLineInset
        case (0, 2):
            mediumLineInset
        case (0, 3), (1, 2), (2, 2):
            longLineInset
        default:
            mediumLineInset
        }
    }
}
