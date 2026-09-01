import Foundation

/// 小工具的数据模型。
///
/// 小工具读的是 60s 开放接口，和任何论坛都没有关系 —— 因此这些类型不放在
/// `DomainModels.swift` 里，那份文件描述的是论坛领域。

enum ToolboxFeed: String, CaseIterable, Identifiable, Hashable, Sendable {
    case worldBriefing
    case aiNews
    case itNews
    case douyinHot
    case rednoteHot
    case bilibiliHot
    case weiboHot
    case zhihuHot

    var id: String { rawValue }

    var title: String {
        switch self {
        case .worldBriefing: "每天 60s 读懂世界"
        case .aiNews: "AI 资讯快报"
        case .itNews: "实时 IT 资讯"
        case .douyinHot: "抖音热搜"
        case .rednoteHot: "小红书热点"
        case .bilibiliHot: "哔哩哔哩热搜"
        case .weiboHot: "微博热搜"
        case .zhihuHot: "知乎话题榜"
        }
    }

    var subtitle: String {
        switch self {
        case .worldBriefing: "每天一分钟，快速了解全球要闻"
        case .aiNews: "聚合 AI 与大模型领域的重要动态"
        case .itNews: "来自 IT 之家的实时科技资讯"
        case .douyinHot: "查看抖音当前热门搜索"
        case .rednoteHot: "发现小红书实时热门话题"
        case .bilibiliHot: "浏览哔哩哔哩实时热搜"
        case .weiboHot: "追踪微博实时热搜话题"
        case .zhihuHot: "了解知乎当前热门讨论"
        }
    }

    var updateFrequency: String {
        switch self {
        case .worldBriefing, .aiNews: "日更"
        case .itNews, .douyinHot, .rednoteHot, .bilibiliHot, .weiboHot, .zhihuHot:
            "实时"
        }
    }

    var systemImage: String {
        switch self {
        case .worldBriefing: "globe.asia.australia"
        case .aiNews: "sparkles"
        case .itNews: "desktopcomputer"
        case .douyinHot: "music.note"
        case .rednoteHot: "book.closed.fill"
        case .bilibiliHot: "play.rectangle.fill"
        case .weiboHot: "bubble.left.and.bubble.right.fill"
        case .zhihuHot: "questionmark.bubble.fill"
        }
    }
}

struct WorldBriefing: Hashable, Sendable {
    var date: String
    var dayOfWeek: String?
    var lunarDate: String?
    var news: [String]
    var tip: String?
    var imageURL: URL?
    var coverURL: URL?
    var sourceURL: URL?
    var updatedAt: Date?
}

struct ToolboxArticle: Identifiable, Hashable, Sendable {
    let id: String
    var rank: Int?
    var title: String
    var summary: String
    var source: String?
    var publishedText: String?
    var publishedAt: Date?
    var link: URL?

    init(
        rank: Int? = nil,
        title: String,
        summary: String,
        source: String? = nil,
        publishedText: String? = nil,
        publishedAt: Date? = nil,
        link: URL? = nil
    ) {
        self.id = link?.absoluteString
            ?? [title, source, publishedText].compactMap { $0 }.joined(separator: "|")
        self.rank = rank
        self.title = title
        self.summary = summary
        self.source = source
        self.publishedText = publishedText
        self.publishedAt = publishedAt
        self.link = link
    }
}

enum ToolboxContent: Hashable, Sendable {
    case worldBriefing(WorldBriefing)
    case articles([ToolboxArticle])
}
