import Foundation

/// 一层清洗完成的正文：既有交给 `WKWebView` 的完整文档，也有可能的原生结构。
struct SanitizedPost: Hashable, Sendable {
    var html: String
    var nativeContent: PostContent?
    /// 正文自带的 `[lessernuke]` 包裹所表示的处罚。楼层元数据里的处罚标记不走这条路。
    var punishment: PostPunishment?
}

/// 楼层正文的原生表示。
///
/// 绝大多数楼层只是带少量内联样式的文字、表情和引用，用 `WKWebView` 渲染它们
/// 意味着每层都要付出一个渲染实例的代价。解析阶段能转换成本结构的楼层直接走
/// SwiftUI 原生渲染；含图片、表格、折叠块、游戏卡片等复杂内容的楼层仍然回退到
/// `WKWebView`（此时 `PostContent` 为 nil）。
///
/// 这里刻意不用 `AttributedString` 承载样式：它的 SwiftUI 属性域在编码时会踩坑，
/// 而 `Post` 是 `Codable` 的。改用自有的样式描述，在渲染时才转成 SwiftUI 类型。
struct PostContent: Hashable, Codable, Sendable {
    var blocks: [PostBlock]

    var isEmpty: Bool { blocks.isEmpty }
}

enum PostBlock: Hashable, Codable, Sendable {
    case paragraph(PostParagraph)
    case quote([PostBlock])
}

struct PostParagraph: Hashable, Codable, Sendable {
    var segments: [PostSegment]
    var alignment: PostTextAlignment = .leading

    var isEmpty: Bool {
        segments.allSatisfy { segment in
            if case let .text(value, _) = segment {
                return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            return false
        }
    }
}

enum PostSegment: Hashable, Codable, Sendable {
    case text(String, PostTextStyle)
    /// NGA 表情。是一张固定集合内的远程小图，渲染时按 URL 取缓存。
    case emoticon(URL)
}

enum PostTextAlignment: String, Hashable, Codable, Sendable {
    case leading
    case center
    case trailing
}

struct PostTextStyle: Hashable, Codable, Sendable {
    var isBold = false
    var isItalic = false
    var isUnderlined = false
    var isStruckThrough = false
    var isMonospaced = false
    var color: PostTextColor?
    /// 对应 UBB 的 `[size=...]`，取值为百分比（50–200）。
    var sizePercent: Int?
    var link: URL?

    var isPlain: Bool { self == PostTextStyle() }
}

/// NGA 允许的固定配色，与楼层样式表里的 `.ubb-color-*` 一一对应。
enum PostTextColor: String, Hashable, Codable, Sendable, CaseIterable {
    case red
    case orange
    case orangered
    case green
    case teal
    case blue
    case skyblue
    case darkblue
    case royalblue
    case purple
    case deeppink
    case chocolate
    case sienna
    case gray
    case silver
    case white

    init?(className: String) {
        let prefix = "ubb-color-"
        guard className.hasPrefix(prefix) else { return nil }
        self.init(rawValue: String(className.dropFirst(prefix.count)))
    }
}
