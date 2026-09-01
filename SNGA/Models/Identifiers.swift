import Foundation

struct AccountID: RawRepresentable, Codable, Hashable, Sendable, Identifiable, CustomStringConvertible {
    let rawValue: UUID

    init(rawValue: UUID) { self.rawValue = rawValue }
    init() { self.rawValue = UUID() }
    init?(_ string: String) {
        guard let value = UUID(uuidString: string) else { return nil }
        self.rawValue = value
    }

    var id: UUID { rawValue }
    var description: String { rawValue.uuidString }
}

/// 一个版面的身份：哪个站，加上那个站自己的键。
///
/// 键是字符串而不是数字，因为不是每个站都用数字：V2EX 的节点是 `swift` 这样的名字，
/// NodeSeek 的分类是 slug。NGA 的编码方式（普通版面是十进制，子版面加 `s` 前缀）
/// 只有 NGA 适配器需要知道，见 `ForumID+NGA.swift`。
struct ForumID: Codable, Hashable, Sendable, Identifiable, CustomStringConvertible {
    let site: ForumSite
    let key: String

    init(site: ForumSite, key: String) {
        self.site = site
        self.key = key
    }

    var id: String { "\(site.rawValue):\(key)" }

    /// 展示与界面标识符都用它。NGA 普通版面得到的仍是原来的十进制数字，
    /// 所以 UI 测试里的 `favorite-forum--7` 这类标识符逐字不变。
    var description: String { key }

    /// 从消息或用户动态打开话题时还不知道它属于哪个版面。
    ///
    /// 这个值只用来占位，不会拿去发请求 —— 话题是按 tid 打开的。
    static func placeholder(site: ForumSite) -> ForumID {
        ForumID(site: site, key: "0")
    }
}

struct TopicID: RawRepresentable, Codable, Hashable, Sendable, Identifiable, CustomStringConvertible {
    let rawValue: Int64
    init(rawValue: Int64) { self.rawValue = rawValue }
    var id: Int64 { rawValue }
    var description: String { String(rawValue) }
}

struct PostID: RawRepresentable, Codable, Hashable, Sendable, Identifiable, CustomStringConvertible {
    let rawValue: Int64
    init(rawValue: Int64) { self.rawValue = rawValue }
    var id: Int64 { rawValue }
    var description: String { String(rawValue) }
}

struct MessageID: RawRepresentable, Codable, Hashable, Sendable, Identifiable, CustomStringConvertible {
    let rawValue: Int64
    init(rawValue: Int64) { self.rawValue = rawValue }
    var id: Int64 { rawValue }
    var description: String { String(rawValue) }
}
