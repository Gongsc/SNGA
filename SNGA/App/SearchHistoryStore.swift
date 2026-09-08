import Foundation
import Observation
import SwiftData

/// 搜索历史域：用户搜过的关键词，按时间从新到旧。
///
/// 只存关键词。不存结果 —— 结果是一份会过期的抓取，历史要的是「点一下重搜一次」；
/// 也不存档位和版面 —— 全站面板和版面内那条栏共用同一份历史，同一个词在两处
/// 各存一行，十条的位置一半会被同义的行占掉。
///
/// 和 `RecentForumRecord` 一样按账号存，于是天然按站点隔离：NGA 上搜的词不会
/// 出现在 NodeSeek 那条栏底下 —— 两个站的关键词根本不是一回事（版面名、用户名
/// 在对方站上什么也搜不到）。
@MainActor
@Observable
final class SearchHistoryStore {
    /// 从新到旧，已经按上限截断过。视图只读这一份，不再自己排序或截断。
    private(set) var entries: [String] = []

    @ObservationIgnored private let session: AppSession

    init(session: AppSession) {
        self.session = session
    }

    /// 读当前账号的历史。切账号、加账号、删账号之后都要重来一遍。
    func reload() {
        guard let activeAccountID = session.activeAccountID else {
            entries = []
            return
        }
        do {
            let maximumCount = SearchHistorySettings.maximumCount
            let records = try sortedRecords(accountID: activeAccountID)
            // 上限调小之后多出来的老行在这里落地删掉，而不是留在库里等下次
            // 调大又冒出来 —— 用户按「只留 5 条」时想的是「其余的没了」。
            let discardedRecords = records.dropFirst(maximumCount)
            discardedRecords.forEach(session.context.delete)
            if !discardedRecords.isEmpty {
                try session.context.save()
            }
            entries = records.prefix(maximumCount).map(\.query)
        } catch {
            entries = []
            session.present(error)
        }
    }

    /// 记一次搜索。
    ///
    /// 同一个词只有一行，重搜是把时间往前挪。翻页和刷新也会走到这里（它们重发的是
    /// 同一个请求），挪一次时间没有副作用 —— 而记在「发出去」这一刻而不是「搜成功」
    /// 那一刻是有意的：搜挂了的词恰恰是用户最想再点一次的。
    func record(_ query: String) {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty,
              let activeAccountID = session.activeAccountID else {
            return
        }
        do {
            let recordID = SearchHistoryRecord.recordID(
                accountID: activeAccountID,
                query: query
            )
            let records = try self.records(accountID: activeAccountID)
            if let record = records.first(where: { $0.id == recordID }) {
                record.lastSearchedAt = .now
            } else {
                session.context.insert(SearchHistoryRecord(
                    accountID: activeAccountID,
                    query: query
                ))
            }
            try session.context.save()
            reload()
        } catch {
            session.present(error)
        }
    }

    func remove(_ query: String) {
        guard let activeAccountID = session.activeAccountID else { return }
        do {
            let recordID = SearchHistoryRecord.recordID(
                accountID: activeAccountID,
                query: query
            )
            try records(accountID: activeAccountID)
                .filter { $0.id == recordID }
                .forEach(session.context.delete)
            try session.context.save()
            reload()
        } catch {
            session.present(error)
        }
    }

    /// 清空当前账号的历史。别的账号的历史不动 —— 清的是「我搜过什么」。
    func clear() {
        guard let activeAccountID = session.activeAccountID else { return }
        do {
            try records(accountID: activeAccountID).forEach(session.context.delete)
            try session.context.save()
            reload()
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

    /// 改上限。调小时立刻把多出来的行删掉，和最近访问版面的处理一致。
    func updateLimit(_ maximumCount: Int) {
        let maximumCount = SearchHistorySettings.normalizedMaximumCount(maximumCount)
        UserDefaults.standard.set(
            maximumCount,
            forKey: SearchHistorySettings.maximumCountKey
        )
        do {
            let records = try session.context.fetch(FetchDescriptor<SearchHistoryRecord>())
            let groupedRecords = Dictionary(grouping: records, by: \.accountIDString)
            var removedAnyRecord = false
            for accountRecords in groupedRecords.values {
                let sortedRecords = accountRecords.sorted(by: recordComesFirst)
                for record in sortedRecords.dropFirst(maximumCount) {
                    session.context.delete(record)
                    removedAnyRecord = true
                }
            }
            if removedAnyRecord {
                try session.context.save()
            }
            reload()
        } catch {
            session.present(error)
        }
    }

    private func records(accountID: AccountID) throws -> [SearchHistoryRecord] {
        try session.context.fetch(FetchDescriptor<SearchHistoryRecord>())
            .filter { $0.accountIDString == accountID.description }
    }

    private func sortedRecords(accountID: AccountID) throws -> [SearchHistoryRecord] {
        try records(accountID: accountID).sorted(by: recordComesFirst)
    }

    /// 同一毫秒里插进来的两行（测试里会遇到）用关键词兜底定序，免得顺序随机。
    private func recordComesFirst(
        _ left: SearchHistoryRecord,
        _ right: SearchHistoryRecord
    ) -> Bool {
        if left.lastSearchedAt != right.lastSearchedAt {
            return left.lastSearchedAt > right.lastSearchedAt
        }
        return left.query < right.query
    }
}
