import Foundation

enum NGAServiceError: LocalizedError, Equatable, Sendable {
    case invalidURL
    case invalidResponse
    case requiresLogin
    case topicDeleted
    case topicLocked
    case restricted(String)
    case rateLimited
    case server(Int)
    case unexpectedPage(String)
    case unsupported(String)
    case ambiguousWrite

    var errorDescription: String? {
        switch self {
        case .invalidURL: "NGA 地址无效"
        case .invalidResponse: "NGA 返回了无法识别的响应"
        case .requiresLogin: "当前请求未通过 NGA 登录验证，请重试；如果持续出现，请重新登录"
        case .topicDeleted: "帖子被删除"
        case .topicLocked: "帖子已锁定，无法查看或回复"
        case let .restricted(message): message.isEmpty ? "当前账号无权访问" : message
        case .rateLimited: "请求过于频繁，请稍后重试"
        case let .server(status): "NGA 服务暂时不可用（HTTP \(status)）"
        case let .unexpectedPage(detail): "NGA 页面结构已变化：\(detail)"
        case let .unsupported(detail): detail
        case .ambiguousWrite: "提交结果不明确，为避免重复发送已停止自动重试"
        }
    }
}

protocol NGAForumService: Sendable {
    var accountID: AccountID { get }

    func profile(uid: Int64) async throws -> Profile
    func userActivities(uid: Int64, kind: UserActivityKind, page: Int) async throws -> UserActivityPage
    func forums() async throws -> [Forum]
    func search(_ request: ForumSearchRequest, page: Int) async throws -> ForumSearchPage
    func topics(
        forumID: ForumID,
        page: Int,
        sortOrder: TopicListSortOrder,
        featuredOnly: Bool
    ) async throws -> ForumPage
    func threadPage(
        topicID: TopicID,
        page: Int,
        authorUID: Int64?
    ) async throws -> ThreadPage
    func submitReply(topicID: TopicID, submission: ReplySubmission) async throws -> PostID?
    func vote(topicID: TopicID, postID: PostID, direction: PostVoteDirection) async throws -> PostVoteState
    func submitTopicPollVote(topicID: TopicID, optionIDs: [String]) async throws
    func messages(folder: MessageFolder, page: Int) async throws -> MessagePage
    func message(id: MessageID) async throws -> ForumMessage
    func replyMessage(id: MessageID, content: String) async throws
    func favorites() async throws -> [Forum]
    func updateFavorite(forumID: ForumID, isFavorite: Bool) async throws
    func favoriteTopicFolders() async throws -> [TopicFavoriteFolder]
    func favoriteTopics(folderID: String, page: Int) async throws -> ForumPage
    func updateTopicFavorite(topicID: TopicID, folderID: String, isFavorite: Bool) async throws
    func createTopicFavoriteFolder(name: String, isPublic: Bool, isDefault: Bool) async throws -> String?
    func updateTopicFavoriteFolder(_ folder: TopicFavoriteFolder) async throws
    func deleteTopicFavoriteFolder(folderID: String) async throws
    func checkInStatus() async throws -> CheckInStatistics
    func checkIn() async throws -> CheckInResult
}

protocol SessionStore: Sendable {
    func cookies(for accountID: AccountID) async throws -> [SessionCookie]
    func save(cookies: [SessionCookie], for accountID: AccountID) async throws
    func remove(accountID: AccountID) async throws
}
