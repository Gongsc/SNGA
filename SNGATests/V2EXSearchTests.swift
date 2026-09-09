import Foundation
import XCTest
@testable import SNGA

/// V2EX 的两档搜索来路完全不同：主题走第三方的 SoV2EX，节点在本地过滤。
///
/// 这份最要紧的一条是**会话不能跟着关键词出站**。SoV2EX 是别人的服务器，
/// 用户的 V2EX cookie 没有任何理由送到那儿去。
final class V2EXSearchTests: XCTestCase {

    private let session = SessionCookie(
        name: "A2", value: "very-secret", domain: ".v2ex.com", path: "/",
        expiresAt: nil, isSecure: true, isHTTPOnly: true
    )

    private func service(_ transport: RecordingHTTPTransport) -> V2EXForumService {
        V2EXForumService(
            accountID: AccountID(),
            cookies: [session],
            transport: transport,
            userAgent: "probe"
        )
    }

    private func transport() throws -> RecordingHTTPTransport {
        RecordingHTTPTransport(
            responding: "{}",
            byPath: [
                "/api/search": try fixture("v2ex-sov2ex-search"),
                "/api/nodes": try fixture("v2ex-nodes")
            ]
        )
    }

    private func fixture(_ name: String) throws -> String {
        let url = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: name, withExtension: "json"),
            "测试包里没有夹具 \(name).json"
        )
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// **关键词出站，会话不出站。**
    func testTheSessionNeverLeavesV2EX() async throws {
        let transport = try transport()
        let request = try XCTUnwrap(ForumSearchRequest(query: "dmit", kind: .topicContent))

        _ = try await service(transport).search(request, page: 1)

        let outbound = try XCTUnwrap(
            transport.requests.first { $0.url?.host == "www.sov2ex.com" },
            "主题搜索该发到 SoV2EX"
        )
        XCTAssertNil(outbound.value(forHTTPHeaderField: "Cookie"), "会话不能跟着出站")
        XCTAssertNil(outbound.value(forHTTPHeaderField: "Referer"))
        XCTAssertNil(outbound.value(forHTTPHeaderField: "Origin"))
        // 顺带确认这个会话在自家请求上是带着的，否则上面那条可能只是因为压根没有 cookie。
        let ownRequest = try XCTUnwrap(
            transport.requests.first { $0.url?.host == "www.v2ex.com" }
        )
        XCTAssertTrue(
            ownRequest.value(forHTTPHeaderField: "Cookie")?.contains("A2=very-secret") == true
        )
    }

    func testTopicSearchReadsResultsAndPaging() async throws {
        let transport = try transport()
        let request = try XCTUnwrap(ForumSearchRequest(query: "dmit", kind: .topicContent))

        let page = try await service(transport).search(request, page: 2)

        XCTAssertEqual(page.topics.count, 3)
        XCTAssertEqual(page.topics.first?.sourceForumName, "VPN")
        XCTAssertEqual(page.totalPages, 21)
        let url = try XCTUnwrap(
            transport.requests.first { $0.url?.host == "www.sov2ex.com" }?.url?.absoluteString
        )
        XCTAssertTrue(url.contains("from=20"), "第二页从第 20 条开始：\(url)")
        XCTAssertFalse(url.contains("node="), "没缩进节点就别带这个参数")
    }

    /// 在某个节点里搜时把**节点名**带上 —— 传数字编号那个参数会被无声地忽略。
    func testSearchingInsideANodeCarriesItsName() async throws {
        let transport = try transport()
        let request = try XCTUnwrap(ForumSearchRequest(
            query: "dmit",
            kind: .topicContent,
            forumID: V2EXEndpoint.forumID(key: "qna")
        ))

        _ = try await service(transport).search(request, page: 1)

        let url = try XCTUnwrap(
            transport.requests.first { $0.url?.host == "www.sov2ex.com" }?.url?.absoluteString
        )
        XCTAssertTrue(url.contains("node=qna"), url)
    }

    /// 首页分类不是节点，带不上 —— 界面在那种页面上本来就不画版面内搜索，
    /// 真被调到了也只能当全站搜，而不是把 `tab:tech` 当成节点名发出去。
    func testAHomepageTabIsNotSentAsANode() async throws {
        let transport = try transport()
        let request = try XCTUnwrap(ForumSearchRequest(
            query: "dmit",
            kind: .topicContent,
            forumID: V2EXEndpoint.tabForumID(key: "tech")
        ))

        _ = try await service(transport).search(request, page: 1)

        let url = try XCTUnwrap(
            transport.requests.first { $0.url?.host == "www.sov2ex.com" }?.url?.absoluteString
        )
        XCTAssertFalse(url.contains("node="), url)
    }

    /// 节点搜索不出网。
    func testNodeSearchStaysLocal() async throws {
        let transport = try transport()
        let request = try XCTUnwrap(ForumSearchRequest(query: "问与答", kind: .forum))

        let page = try await service(transport).search(request, page: 1)

        XCTAssertEqual(page.forums.map(\.id.key), ["qna"])
        XCTAssertTrue(
            transport.requests.allSatisfy { $0.url?.host == "www.v2ex.com" },
            "节点表是 V2EX 自己的，搜节点不该碰第三方"
        )
    }
}
