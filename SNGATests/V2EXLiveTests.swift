import Foundation
import XCTest
@testable import SNGA

/// 打到线上的冒烟用例：确认地址、请求头和选择器现在还对得上。
///
/// **不进自动化** —— 方法名不以 `test` 开头，XCTest 就发现不了。理由和 NodeSeek 那份
/// 一样：依赖第三方站点，慢且会随对方改版而红。夹具测试才是常跑的那套，这几条只在
/// 「怀疑站点改版了」时手动跑：把方法名临时改回 `test` 开头即可。
///
/// **不需要账号**，也不该用账号跑 —— 这几条全走公开页面。V2EX 的浏览面匿名可读，
/// 这正是这份文件比 NodeSeek 那份能盖得更全的原因。
///
/// 写请求一条都不在这里：不往真实论坛发东西。写请求的形状由
/// `V2EXWriteTests` 用假传输层钉住。
final class V2EXLiveTests: XCTestCase {

    private func service() -> V2EXForumService {
        V2EXForumService(
            accountID: AccountID(),
            cookies: [],
            userAgent: ForumSiteDescriptor.v2ex.resolvedUserAgent(fallback: nil)
        )
    }

    func manualLiveNodeListParses() async throws {
        let page = try await service().topics(
            forumID: V2EXEndpoint.forumID(key: "qna"),
            page: 2,
            sortOrder: .latestReply,
            featuredOnly: false
        )

        XCTAssertFalse(page.topics.isEmpty, "线上节点页解析不出主题 —— 多半是选择器过时了")
        XCTAssertGreaterThan(page.totalPages, 1)
        XCTAssertEqual(page.forum?.name, "问与答")
        let first = try XCTUnwrap(page.topics.first)
        XCTAssertFalse(first.subject.isEmpty)
        XCTAssertFalse(first.author.isEmpty)
        print("线上第一条：#\(first.id) \(first.subject.prefix(30))，共 \(page.totalPages) 页")
    }

    /// 「最近主题」和节点页是两种模板，各测一次。
    func manualLiveRecentListParses() async throws {
        let page = try await service().topics(
            forumID: V2EXEndpoint.forumID(key: V2EXEndpoint.recentKey),
            page: 1,
            sortOrder: .latestReply,
            featuredOnly: false
        )

        XCTAssertFalse(page.topics.isEmpty)
        XCTAssertEqual(page.forum?.name, "最近主题")
        // 混合列表里每条都该指出自己属于哪个节点。
        XCTAssertTrue(page.topics.allSatisfy { $0.sourceForumName != nil })
        print("线上最近主题 \(page.topics.count) 条，共 \(page.totalPages) 页")
    }

    func manualLiveThreadPageParses() async throws {
        let page = try await service().threadPage(
            topicID: TopicID(rawValue: 1_240_288), page: 1, authorUID: nil
        )

        XCTAssertFalse(page.posts.isEmpty, "线上主题页解析不出楼层 —— 多半是选择器过时了")
        XCTAssertEqual(page.posts.first?.floor, 0, "第一层应当是主楼")
        let opening = try XCTUnwrap(page.posts.first)
        XCTAssertFalse(page.topic.subject.isEmpty)
        XCTAssertFalse(opening.author.isEmpty)
        XCTAssertFalse(opening.html.isEmpty)
        // 感谢是这个站唯一的表态，每层都该挂着，而且带着代价。
        XCTAssertEqual(opening.reactions.first?.id, "thank")
        XCTAssertNotNil(opening.reactions.first?.cost)
        print("线上主题：\(page.topic.subject.prefix(30))，本页 \(page.posts.count) 层")
    }

    func manualLiveNodeDirectoryParses() async throws {
        let forums = try await service().forums()

        // 第一条是应用自己补的「最近主题」，接着是首页分类，其余才是站点的节点。
        XCTAssertEqual(forums.first?.id.key, V2EXEndpoint.recentKey)
        XCTAssertGreaterThan(forums.count, 1_000, "站点有一千三百多个节点")
        XCTAssertTrue(forums.contains { $0.id.key == "qna" })
        let planes = Set(forums.compactMap(\.category))
            .subtracting(["站点", V2EXEndpoint.tabCategoryName])
        XCTAssertEqual(planes.count, 6, "站点把节点分进六个位面")
        print("线上节点 \(forums.count) 项，位面：\(planes.sorted())")
    }

    /// 首页分类：聚合若干节点的主题，页面上还把那几个节点画成第二行。
    ///
    /// 站点随时会调整这一排（加一格、换个名字），所以这条盯的是**形状**：
    /// 分类打得开、有主题、每条记得住自己来自哪个节点。分类本身写死在
    /// `V2EXEndpoint.tabs` 里，真改了要回去改那张表。
    func manualLiveHomeTabParses() async throws {
        let page = try await service().topics(
            forumID: V2EXEndpoint.tabForumID(key: "tech"),
            page: 1,
            sortOrder: .latestReply,
            featuredOnly: false
        )

        XCTAssertFalse(page.topics.isEmpty)
        XCTAssertEqual(page.forum?.name, "技术")
        XCTAssertFalse(page.subforums.isEmpty, "「技术」底下该有第二排节点")
        XCTAssertFalse(page.hasMore, "分类页没有分页条")
        // 筛选靠这个值。记不住，第二行那几个开关就一个都不管用。
        XCTAssertTrue(page.topics.allSatisfy { $0.sourceForumID != nil })
        print("线上「技术」：\(page.topics.count) 条，聚合节点 \(page.subforums.map(\.name))")
    }

    /// 写死的那张分类表得和站点当前那一排对得上。对不上就该回去改表。
    func manualLiveTabTableMatchesTheSite() async throws {
        let data = try await V2EXNetworkClient(
            cookies: [],
            transport: URLSessionTransport(),
            userAgent: ForumSiteDescriptor.v2ex.resolvedUserAgent(fallback: nil),
            cookieDidChange: { _ in }
        ).get(ForumSiteDescriptor.v2ex.baseURL)
        let html = try XCTUnwrap(String(data: data, encoding: .utf8))

        let live = html
            .matches(of: /<a href="\/\?tab=([a-z0-9]+)"[^>]*>([^<]+)<\/a>/)
            .map { (key: String($0.1), name: String($0.2)) }

        XCTAssertEqual(live.map(\.key), V2EXEndpoint.tabs.map(\.key), "分类的键对不上了")
        XCTAssertEqual(live.map(\.name), V2EXEndpoint.tabs.map(\.name), "分类的名字对不上了")
        print("线上分类：\(live.map(\.name))")
    }

    /// 资料要两次请求：接口给身份和自我介绍，网页给活跃度排名、公司职位、
    /// 外部链接和徽章。这条盯的是两半都拼上了。
    func manualLiveProfileParses() async throws {
        let profile = try await service().profile(uid: 1)

        XCTAssertEqual(profile.displayName, "Livid")
        XCTAssertNotNil(profile.registeredAt)
        // 网页那一半。排名每天在变，只看有没有读出来。
        XCTAssertNotNil(profile.dailyRank, "今日活跃度排名只在网页上")
        XCTAssertNotNil(profile.affiliation, "「🏢 公司 / 职位」只在网页上")
        XCTAssertTrue(profile.userGroup?.contains("MOD") == true, "网页上认得出管理员")
        XCTAssertFalse(profile.links.isEmpty, "资料页上那一排外部链接")
        print(
            "线上会员：\(profile.displayName)，排名 \(profile.dailyRank ?? -1)，"
                + "\(profile.affiliation ?? "—")，\(profile.userGroup ?? "—")，"
                + "链接 \(profile.links.map(\.title))"
        )
    }

    /// 两种用户动态页的形状完全不同，各测一次。
    func manualLiveUserActivitiesParse() async throws {
        let service = service()

        let topics = try await service.userActivities(uid: 1, kind: .topics, page: 1)
        XCTAssertFalse(topics.activities.isEmpty)
        XCTAssertTrue(topics.activities.allSatisfy { !$0.subject.isEmpty })

        let replies = try await service.userActivities(uid: 1, kind: .replies, page: 1)
        XCTAssertFalse(replies.activities.isEmpty)
        XCTAssertTrue(replies.activities.allSatisfy { $0.topicID.rawValue > 0 })
        print("线上动态：主题 \(topics.activities.count) 条，回复 \(replies.activities.count) 条")
    }

    /// 一次性令牌匿名也给，所以这一条不用账号就能验。
    func manualLiveOnceTokenIsAvailable() async throws {
        let client = V2EXNetworkClient(
            cookies: [],
            transport: URLSessionTransport(),
            userAgent: ForumSiteDescriptor.v2ex.resolvedUserAgent(fallback: nil),
            cookieDidChange: { _ in }
        )

        let once = try await client.freshOnce()

        XCTAssertFalse(once.isEmpty)
        XCTAssertTrue(once.allSatisfy(\.isNumber), "令牌应当是一串数字：\(once)")
    }

    /// 主题搜索走第三方的 SoV2EX。这条会把关键词发到 sov2ex.com。
    func manualLiveTopicSearchParses() async throws {
        let request = try XCTUnwrap(ForumSearchRequest(query: "dmit", kind: .topicContent))

        let page = try await service().search(request, page: 1)

        XCTAssertFalse(page.topics.isEmpty)
        XCTAssertGreaterThan(page.totalPages, 1)
        let first = try XCTUnwrap(page.topics.first)
        XCTAssertFalse(first.subject.isEmpty)
        XCTAssertFalse(first.author.isEmpty)
        // 节点编号翻得成名字，时间读得出来（而且不该差八小时）。
        XCTAssertNotNil(first.sourceForumName)
        XCTAssertNotNil(first.publishedAt)
        print("线上搜索：\(page.totalPages) 页，首条 #\(first.id) \(first.subject.prefix(24)) @ \(first.sourceForumName ?? "—")")
    }

    /// 缩进一个节点搜。带的是节点名 —— 编号会被无声地忽略。
    func manualLiveTopicSearchInsideANodeParses() async throws {
        let all = try await service().search(
            try XCTUnwrap(ForumSearchRequest(query: "dmit", kind: .topicContent)),
            page: 1
        )
        let scoped = try await service().search(
            try XCTUnwrap(ForumSearchRequest(
                query: "dmit", kind: .topicContent,
                forumID: V2EXEndpoint.forumID(key: "qna")
            )),
            page: 1
        )

        XCTAssertLessThan(scoped.totalPages, all.totalPages, "缩进节点之后结果该少一些")
        XCTAssertTrue(
            scoped.topics.allSatisfy { $0.forumID.key == "qna" },
            "缩进 qna 之后不该有别的节点的结果"
        )
        print("线上搜索：全站 \(all.totalPages) 页，问与答 \(scoped.totalPages) 页")
    }

    /// 筛选条件真的能把结果缩窄。
    ///
    /// 日期那两个参数尤其值得打一次线上：它们的单位是**秒**，传毫秒接口不报错、
    /// 只是一条都搜不到 —— 光看状态码验不出来。
    func manualLiveSearchFiltersNarrowTheResults() async throws {
        let service = service()
        func search(_ filters: ForumSearchFilters) async throws -> ForumSearchPage {
            try await service.search(
                try XCTUnwrap(ForumSearchRequest(
                    query: "dmit", kind: .topicContent, filters: filters
                )),
                page: 1
            )
        }

        let all = try await search(.none)

        var byAuthor = ForumSearchFilters.none
        byAuthor.author = "idblife"
        let authored = try await search(byAuthor)
        XCTAssertLessThan(authored.totalPages, all.totalPages)
        XCTAssertTrue(authored.topics.allSatisfy { $0.author == "idblife" })

        var byDate = ForumSearchFilters.none
        byDate.postedAfter = try XCTUnwrap(
            DateComponents(calendar: .current, year: 2025, month: 1, day: 1).date
        )
        byDate.postedBefore = try XCTUnwrap(
            DateComponents(calendar: .current, year: 2025, month: 12, day: 31).date
        )
        byDate.sort = .postedAt
        let dated = try await search(byDate)
        XCTAssertFalse(dated.topics.isEmpty, "日期区间传成毫秒的话这里就是空的")
        for topic in dated.topics {
            let year = Calendar.current.component(.year, from: try XCTUnwrap(topic.publishedAt))
            XCTAssertEqual(year, 2025, "落在区间外：\(topic.subject)")
        }
        print("线上筛选：全部 \(all.totalPages) 页，idblife \(authored.totalPages) 页，2025 年内 \(dated.totalPages) 页")
    }

    func manualLiveNodeSearchFindsSomething() async throws {
        let request = try XCTUnwrap(ForumSearchRequest(query: "swift", kind: .forum))

        let page = try await service().search(request, page: 1)

        XCTAssertFalse(page.forums.isEmpty)
        XCTAssertTrue(page.forums.contains { $0.id.key == "swift" })
        print("线上节点搜索命中 \(page.forums.count) 个")
    }
}
