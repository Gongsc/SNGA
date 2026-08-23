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
                for: Schema([AccountRecord.self, AIProfileSummaryRecord.self]),
                configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
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

/// 引用抬头必须和被引正文分开。
///
/// 抬头和被引正文在解析后共用同一个段落（中间只隔一个空行），不切开的话整块
/// 引用就是一大段等粗等大的文字，读者分不出哪句是被引的、哪句是抬头。
/// 切分靠的是「段首连续加粗片段 + 其中带 `[pid]` 回链」这个特征，因此还要保证
/// 它不会误伤作者自己写的粗体开头。
final class QuoteAttributionTests: XCTestCase {
    private let parser = NGAParser()

    func testAttributionSplitsFromQuotedBody() throws {
        let nested = try quoteBlocks(
            of: "[quote][b]Reply to [pid=123,456,0]Reply[/pid] Post by [uid=789]locked315[/uid] (2026-07-22 19:59)[/b]<br/><br/>买个普通的过渡一下就行[/quote]已经逐步推出了"
        )
        let split = QuoteAttribution.split(nested)

        let attribution = try XCTUnwrap(split.attribution, "带回链的抬头应当被切出来")
        XCTAssertEqual(
            plainText(of: attribution.segments),
            "Reply to Reply Post by locked315 (2026-07-22 19:59)"
        )
        XCTAssertTrue(
            attribution.segments.contains { segment in
                guard case let .text(_, style) = segment else { return false }
                return style.link != nil
            },
            "抬头里的回链要留着，压小之后仍然点得开被引楼层"
        )
        XCTAssertEqual(
            plainText(of: split.body.flatMap(segments(of:))),
            "买个普通的过渡一下就行",
            "被引正文要落到 body，且段首不留分隔用的空行"
        )
    }

    /// 作者自己写的粗体开头没有回链，压成小字会把人家的正文吃掉一句。
    func testBoldOpeningWithoutPostReferenceStaysInBody() throws {
        let nested = try quoteBlocks(of: "[quote][b]重点[/b]<br/><br/>剩下的话[/quote]我的回复")
        let split = QuoteAttribution.split(nested)

        XCTAssertNil(split.attribution, "没有回链就不是抬头")
        XCTAssertEqual(split.body, nested, "不切分时 body 必须原样返回")
        XCTAssertEqual(plainText(of: split.body.flatMap(segments(of:))), "重点\n\n剩下的话")
    }

    func testQuoteWithoutAttributionIsUnchanged() throws {
        let nested = try quoteBlocks(of: "[quote]被引用的话[/quote]我的回复")
        let split = QuoteAttribution.split(nested)

        XCTAssertNil(split.attribution)
        XCTAssertEqual(split.body, nested)
    }

    /// 抬头只有回链、没有被引正文（`PostQuoteExpander` 取不到被引楼层时就是这样）：
    /// 抬头照样要切出来，body 允许为空，不能因此把抬头也丢掉。
    func testAttributionWithoutBodyStillSplits() throws {
        let nested = try quoteBlocks(
            of: "[quote][b]Reply to [pid=123,456,0]Reply[/pid] Post by [uid=789]locked315[/uid] (2026-07-22 19:59)[/b][/quote]我的回复"
        )
        let split = QuoteAttribution.split(nested)

        XCTAssertNotNil(split.attribution)
        XCTAssertEqual(plainText(of: split.body.flatMap(segments(of:))), "")
    }

    // MARK: - 辅助

    private func quoteBlocks(of source: String) throws -> [PostBlock] {
        let content = try XCTUnwrap(
            parser.sanitizedPost(source).nativeContent,
            "这段应当走原生渲染"
        )
        let nested = content.blocks.compactMap { block -> [PostBlock]? in
            guard case let .quote(children) = block else { return nil }
            return children
        }
        return try XCTUnwrap(nested.first, "正文里应当有一个引用块")
    }

    private func segments(of block: PostBlock) -> [PostSegment] {
        switch block {
        case let .paragraph(paragraph): paragraph.segments
        case let .quote(nested): nested.flatMap(segments(of:))
        case .image: []
        }
    }

    private func plainText(of segments: [PostSegment]) -> String {
        segments.reduce(into: "") { result, segment in
            if case let .text(value, _) = segment { result += value }
        }
    }
}
