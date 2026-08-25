import Foundation
import SwiftData

/// 把老版本写下的行补齐：站点、版面键，以及按新规则重算的主键。
///
/// C12 给三张表加了 `forumSiteRaw` 和 `forumKey` 两列并开始双写，但已经存在的行
/// 只有那个 NGA Int64。读取端会回落，所以功能不受影响；这里把存量一次补完，
/// 好让下一个版本可以干净地把 Int64 那一列删掉。
///
/// 同一趟里把 `RecentForumRecord` 和 `SubforumPreferenceRecord` 的主键也换成按
/// 「账号 + 站点 + 键」拼的形式。这两件事必须一起做：主键的算法一改，老行就再也
/// 查不到了，接着会被当成新行插进去，变成重复。
///
/// 整趟是幂等的。做完才记标记，中途崩了下次重来 —— 已经补好的行键不为空会被跳过，
/// 主键重算出来和上次相同，再赋一次值没有影响。
enum LegacyStoreBackfill {
    private static let versionKey = "forumKeyBackfillVersion"
    private static let currentVersion = 2

    static func runIfNeeded(
        in context: ModelContext,
        defaults: UserDefaults = .standard
    ) {
        guard defaults.integer(forKey: versionKey) < currentVersion else { return }
        run(in: context)
        defaults.set(currentVersion, forKey: versionKey)
    }

    /// 不看标记直接跑一趟。测试用，也留给以后需要强制重来的情况。
    static func run(in context: ModelContext) {
        var touched = 0
        touched += backfillFavorites(in: context)
        touched += backfillRecentForums(in: context)
        touched += backfillSubforumPreferences(in: context)
        touched += backfillAIProfiles(in: context)

        guard touched > 0 else { return }
        do {
            try context.save()
        } catch {
            // 存不下就让标记不落地，下次启动再来一趟。
            Task {
                await RuntimeLogger.shared.log(
                    .error,
                    category: "storage",
                    "版面键回填失败：\(error.localizedDescription)"
                )
            }
            return
        }
        Task {
            await RuntimeLogger.shared.log(
                category: "storage",
                "版面键回填完成，处理 \(touched) 行"
            )
        }
    }

    private static func backfillFavorites(in context: ModelContext) -> Int {
        let records = (try? context.fetch(FetchDescriptor<FavoriteRecord>())) ?? []
        var touched = 0
        for record in records where record.forumKey.isEmpty {
            let forumID = ForumID(ngaStoredValue: record.forumID)
            record.forumSiteRaw = forumID.site.rawValue
            record.forumKey = forumID.key
            touched += 1
        }
        return touched
    }

    private static func backfillRecentForums(in context: ModelContext) -> Int {
        let records = (try? context.fetch(FetchDescriptor<RecentForumRecord>())) ?? []
        var touched = 0
        for record in records {
            if record.forumKey.isEmpty {
                let forumID = ForumID(ngaStoredValue: record.forumID)
                record.forumSiteRaw = forumID.site.rawValue
                record.forumKey = forumID.key
                touched += 1
            }
            guard let accountID = AccountID(record.accountIDString) else { continue }
            let expected = RecentForumRecord.recordID(
                accountID: accountID,
                forumID: record.forumIdentifier
            )
            if record.id != expected {
                record.id = expected
                touched += 1
            }
        }
        return touched
    }

    /// 画像原本按裸 uid 存，两个站的同号用户会共用一条。主键改成带站点之后，
    /// 老行要跟着改 —— 不改的话下次生成会新插一条，列表里出现两条同一个人的画像。
    ///
    /// 画像是可再生的缓存，清掉也不会错，但它是花过 token 生成的，能留就留。
    private static func backfillAIProfiles(in context: ModelContext) -> Int {
        let records = (try? context.fetch(FetchDescriptor<AIProfileSummaryRecord>())) ?? []
        var touched = 0
        for record in records {
            let expected = AIProfileSummaryRecord.recordID(site: record.site, uid: record.uid)
            if record.id != expected {
                record.id = expected
                touched += 1
            }
        }
        return touched
    }

    private static func backfillSubforumPreferences(in context: ModelContext) -> Int {
        let records = (try? context.fetch(FetchDescriptor<SubforumPreferenceRecord>())) ?? []
        var touched = 0
        for record in records {
            if record.parentForumKey.isEmpty {
                let parentForumID = ForumID(ngaStoredValue: record.parentForumID)
                record.parentForumSiteRaw = parentForumID.site.rawValue
                record.parentForumKey = parentForumID.key
                touched += 1
            }
            if record.selectedForumKeysRaw.isEmpty, !record.selectedForumIDsRaw.isEmpty {
                // getter 此时读的还是 Int64 那一列，正好拿来当来源。
                record.selectedForumKeysRaw = SubforumPreferenceRecord
                    .encodeKeys(record.selectedForumIDs)
                touched += 1
            }
            guard let accountID = AccountID(record.accountIDString) else { continue }
            let expected = SubforumPreferenceRecord.recordID(
                accountID: accountID,
                parentForumID: record.parentForumIdentifier
            )
            if record.id != expected {
                record.id = expected
                touched += 1
            }
        }
        return touched
    }
}
