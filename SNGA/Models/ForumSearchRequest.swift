import Foundation

/// 搜索结果按什么排。
enum ForumSearchSort: String, CaseIterable, Identifiable, Hashable, Sendable {
    /// 站点自己算的相关度。
    case relevance
    /// 发帖时间。
    case postedAt

    var id: String { rawValue }

    var title: String {
        switch self {
        case .relevance: "相关度"
        case .postedAt: "发帖时间"
        }
    }
}

/// 一次搜索的筛选条件。
///
/// 不是每个站都收得下这些 —— 由 `ForumSiteDescriptor.searchFilters(for:)` 说哪几样
/// 画得出来，收不下的那几样界面上根本不画。全是默认值就等于没筛，请求里那几个
/// 参数也一个都不带（带一个空的 `username=` 和不带不是一回事）。
struct ForumSearchFilters: Hashable, Sendable {
    /// 只看这个人发的主题。空串表示不限。
    var author: String = ""
    /// 发帖时间的下界。选的是「哪一天」，含当天。
    var postedAfter: Date?
    /// 发帖时间的上界。选的是「哪一天」，含当天。
    var postedBefore: Date?
    var sort: ForumSearchSort = .relevance
    /// 升序。默认降序 —— 相关度高的、时间新的排前面，两种排法都是这个意思。
    var isAscending: Bool = false

    static let none = ForumSearchFilters()

    var isEmpty: Bool { self == .none }

    var trimmedAuthor: String? {
        let value = author.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

/// 站点的搜索收得下哪几样筛选条件。
///
/// 和 `ForumCapabilities` 分开：那一组说的是「站点有没有这个功能」，这一组细到
/// 「同一个站点的这一档搜索收不收这个参数」—— V2EX 的主题搜索三样全收，
/// 节点搜索一样都不收，而那是同一个站。
struct ForumSearchFilterOptions: OptionSet, Sendable, Hashable {
    let rawValue: Int

    init(rawValue: Int) { self.rawValue = rawValue }

    static let author = ForumSearchFilterOptions(rawValue: 1 << 0)
    static let dateRange = ForumSearchFilterOptions(rawValue: 1 << 1)
    static let sortOrder = ForumSearchFilterOptions(rawValue: 1 << 2)

    static let all: ForumSearchFilterOptions = [.author, .dateRange, .sortOrder]
}

struct ForumSearchRequest: Hashable, Sendable {
    let query: String
    let kind: ForumSearchKind
    let forumID: ForumID?
    /// 附加的筛选条件。站点收不下的那几样由界面挡住，到不了这里。
    var filters: ForumSearchFilters = .none

    init?(
        query: String,
        kind: ForumSearchKind,
        forumID: ForumID? = nil,
        filters: ForumSearchFilters = .none
    ) {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty,
              forumID == nil || kind.supportsCurrentForum else {
            return nil
        }
        self.query = normalizedQuery
        self.kind = kind
        self.forumID = forumID
        self.filters = filters
    }

    var scopeTitle: String {
        forumID == nil ? "全部版面" : "当前版面"
    }
}
