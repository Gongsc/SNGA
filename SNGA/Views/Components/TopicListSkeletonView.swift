import SwiftUI

struct TopicListSkeletonView: View {
    @ScaledMetric(relativeTo: .body) private var titleHeight: CGFloat = 16
    @ScaledMetric(relativeTo: .caption) private var metadataHeight: CGFloat = 12
    @ScaledMetric(relativeTo: .caption) private var authorWidth: CGFloat = 88
    @ScaledMetric(relativeTo: .caption) private var replyWidth: CGFloat = 36
    @ScaledMetric(relativeTo: .caption) private var dateWidth: CGFloat = 112
    @ScaledMetric(relativeTo: .body) private var shortTitleInset: CGFloat = 32
    @ScaledMetric(relativeTo: .body) private var mediumTitleInset: CGFloat = 72
    @ScaledMetric(relativeTo: .body) private var longTitleInset: CGFloat = 108

    var body: some View {
        Section {
            ForEach(0..<8, id: \.self) { index in
                SkeletonShimmerView {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 0) {
                            RoundedRectangle(cornerRadius: 4)
                                .frame(maxWidth: .infinity)
                                .frame(height: titleHeight)
                            Spacer()
                                .frame(width: titleTrailingInset(for: index))
                        }

                        HStack(spacing: 12) {
                            Capsule()
                                .frame(width: authorWidth, height: metadataHeight)
                            Spacer()
                            Capsule()
                                .frame(width: replyWidth, height: metadataHeight)
                            Capsule()
                                .frame(width: dateWidth, height: metadataHeight)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 7)
                }
                .listRowInsets(
                    EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 6)
                )
                .listRowBackground(Color.clear)
                .alignmentGuide(.listRowSeparatorLeading) { dimensions in
                    dimensions[.leading] + 8
                }
                .alignmentGuide(.listRowSeparatorTrailing) { dimensions in
                    dimensions[.trailing] - 8
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("正在加载主题列表")
        .accessibilityIdentifier("topic-list-skeleton")
    }

    private func titleTrailingInset(for index: Int) -> CGFloat {
        switch index % 4 {
        case 0: mediumTitleInset
        case 1: longTitleInset
        case 2: shortTitleInset
        default: mediumTitleInset
        }
    }
}
