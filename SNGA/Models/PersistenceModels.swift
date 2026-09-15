import Foundation
import SwiftData

@Model
final class AccountRecord {
    @Attribute(.unique) var id: UUID
    /// 账号属于哪个站。带默认值，老库走轻量迁移 —— 1.8.2 的账号全是 NGA 的。
    var siteRaw: String = ForumSite.nga.rawValue
    /// 用户在该站的编号。老库里这一列叫 `ngaUID`。
    @Attribute(originalName: "ngaUID") var siteUserID: Int64
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
        site: ForumSite,
        siteUserID: Int64,
        displayName: String,
        avatarURLString: String? = nil,
        sessionState: SessionState = .valid,
        isCurrent: Bool = false
    ) {
        self.id = id
        self.siteRaw = site.rawValue
        self.siteUserID = siteUserID
        self.displayName = displayName
        self.avatarURLString = avatarURLString
        self.sessionStateRaw = sessionState.rawValue
        self.isCurrent = isCurrent
        self.createdAt = Date()
    }

    var accountID: AccountID { AccountID(rawValue: id) }

    var site: ForumSite {
        get { ForumSite(rawValue: siteRaw) ?? .nga }
        set { siteRaw = newValue.rawValue }
    }
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
            site: site,
            siteUserID: siteUserID,
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
        "\(accountID.description):\(parentForumID.site.rawValue):\(parentForumID.key)"
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
        "\(accountID.description):\(forumID.site.rawValue):\(forumID.key)"
    }
}

/// 一条搜索历史 —— 只有关键词，没有结果，也没有搜的是哪一档。
///
/// 不存档位是有意的：同一个词换个档位再搜一次，用户心里还是「我搜过这个词」，
/// 存成两行只会把十条的位置占掉一半。结果更不能存 —— 它是一份会过期的抓取，
/// 而历史要的是「下次点一下能重搜」。
@Model
final class SearchHistoryRecord {
    /// 主键以账号打头，和别的表一样天然按站点隔离；关键词直接接在后面，
    /// 于是「同一个账号搜过的同一个词」只可能有一行 —— 重搜是把时间往前挪，
    /// 不是再插一行。
    @Attribute(.unique) var id: String
    var accountIDString: String
    var query: String
    var lastSearchedAt: Date

    init(accountID: AccountID, query: String, lastSearchedAt: Date = .now) {
        self.id = Self.recordID(accountID: accountID, query: query)
        self.accountIDString = accountID.description
        self.query = query
        self.lastSearchedAt = lastSearchedAt
    }

    static func recordID(accountID: AccountID, query: String) -> String {
        "\(accountID.description):\(query)"
    }
}

/// 读过的一条话题。
///
/// 一张表同时供着两件事：列表里「读过的变灰」和侧栏那个「浏览历史」。它们本来
/// 就是同一个事实 —— 灰掉的就是历史里有的那些，浏览器几十年来也是这么做的。
/// 拆成两张表（一份只存 id 的已读集合，一份带标题的历史）能让已读集合存得更久，
/// 但代价是用户要理解两个上限、两处清空，而「我明明刚看过它，怎么不是灰的」
/// 这种疑问会从「历史满了」变成一件更难解释的事。
///
/// 主键和别的表一样以 `accountIDString` 打头，于是天然按账号、按站点隔离 ——
/// 这一条对话题尤其要紧：`TopicID` 只是个 `Int64`，两个站上撞号是迟早的事。
@Model
final class TopicVisitRecord {
    @Attribute(.unique) var id: String
    var accountIDString: String
    var topicID: Int64
    /// 话题所属版面。回头从历史里点开它时要靠这个还原出一个 `Topic`。
    var forumSiteRaw: String = ForumSite.nga.rawValue
    var forumKey: String = ""
    var subject: String
    var author: String
    var authorUID: Int64?
    /// 存下当时的回复数：`ThreadStore.open` 拿它预估总页数，少了它从历史点进去
    /// 的话题会先画成一页、再跳成十几页。
    var replyCount: Int = 0
    var lastVisitedAt: Date

    init(accountID: AccountID, topic: Topic, lastVisitedAt: Date = .now) {
        self.id = Self.recordID(accountID: accountID, topicID: topic.id)
        self.accountIDString = accountID.description
        self.topicID = topic.id.rawValue
        self.forumSiteRaw = topic.forumID.site.rawValue
        self.forumKey = topic.forumID.key
        self.subject = topic.subject
        self.author = topic.author
        self.authorUID = topic.authorUID
        self.replyCount = topic.replyCount
        self.lastVisitedAt = lastVisitedAt
    }

    /// 再读一次同一条话题：把时间往前挪，顺便补齐当初可能没有的信息。
    ///
    /// 从私信或用户动态点进去的话题带的是占位版面和空作者（那两处给不出）。
    /// 后来在版面列表里又点了同一条，这里就该把真的版面和作者补上，而不是
    /// 守着第一次那份残缺的记录。
    func update(topic: Topic, visitedAt: Date = .now) {
        if topic.forumID != .placeholder(site: topic.forumID.site) {
            forumSiteRaw = topic.forumID.site.rawValue
            forumKey = topic.forumID.key
        }
        if !topic.subject.isEmpty { subject = topic.subject }
        if !topic.author.isEmpty { author = topic.author }
        if let authorUID = topic.authorUID { self.authorUID = authorUID }
        if topic.replyCount > 0 { replyCount = topic.replyCount }
        lastVisitedAt = visitedAt
    }

    var forumIdentifier: ForumID {
        ForumID(storedSite: forumSiteRaw, key: forumKey, legacyNGAValue: 0)
    }

    var topic: Topic {
        Topic(
            id: TopicID(rawValue: topicID),
            forumID: forumIdentifier,
            subject: subject,
            author: author,
            authorUID: authorUID,
            replyCount: replyCount
        )
    }

    static func recordID(accountID: AccountID, topicID: TopicID) -> String {
        "\(accountID.description):\(topicID.rawValue)"
    }
}
