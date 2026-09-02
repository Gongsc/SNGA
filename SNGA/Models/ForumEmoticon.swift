import Foundation

/// 一个能插进回复正文的表情。
///
/// 各站的表情只有两头不一样：拿哪张图显示、往正文里插哪串字。中间那段 —— 分包、
/// 铺成网格、点一下插进去 —— 两站完全一样，所以选择器只认这个模型，不认站点。
struct ForumEmoticon: Identifiable, Hashable, Sendable {
    /// 站内唯一。NGA 用「族:名字」（`ac:茶`），NodeSeek 用短代码名（`ac01`）。
    let id: String
    /// 悬停提示，也是搜索匹配的对象。
    let title: String
    /// 选择器里显示的静态图。
    ///
    /// 「静态」是有意的：NodeSeek 的 Fluent 那组在正文里是 webm/mov，但站点给每个都
    /// 备了同名 PNG，它自己的表情面板用的就是那张。
    let previewURL: URL
    /// 插进正文的原文，连同两侧该有的空白。
    ///
    /// 空白也归站点管：NodeSeek 插的是 ` :ac01: `（前后各一个空格，见
    /// `NodeSeekStickers`），NGA 的 `[s:ac:茶]` 则紧贴前后文。写进模型里，
    /// 插入的那一处就不必再问「现在是哪个站」。
    let insertion: String
}

/// 一组表情。
///
/// 站点自己就是这么分栏的：NodeSeek 有 252 张，一屏铺不下也认不过来。
struct EmoticonPack: Identifiable, Hashable, Sendable {
    let id: String
    /// 分栏标题，按站点自己的叫法。
    let title: String
    /// 名字值不值得搜。
    ///
    /// NGA 的表情叫「抓狂」「计划通」，搜得动；NodeSeek 的叫 `xhj017`，
    /// 摆个搜索框只是白占掉一行网格。
    let isSearchable: Bool
    let emoticons: [ForumEmoticon]
}

/// NGA 的官方表情。
///
/// 站点的表情按「族」分，`ac` 这一族是最常用的那套 AC 娘；`[s:ac:茶]` 是它在
/// 正文里的写法。文件名和名字之间没有规律可循 —— `ac0.png` 叫 blink、`ac39.png`
/// 叫「茶」—— 所以顺序不能动，序号就是文件名。
struct NGAEmoticon: Identifiable, Hashable {
    let family: String
    let name: String
    let fileName: String

    var id: String { "\(family):\(name)" }
    var code: String { "[s:\(family):\(name)]" }
    var imageURL: URL? {
        URL(string: "https://img4.nga.cn/ngabbs/post/smile/\(fileName)")
    }

    static let common: [NGAEmoticon] = {
        let names = [
            "blink", "goodjob", "上", "中枪", "偷笑", "冷", "凌乱", "反对", "吓",
            "吻", "呆", "咦", "哦", "哭", "哭1", "哭笑", "哼", "喘", "喷", "嘲笑",
            "嘲笑1", "囧", "委屈", "心", "忧伤", "怒", "怕", "惊", "愁", "抓狂",
            "抠鼻", "擦汗", "无语", "晕", "汗", "瞎", "羞", "羡慕", "花痴", "茶",
            "衰", "计划通", "赞同", "闪光", "黑枪"
        ]
        return names.enumerated().map {
            NGAEmoticon(family: "ac", name: $0.element, fileName: "ac\($0.offset).png")
        }
    }()
}

extension EmoticonPack {
    /// NGA 在应用里只放 `ac` 这一族 —— 名单见 `NGAEmoticon.common`。
    static let nga: [EmoticonPack] = [
        EmoticonPack(
            id: "ac",
            title: "AC娘",
            isSearchable: true,
            emoticons: NGAEmoticon.common.compactMap { emoticon in
                emoticon.imageURL.map {
                    ForumEmoticon(
                        id: emoticon.id,
                        title: emoticon.name,
                        previewURL: $0,
                        insertion: emoticon.code
                    )
                }
            }
        )
    ]
}
