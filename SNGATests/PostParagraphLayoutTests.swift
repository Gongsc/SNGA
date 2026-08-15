import AppKit
import SwiftData
import SwiftUI
import XCTest
@testable import SNGA

/// 段落必须按「它被测量时的宽度」排版。
///
/// 两者一旦对不上，文字就按另一个宽度折行：右边空出一片，画出来又比上报的高度
/// 更高，压住下面的图片、把表情挤出楼层边框。这个不变量只能在真实的宿主视图里
/// 验证 —— 差异出在 SwiftUI 拿哪些候选宽度来问尺寸，而那要有真正的布局过程。
final class PostParagraphLayoutTests: XCTestCase {
    private let parser = NGAParser()

    private struct Measurement {
        let boundsWidth: CGFloat
        let layoutWidth: CGFloat
        let assignedHeight: CGFloat
        let requiredHeight: CGFloat
    }

    @MainActor
    private func layOutFloors(
        raw: String,
        lazyStack: Bool,
        hostWidth: CGFloat
    ) throws -> [Measurement] {
        let sanitized = parser.sanitizedPost(raw)
        let content = try XCTUnwrap(sanitized.nativeContent, "这段应当走原生渲染")
        let post = Post(
            id: PostID(rawValue: 1),
            topicID: TopicID(rawValue: 1),
            floor: 1,
            author: "测试用户",
            authorUID: 1001,
            postedAt: Date(timeIntervalSince1970: 1_785_000_000),
            html: sanitized.html,
            nativeContent: content
        )
        let model = AppModel(
            container: try ModelContainer(
                for: AccountRecord.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true)
            )
        )
        let row = PostRow(
            post: post,
            topicRating: nil,
            loadOrder: 0,
            reply: {},
            openPost: { _, _ in },
            openInternalLink: { _ in }
        )
        .environment(model)

        let root = ScrollView {
            Group {
                if lazyStack {
                    LazyVStack(spacing: 12) {
                        ForEach(0..<3, id: \.self) { _ in row }
                    }
                } else {
                    VStack(spacing: 12) {
                        ForEach(0..<3, id: \.self) { _ in row }
                    }
                }
            }
            .padding()
        }

        let hosting = NSHostingView(rootView: AnyView(root))
        hosting.frame = NSRect(x: 0, y: 0, width: hostWidth, height: 700)
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

        var result: [Measurement] = []
        func walk(_ view: NSView) {
            if let text = view as? PostParagraphTextView {
                // 排版宽度要在测高之前读：height(fittingWidth:) 之后就说明不了问题了。
                let layoutWidth = text.textContainer?.size.width ?? -1
                result.append(
                    Measurement(
                        boundsWidth: text.bounds.width,
                        layoutWidth: layoutWidth,
                        assignedHeight: text.bounds.height,
                        requiredHeight: text.height(fittingWidth: text.bounds.width)
                    )
                )
            }
            view.subviews.forEach(walk)
        }
        walk(hosting)
        XCTAssertFalse(result.isEmpty, "没有量到任何段落")
        return result
    }

    /// 长到必须折行的正文，配一张独占一行的图片和一个表情 —— 出问题的楼层就是这个形状。
    private static let raw = """
    这一段本身就很长，长到在窗口里放不下必须自动折行，折行之后下面还跟着一行独立的文字，所以这里要一直写到超过一行为止。这一行带表情[s:ac:茶]，后面还要再写一些字把它撑长。
    <img src="https://img.nga.cn/probe.jpg" width="635" height="400">
    这一段同样要长到折行，用来看图片下面那一段有没有被按另一个宽度排版。
    """

    /// 表情是行内附件，图片到达后那一行会比普通行高得多；这一条确认它撑高之后
    /// 仍然待在楼层里，不会画到边框外面去。
    @MainActor
    func testLoadedEmoticonStaysInsideTheFloor() throws {
        let raw = "这一行带表情[s:ac:茶]，后面还要再写一些字把它撑长到需要折行为止，好让附件落在中间那一行上。"
        let url = try XCTUnwrap(
            firstEmoticonURL(in: try XCTUnwrap(parser.sanitizedPost(raw).nativeContent)),
            "这段里应当有一个表情"
        )
        StubImageProtocol.reset()
        StubImageProtocol.stub(url, data: try Self.pngData(width: 200, height: 200))
        URLProtocol.registerClass(StubImageProtocol.self)
        defer {
            URLProtocol.unregisterClass(StubImageProtocol.self)
            StubImageProtocol.reset()
        }

        // 先把表情图取到手，排版时就不必再等异步下载。
        let deadline = Date().addingTimeInterval(5)
        while EmoticonImageStore.shared.image(for: url) == nil, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertNotNil(EmoticonImageStore.shared.image(for: url), "表情图没能加载")

        for measurement in try layOutFloors(raw: raw, lazyStack: false, hostWidth: 900) {
            XCTAssertEqual(
                measurement.layoutWidth,
                measurement.boundsWidth,
                accuracy: 0.5,
                "带表情的段落排版宽度和视图宽度不一致"
            )
            XCTAssertLessThanOrEqual(
                measurement.requiredHeight,
                measurement.assignedHeight + 0.5,
                "表情撑高之后段落画出了楼层边框"
            )
        }
    }

    private func firstEmoticonURL(in content: PostContent) -> URL? {
        func search(_ blocks: [PostBlock]) -> URL? {
            for block in blocks {
                switch block {
                case let .paragraph(paragraph):
                    for segment in paragraph.segments {
                        if case let .emoticon(url) = segment { return url }
                    }
                case let .quote(nested):
                    if let url = search(nested) { return url }
                case .image:
                    continue
                }
            }
            return nil
        }
        return search(content.blocks)
    }

    private static func pngData(width: Int, height: Int) throws -> Data {
        let representation = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: representation)
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        return try XCTUnwrap(representation.representation(using: .png, properties: [:]))
    }

    @MainActor
    func testParagraphLaysOutAtTheWidthItWasMeasuredFor() throws {
        for lazyStack in [true, false] {
            for hostWidth in [900.0, 640.0] as [CGFloat] {
                let shape = lazyStack ? "按需" : "整页"
                for measurement in try layOutFloors(
                    raw: Self.raw,
                    lazyStack: lazyStack,
                    hostWidth: hostWidth
                ) {
                    XCTAssertEqual(
                        measurement.layoutWidth,
                        measurement.boundsWidth,
                        accuracy: 0.5,
                        "\(shape)/\(hostWidth)：排版宽度和视图宽度不一致，文字会按另一个宽度折行"
                    )
                    XCTAssertLessThanOrEqual(
                        measurement.requiredHeight,
                        measurement.assignedHeight + 0.5,
                        "\(shape)/\(hostWidth)：段落画出来比分到的高度更高，会压住下面的内容"
                    )
                }
            }
        }
    }
}
