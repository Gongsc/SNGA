import XCTest
@testable import SNGA

/// 样例取自 tid=47337610 的真实原文。
final class PostQuoteExpanderTests: XCTestCase {
    private let floor3 = "土耳其其也是伊斯兰国家，萨拉赫是伊斯兰世界的绝对巨星，他加盟特拉布宗的那个视频，球迷那溢出的热情，我看了觉得他不会后悔加盟的"
    private let floor5 = "[b]Reply to [pid=877855034,47337610,1]Reply[/pid] Post by [uid=188297]zuldark[/uid] (2026-08-09 08:03)[/b]我一直没搞懂内马尔"
    private let floor6 = "[b]Reply to [pid=877855763,47337610,1]Reply[/pid] Post by [uid=62442264]神似哀伤[/uid] (2026-08-09 08:22)[/b]<br/><br/>就是钱给到位了"

    func testExpandsReplyToHeaderIntoQuote() {
        let expanded = PostQuoteExpander.expanded(floor5) { _ in floor3 }

        XCTAssertTrue(expanded.hasPrefix("[quote]"), "应当改写成引用块")
        XCTAssertTrue(expanded.contains(floor3), "被引正文必须内联进来")
        XCTAssertTrue(expanded.contains("[pid=877855034"), "回链要保留")
        XCTAssertTrue(expanded.contains("zuldark"), "被引作者要保留")
        XCTAssertTrue(
            expanded.hasSuffix("我一直没搞懂内马尔"),
            "本层正文必须完整保留在引用块之后"
        )
    }

    func testExpandsHeaderFollowedByLineBreaks() {
        let expanded = PostQuoteExpander.expanded(floor6) { _ in "被引用的话" }

        XCTAssertTrue(expanded.hasPrefix("[quote]"))
        XCTAssertTrue(expanded.contains("被引用的话"))
        XCTAssertTrue(expanded.hasSuffix("就是钱给到位了"))
    }

    // MARK: - 必须保持原样的情况

    func testUnresolvedReferenceIsLeftUnchanged() {
        // 跨页引用取不到被引楼层时，退回展开前的表现，而不是产出空引用块。
        XCTAssertEqual(PostQuoteExpander.expanded(floor5) { _ in nil }, floor5)
    }

    func testEmptyReferencedContentIsLeftUnchanged() {
        XCTAssertEqual(PostQuoteExpander.expanded(floor5) { _ in "   " }, floor5)
    }

    func testExistingQuoteIsLeftUnchanged() {
        let raw = "[quote][pid=1,2,1]Reply[/pid] [b]Post by 某人 (时间):[/b]<br/><br/>原本就有的引用[/quote]正文"
        XCTAssertEqual(PostQuoteExpander.expanded(raw) { _ in "不该被用到" }, raw)
    }

    func testPostWithoutReferenceIsLeftUnchanged() {
        let raw = "一段没有任何引用的普通回复"
        XCTAssertEqual(PostQuoteExpander.expanded(raw) { _ in "不该被用到" }, raw)
    }

    // MARK: - 内联内容的清理

    func testNestedQuoteIsStrippedFromInlinedBody() {
        // [quote] 不支持嵌套，把带引用的楼层原样套进去会让标记漏成可见文字。
        let referenced = "[quote]更早的引用[/quote]被引楼层自己的话"
        let expanded = PostQuoteExpander.expanded(floor5) { _ in referenced }

        XCTAssertTrue(expanded.contains("被引楼层自己的话"))
        XCTAssertFalse(expanded.contains("更早的引用"), "嵌套引用应当被剥掉")
        XCTAssertEqual(
            expanded.components(separatedBy: "[quote]").count - 1,
            1,
            "只应存在一层引用"
        )
    }

    func testReferencedReplyToHeaderIsStripped() {
        let referenced = "[b]Reply to [pid=999,47337610,1]Reply[/pid] Post by [uid=1]别人[/uid] (时间)[/b]被引楼层自己的话"
        let expanded = PostQuoteExpander.expanded(floor5) { _ in referenced }

        XCTAssertTrue(expanded.contains("被引楼层自己的话"))
        XCTAssertFalse(expanded.contains("[pid=999"), "被引楼层自己的抬头应当被剥掉")
    }

    func testLongQuotedBodyIsTruncated() {
        let referenced = String(repeating: "长", count: 900)
        let expanded = PostQuoteExpander.expanded(floor5) { _ in referenced }

        XCTAssertTrue(expanded.contains("……"), "超长引用应当截断")
        XCTAssertLessThan(
            expanded.count,
            referenced.count,
            "截断后应短于原文"
        )
    }

    func testBatchExpansionResolvesWithinPage() {
        let referenced = Post(
            id: PostID(rawValue: 877855034),
            topicID: TopicID(rawValue: 47337610),
            floor: 3,
            author: "zuldark",
            html: floor3
        )
        let replying = Post(
            id: PostID(rawValue: 877855763),
            topicID: TopicID(rawValue: 47337610),
            floor: 5,
            author: "神似哀伤",
            html: floor5
        )

        var byID: [PostID: String] = [:]
        for post in [referenced, replying] { byID[post.id] = post.html }
        let expanded = PostQuoteExpander.expandingReferences(
            in: [referenced, replying],
            resolve: { byID[$0] }
        )

        XCTAssertEqual(expanded[0].html, floor3, "被引楼层本身不应被改动")
        XCTAssertTrue(expanded[1].html.contains(floor3))
    }
}
