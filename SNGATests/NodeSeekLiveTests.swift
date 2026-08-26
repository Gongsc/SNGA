import Foundation
import XCTest
@testable import SNGA

/// 打到线上的冒烟用例：确认地址、请求头和选择器现在还对得上。
///
/// **不进自动化** —— 方法名不以 `test` 开头，XCTest 就发现不了。理由和登录那条一样：
/// 依赖第三方站点，慢且会随对方改版而红。夹具测试才是常跑的那套，这条只在
/// 「怀疑站点改版了」时手动跑：把方法名临时改回 `test` 开头即可。
///
/// 不需要账号 —— 分类列表匿名可读。
final class NodeSeekLiveTests: XCTestCase {

    func manualLiveCategoryListParses() async throws {
        let service = NodeSeekForumService(
            accountID: AccountID(),
            cookies: [],
            // 线上会核对 UA 与页面 JS 环境是否一致；这里没有 WebView，用浏览器形态的退路。
            userAgent: ForumSiteDescriptor.nodeseek.resolvedUserAgent(fallback: nil)
        )

        let page = try await service.topics(
            forumID: NodeSeekEndpoint.forumID(key: "daily"),
            page: 1,
            sortOrder: .latestReply,
            featuredOnly: false
        )

        XCTAssertFalse(page.topics.isEmpty, "线上列表页解析不出话题 —— 多半是选择器过时了")
        XCTAssertGreaterThan(page.totalPages, 1)
        XCTAssertEqual(page.forum?.name, "日常")
        let first = try XCTUnwrap(page.topics.first)
        XCTAssertFalse(first.subject.isEmpty)
        XCTAssertGreaterThan(first.id.rawValue, 0)
        print("线上第一条：#\(first.id) \(first.subject.prefix(30))，共 \(page.totalPages) 页")
    }
}
