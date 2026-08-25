import Foundation
import XCTest
@testable import SNGA

final class SessionIsolationTests: XCTestCase {
    func testRuntimeLoggerRedactsCredentials() {
        let url = URL(string: "https://bbs.nga.cn/app_api.php?access_uid=123&access_token=secret&fid=-7")!
        let sanitized = RuntimeLogger.sanitizedURL(url)

        XCTAssertFalse(sanitized.contains("secret"))
        XCTAssertFalse(sanitized.contains("access_uid=123"))
        XCTAssertTrue(sanitized.contains("access_token="))
        XCTAssertTrue(sanitized.contains("fid=-7"))
        XCTAssertEqual(
            RuntimeLogger.redacted("Cookie: ngaPassportCid=very-secret"),
            "Cookie: <redacted>"
        )
    }

    func testClientsNeverShareCookieHeaders() async throws {
        let transportA = RecordingTransport()
        let transportB = RecordingTransport()
        let cookieA = SessionCookie(name: "ngaPassportUid", value: "100", domain: "bbs.nga.cn", path: "/", expiresAt: nil, isSecure: true, isHTTPOnly: true)
        let cookieB = SessionCookie(name: "ngaPassportUid", value: "200", domain: "bbs.nga.cn", path: "/", expiresAt: nil, isSecure: true, isHTTPOnly: true)
        let clientA = NGANetworkClient(cookies: [cookieA], transport: transportA)
        let clientB = NGANetworkClient(cookies: [cookieB], transport: transportB)

        async let responseA = clientA.request(.forums)
        async let responseB = clientB.request(.forums)
        _ = try await (responseA, responseB)

        let headersA = await transportA.cookieHeaders()
        let headersB = await transportB.cookieHeaders()
        XCTAssertEqual(headersA, ["ngaPassportUid=100"])
        XCTAssertEqual(headersB, ["ngaPassportUid=200"])
        XCTAssertFalse(headersA.joined().contains("200"))
        XCTAssertFalse(headersB.joined().contains("100"))
    }

    func testWriteFailureIsNeverRetried() async {
        let transport = FailingTransport()
        let client = NGANetworkClient(cookies: [], transport: transport)
        do {
            _ = try await client.request(.checkIn)
            XCTFail("写入失败应抛出错误")
        } catch let error as ForumServiceError {
            XCTAssertEqual(error, .ambiguousWrite)
        } catch {
            XCTFail("错误类型不正确：\(error)")
        }
        let requestCount = await transport.requestCount()
        XCTAssertEqual(requestCount, 1)
    }

    func testConcurrentRequestsReserveSeparateThrottleSlots() async throws {
        let transport = RecordingTransport()
        let client = NGANetworkClient(cookies: [], transport: transport)

        async let first = client.request(.forums)
        async let second = client.request(.forums)
        async let third = client.request(.forums)
        _ = try await (first, second, third)

        let timestamps = await transport.requestTimestamps().sorted()
        XCTAssertEqual(timestamps.count, 3)
        for (earlier, later) in zip(timestamps, timestamps.dropFirst()) {
            XCTAssertGreaterThanOrEqual(
                later.timeIntervalSince(earlier),
                0.22,
                "并发请求必须占用不同的节流时隙"
            )
        }
    }

    func testHTTP503DoesNotRetryImmediately() async {
        let transport = FixedResponseTransport(
            statusCode: 503,
            body: "<html><title>Service Unavailable</title></html>"
        )
        let client = NGANetworkClient(cookies: [], transport: transport)

        do {
            _ = try await client.request(.forums)
            XCTFail("HTTP 503 应抛出错误")
        } catch let error as ForumServiceError {
            XCTAssertEqual(error, .server(503))
        } catch {
            XCTFail("错误类型不正确：\(error)")
        }

        let requestCount = await transport.requestCount()
        XCTAssertEqual(requestCount, 1)
    }

    func testAppAPIReceivesCredentialsFromOnlyItsOwnCookies() async throws {
        let transport = RecordingTransport()
        let cookies = [
            SessionCookie(name: "ngaPassportUid", value: "123", domain: "bbs.nga.cn", path: "/", expiresAt: nil, isSecure: true, isHTTPOnly: true),
            SessionCookie(name: "ngaPassportCid", value: "secret-token", domain: "bbs.nga.cn", path: "/", expiresAt: nil, isSecure: true, isHTTPOnly: true)
        ]
        let client = NGANetworkClient(cookies: cookies, transport: transport)

        _ = try await client.request(.favorites)

        let bodies = await transport.requestBodies()
        let body = try XCTUnwrap(bodies.first)
        XCTAssertTrue(body.contains("access_uid=123"))
        XCTAssertTrue(body.contains("access_token=secret-token"))
    }

    func testCheckInUsesOfficialClientHeaderAndAuthenticatedForm() async throws {
        let transport = RecordingTransport()
        let cookies = [
            SessionCookie(name: "ngaPassportUid", value: "123", domain: "bbs.nga.cn", path: "/", expiresAt: nil, isSecure: true, isHTTPOnly: true),
            SessionCookie(name: "ngaPassportCid", value: "secret-token", domain: "bbs.nga.cn", path: "/", expiresAt: nil, isSecure: true, isHTTPOnly: true)
        ]
        let client = NGANetworkClient(cookies: cookies, transport: transport)

        _ = try await client.request(.checkIn)

        let xUserAgents = await transport.xUserAgents()
        let bodies = await transport.requestBodies()
        XCTAssertEqual(xUserAgents, ["Nga_Official"])
        let body = try XCTUnwrap(bodies.first)
        XCTAssertTrue(body.contains("access_uid=123"))
        XCTAssertTrue(body.contains("access_token=secret-token"))
    }

    func testReplyUsesAuthenticatedStructuredPreflightThenSubmitsExactlyOnce() async throws {
        let transport = ReplySubmissionTransport()
        let cookies = [
            SessionCookie(name: "ngaPassportUid", value: "123", domain: "bbs.nga.cn", path: "/", expiresAt: nil, isSecure: true, isHTTPOnly: true),
            SessionCookie(name: "ngaPassportCid", value: "secret-token", domain: "bbs.nga.cn", path: "/", expiresAt: nil, isSecure: true, isHTTPOnly: true)
        ]
        let service = NGAForumService(
            accountID: AccountID(),
            cookies: cookies,
            transport: transport
        )

        _ = try await service.submitReply(
            topicID: TopicID(rawValue: 47239186),
            submission: ReplySubmission(content: "测试回复", replyTo: PostID(rawValue: 876078281))
        )

        let requests = await transport.requests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].httpMethod, "POST")
        XCTAssertTrue(requests[0].url?.query?.contains("lite=xml") == true)
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "X-User-Agent"), "NGA_WP_JW/(;WINDOWS)")
        let preflightBody = try XCTUnwrap(requests[0].httpBody.flatMap { String(data: $0, encoding: .utf8) })
        XCTAssertTrue(preflightBody.contains("access_uid=123"))
        XCTAssertTrue(preflightBody.contains("access_token=secret-token"))

        let submissionBody = try XCTUnwrap(requests[1].httpBody.flatMap { String(data: $0, encoding: .utf8) })
        XCTAssertTrue(submissionBody.contains("auth=reply-token"))
        XCTAssertTrue(submissionBody.contains("post_content="))
        XCTAssertTrue(submissionBody.contains("step=2"))
        XCTAssertTrue(requests[1].url?.query?.contains("pid=876078281") == true)
    }

    func testTopicRatingUsesDimensionIDInReplyFormAndSubmitsExactlyOnce() async throws {
        let transport = ReplySubmissionTransport()
        let service = NGAForumService(
            accountID: AccountID(),
            cookies: [],
            transport: transport
        )

        _ = try await service.submitReply(
            topicID: TopicID(rawValue: 23_347_410),
            submission: ReplySubmission(
                content: "评分回复",
                replyTo: nil,
                ratingScores: ["52689": 8]
            )
        )

        let requests = await transport.requests()
        XCTAssertEqual(requests.count, 2)
        let body = try XCTUnwrap(
            requests[1].httpBody.flatMap { String(data: $0, encoding: .utf8) }
        )
        let fields = Dictionary(
            uniqueKeysWithValues: (
                URLComponents(string: "?\(body)")?.queryItems ?? []
            ).compactMap { item in
                item.value.map { (item.name, $0) }
            }
        )
        XCTAssertEqual(fields["auth"], "reply-token")
        XCTAssertEqual(fields["post_content"], "评分回复")
        XCTAssertEqual(fields["52689"], "8")
        XCTAssertEqual(fields["step"], "2")
    }

    func testTopicPollSubmitsOfficialFormExactlyOnce() async throws {
        let transport = TopicPollSubmissionTransport()
        let service = NGAForumService(
            accountID: AccountID(),
            cookies: [],
            transport: transport
        )

        try await service.submitTopicPollVote(
            topicID: TopicID(rawValue: 47_273_517),
            optionIDs: ["207428", "207430"]
        )

        let requests = await transport.requests()
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/nuke.php")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "X-User-Agent"),
            "NGA_WP_JW/(;WINDOWS)"
        )
        let body = try XCTUnwrap(
            request.httpBody.flatMap { String(data: $0, encoding: .utf8) }
        )
        let fields = Dictionary(
            uniqueKeysWithValues: (
                URLComponents(string: "?\(body)")?.queryItems ?? []
            ).compactMap { item in
                item.value.map { (item.name, $0) }
            }
        )
        XCTAssertEqual(fields["__lib"], "vote")
        XCTAssertEqual(fields["__act"], "vote")
        XCTAssertEqual(fields["tid"], "47273517")
        XCTAssertEqual(fields["voteid"], "207428,207430")
        XCTAssertEqual(fields["raw"], "3")
    }

    func testThreadFallsBackToWebHTMLWhenStructuredResponseHasNoPosts() async throws {
        let transport = ThreadFallbackTransport()
        let service = NGAForumService(
            accountID: AccountID(),
            cookies: [],
            transport: transport
        )

        let page = try await service.threadPage(
            topicID: TopicID(rawValue: 47239680),
            page: 1,
            authorUID: 88
        )

        XCTAssertEqual(page.topic.subject, "兼容主题")
        XCTAssertEqual(page.posts.first?.author, "网页用户")
        XCTAssertTrue(page.posts.first?.html.contains("网页正文") == true)
        let requests = await transport.requests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests[0].url?.query?.contains("__output=11") == true)
        XCTAssertFalse(requests[1].url?.query?.contains("__output") == true)
        XCTAssertTrue(requests[0].url?.query?.contains("authorid=88") == true)
        XCTAssertTrue(requests[1].url?.query?.contains("authorid=88") == true)
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "User-Agent"), "NGA_WP_JW/(;WINDOWS)")
    }

    func testLocalSessionStorePersistsPerAccountWithoutKeychain() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "SNGA-SessionStore-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LocalSessionStore(directoryURL: directory)
        let accountA = AccountID()
        let accountB = AccountID()
        let cookie = SessionCookie(
            name: "ngaPassportUid",
            value: "123",
            domain: "bbs.nga.cn",
            path: "/",
            expiresAt: nil,
            isSecure: true,
            isHTTPOnly: true
        )

        try await store.save(cookies: [cookie], for: accountA)

        let storedA = try await store.cookies(for: accountA)
        let storedB = try await store.cookies(for: accountB)
        XCTAssertEqual(storedA, [cookie])
        XCTAssertEqual(storedB, [])
        try await store.remove(accountID: accountA)
        let removedA = try await store.cookies(for: accountA)
        XCTAssertEqual(removedA, [])
    }

    func testGenericHTTP403DoesNotInvalidateSession() async {
        let transport = FixedResponseTransport(
            statusCode: 403,
            body: "<html><title>Access denied</title></html>"
        )
        let client = NGANetworkClient(cookies: [], transport: transport)

        do {
            _ = try await client.request(.forums)
            XCTFail("HTTP 403 应抛出错误")
        } catch let error as ForumServiceError {
            guard case let .restricted(message) = error else {
                return XCTFail("普通 403 不应被识别为登录失效：\(error)")
            }
            XCTAssertTrue(message.contains("HTTP 403"))
        } catch {
            XCTFail("错误类型不正确：\(error)")
        }
    }

    func testDeletedTopicHTTP403UsesDeletedTopicError() async {
        let transport = FixedResponseTransport(
            statusCode: 403,
            body: #"{"error":["主题不存在或已被删除"]}"#
        )
        let client = NGANetworkClient(cookies: [], transport: transport)

        do {
            _ = try await client.request(.thread(
                topicID: TopicID(rawValue: 404),
                page: 1,
                authorUID: nil
            ))
            XCTFail("已删除主题应抛出专用错误")
        } catch let error as ForumServiceError {
            XCTAssertEqual(error, .topicDeleted)
            XCTAssertEqual(error.localizedDescription, "帖子被删除")
        } catch {
            XCTFail("错误类型不正确：\(error)")
        }
    }

    func testLockedTopicHTTP403UsesLockedTopicError() async {
        let transport = FixedResponseTransport(
            statusCode: 403,
            body: #"{"error":["11:\u6b64\u5e16\u5b50\u88ab\u9501\u5b9a"],"data":{"__MESSAGE":[11,"\u6b64\u5e16\u5b50\u88ab\u9501\u5b9a",null,403]}}"#
        )
        let client = NGANetworkClient(cookies: [], transport: transport)

        do {
            _ = try await client.request(.thread(
                topicID: TopicID(rawValue: 47_305_779),
                page: 1,
                authorUID: nil
            ))
            XCTFail("锁定主题应抛出专用错误")
        } catch let error as ForumServiceError {
            XCTAssertEqual(error, .topicLocked)
            XCTAssertEqual(error.localizedDescription, "帖子已锁定，无法查看或回复")
        } catch {
            XCTFail("错误类型不正确：\(error)")
        }
    }

    func testNonThreadHTTP403WithDeletedTextRemainsRestricted() async {
        let transport = FixedResponseTransport(
            statusCode: 403,
            body: #"{"error":["主题不存在或已被删除"]}"#
        )
        let client = NGANetworkClient(cookies: [], transport: transport)

        do {
            _ = try await client.request(.forums)
            XCTFail("HTTP 403 应抛出错误")
        } catch let error as ForumServiceError {
            guard case .restricted = error else {
                return XCTFail("非主题接口不应映射成已删除主题：\(error)")
            }
        } catch {
            XCTFail("错误类型不正确：\(error)")
        }
    }

    func testExplicitLoginHTTP403StillRequiresLogin() async {
        let transport = FixedResponseTransport(
            statusCode: 403,
            body: """
            {"error":["1:未登录","<a href='/nuke.php?__lib=login'>登录</a>"]}
            """
        )
        let client = NGANetworkClient(cookies: [], transport: transport)

        do {
            _ = try await client.request(.forums)
            XCTFail("明确的未登录响应应抛出错误")
        } catch let error as ForumServiceError {
            XCTAssertEqual(error, .requiresLogin)
        } catch {
            XCTFail("错误类型不正确：\(error)")
        }
    }
}

private actor RecordingTransport: HTTPTransport {
    private var headers: [String] = []
    private var bodies: [String] = []
    private var recordedXUserAgents: [String] = []
    private var timestamps: [Date] = []

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        timestamps.append(Date())
        headers.append(request.value(forHTTPHeaderField: "Cookie") ?? "")
        bodies.append(request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? "")
        recordedXUserAgents.append(request.value(forHTTPHeaderField: "X-User-Agent") ?? "")
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/html; charset=utf-8"])!
        return (Data("<a href='/thread.php?fid=-7'>测试板块</a>".utf8), response)
    }

    func cookieHeaders() -> [String] { headers }
    func requestBodies() -> [String] { bodies }
    func xUserAgents() -> [String] { recordedXUserAgents }
    func requestTimestamps() -> [Date] { timestamps }
}

private actor FailingTransport: HTTPTransport {
    private var count = 0

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        count += 1
        throw URLError(.networkConnectionLost)
    }

    func requestCount() -> Int { count }
}

private actor FixedResponseTransport: HTTPTransport {
    let statusCode: Int
    let body: String
    private var count = 0

    init(statusCode: Int, body: String) {
        self.statusCode = statusCode
        self.body = body
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        count += 1
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/html; charset=utf-8"]
        )!
        return (Data(body.utf8), response)
    }

    func requestCount() -> Int { count }
}

private actor ThreadFallbackTransport: HTTPTransport {
    private var recordedRequests: [URLRequest] = []

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        recordedRequests.append(request)
        let isStructured = request.url?.query?.contains("__output=11") == true
        let body: String
        let contentType: String
        if isStructured {
            body = #"{"data":{"__T":{"tid":47239680,"fid":-7,"subject":"兼容主题","replies":0},"__R":[]}}"#
            contentType = "application/json; charset=utf-8"
        } else {
            body = """
            <html>
              <head><title>兼容主题 - NGA玩家社区</title></head>
              <body>
                <div>
                  <span class="author">网页用户</span>
                  <div id="postcontent301" class="postcontent"><p>网页正文</p></div>
                </div>
              </body>
            </html>
            """
            contentType = "text/html; charset=utf-8"
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": contentType]
        )!
        return (Data(body.utf8), response)
    }

    func requests() -> [URLRequest] { recordedRequests }
}

private actor ReplySubmissionTransport: HTTPTransport {
    private var recordedRequests: [URLRequest] = []

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        recordedRequests.append(request)
        let isPreflight = recordedRequests.count == 1
        let body = isPreflight
            ? """
              <?xml version="1.0" encoding="UTF-8"?>
              <root><content></content><auth>reply-token</auth></root>
              """
            : """
              <?xml version="1.0" encoding="UTF-8"?>
              <root><__MESSAGE><item>0</item><item>发帖完毕</item><item>200</item></__MESSAGE></root>
              """
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/xml; charset=utf-8"]
        )!
        return (Data(body.utf8), response)
    }

    func requests() -> [URLRequest] { recordedRequests }
}

private actor TopicPollSubmissionTransport: HTTPTransport {
    private var recordedRequests: [URLRequest] = []

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        recordedRequests.append(request)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json; charset=utf-8"]
        )!
        return (Data(#"{"data":["投票成功"]}"#.utf8), response)
    }

    func requests() -> [URLRequest] { recordedRequests }
}
