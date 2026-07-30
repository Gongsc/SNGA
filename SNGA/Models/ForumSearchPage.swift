import Foundation

struct ForumSearchPage: Hashable, Sendable {
    let request: ForumSearchRequest
    var topics: [Topic] = []
    var forums: [Forum] = []
    var users: [Profile] = []
    var activities: [UserActivity] = []
    var page: Int = 1
    var hasMore = false
    var totalPages = 1

    var isEmpty: Bool {
        topics.isEmpty && forums.isEmpty && users.isEmpty && activities.isEmpty
    }
}
