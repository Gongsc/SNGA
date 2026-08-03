import Foundation

enum TopicListSortOrder: String, CaseIterable, Identifiable, Hashable, Sendable {
    case latestReply
    case latestTopic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .latestReply: "最新回复"
        case .latestTopic: "最新话题"
        }
    }

    var queryValue: String {
        switch self {
        case .latestReply: "lastpostdesc"
        case .latestTopic: "postdatedesc"
        }
    }
}
