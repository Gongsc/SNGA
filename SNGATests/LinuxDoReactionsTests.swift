import Foundation
import XCTest
@testable import SNGA

/// Linux.do 的赞和回应。写请求一律对着假传输层断言，不往真站点赞。
final class LinuxDoReactionsTests: XCTestCase {
    private let parser = LinuxDoParser()

    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json"))
        return try Data(contentsOf: url)
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

    /// 夹具主楼：❤️ 86、👍 16、👏 3、🎊 1、无语 1、😮 1（2026-11-04 实测）。
    /// 照站点目录的顺序摆，没人点过的不摆；全部走回应那条路，不走赞。
    func testPostReactionsFollowTheSiteCatalog() throws {
        let post = try XCTUnwrap(parser.topicDetail(json: fixture("linuxdo-topic")).posts.first)
        XCTAssertEqual(post.reactions.map(\.id), ["heart", "+1", "open_mouth", "clap", "confetti_ball", "distorted_face"])
        XCTAssertEqual(post.reactions.map(\.count), [86, 16, 1, 3, 1, 1])
        XCTAssertEqual(post.reactions.first?.emoji, "❤️")
        XCTAssertNil(post.reactions.first { $0.id == "distorted_face" }?.emoji, "系统字体未必画得出，退回图标")
        XCTAssertTrue(post.reactions.allSatisfy { $0.routesToVote == false && $0.cost == nil })
        XCTAssertFalse(post.reactions.contains { $0.isChosen })
        XCTAssertEqual(post.upvoteCount, 108, "赞数是所有回应加起来的")
    }

    /// ❤️ 总在；我点过的那个就算只有我一个也要列出来，并且标成已选。
    func testMyReactionIsShownAndMarked() throws {
        let json = """
        {"post_stream":{"posts":[{"id":5,"username":"user1","cooked":"<p>示例</p>","post_number":2,
          "reactions":[],"current_user_reaction":{"id":"hugs","type":"emoji","can_undo":true},
          "current_user_used_main_reaction":false,
          "actions_summary":[{"id":2,"count":1,"acted":true}]}]}}
        """
        let posts = try parser.posts(json: Data(json.utf8), topicID: TopicID(rawValue: 1))
        let post = try XCTUnwrap(posts.first)
        XCTAssertEqual(post.reactions.map(\.id), ["heart", "hugs"])
        XCTAssertEqual(post.reactions.first { $0.id == "hugs" }?.isChosen, true)
        XCTAssertEqual(post.reactions.first { $0.id == "heart" }?.isChosen, false)
        XCTAssertEqual(post.userVote, .up, "核心的赞 `acted` 也算点过")
    }

    func testReactionToggleIsAPutToThePluginEndpoint() async throws {
        let transport = RecordingHTTPTransport(responding: #"{"csrf":"tok"}"#)
        let state = try await makeService(transport).submitPostReaction(
            topicID: TopicID(rawValue: 1), postID: PostID(rawValue: 24_259_580), reactionID: "+1"
        )
        XCTAssertNil(state, "调用方会整页刷新，不在这里猜数")
        let put = try XCTUnwrap(transport.requests.last)
        XCTAssertEqual(put.httpMethod, "PUT")
        XCTAssertEqual(
            put.url?.absoluteString,
            "https://linux.do/discourse-reactions/posts/24259580/custom-reactions/+1/toggle.json"
        )
        XCTAssertEqual(put.value(forHTTPHeaderField: "X-CSRF-Token"), "tok")
    }

    func testUnknownReactionIsNotSent() async throws {
        let transport = RecordingHTTPTransport(responding: "{}")
        do {
            _ = try await makeService(transport).submitPostReaction(
                topicID: TopicID(rawValue: 1), postID: PostID(rawValue: 2), reactionID: "dislike"
            )
            XCTFail("站点没有的回应不该发出去")
        } catch let error as ForumServiceError {
            guard case .unsupported = error else { return XCTFail("应当是不支持，实际是 \(error)") }
        }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testLikeAndUndoUseThePostActionsEndpoints() async throws {
        let answer = #"{"id":2,"username":"user1","cooked":"","post_number":1,"actions_summary":[{"id":2,"count":7,"acted":true}]}"#
        let transport = RecordingHTTPTransport(
            responding: answer,
            byPath: ["/session/csrf": #"{"csrf":"tok"}"#]
        )
        let service = makeService(transport)
        let liked = try await service.vote(
            topicID: TopicID(rawValue: 1), postID: PostID(rawValue: 2), direction: .up, isUndo: false
        )
        XCTAssertEqual(liked, PostVoteState(upvoteCount: 7, downvoteCount: 0, userVote: .up))
        let post = try XCTUnwrap(transport.requests.last)
        XCTAssertEqual(post.httpMethod, "POST")
        XCTAssertEqual(post.url?.path, "/post_actions")
        XCTAssertEqual(
            String(data: try XCTUnwrap(post.httpBody), encoding: .utf8),
            "id=2&post_action_type_id=2&flag_topic=false"
        )

        _ = try await service.vote(
            topicID: TopicID(rawValue: 1), postID: PostID(rawValue: 2), direction: .up, isUndo: true
        )
        let undo = try XCTUnwrap(transport.requests.last)
        XCTAssertEqual(undo.httpMethod, "DELETE")
        XCTAssertEqual(undo.url?.absoluteString, "https://linux.do/post_actions/2?post_action_type_id=2")
    }

    // MARK: - 回复

    func testReplyCostIsReadFromTheTopicDetail() throws {
        XCTAssertEqual(try parser.topicDetail(json: fixture("linuxdo-topic")).topic.replyCost, 0)
        let json = #"{"id":9,"title":"示例","posts_count":1,"reply_cost":5,"post_stream":{"posts":[],"stream":[]}}"#
        XCTAssertEqual(try parser.topicDetail(json: Data(json.utf8)).topic.replyCost, 5)
    }

    /// 回复某一楼要带楼层号；楼层号是加载那一页时记下的。
    func testReplyCarriesThePostNumberOnceThePageIsLoaded() async throws {
        let transport = RecordingHTTPTransport(
            responding: #"{"id":24400000,"post_number":66}"#,
            byPath: [
                "/session/csrf": #"{"csrf":"tok"}"#,
                "/t/3103315.json": String(decoding: try fixture("linuxdo-topic"), as: UTF8.self),
                "/t/3103315/": String(decoding: try fixture("linuxdo-topic-posts"), as: UTF8.self)
            ]
        )
        let service = makeService(transport)
        let topicID = TopicID(rawValue: 3_103_315)
        _ = try await service.threadPage(topicID: topicID, page: 2, authorUID: nil)

        let created = try await service.submitReply(
            topicID: topicID,
            submission: ReplySubmission(content: "同意 +1", replyTo: PostID(rawValue: 24_263_835))
        )
        XCTAssertEqual(created, PostID(rawValue: 24_400_000))
        let post = try XCTUnwrap(transport.requests.last)
        XCTAssertEqual(post.httpMethod, "POST")
        XCTAssertEqual(post.url?.path, "/posts.json")
        XCTAssertEqual(
            String(data: try XCTUnwrap(post.httpBody), encoding: .utf8),
            "raw=%E5%90%8C%E6%84%8F+%2B1&topic_id=3103315&reply_to_post_number=22"
        )
    }

    /// 没加载过被回复那一楼时不带楼层号，帖子照样发在这个话题里。
    func testReplyWithoutAKnownPostNumberStillPosts() async throws {
        let transport = RecordingHTTPTransport(responding: #"{"csrf":"tok"}"#)
        _ = try await makeService(transport).submitReply(
            topicID: TopicID(rawValue: 7),
            submission: ReplySubmission(content: "hi", replyTo: PostID(rawValue: 99))
        )
        XCTAssertEqual(String(data: try XCTUnwrap(transport.requests.last?.httpBody), encoding: .utf8), "raw=hi&topic_id=7")
    }

    /// 要审核的帖子没有楼层编号，但已经交上去了 —— 不能当失败，否则用户会再发一遍。
    func testQueuedReplyIsNotAFailure() async throws {
        let transport = RecordingHTTPTransport(
            responding: #"{"success":true,"action":"enqueued","pending_post":{"id":5,"raw":"hi"}}"#,
            byPath: ["/session/csrf": #"{"csrf":"tok"}"#]
        )
        let created = try await makeService(transport).submitReply(
            topicID: TopicID(rawValue: 7), submission: ReplySubmission(content: "hi", replyTo: nil)
        )
        XCTAssertNil(created)
    }

    func testThereIsNoDownvote() async throws {
        let transport = RecordingHTTPTransport(responding: "{}")
        let service = makeService(transport)
        XCTAssertTrue(service.capabilities.contains(.postVote))
        XCTAssertFalse(service.capabilities.contains(.postDownvote))
        do {
            _ = try await service.vote(
                topicID: TopicID(rawValue: 1), postID: PostID(rawValue: 2), direction: .down, isUndo: false
            )
            XCTFail("站点没有踩")
        } catch {}
        XCTAssertTrue(transport.requests.isEmpty)
    }
}
