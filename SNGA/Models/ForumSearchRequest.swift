import Foundation

struct ForumSearchRequest: Hashable, Sendable {
    let query: String
    let kind: ForumSearchKind
    let forumID: ForumID?

    init?(query: String, kind: ForumSearchKind, forumID: ForumID? = nil) {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty,
              forumID == nil || kind.supportsCurrentForum else {
            return nil
        }
        self.query = normalizedQuery
        self.kind = kind
        self.forumID = forumID
    }

    var scopeTitle: String {
        forumID == nil ? "全部版面" : "当前版面"
    }
}
