import Foundation
import SwiftSoup
import XCTest
@testable import SNGA

/// Linux.do 的投票（Discourse 投票插件）。
///
/// `linuxdo-poll-topic` 是真实抓取的话题（3123593，主楼挂着 `poll`、`poll2` 两个单选，
/// 2026-11-05），只留了主楼、脱了敏。另外两份是在它上面**改出来的**：多选那份把 `type`
/// 改成 `multiple`、`max` 4，再补了一份 `polls_votes`；已关闭那份把 `status` 改成
/// `closed`、补了 `close` —— 字段名和取值都照同一天实测过的多选、已关闭投票（3122758、
/// 3122167），那两份本身没下载下来（浏览器拦了第二个下载）。
final class LinuxDoPollTests: XCTestCase {
    private let parser = LinuxDoParser()

    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json"))
        return try Data(contentsOf: url)
    }

    private func poll(_ name: String) throws -> TopicPoll {
        try XCTUnwrap(parser.topicDetail(json: fixture(name)).posts.first?.poll)
    }

    private func makeService(_ transport: any HTTPTransport) -> LinuxDoForumService {
        LinuxDoForumService(
            accountID: AccountID(),
            cookies: [SessionCookie(
                name: "_t", value: "token", domain: "linux.do", path: "/",
                expiresAt: nil, isSecure: true, isHTTPOnly: true
            )],
            transport: transport,
            userAgent: "WebViewUA"
        )
    }

    func testTwoPollsOnTheFirstPostBecomeTwoGroups() throws {
        let poll = try poll("linuxdo-poll-topic")
        XCTAssertEqual(poll.id, TopicID(rawValue: 3_123_593))
        XCTAssertEqual(poll.groups.map(\.title), ["撬开了（撬龟壳频率）", "abc（撬龟壳频率）"])
        XCTAssertEqual(poll.groups[0].options.map(\.title), ["每天N次", "每天", "每周", "1-3个月", "3个月以上"])
        XCTAssertEqual(poll.groups[0].options.map(\.voteCount), [9, 13, 8, 2, 3])
        XCTAssertEqual(poll.groups.map { poll.maximumSelections(in: $0) }, [1, 1])
        XCTAssertEqual(poll.participantCount, 37, "两个投票里人多的那个")
        XCTAssertFalse(poll.isLocked)
        XCTAssertTrue(poll.showsResults(at: .now), "`results: always`")
        XCTAssertFalse(poll.groups.flatMap(\.options).contains(where: \.isChosen))
    }

    /// 两个投票的选项文字一样，站点给的选项编号也一样 —— 带上投票名才分得开。
    func testOptionIDsAreUniqueAcrossPollsWithTheSameOptions() throws {
        let ids = try poll("linuxdo-poll-topic").groups.flatMap(\.options).map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertEqual(ids.first, "poll:eb18e73b04c12e5a5452e91d53415ff9")
    }

    /// 投票原生画了，正文里那份选项列表就不该再出现一次。
    func testPollMarkupIsRemovedFromTheBodyOnlyWhenDrawnNatively() throws {
        let post = try XCTUnwrap(parser.topicDetail(json: fixture("linuxdo-poll-topic")).posts.first)
        XCTAssertFalse(post.html.contains("data-poll-option-id"))
        XCTAssertFalse(post.html.contains("每天N次"))
        let kept = try LinuxDoParser.sanitizedBody(#"<div class="poll"><ul><li>甲</li></ul></div>"#)
        XCTAssertTrue(kept.contains("甲"), "没原生画（不在主楼）就留着，别让投票凭空消失")
    }

    func testMultipleChoiceCarriesItsLimitAndMyVotes() throws {
        let poll = try poll("linuxdo-poll-topic-multiple-voted")
        let group = try XCTUnwrap(poll.groups.first)
        XCTAssertEqual(poll.maximumSelections(in: group), 4)
        XCTAssertEqual(group.options.filter(\.isChosen).map(\.title), ["每天N次", "每周"])
    }

    func testClosedPollIsLockedWithItsEndDate() throws {
        let poll = try poll("linuxdo-poll-topic-closed")
        XCTAssertTrue(poll.isLocked)
        XCTAssertFalse(poll.isAcceptingResponses(at: .now))
        XCTAssertEqual(poll.endsAt, ISO8601DateFormatter().date(from: "2026-11-01T12:00:00Z"))
        XCTAssertTrue(poll.hidesResultsUntilEnd, "夹具改成了 `on_close`")
        XCTAssertTrue(poll.showsResults(at: .now), "已经结束，结果照样画")
    }

    /// 单选和多选混在一层楼里时，每组按自己的上限算。
    func testMixedLimitsAreCheckedPerGroup() {
        let poll = TopicPoll(
            id: TopicID(rawValue: 1),
            groups: [
                .init(id: 0, title: nil, options: [.init(id: "a:1", title: "1", voteCount: 0), .init(id: "a:2", title: "2", voteCount: 0)], maximumSelections: 1),
                .init(id: 1, title: nil, options: [.init(id: "b:1", title: "1", voteCount: 0), .init(id: "b:2", title: "2", voteCount: 0)], maximumSelections: 2)
            ],
            maximumSelectionsPerGroup: 2,
            endsAt: nil,
            hidesResultsUntilVoting: false,
            hidesResultsUntilEnd: false,
            participantCount: 0
        )
        XCTAssertNil(poll.uniformMaximumSelections)
        XCTAssertTrue(poll.containsValidSelection(["a:1", "b:1", "b:2"]))
        XCTAssertFalse(poll.containsValidSelection(["a:1", "a:2"]), "第一组是单选")
    }

    /// 每个投票一次 `PUT /polls/vote`，挂在主楼上；主楼编号没翻过就先取一次详情。
    func testVoteIsOnePutPerPollOnTheFirstPost() async throws {
        let detail = String(decoding: try fixture("linuxdo-poll-topic"), as: UTF8.self)
        let transport = ScriptedTransport([(200, detail), (200, #"{"csrf":"tok"}"#), (200, "{}"), (200, "{}")])
        try await makeService(transport).submitTopicPollVote(
            topicID: TopicID(rawValue: 3_123_593),
            optionIDs: ["poll:eb18e73b04c12e5a5452e91d53415ff9", "poll2:c65c529746f5a2fcddc9ae575515b2fb"]
        )
        let puts = transport.requests.filter { $0.httpMethod == "PUT" }
        XCTAssertEqual(puts.count, 2)
        XCTAssertEqual(puts.first?.url?.absoluteString, "https://linux.do/polls/vote")
        let bodies = puts.map { String(decoding: $0.httpBody ?? Data(), as: UTF8.self) }
        XCTAssertEqual(bodies, [
            "post_id=24406720&poll_name=poll&options%5B%5D=eb18e73b04c12e5a5452e91d53415ff9",
            "post_id=24406720&poll_name=poll2&options%5B%5D=c65c529746f5a2fcddc9ae575515b2fb"
        ])
        XCTAssertEqual(puts.first?.value(forHTTPHeaderField: "X-CSRF-Token"), "tok")
    }

    func testMultipleChoiceSendsEveryOptionInOneRequest() async throws {
        let detail = String(decoding: try fixture("linuxdo-poll-topic"), as: UTF8.self)
        let transport = ScriptedTransport([(200, detail), (200, #"{"csrf":"tok"}"#), (200, "{}")])
        try await makeService(transport).submitTopicPollVote(
            topicID: TopicID(rawValue: 3_123_593),
            optionIDs: ["poll:a", "poll:b"]
        )
        let put = try XCTUnwrap(transport.requests.last)
        XCTAssertEqual(
            String(decoding: put.httpBody ?? Data(), as: UTF8.self),
            "post_id=24406720&poll_name=poll&options%5B%5D=a&options%5B%5D=b"
        )
    }

    func testUnrecognizedOptionIsNotSent() async throws {
        let transport = ScriptedTransport([])
        do {
            try await makeService(transport).submitTopicPollVote(topicID: TopicID(rawValue: 1), optionIDs: ["bare"])
            XCTFail("认不出投票名的编号不该发出去")
        } catch {}
        XCTAssertTrue(transport.requests.isEmpty)
    }
}
