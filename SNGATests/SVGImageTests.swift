import Foundation
import XCTest
@testable import SNGA

/// 一份数据是不是 SVG。
///
/// 认错的代价不对称，两个方向各有各的坏样子：
/// - **该认没认**：位图那条路接手。`NSImage` 会「成功」解出一张按 `ch` / `em`
///   当点数算出来的小画布（实测 74×46 点装一整份终端报告），放大之后是一团糊；
///   楼层里那条走 ImageIO 的路则干脆解不出来，图一直停在占位框上。
/// - **不该认认了**：一张位图被塞进 WebKit 当 SVG 文档加载，什么都画不出来。
final class SVGImageTests: XCTestCase {
    private let svgURL = URL(string: "https://report.check.place/ip/1L7P98BVF.svg")!
    private let pngURL = URL(string: "https://img.nga.cn/attachments/mon_202607/23/a.png")!
    private let extensionlessURL = URL(string: "https://img.example.com/8f3a2b")!

    /// 站点报了类型就按它说的算 —— 这是三道里最可靠的一道。
    func testTheResponseTypeIsTrusted() {
        let data = Data("不是标记".utf8)
        XCTAssertTrue(SVGImage.isSVG(data: data, mimeType: "image/svg+xml", url: extensionlessURL))
        // 带参数的写法也要认。
        XCTAssertTrue(
            SVGImage.isSVG(data: data, mimeType: "image/svg+xml; charset=utf-8", url: extensionlessURL)
        )
        XCTAssertTrue(SVGImage.isSVG(data: data, mimeType: "IMAGE/SVG+XML", url: extensionlessURL))
    }

    /// 没有类型就看后缀。
    func testTheExtensionIsTheSecondChance() {
        let data = Data("不是标记".utf8)
        XCTAssertTrue(SVGImage.isSVG(data: data, mimeType: nil, url: svgURL))
        XCTAssertTrue(
            SVGImage.isSVG(
                data: data,
                mimeType: "application/octet-stream",
                url: URL(string: "https://img.example.com/A.SVG")!
            )
        )
    }

    /// 类型和后缀都指望不上时看开头那一段。图床用
    /// `application/octet-stream` 发图、地址上又不带后缀，是常有的事。
    func testTheMarkupSniffIsTheLastChance() {
        let svg = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <svg width="74ch" height="46em" xmlns="http://www.w3.org/2000/svg"></svg>
        """.utf8)
        XCTAssertTrue(
            SVGImage.isSVG(data: svg, mimeType: "application/octet-stream", url: extensionlessURL)
        )
    }

    /// 位图不该被认成 SVG。PNG 的头几个字节是二进制魔数，撞不上 `<svg`。
    func testBitmapsAreNotMistakenForVectors() {
        var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        png.append(Data(repeating: 0x00, count: 512))
        XCTAssertFalse(SVGImage.isSVG(data: png, mimeType: "image/png", url: pngURL))
        XCTAssertFalse(SVGImage.isSVG(data: png, mimeType: nil, url: extensionlessURL))
    }

    /// 只看开头那 1 KB。一张正文里恰好夹着 `<svg` 三个字的大图不该被认走 ——
    /// 而真正的 SVG 的根元素必定在最前面。
    func testTheSniffOnlyLooksAtTheHead() {
        var data = Data(repeating: 0x00, count: 4096)
        data.append(Data("<svg>".utf8))
        XCTAssertFalse(SVGImage.looksLikeSVGMarkup(data))
    }

    /// 空数据什么都不是。
    func testEmptyDataIsNotSVG() {
        XCTAssertFalse(SVGImage.isSVG(data: Data(), mimeType: nil, url: extensionlessURL))
    }
}
