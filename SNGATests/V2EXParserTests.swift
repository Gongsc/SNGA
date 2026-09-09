import Foundation
import XCTest
@testable import SNGA

/// 解析器对着真实响应的夹具跑。
///
/// 夹具是 2026-09-08 从公开页面上抓的（匿名，没有任何凭据参与），各留了一段有代表性
/// 的标记，文件头的注释里写着取自哪个地址、留了什么。先有夹具再有解析器。
final class V2EXParserTests: XCTestCase {

    private let parser = V2EXParser()
    private let qna = V2EXEndpoint.forumID(key: "qna")
    private let recent = V2EXEndpoint.forumID(key: V2EXEndpoint.recentKey)

    private func fixture(_ name: String, extension ext: String = "html") throws -> String {
        let url = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: name, withExtension: ext),
            "测试包里没有夹具 \(name).\(ext)"
        )
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func fixtureData(_ name: String) throws -> Data {
        Data(try fixture(name, extension: "json").utf8)
    }

    // MARK: - 节点列表

    func testParsesEveryTopicOnANodePage() throws {
        let page = try parser.topicList(
            html: try fixture("v2ex-node-topics"), forumID: qna, page: 2
        )

        XCTAssertEqual(page.topics.count, 3)
        XCTAssertEqual(page.page, 2)
        // 分页条上的页码会省略成「1 2 3 … 12072」，总页数只能从跳页框的 max 读。
        XCTAssertEqual(page.totalPages, 12_072)
        XCTAssertTrue(page.hasMore)
    }

    func testReadsAuthorReplyCountAndTimeOnANodePage() throws {
        let page = try parser.topicList(
            html: try fixture("v2ex-node-topics"), forumID: qna, page: 2
        )
        let first = try XCTUnwrap(page.topics.first)

        XCTAssertFalse(first.subject.isEmpty)
        XCTAssertFalse(first.author.isEmpty)
        XCTAssertNotNil(first.authorUID, "节点页画头像，编号在 data-uid 里")
        // 列表上那个时间是最后回复，不是发帖 —— 同一个帖子主题页抬头写的是另一个时刻。
        XCTAssertNotNil(first.lastReplyAt)
        XCTAssertNil(first.publishedAt)
        // 节点页每条都属于当前节点，模板不重复画节点链接。
        XCTAssertEqual(first.forumID, qna)
    }

    func testNodePageCarriesItsHeader() throws {
        let page = try parser.topicList(
            html: try fixture("v2ex-node-topics"), forumID: qna, page: 2
        )
        let forum = try XCTUnwrap(page.forum)

        // 面包屑是「V2EX › 问与答」，节点名是后面那段裸文字。
        XCTAssertEqual(forum.name, "问与答")
        XCTAssertEqual(forum.id, qna)
        XCTAssertEqual(forum.category, "节点")
        // 英文名并进搜索词，目录里搜 qna 才找得到问与答。
        XCTAssertTrue(forum.searchAliases.contains("qna"))
    }

    /// 混合列表（最近主题、首页、某人的主题）每条都带节点链接，各归各的节点。
    func testMixedListingKeepsEachTopicsOwnNode() throws {
        let page = try parser.topicList(
            html: try fixture("v2ex-recent-topics"), forumID: recent, page: 1
        )

        XCTAssertEqual(page.topics.count, 3)
        XCTAssertEqual(page.totalPages, 41_345)
        for topic in page.topics {
            XCTAssertNotEqual(topic.forumID, recent, "混合列表里每条都该指出自己的节点")
            XCTAssertNotNil(topic.sourceForumName)
        }
        // 不是节点页，没有节点抬头。
        XCTAssertNil(page.forum)
    }

    /// 「某人发过的主题」那种页面整列头像都不画，作者编号读不出来 —— 不能因此丢掉主题。
    func testMemberTopicsParseWithoutAvatars() throws {
        let page = try parser.userTopics(html: try fixture("v2ex-member-topics"), page: 1)

        XCTAssertEqual(page.kind, .topics)
        XCTAssertEqual(page.activities.count, 2)
        XCTAssertEqual(page.totalPages, 394)
        XCTAssertTrue(page.hasMore)
        for activity in page.activities {
            XCTAssertFalse(activity.subject.isEmpty)
            XCTAssertNotNil(activity.forumName)
        }
    }

    // MARK: - 首页分类

    /// 首页分类是聚合版面：一格同时列出若干节点的主题，站点还把那几个节点画成第二行。
    func testHomepageTabListsItsMemberNodes() throws {
        let page = try parser.topicList(
            html: try fixture("v2ex-home-tab"),
            forumID: V2EXEndpoint.tabForumID(key: "tech"),
            page: 1
        )

        XCTAssertEqual(page.subforums.map(\.id.key), [
            "programmer", "python", "idev", "claude", "openai", "localllm", "cloud", "bb"
        ])
        XCTAssertEqual(page.subforums.first?.name, "程序员")
        XCTAssertTrue(page.subforums.allSatisfy(\.isSubforum))
        // **一律是勾上的。** 站点在服务端就把这几个节点的主题聚合进来了，
        // 留空的话界面会把它们统统筛掉，一格分类只剩下几条零星主题。
        XCTAssertTrue(page.subforums.allSatisfy { $0.isSelectedInParent == true })
        XCTAssertFalse(page.topics.isEmpty)
    }

    /// 这种页面没有分页条 —— 站点就是不给翻页。缺分页条不是解析失败。
    func testHomepageTabHasNoPaging() throws {
        let page = try parser.topicList(
            html: try fixture("v2ex-home-tab"),
            forumID: V2EXEndpoint.tabForumID(key: "tech"),
            page: 1
        )

        XCTAssertEqual(page.totalPages, 1)
        XCTAssertFalse(page.hasMore)
    }

    /// 每条主题要记住它实际来自哪个节点 —— 界面按这个值把分类里的主题筛开
    /// （见 `ForumStore.displayedTopics`）。记不住，第二行那几个开关就一个都不管用。
    func testMixedListingsRecordEachTopicsOwnNode() throws {
        let tab = try parser.topicList(
            html: try fixture("v2ex-home-tab"),
            forumID: V2EXEndpoint.tabForumID(key: "tech"),
            page: 1
        )
        XCTAssertTrue(tab.topics.allSatisfy { $0.sourceForumID != nil })
        // 筛选要对得上：主题的来源节点得真的在第二行那几个里。
        let members = Set(tab.subforums.map(\.id))
        XCTAssertTrue(tab.topics.contains { members.contains($0.sourceForumID!) })

        let recent = try parser.topicList(
            html: try fixture("v2ex-recent-topics"), forumID: recent, page: 1
        )
        XCTAssertTrue(recent.topics.allSatisfy { $0.sourceForumID != nil })
    }

    /// 节点页里每条都属于当前节点，填「来自别处」是在说一件不存在的事。
    func testNodePagesDoNotClaimTopicsComeFromElsewhere() throws {
        let page = try parser.topicList(
            html: try fixture("v2ex-node-topics"), forumID: qna, page: 2
        )

        XCTAssertTrue(page.topics.allSatisfy { $0.sourceForumID == nil })
        XCTAssertTrue(page.subforums.isEmpty, "节点底下没有节点，站点的节点是平的")
    }

    // MARK: - 主题页

    func testFirstPageCarriesTheOpeningPost() throws {
        let page = try parser.threadPage(
            html: try fixture("v2ex-topic"),
            topicID: TopicID(rawValue: 1_240_288),
            page: 1
        )

        XCTAssertEqual(page.posts.map(\.floor), [0, 1, 23, 25])
        XCTAssertEqual(page.topic.subject, "有啥方式可以防止丢伞，每次买来不出一个月就要丢几把")
        XCTAssertEqual(page.topic.author, "yunshangzhou")
        XCTAssertEqual(page.topic.authorUID, 600_305)
        XCTAssertEqual(page.topic.forumID, qna)
        XCTAssertEqual(page.topic.sourceForumName, "问与答")
        // 从「25 条回复」那一行读，不数这一页的楼层。
        XCTAssertEqual(page.topic.replyCount, 25)
        XCTAssertEqual(page.totalPages, 1)
        XCTAssertFalse(page.hasMore)

        let opening = try XCTUnwrap(page.posts.first)
        XCTAssertTrue(opening.html.contains("只要出门"), opening.html)
        XCTAssertNotNil(opening.nativeContent, "一段纯文字的主楼应当还原得了")
        XCTAssertNotNil(opening.postedAt)
    }

    /// 主楼没有自己的回复编号 —— 感谢主楼走的是另一个地址，适配器靠这个编号分辨。
    func testOpeningPostBorrowsTheTopicID() throws {
        let page = try parser.threadPage(
            html: try fixture("v2ex-topic"),
            topicID: TopicID(rawValue: 1_240_288),
            page: 1
        )

        XCTAssertEqual(page.posts.first?.id.rawValue, 1_240_288)
        XCTAssertEqual(page.posts[1].id.rawValue, 18_060_707, "回复用它自己的编号")
    }

    func testReadsReplyAuthorTimeAndDevice() throws {
        let page = try parser.threadPage(
            html: try fixture("v2ex-topic"),
            topicID: TopicID(rawValue: 1_240_288),
            page: 1
        )
        let first = try XCTUnwrap(page.posts.dropFirst().first)

        XCTAssertEqual(first.author, "oppoic")
        XCTAssertEqual(first.authorUID, 176_424)
        XCTAssertNotNil(first.postedAt)
        XCTAssertNil(first.device, "网页发的楼层站点什么都不写，别替它填「桌面」")

        let viaPhone = try XCTUnwrap(page.posts.first { $0.floor == 23 })
        XCTAssertEqual(viaPhone.device, .apple, "时间后面跟着 via iPhone")
    }

    /// 站点每一页都重画一遍抬头和主楼。跟着照搬的话，翻到第二页会看到主楼
    /// 又出现在第 101 层前面。
    func testLaterPagesDoNotRepeatTheOpeningPost() throws {
        let page = try parser.threadPage(
            html: try fixture("v2ex-topic-paged"),
            topicID: TopicID(rawValue: 1_240_249),
            page: 2
        )

        XCTAssertEqual(page.posts.map(\.floor), [101, 107, 112])
        XCTAssertFalse(page.posts.contains { $0.floor == 0 })
        XCTAssertEqual(page.totalPages, 3)
        XCTAssertTrue(page.hasMore)
        // 抬头照样解析 —— 标题、作者、节点都在第二页上。
        XCTAssertFalse(page.topic.subject.isEmpty)
        XCTAssertEqual(page.topic.replyCount, 217)
    }

    /// 附言是主楼的一部分。漏掉就等于把楼主后来的更正吞了。
    func testSupplementsAreAppendedToTheOpeningPost() throws {
        let page = try parser.threadPage(
            html: try fixture("v2ex-topic-paged"),
            topicID: TopicID(rawValue: 1_240_249),
            page: 1
        )
        let opening = try XCTUnwrap(page.posts.first { $0.floor == 0 })

        XCTAssertTrue(opening.html.contains("第 1 条附言"), "附言的抬头要留着")
        XCTAssertTrue(opening.html.contains("没想到热度这么高"), opening.html)
    }

    /// 内嵌播放器不能整个丢掉。
    ///
    /// 站点把视频渲染成 `<iframe src="…/embed/…">`，而 iframe 是清洗时一定要去掉的
    /// 东西 —— 正文是别人写的。去掉的时候要把地址留下来换成一条链接，
    /// 否则那一层楼里的视频连地址都不剩，读者只看到半句话。
    func testAnEmbeddedPlayerBecomesALink() throws {
        let page = try parser.threadPage(
            html: try fixture("v2ex-post-video"),
            topicID: TopicID(rawValue: 1_240_256),
            page: 1
        )
        let post = try XCTUnwrap(page.posts.first { $0.floor == 57 })

        XCTAssertFalse(post.html.contains("<iframe"), "iframe 一定要清掉")
        XCTAssertTrue(
            post.html.contains("https://www.youtube.com/embed/BpqYEWbkFYw"),
            "地址得留下来：\(post.html)"
        )
        // 前面那半句话不能被连累。
        XCTAssertTrue(post.html.contains("舍弃掉房子"))
        // 还原得了就该原生画出来，那条链接点得动。
        let content = try XCTUnwrap(post.nativeContent)
        XCTAssertTrue(
            String(describing: content).contains("youtube.com/embed/BpqYEWbkFYw"),
            "原生正文里也要有那条链接"
        )
    }

    /// 解不出地址的播放器留着也没用，但不能因此把整段正文弄丢。
    func testAPlayerWithoutAUsableSourceJustDisappears() throws {
        let reply = "<div class=\"reply_content\">看这个 <iframe src=\"about:blank\"></iframe></div>"
        let html = "<html><body><div id=\"Main\"><div class=\"box\"><div class=\"header\">"
            + "<a href=\"/\">V2EX</a> <a href=\"/go/qna\">问与答</a><h1>标题</h1>"
            + "<small class=\"gray\"><a href=\"/member/x\">x</a>"
            + "<span title=\"2026-09-08 10:00:00 +08:00\">刚刚</span></small></div>"
            + "<div class=\"cell\"><div class=\"topic_content\">正文</div></div></div>"
            + "<div class=\"box\"><div id=\"r_1\" class=\"cell\"><span class=\"no\">1</span>"
            + reply + "</div></div></div></body></html>"

        let page = try parser.threadPage(html: html, topicID: TopicID(rawValue: 1), page: 1)
        let post = try XCTUnwrap(page.posts.first { $0.floor == 1 })

        XCTAssertTrue(post.html.contains("看这个"))
        XCTAssertFalse(post.html.contains("iframe"))
        XCTAssertFalse(post.html.contains("about:blank"))
    }

    /// 感谢是一种**要花钱且撤不回来**的表态，不是赞踩。界面据此先问一次再发。
    func testEveryPostOffersTheThankReaction() throws {
        let page = try parser.threadPage(
            html: try fixture("v2ex-topic-paged"),
            topicID: TopicID(rawValue: 1_240_249),
            page: 2
        )

        for post in page.posts {
            let reaction = try XCTUnwrap(post.reactions.first)
            XCTAssertEqual(reaction.id, "thank")
            XCTAssertEqual(reaction.title, "感谢")
            XCTAssertEqual(reaction.cost, "花费 10 个铜币")
            XCTAssertTrue(reaction.isIrreversible)
        }
        // 站点把感谢数画成一个心形图标加一个数字，那个 span 除了 `small fade`
        // 没有别的标记 —— 所以认里面那张图，不认类名。
        let thanked = try XCTUnwrap(page.posts.first { $0.floor == 107 })
        XCTAssertEqual(thanked.reactions.first?.count, 1)
        // 没人感谢过的楼层站点根本不画那个 span，那是「不知道」不是 0。
        let plain = try XCTUnwrap(page.posts.first { $0.floor == 101 })
        XCTAssertNil(plain.reactions.first?.count)
    }

    /// 匿名抓回来的页面上没有感谢按钮，所以「我感谢过了」一律是假。
    func testAnonymousPagesNeverClaimYouAlreadyThanked() throws {
        let page = try parser.threadPage(
            html: try fixture("v2ex-topic"),
            topicID: TopicID(rawValue: 1_240_288),
            page: 1
        )

        XCTAssertFalse(page.posts.contains { $0.reactions.contains { $0.isChosen } })
    }

    // MARK: - 一次性令牌与身份

    func testReadsTheOnceTokenFromThePage() throws {
        XCTAssertEqual(V2EXParser.once(inHTML: try fixture("v2ex-topic")), "35953")
        XCTAssertNil(V2EXParser.once(inHTML: "<html><body>没有令牌</body></html>"))
    }

    /// 匿名页上没有身份。读出一个来才是错的。
    func testAnonymousPageHasNoSignedInUser() throws {
        XCTAssertNil(V2EXParser.signedInUserID(inHTML: try fixture("v2ex-topic")))
    }

    func testSignedInUserIDReadsTheGlobalTheSiteWrites() {
        let html = "<html><body><script>var memberId = 600305;</script></body></html>"
        XCTAssertEqual(V2EXParser.signedInUserID(inHTML: html), 600_305)
    }

    /// 用 gravatar 当头像的会员，地址里是一串哈希、没有编号 —— 那时只剩 data-uid。
    func testSignedInUserIDFallsBackToDataUID() {
        let html = """
        <html><body><div id="menu-entry">
        <img class="avatar" src="https://cdn.v2ex.com/gravatar/abc?s=48" data-uid="12345" />
        </div></body></html>
        """
        XCTAssertEqual(V2EXParser.signedInUserID(inHTML: html), 12_345)
    }

    func testSignedInUserIDReadsTheAvatarPath() {
        let html = """
        <html><body><div id="Top">
        <img class="avatar" src="https://cdn.v2ex.com/avatar/205f/180e/600305_normal.png?m=1" />
        </div></body></html>
        """
        XCTAssertEqual(V2EXParser.signedInUserID(inHTML: html), 600_305)
    }

    // MARK: - 节点目录

    func testPlanesGroupNodesTheWayTheSiteDoes() throws {
        let forums = try parser.planes(html: try fixture("v2ex-planes"))

        XCTAssertEqual(forums.count, 8)
        XCTAssertEqual(Set(forums.map(\.category)), ["混沌海", "机械境"])
        XCTAssertEqual(forums.first?.id.key, "earth")
        XCTAssertEqual(forums.first?.name, "地球")
        XCTAssertTrue(forums.contains { $0.id.key == "qna" && $0.name == "问与答" })
    }

    func testNodeTableFeedsNodeSearch() throws {
        let forums = try parser.nodes(json: try fixtureData("v2ex-nodes")).all

        XCTAssertEqual(forums.prefix(4).map(\.id.key), ["qna", "swift", "babel", "iphone"])
        XCTAssertEqual(forums.first?.name, "问与答")
        XCTAssertTrue(forums.first?.subtitle?.hasPrefix("主题总数") == true)
        XCTAssertTrue(forums.first?.searchAliases.contains("qna") == true)
    }

    /// 搜索结果里的节点是数字编号，所以同一份表还要按编号索引一份。
    func testNodeTableIsAlsoIndexedByID() throws {
        let byID = try parser.nodes(json: try fixtureData("v2ex-nodes")).byID

        XCTAssertEqual(byID[12]?.id.key, "qna")
        XCTAssertEqual(byID[72]?.name, "VPN")
        XCTAssertNil(byID[999_999])
    }

    // MARK: - 主题搜索（SoV2EX）

    /// 结果里的节点是**数字编号**，时间**没有时区后缀但值是 UTC**。
    /// 前者要靠节点表翻成名字，后者按本地时间读会整整差八个小时。
    func testSoV2EXResultsAreTranslatedIntoTopics() throws {
        let nodes = try parser.nodes(json: try fixtureData("v2ex-nodes")).byID
        let request = try XCTUnwrap(ForumSearchRequest(query: "dmit", kind: .topicContent))

        let page = try parser.searchResults(
            json: try fixtureData("v2ex-sov2ex-search"),
            request: request,
            page: 1,
            pageSize: 20,
            nodesByID: nodes
        )

        XCTAssertEqual(page.topics.map(\.id.rawValue), [1_203_314, 834_457, 1_077_726])
        XCTAssertEqual(page.topics.first?.subject, "dmit 和 justmysocks 二选一")
        XCTAssertEqual(page.topics.first?.author, "idblife")
        XCTAssertEqual(page.topics.first?.replyCount, 35)
        // 72 是 vpn 节点。翻不出名字的话，结果列表上说不出它属于哪儿。
        XCTAssertEqual(page.topics.first?.sourceForumName, "VPN")
        XCTAssertEqual(page.topics.first?.forumID.key, "vpn")
        // 2026-04-03T05:17:59 是 UTC，对应 epoch 1775193479。
        XCTAssertEqual(
            page.topics.first?.publishedAt,
            Date(timeIntervalSince1970: 1_775_193_479)
        )
    }

    /// 总页数从 `total` 算，不是数这一页有几条 —— 数出来永远只有一页。
    func testSoV2EXPageCountComesFromTheTotal() throws {
        let request = try XCTUnwrap(ForumSearchRequest(query: "dmit", kind: .topicContent))

        let page = try parser.searchResults(
            json: try fixtureData("v2ex-sov2ex-search"),
            request: request,
            page: 1,
            pageSize: 20,
            nodesByID: [:]
        )

        XCTAssertEqual(page.totalPages, 21, "410 条、每页 20")
        XCTAssertTrue(page.hasMore)
        // 节点表是空的时候也不能把结果丢掉 —— 主题是按编号打开的，节点名只是显示。
        XCTAssertEqual(page.topics.count, 3)
        XCTAssertNil(page.topics.first?.sourceForumName)
    }



    // MARK: - 节点收藏

    /// **下面这两段 HTML 是按站点样式表推断的形状，不是抓来的夹具** ——
    /// `/my/nodes` 要登录，匿名 302 到登录页。所以它们写在用例里，而不是放进
    /// `Fixtures/`：那个目录里的每一份都取自真实响应，混进一份想象出来的，
    /// 下一个人就分不清哪些验过哪些没验过。
    ///
    /// 依据是 `combo.css` 里只为这一页存在的两个类名：`.fav-node`
    /// （`display:block; text-decoration:none; cursor:pointer`，是个 `<a>`）
    /// 和它的子元素 `.fav-node-name`。
    func testFavoriteNodesReadTheSitesOwnClassNames() throws {
        let html = """
        <html><body><div id="Main"><div class="box">
        <a href="/go/qna" class="fav-node"><img src="/x.png" />
          <div class="fav-node-name">问与答</div></a>
        <a href="/go/programmer" class="fav-node"><img src="/y.png" />
          <div class="fav-node-name">程序员</div></a>
        </div></div></body></html>
        """

        let forums = try parser.favoriteNodes(html: html)

        XCTAssertEqual(forums.map(\.id.key), ["qna", "programmer"])
        XCTAssertEqual(forums.first?.name, "问与答")
        XCTAssertTrue(forums.first?.searchAliases.contains("qna") == true)
    }

    /// 认不出那两个类名时退回「`#Main` 里指向 `/go/` 的链接」。
    /// 站点改版把类名换掉时，收藏栏至少还是满的，而不是空的。
    func testFavoriteNodesFallBackToPlainNodeLinks() throws {
        let html = """
        <html><body><div id="Main">
        <a href="/go/swift">Swift</a>
        <a href="/go/swift">Swift（重复的一条）</a>
        <a href="/member/livid">不是节点</a>
        </div></body></html>
        """

        let forums = try parser.favoriteNodes(html: html)

        XCTAssertEqual(forums.map(\.id.key), ["swift"], "同一个节点只留一条")
        XCTAssertEqual(forums.first?.name, "Swift")
    }

    /// 什么都认不出来时给空数组，不抛 —— 收藏读不出来不该挡住浏览。
    func testFavoriteNodesAreEmptyRatherThanThrowing() throws {
        XCTAssertTrue(
            try parser.favoriteNodes(html: "<html><body>别的东西</body></html>").isEmpty
        )
    }

    /// 加减收藏不拼地址，把节点页上那条链接原样读出来。
    ///
    /// 所以这几条用的不是某一种确定的写法 —— 恰恰相反，它们各写一种**不同的**
    /// 形状（编号 / 名字、`once` / `t`），来钉住「不管站点怎么写，都读得出来」。
    /// 站点真实用的是哪一种，仍然没验过；这个解析器的意义就是不必知道。
    func testFavoriteNodeLinkIsReadNotConstructed() throws {
        let shapes = [
            #"<a href="/favorite/node/12?once=73510" class="tb">加入收藏</a>"#,
            #"<a href="/favorite/node/qna?t=73510">收藏节点</a>"#,
            #"<a href="https://www.v2ex.com/favorite/node/qna?once=1">收藏</a>"#
        ]
        for shape in shapes {
            let html = "<html><body><div id=\"Main\">\(shape)</div></body></html>"
            let link = try XCTUnwrap(
                V2EXParser.favoriteNodeLink(inHTML: html, adding: true),
                shape
            )
            XCTAssertTrue(link.absoluteString.hasPrefix("https://www.v2ex.com/favorite/node/"), shape)
            // 页面上只有「收藏」那条时，取消收藏无从谈起。
            XCTAssertNil(V2EXParser.favoriteNodeLink(inHTML: html, adding: false), shape)
        }
    }

    /// `unfavorite` 里也含着 `favorite` 这个词，先判它，否则两个方向会认混。
    func testUnfavoriteIsNotMistakenForFavorite() throws {
        let html = """
        <html><body><div id="Main">
        <a href="/unfavorite/node/12?once=73510" class="tb">取消收藏</a>
        </div></body></html>
        """

        let removing = try XCTUnwrap(V2EXParser.favoriteNodeLink(inHTML: html, adding: false))
        XCTAssertTrue(removing.path().contains("unfavorite"), removing.absoluteString)
        // 页面上是「取消收藏」，说明现在收藏着 —— 再收藏一次无从谈起。
        XCTAssertNil(V2EXParser.favoriteNodeLink(inHTML: html, adding: true))
    }

    /// 主题的收藏链接不能被当成节点的。
    func testTopicFavoriteLinksAreIgnored() {
        let html = """
        <html><body><div id="Main">
        <a href="/favorite/topic/1240288?once=1">收藏主题</a>
        </div></body></html>
        """

        XCTAssertNil(V2EXParser.favoriteNodeLink(inHTML: html, adding: true))
    }

    /// 站外的链接一概不认 —— 正文是别人写的，谁都能在里面放一条。
    func testForeignFavoriteLinksAreIgnored() {
        let html = """
        <html><body><div id="Main">
        <a href="https://example.com/favorite/node/qna?once=1">看着像</a>
        </div></body></html>
        """

        XCTAssertNil(V2EXParser.favoriteNodeLink(inHTML: html, adding: true))
    }

    /// 匿名页上没有这两条链接 —— 站点只画给登录用户。
    func testAnonymousNodePageHasNoFavoriteLink() throws {
        let html = try fixture("v2ex-node-topics")

        XCTAssertNil(V2EXParser.favoriteNodeLink(inHTML: html, adding: true))
        XCTAssertNil(V2EXParser.favoriteNodeLink(inHTML: html, adding: false))
    }

    /// 主题页上两条收藏链接会同时出现：一条收藏这个主题，一条收藏它所属的节点
    /// （站点把节点挂在侧栏）。不按路径里的词分，「收藏主题」会点成「收藏节点」。
    func testTopicAndNodeFavoriteLinksAreToldApart() throws {
        let html = """
        <html><body><div id="Main">
        <a href="/favorite/topic/1240288?once=1">收藏主题</a>
        </div><div id="Rightbar">
        <a href="/favorite/node/12?once=1">收藏节点</a>
        </div></body></html>
        """

        let topic = try XCTUnwrap(V2EXParser.favoriteTopicLink(inHTML: html, adding: true))
        let node = try XCTUnwrap(V2EXParser.favoriteNodeLink(inHTML: html, adding: true))

        XCTAssertTrue(topic.path().contains("/topic/"), topic.absoluteString)
        XCTAssertTrue(node.path().contains("/node/"), node.absoluteString)
    }

    // MARK: - 每日登录奖励

    /// 领过之后站点把领奖按钮换成「查看我的账户余额」，并写着「已连续登录 N 天」。
    /// 下面这段是照着用户在登录态下抓到的形状写的（按钮标签、类名、onclick 的写法
    /// 都是实测的），但它**不是**抓来的页面，所以不进 `Fixtures/`。
    func testCheckInStatusReadsTheStreakAndTheClaimedState() throws {
        let claimed = """
        <html><body><div id="Main"><div class="cell">已连续登录 8 天</div>
        <input type="button" class="super normal button" value="查看我的账户余额"
               onclick="location.href = '/balance';" />
        </div></body></html>
        """

        let status = try parser.checkInStatistics(html: claimed)

        XCTAssertTrue(status.isCheckedInToday, "领奖按钮不在了，就是今天领过了")
        XCTAssertEqual(status.consecutiveDays, 8)
        // 站点不报总天数。填 0 是在说一件错事 —— 留空，界面就不显示那一行。
        XCTAssertNil(status.totalDays)
    }

    func testCheckInStatusSeesAnUnclaimedDay() throws {
        let unclaimed = """
        <html><body><div id="Main"><div class="cell">已连续登录 8 天</div>
        <input type="button" class="super normal button" value="领取 20 铜币"
               onclick="location.href = '/mission/daily/redeem?once=73510';" />
        </div></body></html>
        """

        let status = try parser.checkInStatistics(html: unclaimed)

        XCTAssertFalse(status.isCheckedInToday)
        XCTAssertEqual(status.consecutiveDays, 8)
    }

    /// 同一页上不止一颗按钮，靠路径分 —— 认按钮上的字不行，那句字会随奖励金额变。
    func testTheClaimLinkIsToldApartFromTheBalanceButton() throws {
        let html = """
        <html><body><div id="Main">
        <input type="button" value="查看我的账户余额" onclick="location.href = '/balance';" />
        <input type="button" value="领取 20 铜币"
               onclick="location.href = '/mission/daily/redeem?once=73510';" />
        </div></body></html>
        """

        let link = try XCTUnwrap(V2EXParser.dailyMissionClaimLink(inHTML: html))

        XCTAssertEqual(
            link.absoluteString,
            "https://www.v2ex.com/mission/daily/redeem?once=73510",
            "地址和令牌都要原样用"
        )
    }

    /// 天数读不出来时别编一个。
    func testAnUnrecognisableMissionPageStillAnswers() throws {
        let status = try parser.checkInStatistics(html: "<html><body>别的东西</body></html>")

        XCTAssertNil(status.consecutiveDays)
        XCTAssertTrue(status.isCheckedInToday, "没有领奖按钮，只能当作没得领")
    }

    // MARK: - 会员

    func testProfileFromTheMemberAPI() throws {
        let profile = try parser.profile(json: try fixtureData("v2ex-member"))

        XCTAssertEqual(profile.uid, 1)
        XCTAssertEqual(profile.displayName, "Livid")
        XCTAssertEqual(profile.title, "Remember the bigger green")
        // `pro` 不是 0/1，是一个到期时间戳；非零就是 PRO。
        XCTAssertEqual(profile.userGroup, "PRO")
        XCTAssertEqual(profile.registeredAt, Date(timeIntervalSince1970: 1_272_203_146))
        // 空字符串当没有：站点对没填的字段发的是 ""，照搬会在资料页上画一行空的。
        XCTAssertNil(profile.location)
        XCTAssertNil(profile.signature)
        XCTAssertEqual(
            profile.avatarURL?.absoluteString,
            "https://cdn.v2ex.com/avatar/c4ca/4238/1_large.png?m=1786747568"
        )
    }

    /// 资料接口给不了的那几样只在网页上：今日活跃度排名、公司职位、外部链接、
    /// 还有徽章（接口只报 `pro`，认不出管理员）。
    func testMemberPageFillsInWhatTheAPIDoesNot() throws {
        var profile = try parser.profile(json: try fixtureData("v2ex-member"))
        XCTAssertNil(profile.dailyRank, "前提：接口里没有这个数")
        XCTAssertEqual(profile.userGroup, "PRO", "前提：接口只报得出 PRO")

        try parser.applyMemberPage(html: try fixture("v2ex-member-page"), to: &profile)

        XCTAssertEqual(profile.dailyRank, 497)
        XCTAssertEqual(profile.affiliation, "V2EX / Builder")
        // 网页上认得出管理员，接口认不出。
        XCTAssertEqual(profile.userGroup, "MOD · PRO")
        // 接口给的身份不能被网页那次覆盖掉。
        XCTAssertEqual(profile.uid, 1)
        XCTAssertEqual(profile.displayName, "Livid")
    }

    func testMemberPageLinksUseTheSitesOwnLabels() throws {
        var profile = try parser.profile(json: try fixtureData("v2ex-member"))

        try parser.applyMemberPage(html: try fixture("v2ex-member-page"), to: &profile)

        let link = try XCTUnwrap(profile.links.first)
        XCTAssertEqual(link.title, "主页")
        XCTAssertEqual(link.value, "sepia.sol.build")
        XCTAssertEqual(link.url.absoluteString, "http://sepia.sol.build")
    }

    /// 属地已经在「所在地」那一行了，`.widgets` 里那条指向谷歌地图的 Geo
    /// 再画一遍是重复；公司只填了职位时也要读得出来。
    func testASparseMemberPageDropsGeoAndStillReadsTheJobTitle() throws {
        var profile = Profile(uid: 74_212, displayName: "zapper", avatarURL: nil)

        try parser.applyMemberPage(html: try fixture("v2ex-member-page-sparse"), to: &profile)

        XCTAssertTrue(profile.links.isEmpty, "只有 Geo 的话一条链接都不该画")
        XCTAssertEqual(profile.affiliation, "牛马", "公司为空时只剩职位")
        XCTAssertEqual(profile.dailyRank, 626)
        XCTAssertNil(profile.userGroup, "没有徽章就别改动接口给的那个值")
    }

    /// 资料页取不到时不能把已经拿到的东西弄丢 —— 那一次请求是附带的。
    func testAnUnrelatedPageLeavesTheProfileAlone() throws {
        var profile = try parser.profile(json: try fixtureData("v2ex-member"))

        try parser.applyMemberPage(html: "<html><body>别的东西</body></html>", to: &profile)

        XCTAssertEqual(profile.displayName, "Livid")
        XCTAssertNil(profile.dailyRank)
        XCTAssertTrue(profile.links.isEmpty)
    }

    func testUsernameLookup() throws {
        XCTAssertEqual(try parser.username(json: try fixtureData("v2ex-member")), "Livid")
        XCTAssertThrowsError(try parser.username(json: Data("{}".utf8)))
    }

    /// 一条动态摊成两个相邻的兄弟节点，要成对地走 —— 各选各的再按下标配对，
    /// 中间夹一条广告两列就错开了。
    func testMemberRepliesPairEachDockWithItsBody() throws {
        let page = try parser.userReplies(html: try fixture("v2ex-member-replies"), page: 1)

        XCTAssertEqual(page.kind, .replies)
        XCTAssertEqual(page.activities.count, 2)
        XCTAssertEqual(page.totalPages, 1_572)

        let first = try XCTUnwrap(page.activities.first)
        XCTAssertEqual(first.topicID.rawValue, 1_240_321)
        XCTAssertEqual(first.forumID?.key, "promotions")
        XCTAssertEqual(first.forumName, "推广")
        XCTAssertTrue(first.excerpt?.contains("谢谢举报") == true, first.excerpt ?? "nil")
        // 这一页的时间只有相对说法，没有 title 属性 —— 硬换算会得到一个假的精确值。
        XCTAssertNil(first.postedAt)

        XCTAssertEqual(page.activities.last?.topicID.rawValue, 1_239_253)
        XCTAssertNotEqual(page.activities[0].id, page.activities[1].id)
    }

    // MARK: - 正文与写操作的结果

    /// 站点对回复只做两件事：转义，把换行换成 `<br>`。预览照着做 ——
    /// 借道 Markdown 会让 `**粗体**` 在预览里变粗，发出去却是四个星号。
    func testPlainTextPreviewDoesNotPretendToBeMarkdown() {
        let html = V2EXParser.plainTextPreviewHTML("**不会变粗**\n<script>x</script>")

        XCTAssertTrue(html.contains("**不会变粗**"))
        XCTAssertTrue(html.contains("<br>"))
        XCTAssertTrue(html.contains("&lt;script&gt;"))
        XCTAssertFalse(html.contains("<script>"))
    }

    func testSitePreviewGoesThroughTheSameCleaning() {
        let html = ForumSiteDescriptor.v2ex.sanitizedPreviewHTML("**星号**")

        XCTAssertTrue(html.contains("**星号**"), html)
        XCTAssertTrue(html.contains("<strong>") == false, "纯文本站点不该把它渲染成粗体")
    }

    func testThankResultIsCheckedForSuccess() throws {
        XCTAssertNoThrow(
            try parser.confirmThank(json: Data(#"{"success": true, "once": 42}"#.utf8))
        )
        // 失败时那句 message 就是站点要显示给用户的话。
        XCTAssertThrowsError(
            try parser.confirmThank(json: Data(#"{"success": false, "message": "铜币不足"}"#.utf8))
        ) { error in
            XCTAssertEqual(error as? ForumServiceError, .restricted("铜币不足"))
        }
    }

    /// 回复是表单提交，成功时站点 302 回主题页，没有 JSON 可读 ——
    /// 所以判据反过来：看返回的页面里有没有那条出错提示。
    func testReplyFailureIsReadFromTheReturnedPage() throws {
        let failed = """
        <html><body><div id="Main"><div class="problem">你上一条回复的时间过近</div></div></body></html>
        """
        XCTAssertThrowsError(try parser.confirmReply(html: failed)) { error in
            XCTAssertEqual(error as? ForumServiceError, .restricted("你上一条回复的时间过近"))
        }
        XCTAssertNoThrow(try parser.confirmReply(html: try fixture("v2ex-topic")))
    }

    func testDeviceFromTheAgoText() {
        XCTAssertEqual(V2EXParser.device(inAgoText: "51 分钟前 via iPhone"), .apple)
        XCTAssertEqual(V2EXParser.device(inAgoText: "3 小时前 via Android"), .android)
        XCTAssertEqual(V2EXParser.device(inAgoText: "3 小时前"), nil)
    }

    /// 会员把主题列表藏起来（或者干脆没发过）时，那一页上没有列表也没有分页条 ——
    /// 这是**正常状态，不是解析失败**。报出去的话，用户中心一打开就弹一次。
    func testAHiddenTopicListIsEmptyNotAnError() throws {
        let page = try parser.userTopics(
            html: try fixture("v2ex-member-topics-hidden"), page: 1
        )

        XCTAssertTrue(page.activities.isEmpty)
        XCTAssertFalse(page.hasMore)
        XCTAssertEqual(page.totalPages, 1)
    }

    /// 那一页的抬头写着「全部主题」，长得很像站点在说什么 —— 它**不是**
    /// 「没有这个节点」。认错了就会每次切到 V2EX 都弹一句「V2EX：全部主题」。
    /// 两者的区别在面包屑：这一页有两个链接，那一页只有一个。
    ///
    /// 拿版面列表那个入口去解它本来就该失败（它根本不是版面列表），
    /// 但失败的说法不能是站点没说过的那句。
    func testAHiddenTopicListIsNotMistakenForAMissingNode() throws {
        XCTAssertThrowsError(
            try parser.topicList(
                html: try fixture("v2ex-member-topics-hidden"),
                forumID: ForumID.placeholder(site: .v2ex),
                page: 1
            )
        ) { error in
            XCTAssertNotEqual(
                error as? ForumServiceError,
                .restricted("全部主题"),
                "抬头里的「全部主题」被当成了站点在报错"
            )
            XCTAssertEqual(error as? ForumServiceError, .unexpectedPage("未找到主题列表"))
        }
    }

    /// 站点上没有这个节点时给的是一张 **200 的正常页面**，只是里面没有列表。
    /// 报成「论坛页面结构已变化」既不对也没用 —— 站点没坏，是节点不在。
    func testAMissingNodeSaysSoInsteadOfBlamingThePageStructure() throws {
        XCTAssertThrowsError(
            try parser.topicList(
                html: try fixture("v2ex-node-missing"),
                forumID: V2EXEndpoint.forumID(key: "-7"),
                page: 1
            )
        ) { error in
            // 面包屑最后一段就是站点自己的说法，冠上站名读作「V2EX：节点未找到」。
            XCTAssertEqual(error as? ForumServiceError, .restricted("节点未找到"))
        }
    }

    // MARK: - 结构变了要说出来

    /// 一张什么都对不上的页面必须报错，而不是给一页空列表 —— 那会让人以为节点是空的。
    func testAnUnrecognizablePageThrows() {
        XCTAssertThrowsError(
            try parser.topicList(html: "<html><body>别的东西</body></html>", forumID: qna, page: 1)
        )
        XCTAssertThrowsError(
            try parser.threadPage(
                html: "<html><body>别的东西</body></html>",
                topicID: TopicID(rawValue: 1),
                page: 1
            )
        )
        XCTAssertThrowsError(try parser.planes(html: "<html><body>别的东西</body></html>"))
    }
}
