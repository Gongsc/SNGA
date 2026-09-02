import Foundation

/// NodeSeek 的表情包。
///
/// 站点把表情做成 markdown-it 的 emoji 短代码：正文里写 ` :ac01: `，服务端渲染成
/// `<img class="sticker" src="/static/image/sticker/ac/01.png" loading="lazy" alt="ac01">`
/// （实测：`/post-905301-1` 的主楼就是这个形状）。短代码名 = 组名 + 去掉扩展名的文件名。
///
/// 名单和插入格式都是从站点自己的编辑器 chunk（`assets/markdownEditor-*.js`）里读出来的 ——
/// 分组表写死在那份 JS 里，没有接口能问。文件名只能照抄：扩展名推不出来，小黄鸡那组
/// png 和 gif 是混着排的。
///
/// 两侧的空格同样照抄站点：它插入的是 `replaceSelection(" :ac01: ")`。
///
/// 站点的表情栏上还有一档「App」，那不是表情：点它弹的是发起投票和收星辰两个面板，
/// 一个字都不往正文里插。这两样应用都不支持，所以不摆出来。
enum NodeSeekStickers {

    /// 一组表情在站点里的原样。
    private struct Group {
        let id: String
        let title: String
        /// 站点把这组渲染成 `<video>`（webm + mov 两个源），而不是 `<img>`。
        let isVideo: Bool
        /// 带扩展名的文件名，顺序就是面板上的顺序。
        let files: [String]
    }

    private static let groups: [Group] = [
        // AC 娘分三段编号：01–54、1001–1040、2001–2055，全是 png。
        Group(
            id: "ac",
            title: "AC娘",
            isVideo: false,
            files: numbered(1...54, width: 2, ext: "png")
                + numbered(1001...1040, width: 4, ext: "png")
                + numbered(2001...2055, width: 4, ext: "png")
        ),
        Group(
            id: "yct",
            title: "洋葱头",
            isVideo: false,
            files: numbered(1...22, width: 3, ext: "gif")
        ),
        // 小黄鸡这组必须逐个列：动图和静图混排，扩展名跟着变。
        Group(
            id: "xhj",
            title: "小黄鸡",
            isVideo: false,
            files: [
                "001.png", "002.png", "003.png", "004.gif", "005.png", "006.png",
                "007.png", "008.gif", "009.gif", "010.gif", "011.png", "012.gif",
                "013.gif", "014.gif", "015.gif", "016.gif", "017.gif", "018.gif",
                "019.gif", "020.gif", "021.gif", "022.png", "023.gif", "024.png",
                "025.png", "026.gif", "027.gif", "028.gif", "029.gif", "030.gif",
                "031.png", "032.png"
            ]
        ),
        // Fluent 这组的文件名不带扩展名：正文里取 `.webm`/`.mov`，面板上取同名 `.png`。
        Group(
            id: "emoji",
            title: "Fluent",
            isVideo: true,
            files: (0...48).map { String(format: "%02d", $0) }
        )
    ]

    static let packs: [EmoticonPack] = groups.map { group in
        EmoticonPack(
            id: group.id,
            title: group.title,
            // 表情就叫 `xhj017`，搜不出名堂来。
            isSearchable: false,
            emoticons: group.files.map { file in
                let name = group.id + stem(of: file)
                return ForumEmoticon(
                    id: name,
                    title: name,
                    previewURL: NodeSeekEndpoint.stickerImage(
                        group: group.id,
                        file: group.isVideo ? "\(file).png" : file
                    ),
                    insertion: " :\(name): "
                )
            }
        )
    }

    /// 短代码名 → 静态图。回复预览把 ` :ac01: ` 换回图片时查这张表。
    static let index: [String: URL] = Dictionary(
        packs.flatMap(\.emoticons).map { ($0.id, $0.previewURL) },
        uniquingKeysWith: { first, _ in first }
    )

    /// 照站点的写法去扩展名：从第一个点起全砍掉。Fluent 那组本来就没有点。
    private static func stem(of file: String) -> String {
        guard let dot = file.firstIndex(of: ".") else { return file }
        return String(file[file.startIndex..<dot])
    }

    private static func numbered(
        _ range: ClosedRange<Int>,
        width: Int,
        ext: String
    ) -> [String] {
        range.map { String(format: "%0\(width)d.\(ext)", $0) }
    }
}
