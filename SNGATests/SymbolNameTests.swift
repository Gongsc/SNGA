import AppKit
import XCTest
@testable import SNGA

/// 图标名必须真的存在。
///
/// 写错一个名字，SwiftUI 既不报错也不崩 —— 它画一片空白。加鸡腿的图标就这么消失过：
/// `drumstick` 看着像个合理的名字，而 SF Symbols 里根本没有鸡腿。
///
/// 视图里的名字是字面量，改动时看得见；这些是解析层算出来的，藏在 switch 里，
/// 所以更需要有人盯着。
final class SymbolNameTests: XCTestCase {

    private func assertExists(_ name: String, _ what: String, line: UInt = #line) {
        XCTAssertNotNil(
            NSImage(systemSymbolName: name, accessibilityDescription: nil),
            "\(what) 用的「\(name)」不是有效的 SF Symbol —— 界面上会是一片空白",
            line: line
        )
    }

    func testEveryReactionIconExists() {
        for reaction in NodeSeekReaction.allCases {
            assertExists(reaction.systemImage, "表态「\(reaction.title)」")
        }
    }

    /// 列表标记的图标由解析器按站点的图标类名挑，认不出来的用兜底那个。
    func testEveryTopicBadgeIconExists() throws {
        let html = """
        <li class="post-list-item"><div class="post-list-content">
          <div class="post-title">
            <a href="/post-9-1">帖子</a>
            <span title="置顶"><svg><use href="#pin"></use></svg></span>
            <a href="/award" title="推荐阅读"><svg><use href="#diamonds"></use></svg></a>
            <span><svg><use href="#lock"></use></svg>2</span>
            <span class="nsk-badge read-only">只读</span>
            <span><svg><use href="#brand-new-thing"></use></svg>没见过的标记</span>
          </div>
          <div class="post-info"><span class="info-item info-author"><a href="/space/1">谁</a></span></div>
        </div></li>
        """
        let topic = try XCTUnwrap(
            try NodeSeekParser().topicList(
                html: html, forumID: NodeSeekEndpoint.forumID(key: "daily"), page: 1
            ).topics.first
        )

        XCTAssertEqual(topic.badges.count, 5, "前提：五种标记都读到了")
        for badge in topic.badges {
            assertExists(badge.systemImage, "标记「\(badge.title)」")
        }
    }

    /// 兜底的那个也得存在 —— 认不出的标记全靠它。
    func testTheFallbackBadgeIconExists() {
        assertExists(TopicBadge(title: "随便").systemImage, "标记的兜底图标")
    }
}
