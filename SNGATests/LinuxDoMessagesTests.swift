import Foundation
import XCTest
@testable import SNGA

/// Linux.do 的提醒、私信，以及写请求的底子（CSRF 令牌、表单编码、什么时候重发）。
///
/// 夹具是 2026-11-04 登录后抓的，用户名、编号、标题、私信正文都换过。
/// **写请求一律对着假传输层断言**，不往真站发东西。
final class LinuxDoMessagesTests: XCTestCase {
    private let parser = LinuxDoParser()

    private func fixture(_ name: String) throws -> String {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json"))
        return try String(contentsOf: url, encoding: .utf8)
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

    // MARK: - 解析

    func testNotificationsMapTypesAndUnreadState() throws {
        let page = try parser.notifications(json: Data(fixture("linuxdo-notifications").utf8), page: 1)
        XCTAssertEqual(page.folder, .notifications)
        XCTAssertEqual(page.messages.count, 3)

        let badge = page.messages[0]
        XCTAssertEqual(badge.id.rawValue, 735_204_558)
        XCTAssertEqual(badge.kind, .unknown)
        XCTAssertEqual(badge.subject, "获得了徽章「基本用户」")
        XCTAssertEqual(badge.preview, "你获得了新徽章")
        XCTAssertTrue(badge.isUnread)
        XCTAssertNil(badge.topicID)

        // 私信类提醒的编号换成了那段私信的话题编号 —— 点开它走的是 `message(id:)`。
        let pm = page.messages[1]
        XCTAssertEqual(pm.kind, .privateMessage)
        XCTAssertEqual(pm.id.rawValue, 3_120_878)
        XCTAssertEqual(pm.sender, "user2")
        XCTAssertFalse(pm.isUnread)
        XCTAssertNotNil(pm.sentAt)
        XCTAssertFalse(page.hasMore, "不满 30 条就是没有下一页")
    }

    func testNotificationKinds() {
        XCTAssertEqual(LinuxDoParser.messageKind(ofNotificationType: 1), .mention)
        XCTAssertEqual(LinuxDoParser.messageKind(ofNotificationType: 2), .reply)
        XCTAssertEqual(LinuxDoParser.messageKind(ofNotificationType: 3), .quote)
        XCTAssertEqual(LinuxDoParser.messageKind(ofNotificationType: 6), .privateMessage)
        XCTAssertEqual(LinuxDoParser.messageKind(ofNotificationType: 25), .comment)
        XCTAssertEqual(LinuxDoParser.messageKind(ofNotificationType: 900), .unknown)
    }

    func testPrivateMessageInboxAndThread() throws {
        let inbox = try parser.privateMessages(json: Data(fixture("linuxdo-private-messages").utf8), page: 1)
        XCTAssertEqual(inbox.messages.map(\.id.rawValue), [3_120_878, 3_120_691])
        XCTAssertTrue(inbox.messages.allSatisfy { $0.kind == .privateMessage && !$0.isUnread })
        XCTAssertEqual(inbox.messages.first?.sender, "user2")
        // 列表里的私信不带话题编号：点开它要走 `message(id:)`，而不是被当成一个话题跳过去。
        XCTAssertNil(inbox.messages.first?.topicID)
        XCTAssertFalse(inbox.hasMore)

        let thread = try parser.privateMessage(json: Data(fixture("linuxdo-private-message-topic").utf8))
        XCTAssertEqual(thread.id.rawValue, 3_120_878)
        XCTAssertEqual(thread.posts.map(\.id.rawValue), [24_386_364])
        XCTAssertEqual(thread.posts.first?.author, "user2")
        XCTAssertTrue(thread.posts.first?.html.contains("示例") ?? false)
    }

    // MARK: - 写请求

    func testFormEncodingKeepsPlusSigns() {
        XCTAssertEqual(
            LinuxDoNetworkClient.formEncoded([("raw", "1+1 = 2 & 好"), ("topic_id", "7")]),
            "raw=1%2B1+%3D+2+%26+%E5%A5%BD&topic_id=7"
        )
    }

    func testReplyToAPrivateMessagePostsIntoItsTopic() async throws {
        let transport = RecordingHTTPTransport(
            responding: "{}",
            byPath: ["/session/csrf": #"{"csrf":"tok"}"#]
        )
        try await makeService(transport).replyMessage(id: MessageID(rawValue: 3_120_878), content: "  你好+1  ")

        let post = try XCTUnwrap(transport.requests.last)
        XCTAssertEqual(post.httpMethod, "POST")
        XCTAssertEqual(post.url?.path, "/posts.json")
        XCTAssertEqual(post.value(forHTTPHeaderField: "X-CSRF-Token"), "tok")
        XCTAssertEqual(post.value(forHTTPHeaderField: "Origin"), "https://linux.do")
        let body = String(data: try XCTUnwrap(post.httpBody), encoding: .utf8)
        XCTAssertEqual(body, "raw=%E4%BD%A0%E5%A5%BD%2B1&topic_id=3120878")
    }

    /// 私信类提醒的编号是话题编号，拿去标提醒会标错别的 —— 不发。
    func testMarkReadSkipsPrivateMessagesAndReadOnes() async throws {
        let transport = RecordingHTTPTransport(
            responding: "{}",
            byPath: ["/session/csrf": #"{"csrf":"tok"}"#]
        )
        let page = try parser.notifications(json: Data(fixture("linuxdo-notifications").utf8), page: 1)
        var messages = page.messages
        messages[1].isUnread = true  // 私信类，就算未读也不该发
        try await makeService(transport).markRead(messages)

        let writes = transport.requests.filter { $0.httpMethod == "PUT" }
        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(writes.first?.url?.path, "/notifications/mark-read")
        XCTAssertEqual(String(data: writes.first?.httpBody ?? Data(), encoding: .utf8), "id=735204558")
    }

    func testMarkAllReadOnlyForNotifications() async throws {
        let transport = RecordingHTTPTransport(responding: #"{"csrf":"tok"}"#)
        let service = makeService(transport)
        try await service.markAllRead(folder: .privateMessages)
        XCTAssertTrue(transport.requests.isEmpty, "私信没有「全部已读」的接口，什么都不发")

        try await service.markAllRead(folder: .notifications)
        let put = try XCTUnwrap(transport.requests.last)
        XCTAssertEqual(put.httpMethod, "PUT")
        XCTAssertNil(put.httpBody, "不带 id 就是全部")
    }

    /// 令牌过期（403 + BAD CSRF）时换一个再发一次；别的 403 一次都不重发。
    func testOnlyBadCSRFIsRetried() async throws {
        let stale = ScriptedTransport([
            (200, #"{"csrf":"old"}"#),
            (403, #"["BAD CSRF"]"#),
            (200, #"{"csrf":"new"}"#),
            (200, "{}")
        ])
        try await makeService(stale).replyMessage(id: MessageID(rawValue: 1), content: "hi")
        let posts = stale.requests.filter { $0.httpMethod == "POST" }
        XCTAssertEqual(posts.map { $0.value(forHTTPHeaderField: "X-CSRF-Token") }, ["old", "new"])

        let denied = ScriptedTransport([
            (200, #"{"csrf":"tok"}"#),
            (403, #"{"errors":["您没有权限执行此操作。"],"error_type":"invalid_access"}"#)
        ])
        do {
            try await makeService(denied).replyMessage(id: MessageID(rawValue: 1), content: "hi")
            XCTFail("没权限应当报出来")
        } catch let error as ForumServiceError {
            XCTAssertEqual(error, .restricted("您没有权限执行此操作。"))
        }
        XCTAssertEqual(denied.requests.filter { $0.httpMethod == "POST" }.count, 1, "写请求不能因为失败就重发")
    }

    func testMessagesCapabilitiesAreLit() {
        let service = makeService(RecordingHTTPTransport(responding: "{}"))
        XCTAssertTrue(service.capabilities.contains(.privateMessages))
        XCTAssertTrue(service.capabilities.contains(.notifications))
    }
}

/// 按顺序一条条给出响应的假传输层。用来断言「失败之后发了什么」。
final class ScriptedTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var script: [(Int, String)]
    private var _requests: [URLRequest] = []
    var requests: [URLRequest] { lock.withLock { _requests } }

    init(_ script: [(Int, String)]) { self.script = script }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (status, body) = lock.withLock { () -> (Int, String) in
            _requests.append(request)
            return script.isEmpty ? (200, "{}") : script.removeFirst()
        }
        return (Data(body.utf8), HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!)
    }
}
