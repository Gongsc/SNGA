import AppKit
import SwiftUI
import XCTest
@testable import SNGA

/// 分页条对外的契约。
///
/// 这些不是内部细节，是 SNGAUITests 里几条用例直接依赖的东西：
/// `textFields["topic-list-page-field"].value` 读当前页、点进去、⌘A、打字、回车。
/// 页码框从 `.roundedBorder` 改成 `.plain` 之后看起来只是一行字，底下必须仍然是
/// 一个可编辑的 NSTextField，否则那几条用例会在没人注意的时候悄悄失效。
///
/// 这里用宿主视图验，是因为 UI 测试需要能跑 UI 自动化的环境，而单元测试在哪儿
/// 都能跑 —— 契约破了要在这一层就响。
final class PaginationBarTests: XCTestCase {

    /// 页码框必须是真的、可编辑的文本框，并且不经过任何交互就显示当前页。
    @MainActor
    func testPageFieldIsAnEditableTextFieldShowingCurrentPage() throws {
        let fields = try textFields(inBarShowing: 2, of: 9)
        let field = try XCTUnwrap(fields.first, "分页条里没有文本框")
        XCTAssertEqual(field.stringValue, "2", "页码框应当直接显示当前页")
        XCTAssertTrue(field.isEditable, "页码框要能点进去改")
    }

    /// 只有一页时，话题列表整组藏起来（沿用改动前的行为），话题不藏。
    @MainActor
    func testControlsHideOnSinglePageOnlyWhenAsked() throws {
        XCTAssertTrue(
            try textFields(inBarShowing: 1, of: 1, hidesOnSinglePage: true).isEmpty,
            "话题列表只有一页时不该还留着翻页控件"
        )
        XCTAssertFalse(
            try textFields(inBarShowing: 1, of: 1, hidesOnSinglePage: false).isEmpty,
            "话题只有一页时仍然显示翻页控件"
        )
    }

    // MARK: - 辅助

    @MainActor
    private func textFields(
        inBarShowing currentPage: Int,
        of totalPages: Int,
        hidesOnSinglePage: Bool = false
    ) throws -> [NSTextField] {
        let bar = PaginationBar(
            currentPage: currentPage,
            totalPages: totalPages,
            isLoading: false,
            hidesControlsOnSinglePage: hidesOnSinglePage,
            identifierPrefix: "probe",
            subject: "话题列表",
            navigate: { _ in }
        ) {
            EmptyView()
        }

        let hosting = NSHostingView(rootView: AnyView(bar))
        hosting.frame = NSRect(x: 0, y: 0, width: 520, height: 40)
        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        hosting.layoutSubtreeIfNeeded()

        var found: [NSTextField] = []
        func walk(_ view: NSView) {
            if let field = view as? NSTextField, field.isEditable {
                found.append(field)
            }
            view.subviews.forEach(walk)
        }
        walk(hosting)
        return found
    }
}
