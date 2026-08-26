import Foundation
import XCTest
@testable import SNGA

/// NodeSeek 的地址拼装与站内链接解析。
///
/// 这些形状来自 `Design/SiteProbe-NodeSeek.md`。传输层那部分是实测的；地址形状来自阅读
/// 另一个客户端的源码，接第一个真接口时会被真实响应验证一次。
final class NodeSeekEndpointTests: XCTestCase {

    private let site = ForumSiteDescriptor.nodeseek

    // MARK: - 站点资料

    func testDescriptorMatchesWhatWasMeasured() {
        XCTAssertEqual(site.baseURL.absoluteString, "https://www.nodeseek.com")
        XCTAssertEqual(site.loginURL.absoluteString, "https://www.nodeseek.com/signIn.html")
        XCTAssertEqual(site.replyMarkup, .markdown)
        XCTAssertEqual(site.sessionCookieNames, ["session"])
        // 用户编号不在 cookie 里 —— 登录后要问接口。
        XCTAssertNil(site.uidCookieName)
        // 写死 UA 会触发无限挑战。
        XCTAssertEqual(site.userAgent, .webView)
    }

    func testCapabilitiesLeaveOutWhatTheSiteDoesNotHave() {
        let capabilities = NodeSeekForumService(
            accountID: AccountID(),
            cookies: [],
            userAgent: "probe"
        ).capabilities

        for present in [
            ForumCapabilities.checkIn, .postVote, .postDownvote,
            .quotePost, .poll, .privateMessages, .globalSearch, .userActivities
        ] {
            XCTAssertTrue(capabilities.contains(present))
        }
        for absent in [
            ForumCapabilities.forumFavorites, .subforums,
            .topicRating, .topicFavoriteFolders, .anonymousPosts
        ] {
            XCTAssertFalse(capabilities.contains(absent), "NodeSeek 没有这个功能")
        }
    }

    // MARK: - 列表与帖子地址

    func testHomeCategoryPagesWithoutASlug() {
        let home = NodeSeekEndpoint.forumID(key: NodeSeekEndpoint.homeKey)
        XCTAssertEqual(
            NodeSeekEndpoint.topicList(forumID: home, page: 1, sortByPostTime: false)
                .absoluteString,
            "https://www.nodeseek.com/"
        )
        XCTAssertEqual(
            NodeSeekEndpoint.topicList(forumID: home, page: 3, sortByPostTime: false)
                .absoluteString,
            "https://www.nodeseek.com/page-3"
        )
    }

    func testCategoryPagesUnderItsSlug() {
        let daily = NodeSeekEndpoint.forumID(key: "daily")
        XCTAssertEqual(
            NodeSeekEndpoint.topicList(forumID: daily, page: 1, sortByPostTime: false)
                .absoluteString,
            "https://www.nodeseek.com/categories/daily"
        )
        XCTAssertEqual(
            NodeSeekEndpoint.topicList(forumID: daily, page: 2, sortByPostTime: false)
                .absoluteString,
            "https://www.nodeseek.com/categories/daily/page-2"
        )
    }

    /// 默认排序不带参数，这样地址和站点自己的一模一样。
    func testDefaultSortAddsNoParameter() {
        let daily = NodeSeekEndpoint.forumID(key: "daily")
        XCTAssertFalse(
            NodeSeekEndpoint.topicList(forumID: daily, page: 1, sortByPostTime: false)
                .absoluteString.contains("sortBy")
        )
        XCTAssertTrue(
            NodeSeekEndpoint.topicList(forumID: daily, page: 1, sortByPostTime: true)
                .absoluteString.hasSuffix("?sortBy=postTime")
        )
    }

    func testThreadPathCarriesItsPage() {
        XCTAssertEqual(
            NodeSeekEndpoint.thread(topicID: TopicID(rawValue: 857_694), page: 2).absoluteString,
            "https://www.nodeseek.com/post-857694-2"
        )
    }

    /// 站点只给楼层号不给页码，跳转前得自己算。每页 10 层，`#0` 是主楼。
    func testFloorMapsToItsPage() {
        XCTAssertEqual(NodeSeekEndpoint.page(ofFloor: 0), 1)
        XCTAssertEqual(NodeSeekEndpoint.page(ofFloor: 1), 1)
        XCTAssertEqual(NodeSeekEndpoint.page(ofFloor: 10), 1)
        XCTAssertEqual(NodeSeekEndpoint.page(ofFloor: 11), 2)
        XCTAssertEqual(NodeSeekEndpoint.page(ofFloor: 127), 13)
    }

    // MARK: - 站内链接

    func testInternalLinksResolveToNativeDestinations() throws {
        let cases: [(String, NGAInternalDestination)] = [
            ("https://www.nodeseek.com/post-857694-2",
             .topic(topicID: TopicID(rawValue: 857_694), page: 2, postID: nil)),
            ("https://www.nodeseek.com/post-857694",
             .topic(topicID: TopicID(rawValue: 857_694), page: nil, postID: nil)),
            ("https://www.nodeseek.com/space/12345", .user(uid: 12_345)),
            ("https://www.nodeseek.com/categories/daily",
             .forum(NodeSeekEndpoint.forumID(key: "daily")))
        ]
        for (string, expected) in cases {
            let url = try XCTUnwrap(URL(string: string))
            XCTAssertEqual(site.internalDestination(for: url), expected, string)
        }
    }

    /// 楼层锚点给的是楼层号，要换算成页码才能跳。
    func testFloorAnchorBecomesAPageNumber() throws {
        let url = try XCTUnwrap(URL(string: "https://www.nodeseek.com/post-857694#25"))
        XCTAssertEqual(
            site.internalDestination(for: url),
            .topic(topicID: TopicID(rawValue: 857_694), page: 3, postID: nil)
        )
    }

    func testForeignHostsAreNotInternal() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/post-857694-2"))
        XCTAssertNil(site.internalDestination(for: url))
    }

    // MARK: - 反应

    /// 动作名和含义对不上，接错会花掉用户的鸡腿。这条把对应关系钉住。
    func testReactionCostsAreNotWhatTheNamesSuggest() {
        XCTAssertEqual(NodeSeekReaction.upvote.chickenCost, 0, "投喂是免费的")
        XCTAssertTrue(NodeSeekReaction.upvote.isFree)
        XCTAssertEqual(NodeSeekReaction.like.chickenCost, 1, "like 是加鸡腿，要花钱")
        XCTAssertEqual(NodeSeekReaction.dislike.chickenCost, 2, "dislike 是反对，花两个")
        XCTAssertFalse(NodeSeekReaction.like.isFree)
    }

    // MARK: - Cloudflare 判定

    func testChallengeIsRecognizedInAllThreeShapes() {
        XCTAssertTrue(NodeSeekNetworkClient.isChallenge(
            status: 403, headers: ["cf-mitigated": "challenge"], body: Data()))
        XCTAssertTrue(NodeSeekNetworkClient.isChallenge(
            status: 403, headers: [:], body: Data("<!DOCTYPE html><html>".utf8)))
        XCTAssertTrue(NodeSeekNetworkClient.isChallenge(
            status: 200, headers: [:], body: Data("<title>Just a moment…</title>".utf8)))
        XCTAssertFalse(NodeSeekNetworkClient.isChallenge(
            status: 200, headers: [:], body: Data(#"{"success":true}"#.utf8)))
    }

    /// 这几族接口未登录时答 500 而不是 401，得认出来才能提示「去登录」而不是「重试」。
    func testSessionScopedFamiliesAreRecognized() throws {
        for path in ["/api/notification/unread-count", "/api/statistics/collection",
                     "/api/admin/ruling/page-1", "/api/account/find/alice"] {
            let url = try XCTUnwrap(URL(string: "https://www.nodeseek.com" + path))
            XCTAssertTrue(NodeSeekNetworkClient.isSessionScoped(url), path)
        }
        // 这个未登录也答，不该被当成会话端点。
        let open = try XCTUnwrap(URL(string: "https://www.nodeseek.com/api/account/getInfo/1"))
        XCTAssertFalse(NodeSeekNetworkClient.isSessionScoped(open))
    }
}
