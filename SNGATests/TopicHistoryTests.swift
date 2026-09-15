import Foundation
import SwiftData
import XCTest
@testable import SNGA

/// 浏览历史：记什么、去重、按账号隔离、按条数和天数裁剪，以及它同时供着的
/// 「读过的变灰」。
final class TopicHistoryTests: XCTestCase {
    private static let settingKeys = [
        TopicHistorySettings.enabledKey,
        TopicHistorySettings.dimsVisitedKey,
        TopicHistorySettings.maximumCountKey,
        TopicHistorySettings.retentionDaysKey
    ]

    override func setUp() {
        super.setUp()
        Self.settingKeys.forEach(UserDefaults.standard.removeObject(forKey:))
    }

    override func tearDown() {
        Self.settingKeys.forEach(UserDefaults.standard.removeObject(forKey:))
        super.tearDown()
    }

    private func makeContainer(_ name: String) throws -> ModelContainer {
        let schema = Schema([
            AccountRecord.self,
            FavoriteRecord.self,
            DraftRecord.self,
            SubforumPreferenceRecord.self,
            RecentForumRecord.self,
            SearchHistoryRecord.self,
            TopicVisitRecord.self,
            AIProfileSummaryRecord.self
        ])
        return try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(
                "\(name)-\(UUID().uuidString)",
                schema: schema,
                isStoredInMemoryOnly: true
            )]
        )
    }

    private func makeTopic(
        _ id: Int64,
        subject: String? = nil,
        author: String = "某位作者",
        site: ForumSite = .nga,
        forumKey: String = "-7",
        replyCount: Int = 3
    ) -> Topic {
        Topic(
            id: TopicID(rawValue: id),
            forumID: ForumID(site: site, key: forumKey),
            subject: subject ?? "话题 \(id)",
            author: author,
            replyCount: replyCount
        )
    }

    // MARK: - 记什么

    @MainActor
    func testVisitsAreDeduplicatedNewestFirstAndPersisted() throws {
        let container = try makeContainer("TopicHistory")
        let accountID = AccountID(rawValue: UUID())
        let model = AppModel(container: container)
        model.session.activeAccountID = accountID

        model.topicHistory.record(makeTopic(1))
        model.topicHistory.record(makeTopic(2))
        // 再读一次同一条是把它挪到最前，不是插第二行。
        model.topicHistory.record(makeTopic(1))

        XCTAssertEqual(model.topicHistory.entries.map(\.id.rawValue), [1, 2])

        // 重开一次应用，历史还在，顺序也还在。
        let restored = AppModel(container: container)
        restored.session.activeAccountID = accountID
        restored.topicHistory.reload()
        XCTAssertEqual(restored.topicHistory.entries.map(\.id.rawValue), [1, 2])
    }

    /// 历史要留住回去所需的一切：标题、作者、版面和当时的回复数。
    /// 少了版面，从历史点回去就打不开；少了回复数，页数会先画错再跳一次。
    @MainActor
    func testAVisitKeepsEnoughToReopenTheTopic() throws {
        let container = try makeContainer("TopicHistoryPayload")
        let model = AppModel(container: container)
        model.session.activeAccountID = AccountID(rawValue: UUID())

        let topic = makeTopic(42, subject: "标题", author: "作者", site: .v2ex, forumKey: "swift", replyCount: 87)
        model.topicHistory.record(topic)

        let visit = try XCTUnwrap(model.topicHistory.entries.first)
        XCTAssertEqual(visit.subject, "标题")
        XCTAssertEqual(visit.author, "作者")
        XCTAssertEqual(visit.forumID, ForumID(site: .v2ex, key: "swift"))
        XCTAssertEqual(visit.replyCount, 87)
        XCTAssertEqual(visit.topic.id, topic.id)
    }

    /// 从私信或用户动态点进去的话题带的是占位版面和空作者 —— 那两处给不出。
    /// 后来在版面列表里又点了同一条，历史该把真的补上，而不是守着第一次那份残缺的。
    @MainActor
    func testASecondVisitFillsInWhatTheFirstOneLacked() throws {
        let container = try makeContainer("TopicHistoryBackfill")
        let model = AppModel(container: container)
        model.session.activeAccountID = AccountID(rawValue: UUID())

        model.topicHistory.record(Topic(
            id: TopicID(rawValue: 7),
            forumID: .placeholder(site: .nga),
            subject: "从私信点进去的",
            author: "",
            replyCount: 0
        ))
        model.topicHistory.record(makeTopic(7, subject: "从版面点进去的", author: "楼主", replyCount: 12))

        let visit = try XCTUnwrap(model.topicHistory.entries.first)
        XCTAssertEqual(visit.forumID, ForumID(site: .nga, key: "-7"))
        XCTAssertEqual(visit.author, "楼主")
        XCTAssertEqual(visit.replyCount, 12)
        XCTAssertEqual(model.topicHistory.entries.count, 1)
    }

    /// 反过来也一样：先从版面读过，再从私信点进同一条，历史不该把作者和版面
    /// 退回成占位的那份 —— 面板上刚读过的那条会当场把作者名丢掉。
    @MainActor
    func testASecondVisitNeverDowngradesWhatIsAlreadyKnown() throws {
        let container = try makeContainer("TopicHistoryDowngrade")
        let model = AppModel(container: container)
        model.session.activeAccountID = AccountID(rawValue: UUID())

        model.topicHistory.record(makeTopic(7, subject: "从版面点进去的", author: "楼主", replyCount: 12))
        model.topicHistory.record(Topic(
            id: TopicID(rawValue: 7),
            forumID: .placeholder(site: .nga),
            subject: "",
            author: "",
            replyCount: 0
        ))

        let visit = try XCTUnwrap(model.topicHistory.entries.first)
        XCTAssertEqual(visit.subject, "从版面点进去的")
        XCTAssertEqual(visit.author, "楼主")
        XCTAssertEqual(visit.forumID, ForumID(site: .nga, key: "-7"))
        XCTAssertEqual(visit.replyCount, 12)
    }

    // MARK: - 变灰

    /// 变灰和历史是同一份数据：记下了就灰，删掉了就不灰。
    @MainActor
    func testVisitedTopicsAreDimmedUntilTheyLeaveTheHistory() throws {
        let container = try makeContainer("TopicHistoryDimming")
        let model = AppModel(container: container)
        model.session.activeAccountID = AccountID(rawValue: UUID())

        XCTAssertFalse(model.dimsVisitedTopic(TopicID(rawValue: 1)))
        model.topicHistory.record(makeTopic(1))
        XCTAssertTrue(model.dimsVisitedTopic(TopicID(rawValue: 1)))

        model.topicHistory.remove(TopicID(rawValue: 1))
        XCTAssertFalse(model.dimsVisitedTopic(TopicID(rawValue: 1)))
    }

    /// 「变灰」那个开关只管列表上体不体现，历史照记不误 ——
    /// 关掉它的人是嫌列表花，不是不想要历史。
    @MainActor
    func testTurningOffDimmingKeepsRecordingTheHistory() throws {
        let container = try makeContainer("TopicHistoryDimmingOff")
        let model = AppModel(container: container)
        model.session.activeAccountID = AccountID(rawValue: UUID())

        UserDefaults.standard.set(false, forKey: TopicHistorySettings.dimsVisitedKey)
        model.topicHistory.record(makeTopic(1))

        XCTAssertFalse(model.dimsVisitedTopic(TopicID(rawValue: 1)))
        XCTAssertTrue(model.topicHistory.hasVisited(TopicID(rawValue: 1)))
        XCTAssertEqual(model.topicHistory.entries.count, 1)
    }

    /// 总开关关掉：不再记，而且**已经记下的也删掉**。
    /// 只停止记录、留着旧账，等于把「别留记录」办成了「从今天起别留」。
    @MainActor
    func testTurningOffTheHistoryDeletesWhatWasAlreadyThere() throws {
        let container = try makeContainer("TopicHistoryDisabled")
        let accountID = AccountID(rawValue: UUID())
        let model = AppModel(container: container)
        model.session.activeAccountID = accountID

        model.topicHistory.record(makeTopic(1))
        model.topicHistory.applyEnabledChange(false)

        XCTAssertTrue(model.topicHistory.entries.isEmpty)
        XCTAssertFalse(model.topicHistory.hasVisited(TopicID(rawValue: 1)))

        model.topicHistory.record(makeTopic(2))
        XCTAssertTrue(model.topicHistory.entries.isEmpty)

        // 重开也不会冒出来 —— 删的是库里的行，不只是内存里那份。
        let restored = AppModel(container: container)
        restored.session.activeAccountID = accountID
        restored.topicHistory.reload()
        XCTAssertTrue(restored.topicHistory.entries.isEmpty)
    }

    // MARK: - 按账号隔离

    /// `TopicID` 只是个 `Int64`，两个站上撞号是迟早的事 ——
    /// 隔离靠的是主键以账号打头，而不是话题编号本身唯一。
    @MainActor
    func testHistoryIsScopedToTheAccountEvenWhenTopicIDsCollide() throws {
        let container = try makeContainer("TopicHistoryScope")
        let firstAccountID = AccountID(rawValue: UUID())
        let secondAccountID = AccountID(rawValue: UUID())
        let model = AppModel(container: container)

        model.session.activeAccountID = firstAccountID
        model.topicHistory.record(makeTopic(100, subject: "NGA 上的一百号", site: .nga))

        model.session.activeAccountID = secondAccountID
        model.topicHistory.reload()
        XCTAssertTrue(model.topicHistory.entries.isEmpty)
        // 同一个编号在另一个站上是另一条帖子，不该借着前一个账号的记录变灰。
        XCTAssertFalse(model.topicHistory.hasVisited(TopicID(rawValue: 100)))

        model.topicHistory.record(makeTopic(100, subject: "NodeSeek 上的一百号", site: .nodeseek, forumKey: "daily"))
        XCTAssertEqual(model.topicHistory.entries.first?.subject, "NodeSeek 上的一百号")

        model.session.activeAccountID = firstAccountID
        model.topicHistory.reload()
        XCTAssertEqual(model.topicHistory.entries.first?.subject, "NGA 上的一百号")

        // 没有账号时既不读也不写，而不是攒一份无主的历史。
        model.session.activeAccountID = nil
        model.topicHistory.reload()
        XCTAssertTrue(model.topicHistory.entries.isEmpty)
        model.topicHistory.record(makeTopic(1))
        XCTAssertTrue(model.topicHistory.entries.isEmpty)
    }

    /// 清空只清当前账号。
    @MainActor
    func testClearingOnlyAffectsTheCurrentAccount() throws {
        let container = try makeContainer("TopicHistoryClear")
        let firstAccountID = AccountID(rawValue: UUID())
        let secondAccountID = AccountID(rawValue: UUID())
        let model = AppModel(container: container)

        model.session.activeAccountID = firstAccountID
        model.topicHistory.record(makeTopic(1))
        model.session.activeAccountID = secondAccountID
        model.topicHistory.reload()
        model.topicHistory.record(makeTopic(2))

        model.topicHistory.clear()
        XCTAssertTrue(model.topicHistory.entries.isEmpty)

        model.session.activeAccountID = firstAccountID
        model.topicHistory.reload()
        XCTAssertEqual(model.topicHistory.entries.map(\.id.rawValue), [1])
    }

    // MARK: - 裁剪

    /// 上限有下限。定在一百条是因为这张表同时供着变灰：再小一点，
    /// 在热闹的版面里翻几页就能把「我刚看过的」挤掉，看上去像是变灰坏了。
    func testTheCountLimitIsClampedToItsRange() {
        XCTAssertEqual(TopicHistorySettings.maximumCountRange.lowerBound, 100)
        XCTAssertEqual(TopicHistorySettings.normalizedMaximumCount(3), 100)
        XCTAssertEqual(
            TopicHistorySettings.normalizedMaximumCount(99_999),
            TopicHistorySettings.maximumCountRange.upperBound
        )
        XCTAssertEqual(TopicHistorySettings.normalizedRetentionDays(0), 1)
        XCTAssertEqual(
            TopicHistorySettings.normalizedRetentionDays(99_999),
            TopicHistorySettings.retentionDaysRange.upperBound
        )
    }

    /// 上限是按账号算的，不是所有账号合起来 ——
    /// 否则常用的那个账号会把别的账号的历史挤光。
    @MainActor
    func testTheCountLimitIsPerAccount() throws {
        let container = try makeContainer("TopicHistoryPerAccountLimit")
        let limit = TopicHistorySettings.maximumCountRange.lowerBound
        let firstAccountID = AccountID(rawValue: UUID())
        let secondAccountID = AccountID(rawValue: UUID())
        let model = AppModel(container: container)

        model.session.activeAccountID = firstAccountID
        for index in 1...limit { model.topicHistory.record(makeTopic(Int64(index))) }
        model.session.activeAccountID = secondAccountID
        model.topicHistory.reload()
        for index in 1...limit {
            model.topicHistory.record(makeTopic(Int64(10_000 + index)))
        }

        model.topicHistory.updateMaximumCount(limit)

        // 两个账号各留满一份，谁也没挤掉谁。
        XCTAssertEqual(model.topicHistory.entries.count, limit)
        XCTAssertEqual(model.topicHistory.entries.first?.id.rawValue, Int64(10_000 + limit))
        model.session.activeAccountID = firstAccountID
        model.topicHistory.reload()
        XCTAssertEqual(model.topicHistory.entries.count, limit)
        XCTAssertEqual(model.topicHistory.entries.first?.id.rawValue, Int64(limit))
    }

    /// 上限调小要把多出来的行真的删掉，而不是藏起来等下次调大又冒出来。
    @MainActor
    func testLoweringTheLimitDeletesTheOverflowInsteadOfHidingIt() throws {
        let container = try makeContainer("TopicHistoryLimit")
        let limit = TopicHistorySettings.maximumCountRange.lowerBound
        let model = AppModel(container: container)
        model.session.activeAccountID = AccountID(rawValue: UUID())

        UserDefaults.standard.set(limit + 50, forKey: TopicHistorySettings.maximumCountKey)
        for index in 1...(limit + 20) { model.topicHistory.record(makeTopic(Int64(index))) }
        XCTAssertEqual(model.topicHistory.entries.count, limit + 20)

        model.topicHistory.updateMaximumCount(limit)
        XCTAssertEqual(model.topicHistory.entries.count, limit)
        XCTAssertEqual(model.topicHistory.entries.first?.id.rawValue, Int64(limit + 20))
        XCTAssertFalse(model.topicHistory.hasVisited(TopicID(rawValue: 1)))

        // 调回去，被删掉的不该自己回来。
        model.topicHistory.updateMaximumCount(limit + 50)
        XCTAssertEqual(model.topicHistory.entries.count, limit)
        XCTAssertFalse(model.topicHistory.hasVisited(TopicID(rawValue: 1)))
    }

    /// 一路读下去读满了上限：新的进来，最早的那条出局，变灰也跟着撤销。
    @MainActor
    func testRecordingBeyondTheLimitDropsTheOldestVisit() throws {
        let container = try makeContainer("TopicHistoryOverflow")
        let limit = TopicHistorySettings.maximumCountRange.lowerBound
        let accountID = AccountID(rawValue: UUID())
        let model = AppModel(container: container)
        model.session.activeAccountID = accountID

        UserDefaults.standard.set(limit, forKey: TopicHistorySettings.maximumCountKey)
        for index in 1...(limit + 3) { model.topicHistory.record(makeTopic(Int64(index))) }

        XCTAssertEqual(model.topicHistory.entries.count, limit)
        XCTAssertEqual(model.topicHistory.entries.first?.id.rawValue, Int64(limit + 3))
        XCTAssertFalse(model.topicHistory.hasVisited(TopicID(rawValue: 1)))
        XCTAssertFalse(model.topicHistory.hasVisited(TopicID(rawValue: 3)))
        XCTAssertTrue(model.topicHistory.hasVisited(TopicID(rawValue: 4)))

        // 挤掉的是库里的行，重开不会冒出来。
        let restored = AppModel(container: container)
        restored.session.activeAccountID = accountID
        restored.topicHistory.reload()
        XCTAssertEqual(restored.topicHistory.entries.count, limit)
        XCTAssertFalse(restored.topicHistory.hasVisited(TopicID(rawValue: 1)))
    }

    /// 过期的记录在下一次读历史时删掉，变灰也跟着到期 ——
    /// 一个月前读过的帖子重新显示成没读过，和浏览器一致。
    @MainActor
    func testVisitsOlderThanTheRetentionWindowAreDropped() throws {
        let container = try makeContainer("TopicHistoryRetention")
        let accountID = AccountID(rawValue: UUID())
        let context = ModelContext(container)
        let old = TopicVisitRecord(
            accountID: accountID,
            topic: makeTopic(1, subject: "很久以前读的"),
            lastVisitedAt: .now.addingTimeInterval(-40 * 86_400)
        )
        let recent = TopicVisitRecord(
            accountID: accountID,
            topic: makeTopic(2, subject: "昨天读的"),
            lastVisitedAt: .now.addingTimeInterval(-86_400)
        )
        context.insert(old)
        context.insert(recent)
        try context.save()

        let model = AppModel(container: container)
        model.session.activeAccountID = accountID
        model.topicHistory.reload()

        XCTAssertEqual(model.topicHistory.entries.map(\.id.rawValue), [2])
        XCTAssertFalse(model.topicHistory.hasVisited(TopicID(rawValue: 1)))

        // 删的是库里的行，重开不会冒出来。
        let restored = AppModel(container: container)
        restored.session.activeAccountID = accountID
        restored.topicHistory.reload()
        XCTAssertEqual(restored.topicHistory.entries.map(\.id.rawValue), [2])
    }

    // MARK: - 面板里的搜索

    /// 标题和作者都能搜到，宽松程度和别处一致。
    func testHistorySearchMatchesSubjectAndAuthor() {
        let visit = TopicVisit(
            id: TopicID(rawValue: 1),
            forumID: ForumID(site: .nga, key: "-7"),
            subject: "便宜 VPS 推荐",
            author: "Livid",
            authorUID: nil,
            replyCount: 0,
            visitedAt: .now
        )
        XCTAssertTrue(visit.matches(""))
        XCTAssertTrue(visit.matches("   "))
        XCTAssertTrue(visit.matches("vps"))
        XCTAssertTrue(visit.matches("ＶＰＳ"))
        XCTAssertTrue(visit.matches("livid"))
        // 作者在这里按包含比，和关键字过滤那边的作者档不一样：
        // 在自己的历史里找东西，找宽一点只是多几条候选。
        XCTAssertTrue(visit.matches("liv"))
        XCTAssertFalse(visit.matches("显卡"))
    }
}
