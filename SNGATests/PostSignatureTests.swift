import XCTest
@testable import SNGA

/// 楼层末尾那份签名档：从哪儿读出来、清洗成什么样、界面按谁的说法称呼它。
final class PostSignatureTests: XCTestCase {

    private let parser = NGAParser()

    private func response(
        _ payload: String,
        contentType: String = "application/json; charset=utf-8"
    ) -> NGAHTTPResponse {
        NGAHTTPResponse(
            data: Data(payload.utf8),
            statusCode: 200,
            headers: ["Content-Type": contentType],
            url: URL(string: "https://bbs.nga.cn/read.php?tid=101")!
        )
    }

    /// NGA 把签名跟着话题页一起下发，藏在 `__U` 的用户记录里。
    ///
    /// 解析阶段只把 UBB 原文原样带出来，清洗留给 `NGAForumService` —— 那边按原文
    /// 去重，同一个人回十层也只渲染一次。
    func testThreadPageCarriesTheAuthorSignatureAsRawUBB() throws {
        let payload = #"""
        {"data":{
          "__T":{"tid":101,"fid":-7,"subject":"测试主题","author":"Alice","replies":0},
          "__U":{"1":{"uid":1,"username":"Alice","signature":"[b]签名正文[/b]"}},
          "__R":[{"pid":201,"tid":101,"lou":0,"authorid":1,"content":"<p>正文</p>"}]
        }}
        """#

        let thread = try parser.threadPage(
            from: response(payload),
            topicID: TopicID(rawValue: 101),
            page: 1
        )

        XCTAssertEqual(thread.posts.first?.signature?.html, "[b]签名正文[/b]")
        XCTAssertNil(
            thread.posts.first?.signature?.nativeContent,
            "解析阶段还没清洗，这时候不该有原生结构"
        )
    }

    /// 签名带的标记必须原样留住。
    ///
    /// `__U` 里的签名实测是混着来的：有的是已渲染的 HTML，有的是 UBB 原文，有的两样
    /// 都有（一页 18 条用户记录里 4 条非空，四种形状占了三种）。用户记录上别的字符串
    /// 字段都走 `nonEmptyString`，而那个会调 `plainText` 把标记拍平 —— 拿它读签名，
    /// `<br>` 会没掉，多行签名挤成一行，`[url]` 只剩一对方括号。
    func testTheSignatureKeepsItsMarkupInsteadOfBeingFlattened() throws {
        let payload = #"""
        {"data":{
          "__T":{"tid":101,"fid":-7,"subject":"测试主题","author":"Alice","replies":0},
          "__U":{
            "1":{"uid":1,"username":"Alice","signature":"第一行<br>第二行[b]加粗[/b]"},
            "2":{"uid":2,"username":"Bob","signature":null}
          },
          "__R":[
            {"pid":201,"tid":101,"lou":0,"authorid":1,"content":"正文一"},
            {"pid":202,"tid":101,"lou":1,"authorid":2,"content":"正文二"}
          ]
        }}
        """#

        let thread = try parser.threadPage(
            from: response(payload),
            topicID: TopicID(rawValue: 101),
            page: 1
        )

        XCTAssertEqual(
            thread.posts.first?.signature?.html,
            "第一行<br>第二行[b]加粗[/b]",
            "标记被拍平了：签名进的是正文那条渲染管线，原文要原样交过去"
        )
        // 大多数人没写签名，站点给的是 null 而不是缺这个键。
        XCTAssertNil(thread.posts.last?.signature)
    }

    /// 同一份东西在话题页里叫 `signature`、在资料接口里叫 `sign`，两个都要认。
    func testTheAlternateSpellingOfTheSignatureFieldIsAccepted() throws {
        let payload = #"""
        {"data":{
          "__T":{"tid":101,"fid":-7,"subject":"测试主题","author":"Alice","replies":0},
          "__U":{"1":{"uid":1,"username":"Alice","sign":"另一种写法"}},
          "__R":[{"pid":201,"tid":101,"lou":0,"authorid":1,"content":"<p>正文</p>"}]
        }}
        """#

        let thread = try parser.threadPage(
            from: response(payload),
            topicID: TopicID(rawValue: 101),
            page: 1
        )

        XCTAssertEqual(thread.posts.first?.signature?.html, "另一种写法")
    }

    /// 作者没写签名时不该凭空造一个：楼层里那条分割线是按 `signature` 有没有画的。
    func testAuthorsWithoutASignatureGetNone() throws {
        let payload = #"""
        {"data":{
          "__T":{"tid":101,"fid":-7,"subject":"测试主题","author":"Alice","replies":0},
          "__U":{"1":{"uid":1,"username":"Alice","signature":""}},
          "__R":[{"pid":201,"tid":101,"lou":0,"authorid":1,"content":"<p>正文</p>"}]
        }}
        """#

        let thread = try parser.threadPage(
            from: response(payload),
            topicID: TopicID(rawValue: 101),
            page: 1
        )

        XCTAssertNil(thread.posts.first?.signature)
    }

    /// 网页版那条路：签名在 `#postsigncontent{楼层}` 里，和正文的
    /// `#postcontent{楼层}` 同一个序号。结构照着真实页面写，内容换成无关的字。
    ///
    /// 结构化响应取不到时才会走到这里（见 `NGAForumService.threadPage`），
    /// 但走到了就不该把签名丢了。
    func testTheHTMLThreadPageReadsTheSignatureBlock() throws {
        let html = """
        <html><body><table><tr class="postrow" id="post0">
          <a name="l0"></a>
          <td class="c2">
            <span id="postcontent0" class="postcontent ubbcode">楼层正文</span>
            <div id="postsign0" class=" postsignC">
              <span class="sigline"><span class="en_font xtxt">BBS.NGA.CN</span></span>
              <div class="sign ubbcode" id="postsigncontent0"         style="max-height: 300px; overflow: hidden;">签名第一行<br><br>签名第二行        <div class="clear"></div>        <img src="about:blank" style="display:none" onerror="ubbcode.copyChk(this)"></div>
              <div class="clear"></div>
            </div>
          </td>
        </tr></table></body></html>
        """

        let page = try parser.threadPage(
            from: response(html, contentType: "text/html; charset=utf-8"),
            topicID: TopicID(rawValue: 101),
            page: 1
        )

        let signature = try XCTUnwrap(page.posts.first?.signature)
        XCTAssertTrue(signature.html.contains("签名第一行"))
        XCTAssertTrue(signature.html.contains("签名第二行"))
        // 网页版自己画的那条 BBS.NGA.CN 横线不要 —— 客户端用 `Divider` 代替。
        XCTAssertFalse(signature.html.contains("BBS.NGA.CN"))
        // 撑高度的空 div 和触发复制检查的假图都是网页版自用的，留着只会让
        // `PostContentBuilder` 多还原一个空段落。
        XCTAssertFalse(signature.html.contains("class=\"clear\""))
        XCTAssertFalse(signature.html.contains("about:blank"))
    }

    /// 签名和正文走同一条管线：UBB 渲染成 HTML，能原生还原的顺带给出结构。
    ///
    /// 另外要带上签名自己那份样式 —— 回退到 `WKWebView` 时，字号只能由样式表说。
    func testTheServiceRendersSignaturesThroughThePostPipeline() async throws {
        let payload = #"""
        {"data":{
          "__T":{"tid":101,"fid":-7,"subject":"测试主题","author":"Alice","replies":0},
          "__U":{"1":{"uid":1,"username":"Alice","signature":"[b]签名正文[/b]"}},
          "__R":[
            {"pid":201,"tid":101,"lou":0,"authorid":1,"content":"正文一"},
            {"pid":202,"tid":101,"lou":1,"authorid":1,"content":"正文二"}
          ]
        }}
        """#
        let service = NGAForumService(
            accountID: AccountID(),
            cookies: [],
            transport: RecordingHTTPTransport(responding: payload)
        )

        let thread = try await service.threadPage(
            topicID: TopicID(rawValue: 101),
            page: 1,
            authorUID: nil
        )

        let signature = try XCTUnwrap(thread.posts.first?.signature)
        XCTAssertTrue(
            signature.html.contains("<strong>签名正文</strong>"),
            "UBB 应该已经渲染成 HTML：\(signature.html)"
        )
        XCTAssertTrue(
            signature.html.contains("font-size:12px"),
            "签名的样式表没进文档，回退到 WebView 时它会和正文一样大"
        )
        XCTAssertEqual(
            signature.nativeContent,
            PostContent(blocks: [
                .paragraph(PostParagraph(segments: [
                    .text("签名正文", PostTextStyle(isBold: true))
                ]))
            ])
        )
        // 同一个作者的两层楼拿到的是同一份渲染结果。
        XCTAssertEqual(thread.posts.count, 2)
        XCTAssertEqual(thread.posts.last?.signature, signature)
    }

    // MARK: - NodeSeek

    private func nodeSeekThread(fixture: String) throws -> ThreadPage {
        let url = try XCTUnwrap(
            Bundle(for: PostSignatureTests.self)
                .url(forResource: fixture, withExtension: "html")
        )
        return try NodeSeekParser().threadPage(
            html: try String(contentsOf: url, encoding: .utf8),
            topicID: TopicID(rawValue: 800_001),
            page: 1
        )
    }

    /// NodeSeek 把签名渲染成楼层里的 `div.signature`，是一段带链接的 HTML。
    ///
    /// 和资料里的 `bio` 不是一回事 —— 那个站点只画在悬停的用户卡片上，而且是纯文本。
    func testNodeSeekReadsTheSignatureFromTheThreadPage() throws {
        let thread = try nodeSeekThread(fixture: "nodeseek-post-signature")

        let signature = try XCTUnwrap(thread.posts.first?.signature)
        XCTAssertTrue(signature.html.contains("TG"))
        XCTAssertTrue(signature.html.contains("我写过的帖子"))
        // 没写签名的作者不该多出一条分割线。
        XCTAssertNil(thread.posts.last?.signature)
    }

    /// 签名里的链接要能点。站内的两条得是绝对地址，导航层才认得出它们是站内的。
    func testTheNodeSeekSignatureKeepsItsLinksAndResolvesThemToAbsoluteURLs() throws {
        let thread = try nodeSeekThread(fixture: "nodeseek-post-signature")
        let signature = try XCTUnwrap(thread.posts.first?.signature)
        let content = try XCTUnwrap(
            signature.nativeContent,
            "一行链接应该能原生还原，不该为它再开一个 WKWebView"
        )

        let links = content.blocks.flatMap { block -> [URL] in
            guard case let .paragraph(paragraph) = block else { return [] }
            return paragraph.segments.compactMap { segment in
                guard case let .text(_, style) = segment else { return nil }
                return style.link
            }
        }
        XCTAssertEqual(links.count, 3, "三条链接一条都不能掉")
        XCTAssertTrue(links.contains { $0.absoluteString == "https://example.com/chat" })

        // 站内那两条要被导航层认出来，而不是丢给浏览器。
        let descriptor = ForumSiteDescriptor.nodeseek
        let internalLinks = links.filter { descriptor.internalDestination(for: $0) != nil }
        XCTAssertFalse(
            internalLinks.isEmpty,
            "站内链接没被认出来，点了会跳去浏览器：\(links.map(\.absoluteString))"
        )
    }

    /// 签名摘走之后正文里就不能再有它。
    ///
    /// 站点的楼层结构里，签名紧挨着正文；不摘干净就会出现同一段签名既画在楼层末尾、
    /// 又粘在正文后面。
    func testTheNodeSeekSignatureIsNotAlsoLeftInTheBody() throws {
        let thread = try nodeSeekThread(fixture: "nodeseek-post-signature")
        let post = try XCTUnwrap(thread.posts.first)

        XCTAssertTrue(post.html.contains("这一层的作者写了签名"), "前提：正文还在")
        XCTAssertFalse(post.html.contains("我写过的帖子"))
        XCTAssertFalse(post.html.contains("signature"))
    }

    /// 签名长在 `article.post-content` 里面的那种排法也不能重复画。
    ///
    /// 站点两种排法哪一种都可能，而使用者贴出来的那份元素看不出它的父节点是谁，
    /// 所以两种都得对：按 `.content-item` 找，找到就摘走。
    func testANestedNodeSeekSignatureIsStillHoistedOutOfTheBody() throws {
        let html = """
        <html><body><div class="nsk-post-wrapper"><div class="nsk-post">
        <div class="post-title"><h1><a href="/post-800001-1" class="post-title-link">标题</a></h1></div>
        <div id="0" data-comment-id="11000001" class="content-item">
          <div class="nsk-content-meta-info"><div class="author-info">
            <a href="/space/10001" class="author-name">甲用户</a></div></div>
          <article class="post-content"><p>正文</p>
            <div class="signature"><p><a href="/post-800002-1">签名链接</a></p></div>
          </article>
        </div></div></div></body></html>
        """

        let thread = try NodeSeekParser().threadPage(
            html: html,
            topicID: TopicID(rawValue: 800_001),
            page: 1
        )
        let post = try XCTUnwrap(thread.posts.first)

        XCTAssertNotNil(post.signature)
        XCTAssertTrue(post.html.contains("正文"))
        XCTAssertFalse(post.html.contains("签名链接"))
    }

    /// 资料接口只给一段纯文本（NGA 的 `sign` 已拍平，NodeSeek 的 `bio` 本来就是）。
    /// 纯文本必定能原生还原，但兜底的 HTML 也得转义 —— 签名是别人写的。
    func testAPlainTextSignatureIsEscapedAndNativelyRenderable() {
        let signature = PostSignature(plainText: "<script>alert(1)</script> & 收工")

        XCTAssertFalse(signature.html.contains("<script>"))
        XCTAssertTrue(signature.html.contains("&lt;script&gt;"))
        XCTAssertTrue(signature.html.contains("&amp;"))
        XCTAssertEqual(
            signature.nativeContent,
            PostContent(blocks: [
                .paragraph(PostParagraph(segments: [
                    .text("<script>alert(1)</script> & 收工", PostTextStyle())
                ]))
            ]),
            "原生结构里存的是原文，转义只是给 HTML 兜底那一份用的"
        )
    }

    /// 资料页上那一栏按站点自己的说法称呼。
    ///
    /// NodeSeek 的 `bio` 站点写的是「个人简介」，而且和楼层签名是两份东西 ——
    /// 叫成「签名」会让人以为改了它楼层里就会变。
    func testTheProfileSectionUsesEachSitesOwnWording() {
        XCTAssertEqual(ForumSiteDescriptor.nga.profileSignatureTitle, "签名")
        XCTAssertEqual(ForumSiteDescriptor.nodeseek.profileSignatureTitle, "个人简介")
    }

    /// 资料里的个人简介要带 `readme=1` 才有。它进用户中心那一栏，不进楼层。
    func testNodeSeekReadsTheProfileBio() throws {
        let url = try XCTUnwrap(
            Bundle(for: PostSignatureTests.self)
                .url(forResource: "nodeseek-account-info", withExtension: "json")
        )
        let profile = try NodeSeekParser().profile(json: try Data(contentsOf: url))

        XCTAssertEqual(profile.signature, "萌新mjj，努力学习中")
    }

    /// 开关默认是开的，和两个站点自己的网页一致。
    func testSignaturesAreShownUnlessTheReaderTurnsThemOff() {
        let defaults = UserDefaults.standard
        let key = BrowsingSettings.postSignatureKey
        let original = defaults.object(forKey: key)
        defer {
            if let original {
                defaults.set(original, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        defaults.removeObject(forKey: key)
        XCTAssertTrue(BrowsingSettings.showsPostSignature)

        defaults.set(false, forKey: key)
        XCTAssertFalse(BrowsingSettings.showsPostSignature)
    }
}
