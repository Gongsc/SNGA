import Foundation
import XCTest
@testable import SNGA

final class ForumSearchTests: XCTestCase {
    private let parser = NGAParser()

    func testCurrentForumSearchAcceptsOnlyTopicKinds() {
        XCTAssertEqual(
            ForumSearchKind.allCases.map(\.title),
            [
                "主题标题",
                "主题标题和内容",
                "版面或版主",
                "用户",
                "用户发布的主题",
                "用户发布的内容"
            ]
        )
        XCTAssertEqual(
            ForumSearchKind.currentForumKinds,
            [.topicSubject, .topicContent]
        )
        XCTAssertNotNil(ForumSearchRequest(
            query: "  测试  ",
            kind: .topicSubject,
            forumID: ForumID(rawValue: 414)
        ))
        XCTAssertNil(ForumSearchRequest(
            query: "用户",
            kind: .user,
            forumID: ForumID(rawValue: 414)
        ))
        XCTAssertNil(ForumSearchRequest(query: " \n ", kind: .topicContent))
    }

    func testTopicSearchEndpointUsesExplicitScopeAndContentMode() throws {
        let globalRequest = try XCTUnwrap(
            ForumSearchRequest(query: "Swift", kind: .topicSubject)
        )
        let globalEndpoint = NGAEndpoint.searchTopics(
            request: globalRequest,
            page: 2
        )
        let globalItems = Dictionary(
            uniqueKeysWithValues: globalEndpoint.queryItems.map {
                ($0.name, $0.value ?? "")
            }
        )
        XCTAssertEqual(globalEndpoint.path, "/thread.php")
        XCTAssertEqual(globalItems["key"], "Swift")
        XCTAssertEqual(globalItems["content"], "0")
        XCTAssertEqual(globalItems["page"], "2")
        XCTAssertNil(globalItems["fid"])
        XCTAssertNil(globalItems["stid"])

        let subforumID = ForumID(stid: 35_925_536)
        let currentRequest = try XCTUnwrap(
            ForumSearchRequest(
                query: "客户端",
                kind: .topicContent,
                forumID: subforumID
            )
        )
        let currentEndpoint = NGAEndpoint.searchTopics(
            request: currentRequest,
            page: 1
        )
        let currentItems = Dictionary(
            uniqueKeysWithValues: currentEndpoint.queryItems.map {
                ($0.name, $0.value ?? "")
            }
        )
        XCTAssertEqual(currentItems["content"], "1")
        XCTAssertEqual(currentItems["stid"], "35925536")
        XCTAssertNil(currentItems["fid"])
    }

    func testParsesForumSearchTopicXMLAndPagination() throws {
        let request = try XCTUnwrap(
            ForumSearchRequest(query: "测试", kind: .topicContent)
        )
        let xml = """
        <root>
          <__ROWS>71</__ROWS>
          <__T__ROWS_PAGE>35</__T__ROWS_PAGE>
          <__T>
            <item>
              <tid>47240001</tid>
              <fid>414</fid>
              <subject>测试主题</subject>
              <author>Alice</author>
              <replies>12</replies>
              <postdate>1700000000</postdate>
            </item>
          </__T>
        </root>
        """
        let page = try parser.forumSearchTopics(
            from: response(xml, contentType: "text/xml; charset=utf-8"),
            request: request,
            page: 1
        )

        XCTAssertEqual(page.topics.first?.id, TopicID(rawValue: 47_240_001))
        XCTAssertEqual(page.topics.first?.forumID, ForumID(rawValue: 414))
        XCTAssertEqual(page.topics.first?.subject, "测试主题")
        XCTAssertEqual(page.topics.first?.replyCount, 12)
        XCTAssertEqual(page.totalPages, 3)
        XCTAssertTrue(page.hasMore)
    }

    func testParsesForumAndUserSearchResults() throws {
        let xml = """
        <root>
          <item>
            <fid>414</fid>
            <name>游戏综合讨论</name>
            <info>综合游戏版面</info>
          </item>
          <item>
            <fid>-1</fid>
            <stid>35925536</stid>
            <name>测试子版面</name>
          </item>
        </root>
        """
        let forums = try parser.forumSearchResults(
            from: response(xml, contentType: "text/xml; charset=utf-8")
        )
        XCTAssertEqual(forums.map(\.id), [
            ForumID(rawValue: 414),
            ForumID(stid: 35_925_536)
        ])

        let profile = try parser.searchedProfile(from: response("""
        {"data":[{"uid":42,"username":"搜索用户","posts":18}]}
        """))
        XCTAssertEqual(profile?.uid, 42)
        XCTAssertEqual(profile?.displayName, "搜索用户")

        let missing = try parser.searchedProfile(from: response("""
        {"error":["ERROR","找不到用户"]}
        """))
        XCTAssertNil(missing)
    }

    func testUserNameEndpointPreservesNumericUserName() {
        let endpoint = NGAEndpoint.profile(username: "123456")
        XCTAssertEqual(
            endpoint.queryItems.first(where: { $0.name == "username" })?.value,
            "123456"
        )
        XCTAssertNil(endpoint.queryItems.first(where: { $0.name == "uid" }))
    }

    private func response(
        _ text: String,
        contentType: String = "application/json; charset=utf-8"
    ) -> NGAHTTPResponse {
        NGAHTTPResponse(
            data: Data(text.utf8),
            statusCode: 200,
            headers: ["Content-Type": contentType],
            url: NGAEndpoint.baseURL
        )
    }
}
