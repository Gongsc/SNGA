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

    /// 登录后几乎每个类别底下都挂着一个「父名, Lv1」的等级分区（2026-11-04 实测 14 个）。
    /// 夹具是匿名抓的、没有它们，这里照登录后的形状写一份。
    func testLevelSubcategoriesDropTheRepeatedParentName() throws {
        let json = """
        {"category_list":{"categories":[
          {"id":4,"name":"开发调优","slug":"develop","subcategory_list":[
            {"id":20,"name":"开发调优, Lv1","slug":"develop-lv1","parent_category_id":4}]},
          {"id":14,"name":"资源荟萃","slug":"resource","subcategory_list":[
            {"id":83,"name":"资源荟萃, Lv1","slug":"resource-lv1","parent_category_id":14},
            {"id":94,"name":"网盘资源","slug":"cloud-asset","parent_category_id":14}]}
        ]}}
        """
        let categories = try parser.categories(json: Data(json.utf8))
        XCTAssertEqual(categories.map(\.forum.name), ["开发调优", "Lv1", "资源荟萃", "Lv1", "网盘资源"])
        // 地址照旧用站点的 slug，只是显示名短了。
        XCTAssertEqual(categories.first { $0.forum.id.key == "20" }?.slugPath, "develop/develop-lv1")

        XCTAssertEqual(LinuxDoParser.subcategoryName("开发调优，Lv1", parentName: "开发调优"), "Lv1")
        XCTAssertEqual(LinuxDoParser.subcategoryName("开发调优", parentName: "开发调优"), "开发调优")
        XCTAssertEqual(LinuxDoParser.subcategoryName("网盘资源", parentName: "资源荟萃"), "网盘资源")
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

    func testTopicListCarriesTagsAndThePinnedBadge() throws {
        let page = try parser.topicList(
            json: fixture("linuxdo-category-latest"),
            forumID: LinuxDoEndpoint.forumID(categoryID: 4),
            page: 1
        )
        let first = try XCTUnwrap(page.topics.first)
        XCTAssertEqual(first.tags.map(\.name), ["快问快答", "人工智能"])
        // 标签本身就是一个能打开的列表，编号在解析时就换成版面键。
        XCTAssertEqual(first.tags.last?.forumID, LinuxDoEndpoint.forumID(tagID: 444))
        XCTAssertTrue(first.badges.isEmpty, "普通话题不挂标记")

        let pinned = try XCTUnwrap(page.topics.last)
        XCTAssertEqual(pinned.badges.map(\.title), [LinuxDoParser.pinnedBadgeTitle])
        XCTAssertTrue(pinned.tags.isEmpty)
    }

    /// 老版本 Discourse 的标签是光秃秃的字符串。认不出来会把整页列表拖垮。
    func testTopicListAcceptsPlainStringTags() throws {
        let json = Data("""
        {"topic_list": {"topics": [
          {"id": 1, "title": "t", "posts_count": 1, "tags": ["linux", "linux", " "]}
        ]}}
        """.utf8)
        let page = try parser.topicList(json: json, forumID: LinuxDoEndpoint.forumID(categoryID: 4), page: 1)
        let topic = try XCTUnwrap(page.topics.first)
        XCTAssertEqual(topic.tags, [TopicTag(name: "linux")], "重复的和空白的不算")
    }

    func testListBadgesFollowTheSiteStatuses() {
        func titles(
            pinned: Bool? = nil,
            pinnedGlobally: Bool? = nil,
            archived: Bool? = nil,
            visible: Bool? = nil,
            solved: Bool? = nil
        ) -> [String] {
            LinuxDoParser.listBadges(
                pinned: pinned,
                pinnedGlobally: pinnedGlobally,
                archived: archived,
                visible: visible,
                hasAcceptedAnswer: solved
            ).map(\.title)
        }
        XCTAssertEqual(titles(pinned: true, pinnedGlobally: true), [LinuxDoParser.pinnedGloballyBadgeTitle])
        // 用户在网页上取消过置顶：`pinned_globally` 还是 true，`pinned` 变成 false。照用户的意思不再标。
        XCTAssertEqual(titles(pinned: false, pinnedGlobally: true), [])
        XCTAssertEqual(titles(archived: true, visible: false, solved: true), ["已解决", "已归档", "未公开"])
        // 接口没给 `visible` 不等于不公开。
        XCTAssertEqual(titles(visible: nil), [])
    }

    /// 话题页标题栏要画全部标签，它们来自话题详情，不是列表里那一份。
    func testTopicDetailCarriesTags() throws {
        let detail = try parser.topicDetail(json: fixture("linuxdo-topic"))
        XCTAssertEqual(detail.topic.tags.map(\.name), ["纯水", "人工智能"])
        XCTAssertEqual(detail.topic.tags.first?.forumID, LinuxDoEndpoint.forumID(tagID: 1461))
    }

    func testSearchResultsCarryTags() throws {
        let request = try XCTUnwrap(ForumSearchRequest(query: "linux", kind: .topicContent))
        let page = try parser.search(json: fixture("linuxdo-search"), request: request, page: 1)
        XCTAssertEqual(page.topics.first?.tags.map(\.name), ["人工智能"])
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
        // 夹具里那张盲测图：`src` 是一倍图，要换成 `srcset` 里的二倍图，否则 Retina 屏上比网页糊。
        XCTAssertFalse(
            try body.select("img[src$=_2_936x1000.jpeg][width=468][height=500]").isEmpty(),
            "配图该取二倍图、留着一倍的显示尺寸"
        )
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

    /// 网页在 2x 屏上按 `srcset` 换二倍图；原生分支和 WebView 都拿不到 `srcset`，就在清洗时替它选好。
    func testImageTakesTheHighestDensitySourceAndKeepsItsDisplaySize() throws {
        let cooked = """
        <p><img src="/uploads/a_2_468x500.jpeg" width="468" height="500" \
        srcset="/uploads/a_2_468x500.jpeg, /uploads/a_2_702x750.jpeg 1.5x, /uploads/a_2_936x1000.jpeg 2x"></p>
        """
        let root = try XCTUnwrap(SwiftSoup.parseBodyFragment(try LinuxDoParser.sanitizedBody(cooked)).body())
        let image = try XCTUnwrap(root.select("img").first())
        XCTAssertEqual(try image.attr("src"), "https://linux.do/uploads/a_2_936x1000.jpeg", "相对地址也要解开")
        XCTAssertEqual(try image.attr("width"), "468")
        XCTAssertEqual(try image.attr("height"), "500")
        XCTAssertFalse(image.hasAttr("srcset"))
    }

    func testDensityPickIgnoresWidthDescriptorsAndOrder() {
        XCTAssertEqual(LinuxDoParser.highestDensityCandidate(in: "b 2x, a"), "b")
        XCTAssertEqual(LinuxDoParser.highestDensityCandidate(in: "a"), "a")
        XCTAssertNil(LinuxDoParser.highestDensityCandidate(in: ""))
        XCTAssertNil(LinuxDoParser.highestDensityCandidate(in: "a 468w, b 936w"), "宽度描述符要配 sizes，不猜")
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

    /// 登录后看别人的卡片，同一个人在 `users` 里出现两次，精简版排在前面（实测）。
    /// 只认第一条的话，加入时间、头衔、群组全是空的。
    func testDuplicateCardEntriesAreMergedNotTruncated() throws {
        let json = """
        {"users":[
          {"id":153036,"username":"user9","name":"","avatar_template":"/user_avatar/linux.do/user9/{size}/1_2.png",
           "trust_level":3,"animated_avatar":null},
          {"id":153036,"username":"user9","name":"","avatar_template":"/user_avatar/linux.do/user9/{size}/1_2.png",
           "trust_level":3,"created_at":"2026-07-27T12:46:45.235Z","title":"示例","primary_group_name":"g-premium",
           "last_seen_at":"2026-11-04T08:40:00.000Z","badge_count":5}
        ]}
        """
        let profile = try parser.profile(json: Data(json.utf8), uid: 153_036)
        XCTAssertNotNil(profile.registeredAt, "加入时间在第二条里")
        XCTAssertEqual(profile.title, "示例")
        XCTAssertEqual(profile.userGroup, "g-premium")
        XCTAssertEqual(profile.level, 3)
    }

    /// `/u/{用户名}.json` 的形状（2026-11-04 在浏览器里核过字段名和类型，值是编的）。
    /// 资料在 `user` 里；同级还有一份 `users` 精简列表，不该被它带偏。
    static let fullProfileJSON = """
    {"users":[{"id":800030,"username":"user31","name":"","avatar_template":"/user_avatar/linux.do/user31/{size}/1_2.png","trust_level":4}],
     "user":{"id":800030,"username":"user31","name":"用户31","avatar_template":"/user_avatar/linux.do/user31/{size}/1_2.png",
       "created_at":"2024-01-17T08:26:33.362Z","last_seen_at":"2026-11-04T08:40:00.000Z","last_posted_at":"2026-11-04T08:00:00.000Z",
       "trust_level":4,"title":"示例","primary_group_name":"g-premium","location":"示例","bio_excerpt":"<p>示例</p>",
       "total_followers":12704,"total_following":3,"profile_view_count":392093,"gamification_score":800844,"time_read":11606857,
       "invited_by":null}}
    """

    func testFullProfileCarriesTheProfilePageStats() throws {
        let profile = try parser.fullProfile(json: Data(Self.fullProfileJSON.utf8))
        XCTAssertEqual(profile.uid, 800_030)
        XCTAssertEqual(profile.displayName, "user31")
        XCTAssertNotNil(profile.registeredAt)
        XCTAssertNotNil(profile.lastSeenAt)
        XCTAssertNotNil(profile.lastPostedAt)
        XCTAssertEqual(profile.profileViewCount, 392_093)
        XCTAssertEqual(profile.points, 800_844)
        XCTAssertEqual(profile.followerCount, 12_704)
        XCTAssertEqual(profile.followingCount, 3)
        XCTAssertEqual(profile.readingSeconds, 11_606_857)
        XCTAssertEqual(profile.level, 4)
        XCTAssertEqual(profile.location, "示例")
        XCTAssertEqual(profile.signature, "示例", "简介摘录是 HTML，资料页那一栏要纯文本")
    }

    /// 资料页「基础信息」按站点自己那一排的叫法来。
    func testProfileFieldsUseTheSiteOwnWording() throws {
        let profile = try parser.fullProfile(json: Data(Self.fullProfileJSON.utf8))
        let fields = ForumSiteDescriptor.linuxdo.profileFields(for: profile)
        let titles = fields.map(\.title)
        XCTAssertEqual(Array(titles.prefix(7)), ["加入日期", "最后一个帖子", "最后活动", "浏览量", "信任级别", "关注者", "正在关注"])
        XCTAssertEqual(fields.first { $0.title == "信任级别" }?.value, "领导者")
        XCTAssertEqual(fields.first { $0.title == "点数" }?.value, "800844")
        XCTAssertEqual(fields.first { $0.title == "阅读时间" }?.value, "134 天")
        XCTAssertNotEqual(fields.first { $0.title == "加入日期" }?.value, "—")
    }

    // MARK: - 用户动态与搜索

    func testUserTopicsAndRepliesParse() throws {
        let topics = try parser.userActivities(json: fixture("linuxdo-user-topics"), kind: .topics, page: 1)
        XCTAssertEqual(topics.activities.map(\.topicID.rawValue), [3_026_408, 2_501_838, 2_301_554, 2_296_954])
        XCTAssertEqual(topics.activities.first?.forumID, LinuxDoEndpoint.forumID(categoryID: 11))
        XCTAssertTrue(topics.activities.allSatisfy { $0.kind == .topics && $0.postedAt != nil })
        // 夹具裁到了 4 条；不满 30 条就是没有下一页。
        XCTAssertFalse(topics.hasMore)

        let replies = try parser.userActivities(json: fixture("linuxdo-user-replies"), kind: .replies, page: 2)
        let first = try XCTUnwrap(replies.activities.first)
        XCTAssertEqual(first.topicID.rawValue, 3_044_791)
        XCTAssertEqual(first.postID?.rawValue, 23_803_444, "回复要带楼层编号，才跳得到那一楼")
        XCTAssertEqual(first.forumID, LinuxDoEndpoint.forumID(categoryID: 36))
        XCTAssertNotNil(first.excerpt)
        XCTAssertEqual(replies.page, 2)
        // 同一个话题里的两条回复，编号不能撞。
        XCTAssertEqual(Set(replies.activities.map(\.id)).count, replies.activities.count)
    }

    func testSearchListsTopicsInHitOrder() throws {
        let request = try XCTUnwrap(ForumSearchRequest(query: "linux", kind: .topicContent))
        let page = try parser.search(json: fixture("linuxdo-search"), request: request, page: 1)
        XCTAssertEqual(page.topics.map(\.id.rawValue), [3_117_915, 3_115_449, 3_106_528, 3_105_357])
        // 命中的都是主楼，作者就是楼主。
        XCTAssertEqual(page.topics.first?.author, "user5")
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.totalPages, 2)
    }

    /// 同一个话题命中好几楼时只列一次；命中的不是主楼时不冒充楼主。
    func testSearchDeduplicatesTopicsAndKeepsAuthorHonest() throws {
        let json = """
        {"posts":[{"id":1,"topic_id":10,"post_number":7,"username":"user2"},
                  {"id":2,"topic_id":10,"post_number":1,"username":"user1"},
                  {"id":3,"topic_id":11,"post_number":1,"username":"user3"}],
         "topics":[{"id":10,"title":"示例","posts_count":9,"category_id":4},
                   {"id":11,"title":"示例","posts_count":1,"category_id":4}],
         "grouped_search_result":{"more_full_page_results":null}}
        """
        let request = try XCTUnwrap(ForumSearchRequest(query: "x", kind: .topicContent))
        let page = try parser.search(json: Data(json.utf8), request: request, page: 1)
        XCTAssertEqual(page.topics.map(\.id.rawValue), [10, 11])
        XCTAssertEqual(page.topics.first?.author, "", "第一次命中的是第 7 楼，那一楼的作者不是楼主")
        XCTAssertEqual(page.topics.first?.replyCount, 8)
        XCTAssertFalse(page.hasMore)
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
        // 应用里显示成「—」的两个真实用户的加入时间。
        XCTAssertNotNil(LinuxDoParser.date("2026-07-27T12:46:45.235Z"))
        XCTAssertNotNil(LinuxDoParser.date("2026-09-29T08:41:27.606Z"))
    }
}
