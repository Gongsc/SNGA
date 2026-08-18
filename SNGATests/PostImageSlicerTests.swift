import AppKit
import XCTest
@testable import SNGA

/// 很高的图必须切段再画。
///
/// 一个 `Image` 就是一个和整图一样高的图层，Core Animation 要为整张备下绘制缓冲：
/// 1080×16000 的长截图实测 206 MB，切成段放进 `LazyVStack` 之后只剩 1 MB。
/// 这里守两件事：切出来的段要严丝合缝地铺满原图，显示高度加起来要正好等于版面高度。
@MainActor
final class PostImageSlicerTests: XCTestCase {
    func testShortImageStaysOnePiece() throws {
        let slices = PostImageSlicer.slices(of: try Self.image(width: 800, height: 600))
        XCTAssertEqual(slices.count, 1)
        XCTAssertEqual(slices.first?.pixelRange, 0..<600)
    }

    func testTallImageIsSplitIntoBoundedPieces() throws {
        let height = 16000
        let slices = PostImageSlicer.slices(of: try Self.image(width: 1080, height: height))
        XCTAssertGreaterThan(slices.count, 1)
        for slice in slices {
            XCTAssertLessThanOrEqual(
                slice.pixelRange.count,
                PostImageSlicer.maximumSlicePixels,
                "单段过高就失去了切段的意义"
            )
        }
    }

    /// 段之间不能有缝，也不能重叠 —— 缝会画出白线，重叠会把内容画重。
    func testPiecesTileTheImageExactly() throws {
        let height = 16000
        let slices = PostImageSlicer.slices(of: try Self.image(width: 1080, height: height))
        XCTAssertEqual(slices.first?.pixelRange.lowerBound, 0)
        XCTAssertEqual(slices.last?.pixelRange.upperBound, height)
        for (previous, next) in zip(slices, slices.dropFirst()) {
            XCTAssertEqual(previous.pixelRange.upperBound, next.pixelRange.lowerBound)
        }
        XCTAssertEqual(slices.reduce(0) { $0 + $1.pixelRange.count }, height)
    }

    /// 逐段取整会攒出误差，几十段下来就能把版面顶歪几点。
    func testDisplayHeightsSumToTheReservedHeight() throws {
        let height = 16000
        let slices = PostImageSlicer.slices(of: try Self.image(width: 1080, height: height))
        let total: CGFloat = 8443
        let sum = slices.reduce(CGFloat.zero) { partial, slice in
            partial + PostImageSlicer.displayHeight(
                of: slice,
                totalHeight: total,
                pixelHeight: height
            )
        }
        XCTAssertEqual(sum, total, accuracy: 0.001)
    }

    /// `CGImage` 的原点在左上角。搞反了图片会上下颠倒地拼起来，
    /// 而且是那种一眼看不出是代码问题的错。
    func testFirstPieceComesFromTheTopOfTheImage() throws {
        let image = try Self.twoToneImage(width: 40, height: 4000)
        let slices = PostImageSlicer.slices(of: image)
        XCTAssertGreaterThan(slices.count, 1)

        let firstPiece = try XCTUnwrap(slices.first?.image)
        let lastPiece = try XCTUnwrap(slices.last?.image)
        XCTAssertEqual(try Self.averageIsRed(firstPiece), true, "第一段应当是原图顶部的红色")
        XCTAssertEqual(try Self.averageIsRed(lastPiece), false, "最后一段应当是原图底部的蓝色")
    }

    // MARK: - 辅助

    private static func image(width: Int, height: Int) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(NSColor.systemTeal.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }

    /// 上半红、下半蓝。`CGContext` 的原点在左下角，所以红色画在上半要用高 y。
    private static func twoToneImage(width: Int, height: Int) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: height / 2, width: width, height: height - height / 2))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height / 2))
        return try XCTUnwrap(context.makeImage())
    }

    /// `NSImage(cgImage:size:)` 存的不是 `NSBitmapImageRep`，取不到像素，
    /// 只能把它画进一个 1×1 的上下文再读回来。
    private static func averageIsRed(_ image: NSImage) throws -> Bool {
        var rect = CGRect(origin: .zero, size: image.size)
        let cgImage = try XCTUnwrap(image.cgImage(forProposedRect: &rect, context: nil, hints: nil))
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.interpolationQuality = .low
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let pixel = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        return pixel[0] > pixel[2]
    }
}
