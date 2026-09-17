import XCTest
@testable import SNGA

/// 站点黑名单。
///
/// 两件事值得钉住：**两个方向的请求体装的不是同一样东西**（加按名字、删按编号），
/// 以及**查询失败不能退化成空名单** —— 后者会让界面把一个已经屏蔽了的人画成
/// 「未屏蔽」，用户点下去正好做反。
final class NodeSeekBlockListTests: XCTestCase {
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

    private func body(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody))
                as? [String: Any]
        )
    }

    func testTheListReadsTheBlockedMemberIDs() async throws {
        let transport = RecordingHTTPTransport(
            responding: #"""
            {"success":true,"data":[
              {"block_member_id":20002,"block_member_name":"someone"},
              {"block_member_id":30003,"block_member_name":"another"}
            ]}
            """#
        )
        let ids = try await makeService(transport).blockedUserIDs()

        XCTAssertEqual(ids, [20002, 30003])
        XCTAssertEqual(transport.requests.first?.url?.path, "/api/block-list/list")
    }

    /// 查过了、一个都没有 —— 这是个正常答复，不是错。
    func testAnEmptyListIsNotAnError() async throws {
        let transport = RecordingHTTPTransport(responding: #"{"success":true,"data":[]}"#)
        let ids = try await makeService(transport).blockedUserIDs()
        XCTAssertTrue(ids.isEmpty)
    }

    /// 而查询失败必须抛，**不能返回空集合**。两者都「一个人都没有」，含义却正相反：
    /// 一个是「你没屏蔽任何人」，一个是「不知道」。
    func testAFailedQueryThrowsRatherThanLookingLikeAnEmptyList() async throws {
        for payload in [
            #"{"success":false,"message":"请先登录"}"#,
            #"{"success":true}"#,
            "<html>Just a page</html>"
        ] {
            let transport = RecordingHTTPTransport(responding: payload)
            do {
                _ = try await makeService(transport).blockedUserIDs()
                XCTFail("『查不到』被当成了『名单是空的』：\(payload)")
            } catch {
                XCTAssertTrue(error is ForumServiceError)
            }
        }
    }

    /// 加进黑名单传的是**名字**。
    func testBlockingSendsTheName() async throws {
        let transport = RecordingHTTPTransport(responding: #"{"success":true}"#)

        try await makeService(transport)
            .updateUserBlock(uid: 20002, name: "someone", isBlocked: true)

        let request = try XCTUnwrap(transport.requests.last)
        XCTAssertEqual(request.url?.path, "/api/block-list/add")
        XCTAssertEqual(try body(request)["block_member_name"] as? String, "someone")
        XCTAssertNil(
            try body(request)["block_member_id"],
            "加进去这一边不认编号，多传只会让人以为它是可选的"
        )
    }

    /// 移出黑名单传的是**编号**。同一个动作的两个方向参数不一样，是站点的不对称，
    /// 不是这里写歪了。
    func testUnblockingSendsTheID() async throws {
        let transport = RecordingHTTPTransport(responding: #"{"success":true}"#)

        try await makeService(transport)
            .updateUserBlock(uid: 20002, name: "someone", isBlocked: false)

        let request = try XCTUnwrap(transport.requests.last)
        XCTAssertEqual(request.url?.path, "/api/block-list/del")
        XCTAssertEqual((try body(request)["block_member_id"] as? NSNumber)?.int64Value, 20002)
        XCTAssertNil(try body(request)["block_member_name"])
    }

    /// 名字空着就不发。按名字加人的接口收到一个空串，最坏的结果是屏蔽了某个
    /// 名字为空的账号。
    func testBlockingWithoutANameNeverLeaves() async throws {
        let transport = RecordingHTTPTransport(responding: #"{"success":true}"#)
        do {
            try await makeService(transport)
                .updateUserBlock(uid: 20002, name: "   ", isBlocked: true)
            XCTFail("名字空着还发了出去")
        } catch {
            XCTAssertTrue(transport.requests.isEmpty)
        }
    }

    /// 解除不需要名字 —— 它按编号走。
    func testUnblockingDoesNotNeedAName() async throws {
        let transport = RecordingHTTPTransport(responding: #"{"success":true}"#)
        try await makeService(transport)
            .updateUserBlock(uid: 20002, name: "", isBlocked: false)
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testARefusedWriteIsReported() async throws {
        let transport = RecordingHTTPTransport(
            responding: #"{"success":false,"message":"不能屏蔽管理员"}"#
        )
        do {
            try await makeService(transport)
                .updateUserBlock(uid: 1, name: "admin", isBlocked: true)
            XCTFail("站点答了 success:false")
        } catch {
            XCTAssertEqual(error as? ForumServiceError, .restricted("不能屏蔽管理员"))
        }
    }

    /// 没有这回事的站点走默认实现，抛 `.unsupported` —— 界面按能力位不画那个按钮，
    /// 正常路径走不到这里；走到了就说明有个调用点漏了门控，这个报错是来指出它的。
    func testSitesWithoutABlockListSaySoInsteadOfPretending() async throws {
        let service = V2EXForumService(
            accountID: AccountID(),
            cookies: [],
            transport: RecordingHTTPTransport(responding: ""),
            userAgent: "probe"
        )
        do {
            _ = try await service.blockedUserIDs()
            XCTFail("V2EX 没有站点黑名单")
        } catch {
            guard case .unsupported = error as? ForumServiceError else {
                return XCTFail("应当是 .unsupported，实际是 \(error)")
            }
        }
    }

    func testOnlyNodeSeekAdvertisesTheCapability() {
        let nodeseek = NodeSeekForumService(
            accountID: AccountID(), cookies: [], userAgent: "probe"
        )
        let v2ex = V2EXForumService(
            accountID: AccountID(), cookies: [], userAgent: "probe"
        )
        let nga = NGAForumService(accountID: AccountID(), cookies: [])

        XCTAssertTrue(nodeseek.capabilities.contains(.userBlocking))
        XCTAssertFalse(v2ex.capabilities.contains(.userBlocking))
        XCTAssertFalse(nga.capabilities.contains(.userBlocking))
    }
}
