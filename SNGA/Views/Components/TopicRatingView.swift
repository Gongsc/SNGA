import SwiftUI

struct TopicRatingView: View {
    @Environment(\.sngaTheme) private var theme
    let rating: TopicRating
    var startReply: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("主题评分", systemImage: "star.square.on.square")
                .font(.headline)
                .foregroundStyle(theme.accentColor)

            ForEach(rating.dimensions) { dimension in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(dimension.title)
                        Spacer()
                        Text(
                            dimension.averageScore,
                            format: .number.precision(.fractionLength(0...2))
                        )
                        .font(.headline.monospacedDigit())
                        Text("/ \(rating.maximumScore)")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    ProgressView(
                        value: dimension.averageScore,
                        total: Double(rating.maximumScore)
                    )
                    .tint(theme.accentColor)
                    .accessibilityLabel("\(dimension.title)平均分")
                    .accessibilityValue(
                        "\(dimension.averageScore) 分，共 \(dimension.ratingCount) 个评分"
                    )
                }
            }

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(
                        "\(rating.participantCount) 人评分 · "
                            + "评分范围 \(rating.minimumScore)–\(rating.maximumScore)"
                    )
                    if let endsAt = rating.endsAt {
                        Text(
                            endsAt,
                            format: .dateTime
                                .year()
                                .month(.twoDigits)
                                .day(.twoDigits)
                                .hour(.twoDigits(amPM: .omitted))
                                .minute(.twoDigits)
                        )
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)

                Spacer()

                if rating.isAcceptingResponses(at: .now) {
                    Button(
                        "写回复并评分",
                        systemImage: "square.and.pencil",
                        action: startReply
                    )
                    .buttonStyle(.bordered)
                    .frame(minHeight: 44)
                } else {
                    Label("评分已结束", systemImage: "clock.badge.xmark")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .background(
            theme.accentColor.opacity(0.045),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(theme.accentColor.opacity(0.25))
        }
    }
}
