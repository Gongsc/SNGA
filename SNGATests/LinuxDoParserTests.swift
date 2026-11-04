import Foundation
import SwiftSoup
import XCTest
@testable import SNGA

/// Linux.do 的解析，对着 2026-11-04 抓的真实响应跑。
///
/// 夹具里的用户名换成了 `userN`、用户编号换成了 8000xx，话题标题和用户头衔一类自由文本
/// 换成了「示例」—— 所以断言里看到这些值是正常的。楼层正文（`cooked`）是原样，
/// 里面的用户名同样换过。
final class LinuxDoParserTests: XCTestCase {
    private let parser = LinuxDoParser()

    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: name, withExtension: "json"),
            "缺夹具 \(name).json"
        )
        return try Data(contentsOf: url)
    }

    // MARK: - 类别

    func testCategoriesKeepSubcategoriesRightAfterTheirParent() throws {
        let categories = try parser.categories(json: fixture("linuxdo-categories"))

        XCTAssertEqual(categories.map(\.forum.id.key), ["4", "14", "94", "11"])
        XCTAssertEqual(categories.map(\.forum.name), ["开发调优", "资源荟萃", "网盘资源", "搞七捻三"])
        // 子类别的 slug 路径是「父/子」—— 列表地址照它拼，省一次 302。
        let cloud = try XCTUnwrap(categories.first { $0.forum.id.key == "94" })
        XCTAssertEqual(cloud.slugPath, "resource/cloud-asset")
        XCTAssertEqual(cloud.parentID, LinuxDoEndpoint.forumID(categoryID: 14))
        XCTAssertTrue(cloud.forum.isSubforum)
        let develop = try XCTUnwrap(categories.first)
        XCTAssertEqual(develop.slugPath, "develop")
        XCTAssertNil(develop.parentID)
        XCTAssertFalse(develop.forum.isSubforum)
        XCTAssertTrue(categories.allSatisfy { $0.forum.id.site == .linuxdo })
    }

    // MARK: - 话题列表

    func testTopicListTakesTheAuthorFromTheFirstPoster() throws {
        let forumID = LinuxDoEndpoint.forumID(categoryID: 4)
        let page = try parser.topicList(json: fixture("linuxdo-category-latest"), forumID: forumID, page: 1)

        XCTAssertEqual(page.topics.map(\.id.rawValue), [3_121_019, 3_121_017, 3_121_015, 3])
        let first = try XCTUnwrap(page.topics.first)
        // 楼主不在话题对象上，要拿 `posters` 的第一个编号去 `users` 里查。
        XCTAssertEqual(first.author, "user33")
        XCTAssertEqual(first.authorUID, 800_032)
        XCTAssertEqual(first.replyCount, 1, "posts_count 是 2，其中一楼是主楼")
        XCTAssertEqual(first.forumID, forumID)
        XCTAssertEqual(first.sourceForumID, LinuxDoEndpoint.forumID(categoryID: 4))
        XCTAssertNotNil(first.publishedAt)
        XCTAssertNotNil(first.lastReplyAt)

        // 那条置顶是系统用户（编号 -1）发的。负编号不是一个能打开资料的人，不填。
        let pinned = try XCTUnwrap(page.topics.last)
        XCTAssertTrue(pinned.isPinned)
        XCTAssertTrue(pinned.isLocked)
        XCTAssertNil(pinned.authorUID)

        // 站点只说还有没有下一页，不报总页数。
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.totalPages, 2)
    }

    /// 父类别的列表里混着子类别的话题，子类别要一律勾上，否则界面会把它们全筛掉。
    func testSubcategoriesAreAttachedAndSelectedByDefault() throws {
        let child = Forum(id: LinuxDoEndpoint.forumID(categoryID: 94), name: "网盘资源", isSubforum: true)
        let page = try parser.topicList(
            json: fixture("linuxdo-category-latest"),
            forumID: LinuxDoEndpoint.forumID(categoryID: 14),
            page: 1,
            subforums: [child]
        )
        XCTAssertEqual(page.subforums.map(\.id), [child.id])
        XCTAssertEqual(page.subforums.first?.isSelectedInParent, true)
    }

    // MARK: - 话题与楼层

    func testTopicDetailCarriesTheWholeStreamAndTheFirstChunk() throws {
        let detail = try parser.topicDetail(json: fixture("linuxdo-topic"))

        XCTAssertEqual(detail.topic.id.rawValue, 3_103_315)
        XCTAssertEqual(detail.topic.forumID, LinuxDoEndpoint.forumID(categoryID: 4))
        XCTAssertEqual(detail.topic.author, "user1")
        XCTAssertEqual(detail.topic.authorUID, 800_001)
        XCTAssertEqual(detail.topic.replyCount, 64)
        // 楼层编号流是全部 65 楼；内容只带回来一块（夹具里裁到了主楼）。
        XCTAssertEqual(detail.stream.count, 65)
        XCTAssertEqual(detail.stream.prefix(3), [24_259_580, 24_259_636, 24_259_711])

        let opening = try XCTUnwrap(detail.posts.first)
        XCTAssertEqual(opening.id.rawValue, 24_259_580)
        XCTAssertEqual(opening.floor, 0, "站点从 1 数楼层，应用的主楼是 0")
        XCTAssertEqual(opening.author, "user1")
        XCTAssertEqual(opening.authorUID, 800_001)
        XCTAssertEqual(
            opening.avatarURL?.absoluteString,
            "https://linux.do/user_avatar/linux.do/user1/96/1_2.png"
        )
        XCTAssertNotNil(opening.postedAt)
        // 赞是 `actions_summary` 里编号 2 那一项。
        XCTAssertEqual(opening.upvoteCount, 108)
    }

    func testPostsBatchIsOrderedByFloor() throws {
        let posts = try parser.posts(json: fixture("linuxdo-topic-posts"), topicID: TopicID(rawValue: 3_103_315))
        XCTAssertEqual(posts.map(\.floor), [20, 21])
        XCTAssertEqual(posts.map(\.author), ["user20", "user27"])
        XCTAssertTrue(posts.allSatisfy { $0.topicID.rawValue == 3_103_315 })
    }

    // MARK: - 正文清洗

    /// 主楼里引用、灯箱图、表情、折叠块、表格、代码块都有，正好把清洗过一遍。
    func testCookedBodyDropsTheSiteOwnChrome() throws {
        let detail = try parser.topicDetail(json: fixture("linuxdo-topic"))
        let html = try XCTUnwrap(detail.posts.first?.html)
        let body = try XCTUnwrap(SwiftSoup.parse(html).body())

        // 灯箱只剩那张图：外面那层、信息条、图标都没了。
        XCTAssertTrue(try body.select("div.lightbox-wrapper, .meta, svg").isEmpty())
        XCTAssertFalse(try body.select("img[src^=https://cdn3.ldstatic.com/]").isEmpty())
        XCTAssertTrue(try body.select("img[srcset]").isEmpty(), "srcset 里的相对地址解不出来")
        // 引用变成普通的引用块，抬头那行（被引的话题名）是粗体。
        XCTAssertTrue(try body.select("aside").isEmpty())
        let quote = try XCTUnwrap(body.select("blockquote").first())
        XCTAssertFalse(try quote.select("> p > strong").isEmpty())
        // 表情留着 `emoji` 类名 —— 原生分支靠它把表情当成文字里的小图，不是一张配图。
        XCTAssertFalse(try body.select("img.emoji").isEmpty())
        // 折叠块、删除线和分隔线是站点常用的，relaxed 白名单默认不放行。
        XCTAssertFalse(try body.select("details > summary").isEmpty())
        XCTAssertFalse(try body.select("s").isEmpty())
        XCTAssertFalse(try body.select("hr").isEmpty())
        // 标题前的锚点去掉。
        XCTAssertTrue(try body.select("a.anchor, a[name]").isEmpty())
        XCTAssertTrue(try body.select("script, iframe").isEmpty())
    }

    func testLightboxCollapsesToItsImage() throws {
        let cooked = """
        <p><div class="lightbox-wrapper"><a class="lightbox" href="https://cdn3.ldstatic.com/original/a.jpeg">\
        <img src="https://cdn3.ldstatic.com/optimized/a_2_468x500.jpeg" alt="a" width="468" height="500">\
        <div class="meta"><svg><use href="#far-image"></use></svg><span class="filename">a</span></div></a></div></p>
        """
        let body = try LinuxDoParser.sanitizedBody(cooked)
        let root = try XCTUnwrap(SwiftSoup.parseBodyFragment(body).body())
        XCTAssertEqual(try root.select("img").count, 1)
        XCTAssertEqual(try root.select("img").attr("src"), "https://cdn3.ldstatic.com/optimized/a_2_468x500.jpeg")
        XCTAssertTrue(try root.select("a, span, svg").isEmpty())
    }

    func testOneboxBecomesAPlainLink() throws {
        let cooked = """
        <aside class="onebox allowlistedgeneric" data-onebox-src="https://example.com/post">\
        <header class="source"><a href="https://example.com/post">example.com</a></header>\
        <article class="onebox-body"><h3><a href="https://example.com/post">一篇文章</a></h3><p>摘要</p></article></aside>
        """
        let body = try LinuxDoParser.sanitizedBody(cooked)
        let root = try XCTUnwrap(SwiftSoup.parseBodyFragment(body).body())
        let link = try XCTUnwrap(root.select("a").first())
        XCTAssertEqual(try link.attr("href"), "https://example.com/post")
        XCTAssertEqual(try link.text(), "一篇文章")
        XCTAssertTrue(try root.select("aside, article, header").isEmpty())
    }

    func testRelativeLinksAreResolvedAgainstTheSite() throws {
        let body = try LinuxDoParser.sanitizedBody(
            #"<p><a href="/t/topic/1">站内</a> <a href="javascript:alert(1)">坏</a></p>"#
        )
        let root = try XCTUnwrap(SwiftSoup.parseBodyFragment(body).body())
        let links = try root.select("a")
        XCTAssertEqual(try links.first()?.attr("href"), "https://linux.do/t/topic/1")
        XCTAssertFalse(try links.last()?.hasAttr("href") ?? true)
    }

    /// 只有文字和表情的楼层应当原生画，表情是行内的小图而不是一张配图。
    func testShortPostWithEmojiRendersNatively() throws {
        let body = try LinuxDoParser.sanitizedBody(
            #"<p>好用 <img src="https://cdn.ldstatic.com/images/emoji/twemoji/clap.png?v=16" title=":clap:" class="emoji" alt=":clap:" width="20" height="20"></p>"#
        )
        let root = try XCTUnwrap(SwiftSoup.parseBodyFragment(body).body())
        let content = try XCTUnwrap(PostContentBuilder.content(from: root), "表情不该把整楼打回 WebView")
        XCTAssertEqual(content.blocks.count, 1, "表情应当留在段落里，不自成一块")
    }

    // MARK: - 用户

    func testProfileComesFromTheUserCard() throws {
        let profile = try parser.profile(json: fixture("linuxdo-user-card"), uid: 800_030)
        XCTAssertEqual(profile.uid, 800_030)
        XCTAssertEqual(profile.displayName, "user31")
        XCTAssertEqual(profile.level, 4)
        XCTAssertEqual(profile.userGroup, "g-premium")
        XCTAssertEqual(profile.title, "示例")
        XCTAssertNotNil(profile.registeredAt)
        XCTAssertEqual(
            profile.avatarURL?.absoluteString,
            "https://linux.do/user_avatar/linux.do/user31/240/1_2.png"
        )
    }

    func testCurrentUserIsReadFromTheSessionEndpoint() throws {
        XCTAssertEqual(
            try parser.currentUserID(json: Data(#"{"current_user":{"id":800001,"username":"user1"}}"#.utf8)),
            800_001
        )
        // 会话不被认时没有 `current_user` —— 那是要重新登录，不是页面变了。
        XCTAssertThrowsError(try parser.currentUserID(json: Data("{}".utf8))) { error in
            XCTAssertEqual(error as? ForumServiceError, .requiresLogin)
        }
    }

    func testDatesWithMillisecondsParse() {
        XCTAssertNotNil(LinuxDoParser.date("2026-11-01T02:17:46.149Z"))
        XCTAssertNotNil(LinuxDoParser.date("2026-11-01T02:17:46Z"))
        XCTAssertNil(LinuxDoParser.date("昨天"))
    }
}
