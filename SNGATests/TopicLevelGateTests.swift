import Foundation
import SwiftData
import XCTest
@testable import SNGA

/// 等级不够的话题在列表里画成灰的：什么时候画、什么时候**不**画。
///
/// 「什么时候不画」才是这里的重点。误判的两个方向代价不对等：漏画一行只是少了
/// 一点提示，错画一行是把读者本来点得开的帖子说成点不开的。
final class TopicLevelGateTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: BrowsingSettings.dimsGatedTopicsKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: BrowsingSettings.dimsGatedTopicsKey)
        super.tearDown()
    }

    private func makeContainer() throws -> ModelContainer {
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
                "TopicLevelGate-\(UUID().uuidString)",
                schema: schema,
                isStoredInMemoryOnly: true
            )]
        )
    }

    private func makeTopic(requiredLevels: [Int?]) -> Topic {
        Topic(
            id: TopicID(rawValue: 1),
            forumID: ForumID(site: .nodeseek, key: "daily"),
            subject: "沙盒区的一条",
            author: "某位作者",
            replyCount: 0,
            badges: requiredLevels.map { level in
                TopicBadge(
                    title: level.map { "等级 \($0) 可见" } ?? "置顶",
                    value: level.map(String.init),
                    systemImage: level == nil ? "pin.fill" : "lock.fill",
                    requiredLevel: level
                )
            }
        )
    }

    @MainActor
    private func makeModel(myLevel: Int?) throws -> AppModel {
        let accountID = AccountID(rawValue: UUID())
        let model = AppModel(container: try makeContainer())
        model.session.activeAccountID = accountID
        if let myLevel {
            model.session.setLevel(myLevel, for: accountID)
        }
        return model
    }

    @MainActor
    func testATopicAboveMyLevelIsGatedAndSaysHowFar() throws {
        let model = try makeModel(myLevel: 1)
        let gate = try XCTUnwrap(model.levelGate(for: makeTopic(requiredLevels: [3])))

        XCTAssertEqual(gate.required, 3)
        XCTAssertEqual(gate.current, 1)
        // 说的是「还差多少」，不只是「进不去」—— 一片灰色不告诉读者要升几级。
        XCTAssertEqual(gate.description, "等级 3 可见，你现在是等级 1")
    }

    /// 刚好够得着就不是门槛。「等级 2 可见」对一个 2 级用户是开着的门。
    @MainActor
    func testExactlyMeetingTheRequirementIsNotGated() throws {
        let model = try makeModel(myLevel: 2)
        XCTAssertNil(model.levelGate(for: makeTopic(requiredLevels: [2])))
        XCTAssertNil(model.levelGate(for: makeTopic(requiredLevels: [1])))
    }

    /// 没有等级标记的话题永远不画灰 —— 置顶、只读这些标记不是门槛。
    @MainActor
    func testTopicsWithoutALevelBadgeAreNeverGated() throws {
        let model = try makeModel(myLevel: 1)
        XCTAssertNil(model.levelGate(for: makeTopic(requiredLevels: [])))
        XCTAssertNil(model.levelGate(for: makeTopic(requiredLevels: [nil, nil])))
    }

    /// 自己的等级还没取到时一律不画。
    ///
    /// 这是两个误判方向里更要紧的那个：拿一个猜的数（比如当成 0）去比，
    /// 整个沙盒区会被画成一片灰，而读者其实点得开。
    @MainActor
    func testAnUnknownOwnLevelGatesNothing() throws {
        let model = try makeModel(myLevel: nil)
        XCTAssertNil(model.levelGate(for: makeTopic(requiredLevels: [3])))
    }

    /// 站点报不出等级（NGA、V2EX 都没有这个概念）时同理：等级留空，一条都不拦。
    @MainActor
    func testASiteWithoutLevelsGatesNothing() throws {
        let model = try makeModel(myLevel: nil)
        let topic = Topic(
            id: TopicID(rawValue: 2),
            forumID: ForumID(site: .nga, key: "-7"),
            subject: "NGA 的一条",
            author: "某位作者",
            replyCount: 0
        )
        XCTAssertNil(model.levelGate(for: topic))
    }

    /// 一条话题挂着几个等级标记时按**最高**那个算 —— 够不着最高的就是进不去。
    @MainActor
    func testTheHighestRequirementWins() throws {
        let model = try makeModel(myLevel: 2)
        let gate = try XCTUnwrap(model.levelGate(for: makeTopic(requiredLevels: [1, 5, 3])))
        XCTAssertEqual(gate.required, 5)
    }

    /// 设置里关掉之后一条都不画，但等级照样记着 —— 关的是这层灰，不是这件事。
    @MainActor
    func testTurningTheSettingOffStopsGatingButKeepsTheLevel() throws {
        let model = try makeModel(myLevel: 1)
        UserDefaults.standard.set(false, forKey: BrowsingSettings.dimsGatedTopicsKey)

        XCTAssertNil(model.levelGate(for: makeTopic(requiredLevels: [3])))
        XCTAssertEqual(model.session.activeAccountLevel, 1)
    }

    /// 等级按账号记：换个账号看到的是那个账号的等级，不是上一个的。
    @MainActor
    func testLevelsAreRememberedPerAccount() throws {
        let model = AppModel(container: try makeContainer())
        let first = AccountID(rawValue: UUID())
        let second = AccountID(rawValue: UUID())

        model.session.setLevel(1, for: first)
        model.session.setLevel(9, for: second)

        model.session.activeAccountID = first
        XCTAssertNotNil(model.levelGate(for: makeTopic(requiredLevels: [3])))
        model.session.activeAccountID = second
        XCTAssertNil(model.levelGate(for: makeTopic(requiredLevels: [3])))
    }
}
