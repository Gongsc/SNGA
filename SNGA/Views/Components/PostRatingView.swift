import SwiftUI

struct PostRatingView: View {
    @Environment(\.sngaTheme) private var theme
    let rating: TopicRating
    let scores: [String: Int]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("评分", systemImage: "star.fill")
                .foregroundStyle(theme.accentColor)

            ForEach(rating.dimensions) { dimension in
                if let score = scores[dimension.id] {
                    LabeledContent(dimension.title) {
                        Text("\(score) / \(rating.maximumScore)")
                            .monospacedDigit()
                            .bold()
                    }
                }
            }
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
        .accessibilityElement(children: .combine)
    }
}
