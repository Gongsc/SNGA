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
    /// 1.8.2 起就存在的 NGA 编码。C13 回填完之后只剩兼容读取，下个版本删掉。
    var forumID: Int64
    /// 版面所属站点。带默认值，老库走轻量迁移。
    var forumSiteRaw: String = ForumSite.nga.rawValue
    /// 站点自己的版面键。老行是空的，由 C13 一次性回填。
    var forumKey: String = ""
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
        self.forumID = forum.id.ngaRawValue ?? 0
        self.forumSiteRaw = forum.id.site.rawValue
        self.forumKey = forum.id.key
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

    var forumIdentifier: ForumID {
        ForumID(storedSite: forumSiteRaw, key: forumKey, legacyNGAValue: forumID)
    }

    var forum: Forum {
        let id = forumIdentifier
        return Forum(
            id: id,
            name: forumName,
            subtitle: forumSubtitle,
            isSubforum: id.ngaIsSubforum
        )
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
    var parentForumSiteRaw: String = ForumSite.nga.rawValue
    var parentForumKey: String = ""
    var selectedForumIDsRaw: String
    /// 逗号分隔的版面键。键里不含逗号，所以分隔符沿用逗号。
    var selectedForumKeysRaw: String = ""
    var updatedAt: Date

    init(
        accountID: AccountID,
        parentForumID: ForumID,
        selectedForumIDs: Set<ForumID>
    ) {
        self.id = Self.recordID(accountID: accountID, parentForumID: parentForumID)
        self.accountIDString = accountID.description
        self.parentForumID = parentForumID.ngaRawValue ?? 0
        self.parentForumSiteRaw = parentForumID.site.rawValue
        self.parentForumKey = parentForumID.key
        self.selectedForumIDsRaw = Self.encode(selectedForumIDs)
        self.selectedForumKeysRaw = Self.encodeKeys(selectedForumIDs)
        self.updatedAt = Date()
    }

    var parentForumIdentifier: ForumID {
        ForumID(storedSite: parentForumSiteRaw, key: parentForumKey, legacyNGAValue: parentForumID)
    }

    var selectedForumIDs: Set<ForumID> {
        get {
            guard selectedForumKeysRaw.isEmpty else {
                let site = ForumSite(rawValue: parentForumSiteRaw) ?? .nga
                return Set(
                    selectedForumKeysRaw
                        .split(separator: ",")
                        .map { ForumID(site: site, key: String($0)) }
                )
            }
            // C13 回填之前的老行只有 Int64。
            return Set(
                selectedForumIDsRaw
                    .split(separator: ",")
                    .compactMap { Int64($0) }
                    .map { ForumID(ngaStoredValue: $0) }
            )
        }
        set {
            selectedForumIDsRaw = Self.encode(newValue)
            selectedForumKeysRaw = Self.encodeKeys(newValue)
            updatedAt = Date()
        }
    }

    static func recordID(accountID: AccountID, parentForumID: ForumID) -> String {
        "\(accountID.description):\(parentForumID.ngaRawValue ?? 0)"
    }

    private static func encode(_ forumIDs: Set<ForumID>) -> String {
        forumIDs
            .compactMap(\.ngaRawValue)
            .sorted()
            .map(String.init)
            .joined(separator: ",")
    }

    static func encodeKeys(_ forumIDs: Set<ForumID>) -> String {
        forumIDs
            .map(\.key)
            .sorted()
            .joined(separator: ",")
    }
}

@Model
final class RecentForumRecord {
    @Attribute(.unique) var id: String
    var accountIDString: String
    var forumID: Int64
    var forumSiteRaw: String = ForumSite.nga.rawValue
    var forumKey: String = ""
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
        self.forumID = forum.id.ngaRawValue ?? 0
        self.forumSiteRaw = forum.id.site.rawValue
        self.forumKey = forum.id.key
        self.forumName = forum.name
        self.forumSubtitle = forum.subtitle
        self.forumIconURLString = forum.iconURL?.absoluteString
        self.forumCategory = forum.category
        self.pinnedTopicID = forum.pinnedTopicID?.rawValue
        self.lastVisitedAt = lastVisitedAt
    }

    var forumIdentifier: ForumID {
        ForumID(storedSite: forumSiteRaw, key: forumKey, legacyNGAValue: forumID)
    }

    var forum: Forum {
        let id = forumIdentifier
        return Forum(
            id: id,
            name: forumName,
            subtitle: forumSubtitle,
            iconURL: forumIconURLString.flatMap(URL.init(string:)),
            category: forumCategory,
            pinnedTopicID: pinnedTopicID.map(TopicID.init(rawValue:)),
            isSubforum: id.ngaIsSubforum
        )
    }

    func update(forum: Forum, visitedAt: Date?) {
        forumSiteRaw = forum.id.site.rawValue
        forumKey = forum.id.key
        forumName = forum.name
        forumSubtitle = forum.subtitle
        if let iconURL = forum.iconURL {
            forumIconURLString = iconURL.absoluteString
        }
        forumCategory = forum.category
        pinnedTopicID = forum.pinnedTopicID?.rawValue
        if let visitedAt {
            lastVisitedAt = visitedAt
        }
    }

    static func recordID(accountID: AccountID, forumID: ForumID) -> String {
        "\(accountID.description):\(forumID.ngaRawValue ?? 0)"
    }
}
