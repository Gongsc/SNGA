import XCTest
@testable import SNGA

/// 新帖监控。
///
/// 夹具是 `rss.nodeseek.com` 的真实响应（2026-09-16 匿名抓的），只把 `dc:creator`
/// 换成了占位名 —— 其余结构、标题、编号、时间原样。二十条、编号倒序，这两件正是
/// 「首次不提醒」那条规则要应付的东西。
final class TopicMonitorTests: XCTestCase {
    private func feedXML() throws -> Data {
        try Data(
            contentsOf: try XCTUnwrap(
                Bundle(for: Self.self)
                    .url(forResource: "nodeseek-rss", withExtension: "xml")
            )
        )
    }

    private func items() throws -> [TopicMonitorFeedItem] {
        try TopicMonitorFeedParser.items(from: try feedXML())
    }

    // MARK: - 订阅解析

    func testTheFeedReadsEveryItem() throws {
        let parsed = try items()

        XCTAssertEqual(parsed.count, 20, "订阅一次给二十条")
        let first = try XCTUnwrap(parsed.first)
        XCTAssertEqual(first.id, 931_683)
        XCTAssertEqual(first.title, "某家de9929是真顶尖（非k系）")
        XCTAssertEqual(first.category, "review")
        XCTAssertEqual(
            first.link,
            URL(string: "https://www.nodeseek.com/post-931683-1")
        )
        XCTAssertNotNil(first.publishedAt)
    }

    /// `pubDate` 是 RFC 822，月份名是英文的。formatter 不钉死 POSIX locale 的话，
    /// 在中文系统上会全部解析失败 —— 而开发机多半正是中文系统，测不出来才怪。
    func testPublishedDatesSurviveANonEnglishLocale() throws {
        let parsed = try items()
        XCTAssertEqual(
            parsed.count(where: { $0.publishedAt != nil }), parsed.count,
            "有条目的时间没解析出来"
        )
    }

    /// 标题必须是解码过的，不能还带着 CDATA 或实体 —— 规则是拿它去匹配的。
    func testTitlesComeOutDecoded() throws {
        for item in try items() {
            XCTAssertFalse(item.title.contains("CDATA"), item.title)
            XCTAssertFalse(item.title.hasPrefix("<"), item.title)
            XCTAssertFalse(item.title.isEmpty)
        }
    }

    func testAnUnreadableFeedThrows() {
        XCTAssertThrowsError(
            try TopicMonitorFeedParser.items(from: Data("<<<not xml".utf8))
        )
    }

    // MARK: - 规则

    func testABareLineIsACaseInsensitiveKeyword() {
        let compiled = TopicMonitorRules.compile("vmiss")
        XCTAssertEqual(compiled.rules.count, 1)
        XCTAssertTrue(compiled.rules[0].matches("[IP测试留档]VMISS-US.LA"))
        XCTAssertTrue(compiled.rules[0].matches("vmiss 又出新机"))
        XCTAssertFalse(compiled.rules[0].matches("别的机器"))
    }

    func testSlashDelimitedRulesKeepTheirOwnFlags() {
        let compiled = TopicMonitorRules.compile("/vmiss/")
        XCTAssertEqual(compiled.rules.count, 1)
        XCTAssertFalse(
            compiled.rules[0].matches("VMISS 大写"),
            "写了 /vmiss/ 就是要区分大小写，不能替他加上 i"
        )

        let insensitive = TopicMonitorRules.compile("/vmiss/i")
        XCTAssertTrue(insensitive.rules[0].matches("VMISS 大写"))
    }

    func testBlankLinesAreSkippedAndBadOnesAreReported() {
        let compiled = TopicMonitorRules.compile("""
        vmiss

          搬瓦工
        /香港.*(年付|月付)/i
        (未闭合
        /vmiss/zz
        """)

        XCTAssertEqual(compiled.rules.map(\.source), ["vmiss", "搬瓦工", "/香港.*(年付|月付)/i"])
        XCTAssertEqual(
            compiled.invalidLines, ["(未闭合", "/vmiss/zz"],
            "写坏的行要说出来 —— 它和一条永远匹配不上的规则在界面上长得一样"
        )
    }

    /// 规则编号是按**能用的**那几条数的，不是按行号。中间夹一条写坏的，颜色不该跳号。
    func testRuleIndexesCountUsableRulesOnly() {
        let compiled = TopicMonitorRules.compile("a\n(坏\nb")
        XCTAssertEqual(compiled.rules.map(\.index), [0, 1])
    }

    // MARK: - 水位线

    /// 首次检查只记位置，不提醒。
    ///
    /// 订阅当前那二十条里多半有几条能命中，但它们不是「新出现的」，只是「你刚开始
    /// 看」。第一次就弹二十条通知，用户学到的唯一一件事是把提醒关掉。
    func testTheFirstCheckOnlyRecordsThePosition() throws {
        let rules = TopicMonitorRules.compile("出").rules
        let result = TopicMonitorPolicy.check(
            items: try items(), rules: rules, watermark: nil
        )

        XCTAssertTrue(result.isFirstSnapshot)
        XCTAssertTrue(result.newHits.isEmpty, "首次就提醒，等于开箱二十条通知")
        XCTAssertEqual(result.watermark, 931_683, "位置要落在当前最大的那个编号上")
        XCTAssertGreaterThan(result.matched, 0, "前提：这批里本来就有命中的")
    }

    func testLaterChecksOnlyLookAtPostsAboveTheWatermark() throws {
        let rules = TopicMonitorRules.compile("vmiss").rules
        let all = try items()
        // 把位置放在那条 vmiss 帖子（931669）之下一点，让它落进「新的」那一侧。
        let result = TopicMonitorPolicy.check(
            items: all, rules: rules, watermark: 931_668
        )

        XCTAssertFalse(result.isFirstSnapshot)
        XCTAssertEqual(result.newHits.map(\.id), [931_669])
        XCTAssertEqual(result.watermark, 931_683)
        XCTAssertEqual(result.examined, 15, "水位线以上有十五条")
    }

    /// 同一批再跑一遍，一条都不该再收 —— 否则每一轮都会把同样的帖子重新提醒一次。
    func testNothingIsReportedTwice() throws {
        let rules = TopicMonitorRules.compile("出").rules
        let all = try items()
        let first = TopicMonitorPolicy.check(items: all, rules: rules, watermark: 931_600)
        XCTAssertFalse(first.newHits.isEmpty, "前提：第一轮确实收到了东西")

        let second = TopicMonitorPolicy.check(
            items: all, rules: rules, watermark: first.watermark
        )
        XCTAssertTrue(second.newHits.isEmpty)
        XCTAssertEqual(second.watermark, first.watermark)
    }

    /// **水位线只进不退。** 订阅回了一批旧数据（缓存、上游回滚）时把位置往回拨，
    /// 会让已经提醒过的帖子再提醒一遍。
    func testStaleDataNeverRewindsTheWatermark() throws {
        let rules = TopicMonitorRules.compile("出").rules
        let result = TopicMonitorPolicy.check(
            items: try items(), rules: rules, watermark: 999_999
        )

        XCTAssertEqual(result.watermark, 999_999)
        XCTAssertTrue(result.newHits.isEmpty)
    }

    /// 空的一批也不该把位置清掉。
    func testAnEmptyFeedLeavesThePositionAlone() {
        let result = TopicMonitorPolicy.check(
            items: [], rules: TopicMonitorRules.compile("出").rules, watermark: 931_683
        )
        XCTAssertEqual(result.watermark, 931_683)
        XCTAssertTrue(result.newHits.isEmpty)
    }

    /// 一条帖子命中多条规则时，算第一条 —— 界面按规则分色，一条结果只能有一个颜色。
    func testAHitIsAttributedToTheFirstMatchingRule() {
        let rules = TopicMonitorRules.compile("香港\n年付").rules
        let item = TopicMonitorFeedItem(
            id: 2, title: "香港 年付 便宜鸡", category: nil, author: nil,
            publishedAt: nil, link: nil
        )
        let result = TopicMonitorPolicy.check(items: [item], rules: rules, watermark: 1)

        XCTAssertEqual(result.newHits.count, 1)
        XCTAssertEqual(result.newHits.first?.ruleIndex, 0)
        XCTAssertEqual(result.newHits.first?.ruleSource, "香港")
    }

    // MARK: - 结果合并

    func testNewHitsComeFirstAndDuplicatesCollapse() {
        let existing = [hit(id: 3), hit(id: 2), hit(id: 1)]
        let merged = TopicMonitorPolicy.merging(existing, with: [hit(id: 4), hit(id: 3)])
        XCTAssertEqual(merged.map(\.id), [4, 3, 2, 1])
    }

    func testTheResultListIsCapped() {
        let existing = (1...250).map { hit(id: Int64($0)) }
        let merged = TopicMonitorPolicy.merging(existing, with: [hit(id: 999)])
        XCTAssertEqual(merged.count, TopicMonitorPolicy.maximumHitCount)
        XCTAssertEqual(merged.first?.id, 999, "新的排前面，被挤掉的该是最旧的")
    }

    private func hit(id: Int64) -> TopicMonitorHit {
        TopicMonitorHit(
            id: id, title: "第 \(id) 条", category: nil, author: nil,
            publishedAt: nil, link: nil, ruleIndex: 0, ruleSource: "x",
            foundAt: Date(timeIntervalSince1970: 0)
        )
    }

    // MARK: - 取数

    /// 订阅是公开的，**一个 cookie 都不带**。监控要的是「站上出了什么新帖」，
    /// 和「我是谁」无关；带上会话既没用，又把账号暴露给一台不必知道它的机器。
    func testTheFeedRequestCarriesNoSession() async throws {
        let transport = RecordingHTTPTransport(responding: String(decoding: try feedXML(), as: UTF8.self))
        _ = try await TopicMonitorFeed(transport: transport).load()

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.host, "rss.nodeseek.com")
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Referer"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Origin"))
    }

    func testAServerErrorIsReportedRatherThanLookingEmpty() async throws {
        let transport = RecordingHTTPTransport(responding: "", status: 503)
        do {
            _ = try await TopicMonitorFeed(transport: transport).load()
            XCTFail("503 被当成了『这一轮没有新帖』")
        } catch {
            XCTAssertEqual(error as? ForumServiceError, .server(503))
        }
    }
}
