import SwiftUI

/// 回复编辑器的表情选择器。
///
/// 名单由站点资料给（`ForumSiteDescriptor.emoticonPacks`），这里只管画。两处按数据
/// 决定画不画：多于一包才出分栏，名字有含义的包才给搜索框 —— NodeSeek 的表情叫
/// `xhj017`，搜索框在那儿只会占掉一行网格。
struct EmoticonPicker: View {
    let packs: [EmoticonPack]
    var insert: (ForumEmoticon) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedPackID: String?
    @State private var searchText = ""

    private var pack: EmoticonPack? {
        packs.first { $0.id == selectedPackID } ?? packs.first
    }

    private var results: [ForumEmoticon] {
        guard let pack else { return [] }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard pack.isSearchable, !query.isEmpty else { return pack.emoticons }
        return pack.emoticons.filter { $0.title.localizedStandardContains(query) }
    }

    var body: some View {
        VStack(spacing: 10) {
            if packs.count > 1 {
                Picker("表情包", selection: Binding(
                    get: { pack?.id ?? "" },
                    set: { selectedPackID = $0 }
                )) {
                    ForEach(packs) { Text($0.title).tag($0.id) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            if pack?.isSearchable == true {
                TextField("搜索表情", text: $searchText)
                    .textFieldStyle(.roundedBorder)
            }

            ScrollView {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.fixed(42), spacing: 6), count: 8),
                    spacing: 6
                ) {
                    ForEach(results) { emoticon in
                        Button {
                            insert(emoticon)
                        } label: {
                            thumbnail(emoticon)
                        }
                        .buttonStyle(.plain)
                        .help(emoticon.title)
                    }
                }
                .padding(4)
            }
            // 换一包要从头看起：不重建的话滚动位置会留在上一包翻到的地方。
            .id(pack?.id)
        }
        .padding(12)
        .frame(width: 410, height: 320)
    }

    /// 动图在这里只有第一帧 —— `AsyncImage` 不放动画。选择器只要认得出是哪一个，
    /// 为了几十张缩略图去挂一套动图解码不划算。
    private func thumbnail(_ emoticon: ForumEmoticon) -> some View {
        AsyncImage(url: emoticon.previewURL) { image in
            image
                .resizable()
                .scaledToFit()
        } placeholder: {
            ProgressView()
                .controlSize(.mini)
        }
        .frame(width: 30, height: 30)
        .background {
            // 深色下垫一层白。两站的表情大多是透明底的黑线稿，不垫就是一格看不见的
            // 空白；彩色的那些垫上去只是多一圈白边，认得出来更要紧。
            RoundedRectangle(cornerRadius: 5)
                .fill(colorScheme == .dark ? Color.white.opacity(0.88) : Color.clear)
        }
        .contentShape(.rect)
        .accessibilityLabel(emoticon.title)
    }
}
