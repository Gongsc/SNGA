import Foundation
import SwiftData
import XCTest
@testable import SNGA

final class AIProfileTests: XCTestCase {
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: AISettings.baseURLKey)
        UserDefaults.standard.removeObject(forKey: AISettings.modelKey)
        UserDefaults.standard.removeObject(forKey: AISettings.instructionKey)
        UserDefaults.standard.removeObject(forKey: AISettings.historyLimitKey)
        super.tearDown()
    }

    func testBaseURLAllowsHTTPSAndLoopbackHTTPOnly() {
        XCTAssertEqual(
            AISettings.normalizedBaseURL(from: " https://example.com/v1/ ")?.absoluteString,
            "https://example.com/v1"
        )
        XCTAssertEqual(
            AISettings.normalizedBaseURL(from: "http://localhost:11434/v1")?.absoluteString,
            "http://localhost:11434/v1"
        )
        XCTAssertEqual(
            AISettings.normalizedBaseURL(from: "http://[::1]:11434/v1")?.host(),
            "::1"
        )
        XCTAssertNil(AISettings.normalizedBaseURL(from: "http://example.com/v1"))
        XCTAssertNil(AISettings.normalizedBaseURL(from: "https://user:secret@example.com/v1"))
        XCTAssertNil(AISettings.normalizedBaseURL(from: "https://example.com/v1?token=secret"))
    }

    func testInputIsBoundedAndKeepsNewestActivities() throws {
        let profile = Profile(uid: 42, displayName: "测试用户", avatarURL: nil)
        let topics = (0..<100).map { index in
            UserActivity(
                id: "topic-\(index)",
                kind: .topics,
                topicID: TopicID(rawValue: Int64(index)),
                subject: "较新的话题 \(index)",
                excerpt: String(repeating: "长摘要", count: 500),
                postedAt: Date(timeIntervalSince1970: Double(2_000_000_000 - index))
            )
        }
        let replies = (0..<100).map { index in
            UserActivity(
                id: "reply-\(index)",
                kind: .replies,
                topicID: TopicID(rawValue: Int64(index)),
                subject: "较新的回复 \(index)",
                excerpt: String(repeating: "回复内容", count: 500),
                postedAt: Date(timeIntervalSince1970: Double(2_000_000_000 - index))
            )
        }

        let input = AIProfileInput.make(profile: profile, topics: topics, replies: replies)
        let data = try XCTUnwrap(input.jsonString().data(using: .utf8))

        XCTAssertLessThanOrEqual(data.count, AISettings.maximumInputBytes)
        XCTAssertTrue(input.coverage.wasTruncated)
        XCTAssertLessThan(input.topics.count + input.replies.count, 200)
        XCTAssertEqual(input.topics.first?.subject, "较新的话题 0")
        XCTAssertEqual(input.replies.first?.subject, "较新的回复 0")
    }

    func testRequestUsesCompatibleChatShapeAndProtectsAPIKey() throws {
        let configuration = AIConfiguration(
            baseURL: try XCTUnwrap(URL(string: "https://example.com/v1")),
            model: "test-model",
            apiKey: "top-secret",
            instruction: "请简洁总结"
        )
        let input = AIProfileInput.make(
            profile: Profile(uid: 7, displayName: "用户", avatarURL: nil),
            topics: [],
            replies: []
        )

        let request = try OpenAICompatibleClient.makeRequest(
            configuration: configuration,
            input: input,
            streams: true
        )
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])

        XCTAssertEqual(request.url?.absoluteString, "https://example.com/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer top-secret")
        XCTAssertEqual(json["model"] as? String, "test-model")
        XCTAssertEqual(json["stream"] as? Bool, true)
        XCTAssertEqual(messages.map { $0["role"] as? String }, ["system", "user"])
        XCTAssertTrue((messages[0]["content"] as? String)?.contains("不可信的只读资料") == true)
        XCTAssertFalse(String(data: body, encoding: .utf8)?.contains("top-secret") == true)
    }

    func testParsesStreamAndOrdinaryResponses() throws {
        XCTAssertEqual(
            try OpenAICompatibleClient.streamContent(
                from: "data: {\"choices\":[{\"delta\":{\"content\":\"你好\"}}]}"
            ),
            "你好"
        )
        XCTAssertNil(try OpenAICompatibleClient.streamContent(from: "data: [DONE]"))

        let ordinary = Data("""
        {"choices":[{"message":{"content":"完整画像"}}]}
        """.utf8)
        XCTAssertEqual(try OpenAICompatibleClient.completionText(from: ordinary), "完整画像")
    }

    func testUnsupportedStreamingFallsBackExactlyOnce() async throws {
        let transport = QueueAIChatTransport(responses: [
            .data(
                Data("{\"error\":{\"message\":\"stream is not supported\"}}".utf8),
                response(status: 400)
            ),
            .data(
                Data("{\"choices\":[{\"message\":{\"content\":\"回退画像\"}}]}".utf8),
                response(status: 200)
            )
        ])
        let client = OpenAICompatibleClient(transport: transport)

        let result = try await collect(client.streamSummary(
            configuration: configuration,
            input: emptyInput
        ))
        let requests = await transport.recordedRequests()
        let bodies = try requests.map { request -> [String: Any] in
            try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        }

        XCTAssertEqual(result, "回退画像")
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(bodies[0]["stream"] as? Bool, true)
        XCTAssertEqual(bodies[1]["stream"] as? Bool, false)
    }

    func testStreamingRequestAcceptsOrdinaryJSONWithoutRetry() async throws {
        let transport = QueueAIChatTransport(responses: [
            .data(
                Data("{\"choices\":[{\"message\":{\"content\":\"普通响应画像\"}}]}".utf8),
                response(status: 200)
            )
        ])
        let client = OpenAICompatibleClient(transport: transport)

        let result = try await collect(client.streamSummary(
            configuration: configuration,
            input: emptyInput
        ))
        let requests = await transport.recordedRequests()

        XCTAssertEqual(result, "普通响应画像")
        XCTAssertEqual(requests.count, 1)
    }

    func testAmbiguousStreamingErrorDoesNotTriggerPaidRetry() async {
        let transport = QueueAIChatTransport(responses: [
            .data(
                Data("{\"error\":{\"message\":\"upstream stream reset\"}}".utf8),
                response(status: 400)
            ),
            .data(
                Data("{\"choices\":[{\"message\":{\"content\":\"不应请求\"}}]}".utf8),
                response(status: 200)
            )
        ])
        let client = OpenAICompatibleClient(transport: transport)

        do {
            _ = try await collect(client.streamSummary(
                configuration: configuration,
                input: emptyInput
            ))
            XCTFail("含糊的 stream 错误不能触发自动重试")
        } catch let error as AIServiceError {
            guard case let .server(status, _) = error else {
                XCTFail("错误类型不正确")
                return
            }
            XCTAssertEqual(status, 400)
        } catch {
            XCTFail("错误类型不正确：\(error)")
        }
        let requestCount = await transport.recordedRequests().count
        XCTAssertEqual(requestCount, 1)
    }

    func testPartialStreamingFailureDoesNotRetry() async {
        let partialStream = AsyncThrowingStream<String, Error> { continuation in
            continuation.yield("data: {\"choices\":[{\"delta\":{\"content\":\"部分内容\"}}]}")
            continuation.finish(throwing: TestStreamError.disconnected)
        }
        let transport = QueueAIChatTransport(responses: [
            .stream(partialStream, response(status: 200)),
            .data(
                Data("{\"choices\":[{\"message\":{\"content\":\"不应请求\"}}]}".utf8),
                response(status: 200)
            )
        ])
        let client = OpenAICompatibleClient(transport: transport)

        do {
            _ = try await collect(client.streamSummary(
                configuration: configuration,
                input: emptyInput
            ))
            XCTFail("已输出部分内容后的流式失败不应重试或成功")
        } catch {
            // 预期保留原始传输错误。
        }
        let requestCount = await transport.recordedRequests().count
        XCTAssertEqual(requestCount, 1)
    }

    func testAuthenticationFailureDoesNotRetry() async {
        let transport = QueueAIChatTransport(responses: [
            .data(
                Data("{\"error\":{\"message\":\"invalid api key\"}}".utf8),
                response(status: 401)
            )
        ])
        let client = OpenAICompatibleClient(transport: transport)

        do {
            _ = try await collect(client.streamSummary(
                configuration: configuration,
                input: emptyInput
            ))
            XCTFail("鉴权失败不应成功")
        } catch let error as AIServiceError {
            guard case let .server(status, _) = error else {
                XCTFail("错误类型不正确")
                return
            }
            XCTAssertEqual(status, 401)
        } catch {
            XCTFail("错误类型不正确：\(error)")
        }
        let requestCount = await transport.recordedRequests().count
        XCTAssertEqual(requestCount, 1)
    }

    func testInMemoryKeyStoreSupportsSaveAndDelete() async throws {
        let store = InMemoryAIKeyStore()
        let initialKey = await store.apiKey()
        XCTAssertNil(initialKey)
        await store.save(apiKey: " secret ")
        let savedKey = await store.apiKey()
        XCTAssertEqual(savedKey, "secret")
        await store.removeAPIKey()
        let removedKey = await store.apiKey()
        XCTAssertNil(removedKey)
    }

    @MainActor
    func testHistoryGenerationUpsertsDeletesAndTrims() async throws {
        UserDefaults.standard.set(AISettings.defaultBaseURL, forKey: AISettings.baseURLKey)
        UserDefaults.standard.set("test-model", forKey: AISettings.modelKey)
        UserDefaults.standard.set(AISettings.defaultInstruction, forKey: AISettings.instructionKey)
        UserDefaults.standard.set(50, forKey: AISettings.historyLimitKey)

        let schema = Schema([AccountRecord.self, AIProfileSummaryRecord.self])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration("AIProfileTests", schema: schema, isStoredInMemoryOnly: true)]
        )
        let session = AppSession(
            container: container,
            sessionStore: LocalSessionStore.shared,
            notificationService: .shared
        )
        let accountID = AccountID(rawValue: UUID())
        session.activeAccountID = accountID
        session.setService(DebugForumService(accountID: accountID), for: accountID)
        let store = AIProfileStore(
            context: session.context,
            session: session,
            summarizer: ImmediateSummarizer(text: "测试画像"),
            keyStore: InMemoryAIKeyStore()
        )
        let profile = Profile(uid: 42, displayName: "测试用户", avatarURL: nil)

        store.generate(uid: 42, fallbackProfile: profile)
        try await waitUntilFinished(store)
        store.generate(uid: 42, fallbackProfile: profile)
        try await waitUntilFinished(store)

        XCTAssertEqual(store.records.count, 1)
        XCTAssertEqual(store.records.first?.summary, "测试画像")
        XCTAssertEqual(store.records.first?.topicCount, 1)
        XCTAssertEqual(store.records.first?.replyCount, 1)

        session.context.insert(AIProfileSummaryRecord(
            uid: 43,
            displayName: "用户 43",
            avatarURL: nil,
            summary: "画像 43",
            model: "test-model",
            generatedAt: Date(timeIntervalSince1970: 10),
            topicCount: 0,
            replyCount: 0,
            wasTruncated: false
        ))
        session.context.insert(AIProfileSummaryRecord(
            uid: 44,
            displayName: "用户 44",
            avatarURL: nil,
            summary: "画像 44",
            model: "test-model",
            generatedAt: Date(timeIntervalSince1970: 20),
            topicCount: 0,
            replyCount: 0,
            wasTruncated: false
        ))
        try session.context.save()
        let restoredStore = AIProfileStore(
            context: session.context,
            session: session,
            summarizer: ImmediateSummarizer(text: "测试画像"),
            keyStore: InMemoryAIKeyStore()
        )
        restoredStore.trimToHistoryLimit(2)
        XCTAssertEqual(restoredStore.records.count, 2)
        XCTAssertFalse(restoredStore.records.contains { $0.uid == 43 })

        if let first = restoredStore.records.first {
            restoredStore.delete(first)
        }
        XCTAssertEqual(restoredStore.records.count, 1)
        restoredStore.clearAll()
        XCTAssertTrue(restoredStore.records.isEmpty)
    }

    @MainActor
    func testCancellationDoesNotSavePartialResult() async throws {
        configureAIForStoreTests()
        let (session, container) = try makeSession()
        _ = container
        let store = AIProfileStore(
            context: session.context,
            session: session,
            summarizer: SlowSummarizer(),
            keyStore: InMemoryAIKeyStore()
        )

        store.generate(
            uid: 42,
            fallbackProfile: Profile(uid: 42, displayName: "测试用户", avatarURL: nil)
        )
        let deadline = Date().addingTimeInterval(3)
        while store.streamedText.isEmpty, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(store.streamedText, "部分画像")

        store.cancelGeneration()
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertNil(store.generatingUID)
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertEqual(store.errorMessage, "已取消生成，本次结果没有保存。")
    }

    @MainActor
    func testFailedRegenerationKeepsExistingRecord() async throws {
        configureAIForStoreTests()
        let (session, container) = try makeSession()
        _ = container
        session.context.insert(AIProfileSummaryRecord(
            uid: 42,
            displayName: "测试用户",
            avatarURL: nil,
            summary: "旧画像",
            model: "old-model",
            topicCount: 1,
            replyCount: 1,
            wasTruncated: false
        ))
        try session.context.save()
        let store = AIProfileStore(
            context: session.context,
            session: session,
            summarizer: FailingSummarizer(),
            keyStore: InMemoryAIKeyStore()
        )

        store.generate(
            uid: 42,
            fallbackProfile: Profile(uid: 42, displayName: "测试用户", avatarURL: nil)
        )
        try await waitUntilFinished(store, expectsError: true)

        XCTAssertEqual(store.records.count, 1)
        XCTAssertEqual(store.records.first?.summary, "旧画像")
        XCTAssertEqual(store.records.first?.model, "old-model")
        XCTAssertNotNil(store.errorMessage)
    }

    @MainActor
    func testAddingAIHistoryModelMigratesExistingStore() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(
                path: "SNGA-AI-Migration-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appending(path: "SNGA.store")

        do {
            let legacySchema = Schema([AccountRecord.self])
            let legacyContainer = try ModelContainer(
                for: legacySchema,
                configurations: [ModelConfiguration(
                    "Legacy",
                    schema: legacySchema,
                    url: storeURL,
                    cloudKitDatabase: .none
                )]
            )
            legacyContainer.mainContext.insert(AccountRecord(
                ngaUID: 10001,
                displayName: "迁移前账号",
                isCurrent: true
            ))
            try legacyContainer.mainContext.save()
        }

        let currentSchema = Schema([AccountRecord.self, AIProfileSummaryRecord.self])
        let currentContainer = try ModelContainer(
            for: currentSchema,
            configurations: [ModelConfiguration(
                "Current",
                schema: currentSchema,
                url: storeURL,
                cloudKitDatabase: .none
            )]
        )
        let accounts = try currentContainer.mainContext.fetch(FetchDescriptor<AccountRecord>())
        XCTAssertEqual(accounts.map(\.displayName), ["迁移前账号"])

        currentContainer.mainContext.insert(AIProfileSummaryRecord(
            uid: 10001,
            displayName: "迁移前账号",
            avatarURL: nil,
            summary: "迁移后可保存画像",
            model: "test-model",
            topicCount: 0,
            replyCount: 0,
            wasTruncated: false
        ))
        try currentContainer.mainContext.save()
        let profiles = try currentContainer.mainContext.fetch(
            FetchDescriptor<AIProfileSummaryRecord>()
        )
        XCTAssertEqual(profiles.first?.summary, "迁移后可保存画像")
    }

    private var configuration: AIConfiguration {
        AIConfiguration(
            baseURL: URL(string: "https://example.com/v1")!,
            model: "test-model",
            apiKey: nil,
            instruction: "总结"
        )
    }

    private var emptyInput: AIProfileInput {
        AIProfileInput.make(
            profile: Profile(uid: 1, displayName: "用户", avatarURL: nil),
            topics: [],
            replies: []
        )
    }

    private func response(status: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://example.com/v1/chat/completions")!,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
    }

    private func collect(_ stream: AsyncThrowingStream<String, Error>) async throws -> String {
        var result = ""
        for try await fragment in stream { result += fragment }
        return result
    }

    @MainActor
    private func waitUntilFinished(
        _ store: AIProfileStore,
        expectsError: Bool = false
    ) async throws {
        let deadline = Date().addingTimeInterval(3)
        while store.generatingUID != nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNil(store.generatingUID)
        if !expectsError { XCTAssertNil(store.errorMessage) }
    }

    @MainActor
    private func configureAIForStoreTests() {
        UserDefaults.standard.set(AISettings.defaultBaseURL, forKey: AISettings.baseURLKey)
        UserDefaults.standard.set("test-model", forKey: AISettings.modelKey)
        UserDefaults.standard.set(AISettings.defaultInstruction, forKey: AISettings.instructionKey)
        UserDefaults.standard.set(50, forKey: AISettings.historyLimitKey)
    }

    @MainActor
    private func makeSession() throws -> (AppSession, ModelContainer) {
        let schema = Schema([AccountRecord.self, AIProfileSummaryRecord.self])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(
                "AIProfileTests-\(UUID().uuidString)",
                schema: schema,
                isStoredInMemoryOnly: true
            )]
        )
        let session = AppSession(
            container: container,
            sessionStore: LocalSessionStore.shared,
            notificationService: .shared
        )
        let accountID = AccountID(rawValue: UUID())
        session.activeAccountID = accountID
        session.setService(DebugForumService(accountID: accountID), for: accountID)
        return (session, container)
    }
}

private enum TestStreamError: Error {
    case disconnected
}

private actor QueueAIChatTransport: AIChatTransport {
    private var responses: [AIChatTransportResponse]
    private var requests: [URLRequest] = []

    init(responses: [AIChatTransportResponse]) {
        self.responses = responses
    }

    func response(for request: URLRequest) throws -> AIChatTransportResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw AIServiceError.invalidResponse }
        return responses.removeFirst()
    }

    func recordedRequests() -> [URLRequest] {
        requests
    }
}

private struct ImmediateSummarizer: AIProfileSummarizing {
    let text: String

    func streamSummary(
        configuration: AIConfiguration,
        input: AIProfileInput
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(text)
            continuation.finish()
        }
    }
}

private struct SlowSummarizer: AIProfileSummarizing {
    func streamSummary(
        configuration: AIConfiguration,
        input: AIProfileInput
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    continuation.yield("部分画像")
                    try await Task.sleep(for: .seconds(5))
                    continuation.yield("不应保存")
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private struct FailingSummarizer: AIProfileSummarizing {
    func streamSummary(
        configuration: AIConfiguration,
        input: AIProfileInput
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: AIServiceError.invalidResponse)
        }
    }
}
