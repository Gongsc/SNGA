import SwiftUI

struct NGAEmoticonPicker: View {
    var insert: (NGAEmoticon) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var searchText = ""

    private var results: [NGAEmoticon] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return NGAEmoticon.common }
        return NGAEmoticon.common.filter {
            $0.name.localizedStandardContains(query)
        }
    }

    var body: some View {
        VStack(spacing: 10) {
            TextField("搜索表情", text: $searchText)
                .textFieldStyle(.roundedBorder)

            ScrollView {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.fixed(42), spacing: 6), count: 8),
                    spacing: 6
                ) {
                    ForEach(results) { emoticon in
                        Button {
                            insert(emoticon)
                        } label: {
                            Label {
                                Text(emoticon.name)
                            } icon: {
                                AsyncImage(url: emoticon.imageURL) { image in
                                    image
                                        .resizable()
                                        .scaledToFit()
                                } placeholder: {
                                    ProgressView()
                                        .controlSize(.mini)
                                }
                                .frame(width: 30, height: 30)
                                .background {
                                    RoundedRectangle(cornerRadius: 5)
                                        .fill(
                                            colorScheme == .dark
                                                ? Color.white.opacity(0.88)
                                                : Color.clear
                                        )
                                }
                                .contentShape(.rect)
                            }
                            .labelStyle(.iconOnly)
                        }
                        .buttonStyle(.plain)
                        .help(emoticon.name)
                    }
                }
                .padding(4)
            }
        }
        .padding(12)
        .frame(width: 410, height: 300)
    }
}
