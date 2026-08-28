import Foundation
import XCTest
@testable import SNGA

/// 用户资料里显示哪几行、叫什么，由站点自己说。
///
/// 各站报的东西和叫法都不一样，连「发帖数」的含义都不同 —— NGA 是总数，
/// NodeSeek 分主题帖和评论。写死一套就会在别的站上显示对不上号的词。
final class ProfileFieldsTests: XCTestCase {

    private func titles(_ descriptor: ForumSiteDescriptor, _ profile: Profile) -> [String] {
        descriptor.profileFields(for: profile).map(\.title)
    }

    private func value(
        _ descriptor: ForumSiteDescriptor, _ profile: Profile, _ title: String
    ) -> String? {
        descriptor.profileFields(for: profile).first { $0.title == title }?.value
    }

    // MARK: - NodeSeek

    private func nodeSeekProfile() throws -> Profile {
        try NodeSeekParser().profile(
            json: try Data(contentsOf: try XCTUnwrap(
                Bundle(for: Self.self)
                    .url(forResource: "nodeseek-account-info", withExtension: "json")
            ))
        )
    }

    func testNodeSeekUsesItsOwnVocabulary() throws {
        let titles = titles(.nodeseek, try nodeSeekProfile())

        XCTAssertTrue(titles.contains("等级"), "站点管这个叫等级，不叫用户组：\(titles)")
        XCTAssertTrue(titles.contains("鸡腿数目"), titles.description)
        XCTAssertTrue(titles.contains("主题帖数"), titles.description)
        XCTAssertTrue(titles.contains("评论数目"), titles.description)
        XCTAssertTrue(titles.contains("加入天数"), titles.description)

        XCTAssertFalse(titles.contains("用户组"), "这是 NGA 的说法")
        XCTAssertFalse(titles.contains("发帖数"), "站点分开报主题帖和评论，不报总数")
        XCTAssertFalse(titles.contains("IP 属地"), "站点不报这个，摆一行「—」不如不摆")
    }

    /// 站点没有声望这个概念。塞一个数进去，界面上就会多出一个假的声望。
    func testNodeSeekHasNoReputationOrFame() throws {
        let profile = try nodeSeekProfile()

        XCTAssertNil(profile.reputation)
        XCTAssertNil(profile.fame, "星辰不是声望，不该冒充它")
    }

    /// 等级就是个数字，站点的资料页写的是「等级 1」。
    func testTheLevelIsPlainNotPrefixed() throws {
        let level = try XCTUnwrap(value(.nodeseek, try nodeSeekProfile(), "等级"))

        XCTAssertFalse(level.hasPrefix("Lv."), "站点不这么写：\(level)")
        XCTAssertNotNil(Int(level), "等级该是个数字：\(level)")
    }

    /// 站点显示的是加入了多少天，不是注册日期。
    func testJoinedIsCountedInDays() {
        let profile = Profile(
            uid: 1, displayName: "谁",
            registeredAt: Calendar.current.date(byAdding: .day, value: -17, to: .now)
        )

        XCTAssertEqual(value(.nodeseek, profile, "加入天数"), "17")
    }

    /// 站点没报的字段整行不出现，而不是显示一个「—」。
    func testFieldsTheSiteDidNotReportAreOmitted() {
        let bare = Profile(uid: 1, displayName: "谁")

        let titles = titles(.nodeseek, bare)
        XCTAssertFalse(titles.contains("鸡腿数目"))
        XCTAssertFalse(titles.contains("加入天数"))
    }

    // MARK: - NGA 不受影响

    func testNGAKeepsItsOwnFields() {
        let profile = Profile(
            uid: 1, displayName: "谁", userGroup: "游侠", honor: "头衔",
            registeredAt: .now, postCount: 100, location: "上海", followerCount: 3
        )

        XCTAssertEqual(
            titles(.nga, profile),
            ["用户组", "发帖数", "注册时间", "IP 属地", "头衔", "被关注"]
        )
        XCTAssertFalse(titles(.nga, profile).contains("鸡腿数目"), "别把别人的词带过来")
    }

    /// NGA 报的东西缺了也照样占位 —— 那几行是它资料页的固定内容。
    func testNGAKeepsItsPlaceholdersForMissingValues() {
        let titles = titles(.nga, Profile(uid: 1, displayName: "谁"))

        XCTAssertTrue(titles.contains("用户组"))
        XCTAssertEqual(value(.nga, Profile(uid: 1, displayName: "谁"), "用户组"), "—")
    }
}

/// 「声望」那一段（威望、声望、N 币）是 NGA 一家的。
extension ProfileFieldsTests {

    /// 按「有没有数」判断会出错：NodeSeek 的鸡腿也走 `money`，那一段就会冒出来，
    /// 还把鸡腿标成「N 币」。
    func testTheReputationSectionIsNotShownForNodeSeek() {
        XCTAssertFalse(ForumSiteDescriptor.nodeseek.showsReputationSection)
    }

    func testTheReputationSectionStaysForNGA() {
        XCTAssertTrue(ForumSiteDescriptor.nga.showsReputationSection)
    }

    /// 鸡腿有值也不能让那一段冒出来 —— 这正是按数据判断会踩的坑。
    func testHavingMoneyDoesNotBringTheSectionBack() throws {
        let profile = try NodeSeekParser().profile(
            json: try Data(contentsOf: try XCTUnwrap(
                Bundle(for: Self.self)
                    .url(forResource: "nodeseek-account-info", withExtension: "json")
            ))
        )

        XCTAssertNotNil(profile.money, "前提：鸡腿是有值的")
        XCTAssertFalse(ForumSiteDescriptor.nodeseek.showsReputationSection)
    }
}
