import SwiftUI

struct TopicRatingEditorView: View {
    @Environment(\.sngaTheme) private var theme
    let rating: TopicRating
    @Binding var selections: [TopicRatingSelection]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("随回复提交评分", systemImage: "star.bubble")
                .font(.headline)
                .foregroundStyle(theme.accentColor)

            Text("评分会与本次回复一起发送；保留“不评分”即可只回复内容。")
                .font(.callout)
                .foregroundStyle(.secondary)

            ForEach($selections) { $selection in
                if let dimension = rating.dimension(id: selection.id) {
                    LabeledContent(dimension.title) {
                        Picker(dimension.title, selection: $selection.score) {
                            Text("不评分").tag(nil as Int?)
                            ForEach(rating.scoreValues, id: \.self) { score in
                                Text("\(score) 分").tag(score as Int?)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(minWidth: 120)
                    }
                }
            }
        }
        .padding(12)
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
