import Foundation
import XCTest
@testable import SNGA

/// Linux.do 适配器：发出去的请求对不对、切页对不对、站点地址和站内链接。
///
/// 网络一律走 `RecordingHTTPTransport`，夹具见 `LinuxDoParserTests`。
final class LinuxDoForumServiceTests: XCTestCase {

    private func fixture(_ name: String) throws -> String {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func makeService(_ transport: RecordingHTTPTransport) -> LinuxDoForumService {
        LinuxDoForumService(
            accountID: AccountID(),
            cookies: [
                SessionCookie(
                    name: "_t", value: "token", domain: "linux.do", path: "/",
                    expiresAt: nil, isSecure: true, isHTTPOnly: true
                ),
                SessionCookie(
                    name: "cf_clearance", value: "clear", domain: ".linux.do", path: "/",
                    expiresAt: nil, isSecure: true, isHTTPOnly: true
                )
            ],
            transport: transport,
            userAgent: "WebViewUA"
        )
    }

    // MARK: - 站点资料

    func testDescriptorMatchesWhatWasMeasured() {
        let site = ForumSiteDescriptor.linuxdo
        XCTAssertEqual(site.baseURL.absoluteString, "https://linux.do")
        XCTAssertEqual(site.loginURL.absoluteString, "https://linux.do/login")
        XCTAssertEqual(site.replyMarkup, .markdown)
        XCTAssertEqual(site.sessionCookieNames, ["_t"])
        // 编号 cookie 和页面里都没有，只能登录后问。
        XCTAssertEqual(site.userIDSource, .sessionQuery)
        XCTAssertNil(site.uidCookieName)
        // Cloudflare 会拿 UA 和页面 JS 环境对，必须用 WebView 自报的那个。
        XCTAssertEqual(site.userAgent, .webView)
        XCTAssertTrue(site.owns(cookieDomain: ".linux.do"))
        XCTAssertFalse(site.owns(cookieDomain: "notlinux.do"))
    }

    /// 能力位一条条写，现在只点亮了真接上的那一位。
    func testOnlyImplementedCapabilitiesAreLit() {
        let service = makeService(RecordingHTTPTransport(responding: "{}"))
        XCTAssertEqual(service.capabilities, [.subforums])
    }

    // MARK: - 请求

    func testRequestsCarryEveryCookieAndTheWebViewUserAgent() async throws {
        let transport = RecordingHTTPTransport(responding: #"{"current_user":{"id":800001}}"#)
        let uid = try await makeService(transport).currentUserID()

        XCTAssertEqual(uid, 800_001)
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://linux.do/session/current.json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "WebViewUA")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        let cookie = try XCTUnwrap(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertTrue(cookie.contains("_t=token"))
        XCTAssertTrue(cookie.contains("cf_clearance=clear"), "少带一个就可能被挑战")
    }

    func testCategoryListUsesTheSlugPathAndAttachesSubcategories() async throws {
        let transport = RecordingHTTPTransport(
            responding: "{}",
            byPath: [
                "/categories.json": try fixture("linuxdo-categories"),
                "/c/": try fixture("linuxdo-category-latest")
            ]
        )
        let service = makeService(transport)
        let page = try await service.topics(
            forumID: LinuxDoEndpoint.forumID(categoryID: 14),
            page: 2,
            sortOrder: .latestTopic,
            featuredOnly: false
        )

        let list = try XCTUnwrap(transport.requests.last?.url)
        // 有 slug 就带上，省一次 302；页码从 0 数；「最新话题」是 order=created。
        XCTAssertEqual(list.path, "/c/resource/14/l/latest.json")
        let query = URLComponents(url: list, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertTrue(query.contains(URLQueryItem(name: "page", value: "1")))
        XCTAssertTrue(query.contains(URLQueryItem(name: "order", value: "created")))
        XCTAssertEqual(page.forum?.name, "资源荟萃")
        XCTAssertEqual(page.subforums.map(\.name), ["网盘资源"])

        // 类别表只取一次。
        _ = try await service.topics(
            forumID: LinuxDoEndpoint.forumID(categoryID: 4), page: 1, sortOrder: .latestReply, featuredOnly: false
        )
        XCTAssertEqual(transport.requests.filter { $0.url?.path == "/categories.json" }.count, 1)
    }

    /// 版面表只列顶层类别。子类别平铺出来，登录后会把每个类别的 Lv1 分区各列一遍，
    /// 看起来就是一份重复的列表（用户在应用里实际看到的）。
    func testForumListShowsOnlyTopLevelCategories() async throws {
        let transport = RecordingHTTPTransport(responding: try fixture("linuxdo-categories"))
        let forums = try await makeService(transport).forums()
        XCTAssertEqual(forums.map(\.name), ["最新", "开发调优", "资源荟萃", "搞七捻三"])
        XCTAssertFalse(forums.contains { $0.isSubforum })
    }

    func testLatestDoesNotNeedTheCategoryTable() async throws {
        let transport = RecordingHTTPTransport(responding: try fixture("linuxdo-category-latest"))
        let page = try await makeService(transport).topics(
            forumID: LinuxDoEndpoint.forumID(key: LinuxDoEndpoint.latestKey),
            page: 1,
            sortOrder: .latestReply,
            featuredOnly: false
        )
        XCTAssertEqual(transport.requests.map { $0.url?.absoluteString }, ["https://linux.do/latest.json"])
        XCTAssertEqual(page.forum?.name, "最新")
    }

    /// 站点不分页，适配器按 20 楼一页自己切：第一页走详情，第二页按编号批量取那 20 楼。
    func testThreadPagesAreCutFromThePostStream() async throws {
        let transport = RecordingHTTPTransport(
            responding: "{}",
            byPath: [
                "/t/3103315.json": try fixture("linuxdo-topic"),
                "/t/3103315/": try fixture("linuxdo-topic-posts")
            ]
        )
        let service = makeService(transport)
        let topicID = TopicID(rawValue: 3_103_315)

        let first = try await service.threadPage(topicID: topicID, page: 1, authorUID: nil)
        XCTAssertEqual(first.totalPages, 4, "65 楼，每页 20")
        XCTAssertTrue(first.hasMore)
        XCTAssertEqual(first.posts.first?.floor, 0)
        // 只取这一页缺的那些楼，不多取。
        let firstBatch = try XCTUnwrap(transport.requests.last?.url)
        XCTAssertEqual(firstBatch.path, "/t/3103315/posts.json")
        XCTAssertEqual(postIDs(in: firstBatch).count, 19, "详情已经带回了主楼")

        transport.reset()
        let second = try await service.threadPage(topicID: topicID, page: 2, authorUID: nil)
        // 编号流记着，第二页不必再取详情。
        XCTAssertEqual(transport.requests.count, 1)
        let batch = try XCTUnwrap(transport.requests.first?.url)
        XCTAssertEqual(postIDs(in: batch).count, 20)
        XCTAssertEqual(postIDs(in: batch).first, "24263769", "第二页从编号流的第 21 个开始")
        XCTAssertEqual(second.posts.map(\.floor), [20, 21])
        XCTAssertEqual(second.page, 2)
        XCTAssertEqual(second.topic.id, topicID)
    }

    func testChallengeIsReportedAsVerificationNotLogin() async throws {
        let transport = RecordingHTTPTransport(
            responding: "<html><head><title>Just a moment...</title></head></html>",
            status: 403
        )
        do {
            _ = try await makeService(transport).currentUserID()
            XCTFail("挑战页不该被当成正常响应")
        } catch let error as ForumServiceError {
            guard case let .restricted(message) = error else {
                return XCTFail("应当提示去完成人机验证，实际是 \(error)")
            }
            XCTAssertTrue(message.contains("人机验证"))
        }
    }

    func testDiscourseErrorMessageIsShownAsIs() async throws {
        let transport = RecordingHTTPTransport(
            responding: #"{"errors":["您没有权限查看请求的资源。"],"error_type":"invalid_access"}"#,
            status: 403
        )
        do {
            _ = try await makeService(transport).threadPage(topicID: TopicID(rawValue: 1), page: 1, authorUID: nil)
            XCTFail("403 应当抛错")
        } catch let error as ForumServiceError {
            XCTAssertEqual(error, .restricted("您没有权限查看请求的资源。"))
        }
    }

    // MARK: - 站内链接

    func testInternalLinks() {
        let site = ForumSiteDescriptor.linuxdo
        func destination(_ string: String) -> NGAInternalDestination? {
            site.internalDestination(for: URL(string: string)!)
        }
        XCTAssertEqual(
            destination("https://linux.do/t/topic/3103315"),
            .topic(topicID: TopicID(rawValue: 3_103_315), page: nil, postID: nil)
        )
        // 第 45 楼在第 3 页（每页 20 楼）。楼层号和编号流的位置在有删帖时会差几楼，
        // 落到相邻一页也比打开浏览器强。
        XCTAssertEqual(
            destination("https://linux.do/t/some-slug/3103315/45"),
            .topic(topicID: TopicID(rawValue: 3_103_315), page: 3, postID: nil)
        )
        XCTAssertEqual(destination("https://linux.do/c/develop/4"), .forum(LinuxDoEndpoint.forumID(categoryID: 4)))
        XCTAssertEqual(
            destination("https://linux.do/c/resource/cloud-asset/94/l/latest"),
            .forum(LinuxDoEndpoint.forumID(categoryID: 94))
        )
        XCTAssertEqual(destination("https://linux.do/latest"), .forum(LinuxDoEndpoint.forumID(key: "latest")))
        // 用户地址里是名字，同步路径上翻译不了，交给浏览器。
        XCTAssertNil(destination("https://linux.do/u/user1"))
        XCTAssertNil(destination("https://example.com/t/topic/1"))
    }

    private func postIDs(in url: URL) -> [String] {
        (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .filter { $0.name == "post_ids[]" }
            .compactMap(\.value)
    }
}
