import Foundation

enum ForumSearchKind: String, CaseIterable, Identifiable, Hashable, Sendable {
    case topicSubject
    case topicContent
    case forum
    case user
    case userTopics
    case userContent

    var id: String { rawValue }

    var title: String {
        switch self {
        case .topicSubject: "主题标题"
        case .topicContent: "主题标题和内容"
        case .forum: "版面或版主"
        case .user: "用户"
        case .userTopics: "用户发布的主题"
        case .userContent: "用户发布的内容"
        }
    }

    var prompt: String {
        switch self {
        case .topicSubject, .topicContent: "输入搜索关键词"
        case .forum: "输入版面名称或版主名称"
        case .user, .userTopics, .userContent: "输入用户 ID 或用户名"
        }
    }

    var systemImage: String {
        switch self {
        case .topicSubject: "text.magnifyingglass"
        case .topicContent: "doc.text.magnifyingglass"
        case .forum: "rectangle.3.group.bubble.left"
        case .user: "person.crop.circle.badge.questionmark"
        case .userTopics: "person.text.rectangle"
        case .userContent: "person.bubble"
        }
    }

    var supportsCurrentForum: Bool {
        switch self {
        case .topicSubject, .topicContent: true
        case .forum, .user, .userTopics, .userContent: false
        }
    }

    var userActivityKind: UserActivityKind? {
        switch self {
        case .userTopics: .topics
        case .userContent: .replies
        case .topicSubject, .topicContent, .forum, .user: nil
        }
    }

    static let currentForumKinds = allCases.filter(\.supportsCurrentForum)
}
