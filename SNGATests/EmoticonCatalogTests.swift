import XCTest
@testable import SNGA

/// 表情名单。
///
/// 名单是从站点的 JS 里抄来的死数据，值得逐条钉住的只有三件事：**短代码怎么拼**、
/// **图片地址怎么拼**、**插进正文的是什么**。这三样错一样，发出去的回复就是一串
/// 没人认识的字。
final class EmoticonCatalogTests: XCTestCase {

    private func nodeSeekPack(_ id: String) throws -> EmoticonPack {
        try XCTUnwrap(NodeSeekStickers.packs.first { $0.id == id }, "没有 \(id) 这一包")
    }

    // MARK: - NodeSeek

    /// 分包和条数照着站点的分组表。少一条就是面板上少一个格子。
    func testNodeSeekHasTheFourStickerPacksTheSiteShips() {
        XCTAssertEqual(NodeSeekStickers.packs.map(\.id), ["ac", "yct", "xhj", "emoji"])
        XCTAssertEqual(NodeSeekStickers.packs.map(\.title), ["AC娘", "洋葱头", "小黄鸡", "Fluent"])
        XCTAssertEqual(NodeSeekStickers.packs.map(\.emoticons.count), [149, 22, 32, 49])
    }

    /// 短代码 = 组名 + 去掉扩展名的文件名，编号的位数不能变 —— `ac1` 站点不认。
    func testAStickerCodeIsTheGroupNamePlusTheZeroPaddedNumber() throws {
        let ac = try nodeSeekPack("ac").emoticons

        XCTAssertEqual(ac.first?.id, "ac01")
        // AC 娘分三段编号，后两段是四位数。
        XCTAssertEqual(ac[54].id, "ac1001")
        XCTAssertEqual(ac.last?.id, "ac2055")
    }

    /// 插进正文的是短代码，两侧各带一个空格 —— 站点自己插的就是这个。
    func testTheInsertedTextIsTheShortcodeWithTheSitesOwnPadding() throws {
        XCTAssertEqual(try nodeSeekPack("ac").emoticons.first?.insertion, " :ac01: ")
    }

    /// 扩展名是逐个文件定的，不是逐包定的：小黄鸡这组 png 和 gif 混着排，
    /// 按包套一个扩展名会有一半变成 404。
    func testStickerFileExtensionsFollowTheFileNotThePack() throws {
        let xhj = try nodeSeekPack("xhj").emoticons

        XCTAssertEqual(
            xhj.first?.previewURL.absoluteString,
            "https://www.nodeseek.com/static/image/sticker/xhj/001.png"
        )
        XCTAssertEqual(
            xhj[3].previewURL.absoluteString,
            "https://www.nodeseek.com/static/image/sticker/xhj/004.gif"
        )
    }

    /// Fluent 那组正文里是 webm/mov，选择器和预览一律取同名 PNG。
    /// 取成 webm，选择器里就是一格空白。
    func testTheVideoPackFallsBackToItsPosterImage() throws {
        let fluent = try nodeSeekPack("emoji").emoticons

        XCTAssertEqual(fluent.first?.id, "emoji00")
        XCTAssertEqual(
            fluent.first?.previewURL.absoluteString,
            "https://www.nodeseek.com/static/image/sticker/emoji/00.png"
        )
        XCTAssertEqual(fluent.first?.insertion, " :emoji00: ")
    }

    /// 预览的索引要盖住每一张，否则那几张在预览里会以短代码的样子留着。
    func testThePreviewIndexCoversEveryStickerInEveryPack() {
        let all = NodeSeekStickers.packs.flatMap(\.emoticons)

        XCTAssertEqual(NodeSeekStickers.index.count, all.count)
        for emoticon in all {
            XCTAssertEqual(NodeSeekStickers.index[emoticon.id], emoticon.previewURL, emoticon.id)
        }
    }

    /// 名字就叫 `xhj017`，搜不出名堂 —— 选择器据此不画搜索框。
    func testNodeSeekPacksDoNotOfferSearch() {
        XCTAssertTrue(NodeSeekStickers.packs.allSatisfy { !$0.isSearchable })
    }

    // MARK: - NGA

    /// NGA 那套走的是 UBB 代码，不带空格：`[s:ac:茶]` 紧贴前后文。
    func testNGAEmoticonsInsertTheirUBBCode() throws {
        let pack = try XCTUnwrap(EmoticonPack.nga.first)

        XCTAssertEqual(pack.emoticons.count, NGAEmoticon.common.count)
        XCTAssertTrue(pack.isSearchable, "NGA 的表情有中文名，搜得动")
        let tea = try XCTUnwrap(pack.emoticons.first { $0.title == "茶" })
        XCTAssertEqual(tea.insertion, "[s:ac:茶]")
        XCTAssertEqual(
            tea.previewURL.absoluteString,
            "https://img4.nga.cn/ngabbs/post/smile/ac39.png"
        )
    }

    // MARK: - 站点资料

    /// 两个站都得有表情，否则编辑器上那个按钮就不画了。
    func testBothSitesExposeTheirPacksThroughTheSiteDescriptor() {
        XCTAssertEqual(ForumSiteDescriptor.nga.emoticonPacks.map(\.id), ["ac"])
        XCTAssertEqual(
            ForumSiteDescriptor.nodeseek.emoticonPacks.map(\.id),
            ["ac", "yct", "xhj", "emoji"]
        )
    }

    /// 回复预览这条链路整个走一遍：短代码换成图，外面还得包上文档外壳。
    ///
    /// 少了外壳，预览是没有样式的一段裸 HTML —— 深色下黑字黑底，表情也不受
    /// `.sticker` 那条 120px 的上限约束。
    func testTheNodeSeekPreviewRendersStickersInsideAStyledDocument() {
        let html = ForumSiteDescriptor.nodeseek.sanitizedPreviewHTML("行 :ac01: 了")

        XCTAssertTrue(html.hasPrefix("<!doctype html>"), String(html.prefix(80)))
        XCTAssertTrue(html.contains(".sticker{max-width"), "样式表没带上")
        XCTAssertTrue(
            html.contains("https://www.nodeseek.com/static/image/sticker/ac/01.png"),
            "短代码没换成图"
        )
    }
}
