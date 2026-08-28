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

    /// 用词和顺序照着站点自己的用户卡。
    func testNodeSeekUsesItsOwnVocabulary() throws {
        let titles = titles(.nodeseek, try nodeSeekProfile())

        for expected in ["加入天数", "等级", "主题帖", "鸡腿", "评论数", "星辰", "粉丝"] {
            XCTAssertTrue(titles.contains(expected), "少了「\(expected)」：\(titles)")
        }
        for foreign in ["用户组", "发帖数", "IP 属地", "被关注"] {
            XCTAssertFalse(titles.contains(foreign), "「\(foreign)」是别处的说法：\(titles)")
        }
    }

    /// 星辰带在 `fame` 里，但显示成「星辰」，不是「声望」—— 那是 NGA 的词，
    /// 而且它那一整段在这个站点上根本不画。
    func testStardustIsShownAsItselfNotAsReputation() throws {
        let profile = try nodeSeekProfile()

        XCTAssertNotNil(profile.fame)
        XCTAssertEqual(value(.nodeseek, profile, "星辰"), profile.fame.map(String.init))
        XCTAssertFalse(titles(.nodeseek, profile).contains("声望"))
        XCTAssertFalse(ForumSiteDescriptor.nodeseek.showsReputationSection)
        // 威望是 NGA 独有的。
        XCTAssertNil(profile.reputation)
    }

    /// 站点的用户卡写的是「等级 Lv 1」。前缀是显示时加的 —— 解析出来的仍是个纯数字，
    /// 不然以后想拿它比大小就得先剥前缀。
    func testTheLevelIsFormattedForDisplayNotAtParseTime() throws {
        let profile = try nodeSeekProfile()

        XCTAssertNotNil(Int(try XCTUnwrap(profile.userGroup)), "解析出来的该是纯数字")
        XCTAssertEqual(value(.nodeseek, profile, "等级"), "Lv 4")
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
        XCTAssertFalse(titles.contains("鸡腿"))
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
        XCTAssertFalse(titles(.nga, profile).contains("鸡腿"), "别把别人的词带过来")
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

/// 用户卡上的未读三项：回复、@我、私信。站点只对本人报这几个数。
final class NodeSeekOwnProfileTests: XCTestCase {

    private let accountInfo = """
    {"success":true,"detail":{"member_id":66675,"member_name":"我","rank":1,
     "coin":159,"stardust":0,"nPost":3,"nComment":21,"fans":0,"follows":0,
     "created_at":"2026-08-11T00:00:00.000Z","bio":""}}
    """
    private let unread = #"{"success":true,"unreadCount":{"all":5,"atMe":1,"message":2,"reply":3}}"#

    /// 首页用来认出「我是谁」，之后才谈得上「这是不是我自己」。
    private func homePage(uid: Int64) -> String {
        let state = Data(#"{"user":{"member_id":\#(uid)}}"#.utf8).base64EncodedString()
        return "<html><body><script>var s=\"\(state)\"</script></body></html>"
    }

    private func service(_ transport: RecordingHTTPTransport) -> NodeSeekForumService {
        NodeSeekForumService(
            accountID: AccountID(), cookies: [], transport: transport, userAgent: "probe"
        )
    }

    func testLookingAtYourOwnProfileBringsTheUnreadCounts() async throws {
        let transport = RecordingHTTPTransport(
            responding: homePage(uid: 66675),
            byPath: [
                "/api/account/getInfo/": accountInfo,
                "/api/notification/unread-count": unread
            ]
        )

        let profile = try await service(transport).profile(uid: 66675)

        XCTAssertEqual(profile.unreadReplies, 3)
        XCTAssertEqual(profile.unreadMentions, 1)
        XCTAssertEqual(profile.unreadMessages, 2)
        XCTAssertEqual(
            ForumSiteDescriptor.nodeseek.profileFields(for: profile)
                .first { $0.title == "未读私信" }?.value,
            "2"
        )
    }

    /// 看别人的资料时不该去要未读数 —— 那是我的数，不是他的。
    func testLookingAtSomeoneElseDoesNotAskForUnreadCounts() async throws {
        let transport = RecordingHTTPTransport(
            responding: homePage(uid: 66675),
            byPath: [
                "/api/account/getInfo/": accountInfo,
                "/api/notification/unread-count": unread
            ]
        )

        let profile = try await service(transport).profile(uid: 3515)

        XCTAssertNil(profile.unreadReplies)
        XCTAssertFalse(
            transport.requests.contains { $0.url?.path.contains("unread-count") == true },
            "看别人的资料却去要了我的未读数"
        )
        XCTAssertFalse(
            ForumSiteDescriptor.nodeseek.profileFields(for: profile)
                .map(\.title).contains("未读私信")
        )
    }

    /// 未读数取不到时资料页照常显示 —— 它是附带的。
    func testAFailedUnreadFetchDoesNotBreakTheProfile() async throws {
        let transport = RecordingHTTPTransport(
            responding: homePage(uid: 66675),
            byPath: [
                "/api/account/getInfo/": accountInfo,
                "/api/notification/unread-count": #"{"success":false}"#
            ]
        )

        let profile = try await service(transport).profile(uid: 66675)

        XCTAssertEqual(profile.displayName, "我")
        XCTAssertNil(profile.unreadMessages)
    }
}
