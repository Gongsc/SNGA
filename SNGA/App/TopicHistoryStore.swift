import Foundation
import Observation
import SwiftData

enum TopicHistorySettings {
    /// 记不记。关掉之后一条都不写，已经存下的也全部删掉 —— 关这个开关的人
    /// 想的是「别留记录」，而不是「从现在起别再记了，之前的留着」。
    static let enabledKey = "browsing.topicHistory.enabled"
    /// 读过的话题在列表里变不变灰。
    static let dimsVisitedKey = "browsing.topicHistory.dimsVisited"
    static let maximumCountKey = "browsing.topicHistory.maximumCount"
    static let retentionDaysKey = "browsing.topicHistory.retentionDays"

    /// 条数上限定得比「一屏能看完的历史」大得多，是因为这张表同时供着变灰那件事。
    ///
    /// 上限一小，「我二十分钟前刚看过它，怎么不是灰的」就会时不时冒出来 ——
    /// 在一个热闹的版面里翻几页就能把一份一百条的历史挤掉。历史面板那边有搜索
    /// 也按天分了组，五百条并不难翻。
    static let defaultMaximumCount = 500
    static let maximumCountRange = 100...5000
    static let maximumCountStep = 100

    /// 保留天数。到期的行会在下一次读历史时删掉，变灰也跟着到期 ——
    /// 一个月前读过的帖子重新显示成没读过，和浏览器的行为一致。
    static let defaultRetentionDays = 30
    static let retentionDaysRange = 1...365

    static var isEnabled: Bool {
        boolValue(forKey: enabledKey, default: true)
    }

    static var dimsVisitedTopics: Bool {
        boolValue(forKey: dimsVisitedKey, default: true)
    }

    static var maximumCount: Int {
        intValue(forKey: maximumCountKey, default: defaultMaximumCount, in: maximumCountRange)
    }

    static var retentionDays: Int {
        intValue(forKey: retentionDaysKey, default: defaultRetentionDays, in: retentionDaysRange)
    }

    static func normalizedMaximumCount(_ value: Int) -> Int {
        normalized(value, in: maximumCountRange)
    }

    static func normalizedRetentionDays(_ value: Int) -> Int {
        normalized(value, in: retentionDaysRange)
    }

    static func normalized(_ value: Int, in range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }

    private static func boolValue(forKey key: String, default fallback: Bool) -> Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: key) != nil else { return fallback }
        return defaults.bool(forKey: key)
    }

    private static func intValue(
        forKey key: String,
        default fallback: Int,
        in range: ClosedRange<Int>
    ) -> Int {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: key) != nil else { return fallback }
        return normalized(defaults.integer(forKey: key), in: range)
    }
}

/// 浏览历史域：读过哪些话题、什么时候读的。
///
/// 供着两处：侧栏那个「浏览历史」，以及话题列表里「读过的变灰」。两处读的是同
/// 一份数据，见 `TopicVisitRecord` 上的注释。
///
/// 和别的域不一样的地方是它**不重新查库**。搜索历史只有十来条，每记一次就整表
/// 读一遍无所谓；这里默认五百条上限，而写入发生在每一次打开话题 —— 那一下正是
/// 用户在等页面出来的时候，不该拿去整表扫描。所以内存里留一份完整的列表和一个
/// 编号集合，写库只写变动的那一行。
@MainActor
@Observable
final class TopicHistoryStore {
    /// 从新到旧，已经按上限和天数裁过。视图只读这一份。
    private(set) var entries: [TopicVisit] = []
    /// 变灰只问这一份。视图一屏几十行，每行都去数组里找一遍是几十次线性查找。
    private(set) var visitedTopicIDs: Set<TopicID> = []

    @ObservationIgnored private let session: AppSession
    /// 内存里这份列表是哪个账号的。
    ///
    /// 因为这个 store 记账时不重新查库，它必须知道手上这份是不是当前账号的 ——
    /// 否则在还没 `reload` 过的账号上记一笔，会在一份空列表上往前插，之后
    /// 「读过的变灰」对更早那些话题就一律答不知道，直到下一次 `reload`。
    @ObservationIgnored private var loadedAccountID: AccountID?

    init(session: AppSession) {
        self.session = session
    }

    func hasVisited(_ topicID: TopicID) -> Bool {
        visitedTopicIDs.contains(topicID)
    }

    /// 读当前账号的历史，顺便把过期和超额的行落地删掉。
    /// 切账号、加账号、删账号、改上限之后都要重来一遍。
    func reload() {
        guard let activeAccountID = session.activeAccountID else {
            reset()
            return
        }
        loadedAccountID = activeAccountID
        guard TopicHistorySettings.isEnabled else {
            // 关着的时候不光不记，连读都不读：内存里留着一份「上次开着时」的
            // 历史，列表照样会变灰，看上去像是开关没生效。
            entries = []
            visitedTopicIDs = []
            return
        }
        do {
            let records = try sortedRecords(accountID: activeAccountID)
            let kept = prune(records)
            entries = kept.map(\.visit)
            visitedTopicIDs = Set(entries.map(\.id))
        } catch {
            entries = []
            visitedTopicIDs = []
            session.present(error)
        }
    }

    /// 记一次「打开了这条话题」。
    ///
    /// 记在打开这一刻，而不是内容加载成功那一刻：加载失败的话题恰恰是用户还会
    /// 再点一次的那条，把它从历史里漏掉，他就只能自己回想刚才点的是哪一条。
    func record(_ topic: Topic) {
        guard TopicHistorySettings.isEnabled,
              let activeAccountID = session.activeAccountID else {
            return
        }
        // 手上这份列表不是这个账号的就先读一遍 —— 见 `loadedAccountID`。
        if loadedAccountID != activeAccountID {
            reload()
        }
        do {
            let recordID = TopicVisitRecord.recordID(
                accountID: activeAccountID,
                topicID: topic.id
            )
            let visitRecord: TopicVisitRecord
            if let existing = try record(id: recordID) {
                existing.update(topic: topic)
                visitRecord = existing
            } else {
                let inserted = TopicVisitRecord(accountID: activeAccountID, topic: topic)
                session.context.insert(inserted)
                visitRecord = inserted
            }
            try session.context.save()
            // 内存里就地挪到最前，不重新查库 —— 见类型注释里那一段。
            //
            // 读的是合并之后那一行，不是传进来的 `topic`：从私信点进去的话题带的是
            // 占位版面和空作者，`update` 会保住之前存的真值，而这里要是按传进来的
            // 那份建，面板上刚读过的那条反而会把作者名丢掉。
            let visit = visitRecord.visit
            entries.removeAll { $0.id == topic.id }
            entries.insert(visit, at: 0)
            visitedTopicIDs.insert(topic.id)
            try trimOverflow(accountID: activeAccountID)
        } catch {
            session.present(error)
        }
    }

    func remove(_ topicID: TopicID) {
        guard let activeAccountID = session.activeAccountID else { return }
        do {
            let recordID = TopicVisitRecord.recordID(
                accountID: activeAccountID,
                topicID: topicID
            )
            if let record = try record(id: recordID) {
                session.context.delete(record)
                try session.context.save()
            }
            entries.removeAll { $0.id == topicID }
            visitedTopicIDs.remove(topicID)
        } catch {
            session.present(error)
        }
    }

    private func reset() {
        entries = []
        visitedTopicIDs = []
        loadedAccountID = nil
    }

    /// 清空当前账号的历史。别的账号不动 —— 清的是「我读过什么」。
    func clear() {
        guard let activeAccountID = session.activeAccountID else { return }
        do {
            try records(accountID: activeAccountID).forEach(session.context.delete)
            try session.context.save()
            entries = []
            visitedTopicIDs = []
        } catch {
            session.present(error)
        }
    }

    /// 删掉某个账号的全部历史。账号被移除时调用。
    func removeAll(accountID: AccountID) {
        do {
            try records(accountID: accountID).forEach(session.context.delete)
            try session.context.save()
        } catch {
            session.present(error)
        }
    }

    /// 总开关关掉时把已经存下的一并删掉，所有账号都清。
    ///
    /// 只停止记录、留着旧账，等于把「别留记录」办成了「从今天起别留」——
    /// 关这个开关的人想删的正是之前那些。
    func applyEnabledChange(_ isEnabled: Bool) {
        UserDefaults.standard.set(isEnabled, forKey: TopicHistorySettings.enabledKey)
        guard !isEnabled else {
            reload()
            return
        }
        do {
            try session.context.fetch(FetchDescriptor<TopicVisitRecord>())
                .forEach(session.context.delete)
            try session.context.save()
        } catch {
            session.present(error)
        }
        reset()
    }

    /// 改条数上限。调小时立刻把多出来的行删掉，和最近访问版面、搜索历史一致 ——
    /// 按「只留 200 条」时想的是「其余的没了」。
    func updateMaximumCount(_ maximumCount: Int) {
        UserDefaults.standard.set(
            TopicHistorySettings.normalizedMaximumCount(maximumCount),
            forKey: TopicHistorySettings.maximumCountKey
        )
        pruneEveryAccount()
    }

    func updateRetentionDays(_ retentionDays: Int) {
        UserDefaults.standard.set(
            TopicHistorySettings.normalizedRetentionDays(retentionDays),
            forKey: TopicHistorySettings.retentionDaysKey
        )
        pruneEveryAccount()
    }

    // MARK: - 裁剪

    /// 每个账号各裁各的。上限是「每个账号留多少条」，不是「一共留多少条」——
    /// 后者会让常用的那个账号把别的账号的历史挤光。
    private func pruneEveryAccount() {
        do {
            let records = try session.context.fetch(FetchDescriptor<TopicVisitRecord>())
            let grouped = Dictionary(grouping: records, by: \.accountIDString)
            for accountRecords in grouped.values {
                prune(accountRecords.sorted(by: recordComesFirst), savesContext: false)
            }
            try session.context.save()
            reload()
        } catch {
            session.present(error)
        }
    }

    /// 删掉过期和超额的行，返回留下的那些（仍是从新到旧）。
    @discardableResult
    private func prune(
        _ sortedRecords: [TopicVisitRecord],
        savesContext: Bool = true
    ) -> [TopicVisitRecord] {
        let cutoff = Date.now.addingTimeInterval(
            -Double(TopicHistorySettings.retentionDays) * 86_400
        )
        let maximumCount = TopicHistorySettings.maximumCount
        var kept: [TopicVisitRecord] = []
        var discarded: [TopicVisitRecord] = []
        for record in sortedRecords {
            if record.lastVisitedAt < cutoff || kept.count >= maximumCount {
                discarded.append(record)
            } else {
                kept.append(record)
            }
        }
        guard !discarded.isEmpty else { return kept }
        discarded.forEach(session.context.delete)
        if savesContext {
            try? session.context.save()
        }
        return kept
    }

    /// 刚记完一条之后把超出上限的尾巴削掉。只在真的超了的时候查一次库。
    private func trimOverflow(accountID: AccountID) throws {
        let maximumCount = TopicHistorySettings.maximumCount
        guard entries.count > maximumCount else { return }
        let overflow = entries[maximumCount...]
        let overflowIDs = Set(overflow.map(\.id))
        entries.removeLast(entries.count - maximumCount)
        overflowIDs.forEach { visitedTopicIDs.remove($0) }
        let overflowRecordIDs = Set(overflowIDs.map {
            TopicVisitRecord.recordID(accountID: accountID, topicID: $0)
        })
        try records(accountID: accountID)
            .filter { overflowRecordIDs.contains($0.id) }
            .forEach(session.context.delete)
        try session.context.save()
    }

    // MARK: - 查库

    private func record(id: String) throws -> TopicVisitRecord? {
        var descriptor = FetchDescriptor<TopicVisitRecord>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try session.context.fetch(descriptor).first
    }

    private func records(accountID: AccountID) throws -> [TopicVisitRecord] {
        let accountIDString = accountID.description
        return try session.context.fetch(FetchDescriptor<TopicVisitRecord>(
            predicate: #Predicate { $0.accountIDString == accountIDString }
        ))
    }

    private func sortedRecords(accountID: AccountID) throws -> [TopicVisitRecord] {
        try records(accountID: accountID).sorted(by: recordComesFirst)
    }

    /// 同一毫秒里插进来的两行（测试里会遇到）用编号兜底定序，免得顺序随机。
    private func recordComesFirst(
        _ left: TopicVisitRecord,
        _ right: TopicVisitRecord
    ) -> Bool {
        if left.lastVisitedAt != right.lastVisitedAt {
            return left.lastVisitedAt > right.lastVisitedAt
        }
        return left.topicID > right.topicID
    }
}

/// 历史里的一条。
///
/// 是个值类型，不是 `TopicVisitRecord` 本身：视图拿着托管对象，账号一切、行一删
/// 就是一堆失效引用；而这一份只是「当时看到的那条话题长什么样」。
struct TopicVisit: Identifiable, Hashable, Sendable {
    let id: TopicID
    var forumID: ForumID
    var subject: String
    var author: String
    var authorUID: Int64?
    var replyCount: Int
    var visitedAt: Date

    /// 还原成一条能打开的话题。
    var topic: Topic {
        Topic(
            id: id,
            forumID: forumID,
            subject: subject,
            author: author,
            authorUID: authorUID,
            replyCount: replyCount
        )
    }

    /// 历史面板里的搜索：标题和作者都算。作者按包含比，和关键字过滤那边的
    /// 作者档不一样 —— 这里是在自己的历史里找东西，找宽一点只是多几条候选。
    func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        let options: String.CompareOptions = [
            .caseInsensitive, .diacriticInsensitive, .widthInsensitive
        ]
        return subject.range(of: query, options: options) != nil
            || author.range(of: query, options: options) != nil
    }
}

private extension TopicVisitRecord {
    var visit: TopicVisit {
        TopicVisit(
            id: TopicID(rawValue: topicID),
            forumID: forumIdentifier,
            subject: subject,
            author: author,
            authorUID: authorUID,
            replyCount: replyCount,
            visitedAt: lastVisitedAt
        )
    }
}
