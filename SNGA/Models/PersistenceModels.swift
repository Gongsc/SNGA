import Foundation
import SwiftData

@Model
final class AccountRecord {
    @Attribute(.unique) var id: UUID
    var ngaUID: Int64
    var displayName: String
    var avatarURLString: String?
    var sessionStateRaw: String
    var isCurrent: Bool
    var createdAt: Date
    var lastCheckInDay: String?
    var lastCheckInMessage: String?
    var unreadBaseline: Int?
    var seenUnreadMessageKeysRaw: String?
    var readNotificationKeysRaw: String?

    init(
        id: UUID = UUID(),
        ngaUID: Int64,
        displayName: String,
        avatarURLString: String? = nil,
        sessionState: SessionState = .valid,
        isCurrent: Bool = false
    ) {
        self.id = id
        self.ngaUID = ngaUID
        self.displayName = displayName
        self.avatarURLString = avatarURLString
        self.sessionStateRaw = sessionState.rawValue
        self.isCurrent = isCurrent
        self.createdAt = Date()
    }

    var accountID: AccountID { AccountID(rawValue: id) }
    var seenUnreadMessageKeys: [String]? {
        get {
            seenUnreadMessageKeysRaw?.split(separator: "\n").map(String.init)
        }
        set {
            seenUnreadMessageKeysRaw = newValue?.joined(separator: "\n")
        }
    }

    var readNotificationKeys: [String] {
        get {
            readNotificationKeysRaw?.split(separator: "\n").map(String.init) ?? []
        }
        set {
            readNotificationKeysRaw = newValue.isEmpty ? nil : newValue.joined(separator: "\n")
        }
    }

    var sessionState: SessionState {
        get { SessionState(rawValue: sessionStateRaw) ?? .temporaryFailure }
        set { sessionStateRaw = newValue.rawValue }
    }

    func summary() -> AccountSummary {
        AccountSummary(
            id: accountID,
            ngaUID: ngaUID,
            displayName: displayName,
            avatarURL: avatarURLString.flatMap(URL.init(string:)),
            sessionState: sessionState,
            isCurrent: isCurrent
        )
    }
}

@Model
final class FavoriteRecord {
    @Attribute(.unique) var id: UUID
    var accountIDString: String
    var forumID: Int64
    var forumName: String
    var forumSubtitle: String?
    var order: Int
    var syncStateRaw: String
    var serverPresent: Bool
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        accountID: AccountID,
        forum: Forum,
        order: Int,
        syncState: FavoriteSyncState,
        serverPresent: Bool
    ) {
        self.id = id
        self.accountIDString = accountID.description
        self.forumID = forum.id.rawValue
        self.forumName = forum.name
        self.forumSubtitle = forum.subtitle
        self.order = order
        self.syncStateRaw = syncState.rawValue
        self.serverPresent = serverPresent
        self.updatedAt = Date()
    }

    var syncState: FavoriteSyncState {
        get { FavoriteSyncState(rawValue: syncStateRaw) ?? .localOnly }
        set { syncStateRaw = newValue.rawValue }
    }

    var forum: Forum {
        Forum(id: ForumID(rawValue: forumID), name: forumName, subtitle: forumSubtitle)
    }
}

@Model
final class DraftRecord {
    @Attribute(.unique) var id: String
    var accountIDString: String
    var topicID: Int64
    var replyToPostID: Int64?
    var content: String
    var updatedAt: Date

    init(accountID: AccountID, topicID: TopicID, replyToPostID: PostID? = nil, content: String = "") {
        self.id = "\(accountID.description):\(topicID.rawValue)"
        self.accountIDString = accountID.description
        self.topicID = topicID.rawValue
        self.replyToPostID = replyToPostID?.rawValue
        self.content = content
        self.updatedAt = Date()
    }
}

@Model
final class SubforumPreferenceRecord {
    @Attribute(.unique) var id: String
    var accountIDString: String
    var parentForumID: Int64
    var selectedForumIDsRaw: String
    var updatedAt: Date

    init(
        accountID: AccountID,
        parentForumID: ForumID,
        selectedForumIDs: Set<ForumID>
    ) {
        self.id = Self.recordID(accountID: accountID, parentForumID: parentForumID)
        self.accountIDString = accountID.description
        self.parentForumID = parentForumID.rawValue
        self.selectedForumIDsRaw = Self.encode(selectedForumIDs)
        self.updatedAt = Date()
    }

    var selectedForumIDs: Set<ForumID> {
        get {
            Set(
                selectedForumIDsRaw
                    .split(separator: ",")
                    .compactMap { Int64($0) }
                    .map { ForumID(rawValue: $0) }
            )
        }
        set {
            selectedForumIDsRaw = Self.encode(newValue)
            updatedAt = Date()
        }
    }

    static func recordID(accountID: AccountID, parentForumID: ForumID) -> String {
        "\(accountID.description):\(parentForumID.rawValue)"
    }

    private static func encode(_ forumIDs: Set<ForumID>) -> String {
        forumIDs
            .map(\.rawValue)
            .sorted()
            .map(String.init)
            .joined(separator: ",")
    }
}

@Model
final class RecentForumRecord {
    @Attribute(.unique) var id: String
    var accountIDString: String
    var forumID: Int64
    var forumName: String
    var forumSubtitle: String?
    var forumIconURLString: String?
    var forumCategory: String?
    var pinnedTopicID: Int64?
    var lastVisitedAt: Date

    init(
        accountID: AccountID,
        forum: Forum,
        lastVisitedAt: Date = .now
    ) {
        self.id = Self.recordID(accountID: accountID, forumID: forum.id)
        self.accountIDString = accountID.description
        self.forumID = forum.id.rawValue
        self.forumName = forum.name
        self.forumSubtitle = forum.subtitle
        self.forumIconURLString = forum.iconURL?.absoluteString
        self.forumCategory = forum.category
        self.pinnedTopicID = forum.pinnedTopicID?.rawValue
        self.lastVisitedAt = lastVisitedAt
    }

    var forum: Forum {
        Forum(
            id: ForumID(rawValue: forumID),
            name: forumName,
            subtitle: forumSubtitle,
            iconURL: forumIconURLString.flatMap(URL.init(string:)),
            category: forumCategory,
            pinnedTopicID: pinnedTopicID.map(TopicID.init(rawValue:))
        )
    }

    func update(forum: Forum, visitedAt: Date?) {
        forumName = forum.name
        forumSubtitle = forum.subtitle
        forumIconURLString = forum.iconURL?.absoluteString
        forumCategory = forum.category
        pinnedTopicID = forum.pinnedTopicID?.rawValue
        if let visitedAt {
            lastVisitedAt = visitedAt
        }
    }

    static func recordID(accountID: AccountID, forumID: ForumID) -> String {
        "\(accountID.description):\(forumID.rawValue)"
    }
}
