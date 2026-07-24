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

struct ForumID: RawRepresentable, Codable, Hashable, Sendable, Identifiable, CustomStringConvertible {
    let rawValue: Int64

    private static let subforumThreshold = Int64.min / 2

    init(rawValue: Int64) { self.rawValue = rawValue }

    init(stid: Int64) {
        precondition(stid >= 0, "NGA stid must be non-negative")
        self.rawValue = Int64.min + stid
    }

    var id: Int64 { rawValue }
    var isSubforum: Bool { rawValue < Self.subforumThreshold }
    var queryName: String { isSubforum ? "stid" : "fid" }
    var ngaValue: Int64 { isSubforum ? rawValue - Int64.min : rawValue }
    var description: String { String(ngaValue) }
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
