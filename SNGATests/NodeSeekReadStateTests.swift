import XCTest
@testable import SNGA

/// 已读同步。
///
/// 这个站不会因为「你拉过一次列表」就把通知当读过 —— 每条自带 `viewed`，不显式说
/// 一声就一直挂着。所以断言的重点不是「有没有报错」，而是**到底发出去了什么**：
/// 发给哪个接口、请求体里那个字段叫什么、哪些消息根本不该被发出去。
///
/// 一律对着假传输层跑。把这几发请求打到真站上，就是在替用户改他账号里的状态。
final class NodeSeekReadStateTests: XCTestCase {
    private func makeService(
        _ transport: RecordingHTTPTransport
    ) -> NodeSeekForumService {
        NodeSeekForumService(
            accountID: AccountID(),
            cookies: [],
            transport: transport,
            userAgent: "probe"
        )
    }

    private func notification(
        id: Int64,
        kind: ForumMessageKind,
        isUnread: Bool = true
    ) -> ForumMessage {
        ForumMessage(
            id: MessageID(rawValue: id),
            kind: kind,
            sender: "someone",
            subject: "话题",
            preview: "",
            isUnread: isUnread
        )
    }

    private func body(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody))
                as? [String: Any]
        )
    }

    /// 两类通知落在两个接口上，装编号的字段名还各不相同 —— 一个驼峰，一个是拼错了
    /// 的复数。这条用例在的意义就是把那两个名字钉住：改成「统一风格」的一刻它就红。
    func testEachKindGoesToItsOwnEndpointWithItsOwnFieldName() async throws {
        let transport = RecordingHTTPTransport(responding: #"{"success":true}"#)
        let service = makeService(transport)

        try await service.markRead([
            notification(id: 11, kind: .mention),
            notification(id: 22, kind: .reply),
            notification(id: 33, kind: .reply)
        ])

        XCTAssertEqual(transport.requests.count, 2, "两类通知该是两次请求")

        let atMe = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(atMe.url?.path, "/api/notification/at-me/markViewed")
        XCTAssertNil(atMe.url?.query, "逐条标记不带 all=true")
        XCTAssertEqual(try body(atMe)["atMe"] as? [Int64], [11])

        let reply = try XCTUnwrap(transport.requests.last)
        XCTAssertEqual(reply.url?.path, "/api/notification/reply-to-me/markViewed")
        XCTAssertEqual(
            try body(reply)["replys"] as? [Int64], [22, 33],
            "回复那一类的字段是 replys（站点自己就这么拼），不是 replies"
        )
    }

    /// 已经读过的不该再发一次 —— 翻页回来重新点开一条旧消息是常事。
    func testAlreadyReadMessagesSendNothing() async throws {
        let transport = RecordingHTTPTransport(responding: #"{"success":true}"#)
        let service = makeService(transport)

        try await service.markRead([
            notification(id: 11, kind: .mention, isUnread: false),
            notification(id: 22, kind: .reply, isUnread: false)
        ])

        XCTAssertTrue(transport.requests.isEmpty)
    }

    /// 应用里的「论坛消息」把私信和通知合成了一条流，所以传进来的这批里会混着私信。
    /// 私信那条路没验过（它的 `id` 装的是对方的用户编号，不是消息编号），一条都不发。
    func testPrivateMessagesInTheNotificationFeedAreLeftAlone() async throws {
        let transport = RecordingHTTPTransport(responding: #"{"success":true}"#)
        let service = makeService(transport)

        try await service.markRead([
            notification(id: 44, kind: .privateMessage),
            notification(id: 55, kind: .unknown)
        ])

        XCTAssertTrue(transport.requests.isEmpty, "猜一个字段名去写别人的账号状态，不如什么都不做")
    }

    func testMarkAllReadHitsBothKindsWithTheAllFlag() async throws {
        let transport = RecordingHTTPTransport(responding: #"{"success":true}"#)
        let service = makeService(transport)

        try await service.markAllRead(folder: .notifications)

        XCTAssertEqual(
            transport.requests.compactMap(\.url?.absoluteString).sorted(),
            [
                "https://www.nodeseek.com/api/notification/at-me/markViewed?all=true",
                "https://www.nodeseek.com/api/notification/reply-to-me/markViewed?all=true"
            ]
        )
    }

    func testMarkAllReadSkipsThePrivateMessageInbox() async throws {
        let transport = RecordingHTTPTransport(responding: #"{"success":true}"#)
        let service = makeService(transport)

        try await service.markAllRead(folder: .privateMessages)

        XCTAssertTrue(transport.requests.isEmpty)
    }

    /// 站点说没成就是没成。这个站的写接口把话写在响应体里（`success` 为假，
    /// 状态码可能还是 200），不认这一条就会把一次失败当成功咽下去。
    func testARefusedMarkIsReportedRatherThanSwallowed() async throws {
        let transport = RecordingHTTPTransport(
            responding: #"{"success":false,"message":"登录状态已失效"}"#
        )
        let service = makeService(transport)

        do {
            try await service.markRead([notification(id: 11, kind: .mention)])
            XCTFail("站点答了 success:false，这里不该当成功")
        } catch {
            XCTAssertEqual(
                error as? ForumServiceError,
                .restricted("登录状态已失效")
            )
        }
    }

    /// 另外两个站没有需要同步的东西 —— NGA 拉一次列表服务端就清零了，V2EX 的提醒
    /// 打开即已读。默认实现什么都不做，而不是抛 `.unsupported`：无事可做是正确
    /// 答案，不是一次失败，调用点在用户打开消息的路上，不该为它吞一次错。
    func testSitesWithNothingToSyncDoNothingRatherThanThrow() async throws {
        let transport = RecordingHTTPTransport(responding: "")
        let service = V2EXForumService(
            accountID: AccountID(),
            cookies: [],
            transport: transport,
            userAgent: "probe"
        )

        try await service.markRead([notification(id: 11, kind: .reply)])
        try await service.markAllRead(folder: .notifications)

        XCTAssertTrue(transport.requests.isEmpty)
    }
}
