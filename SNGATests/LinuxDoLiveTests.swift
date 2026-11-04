import AppKit
import Foundation
@preconcurrency import WebKit
import XCTest
@testable import SNGA

/// Linux.do 接入前的生死线：WebView 登录拿到的会话，交给 `URLSession` 还认不认。
///
/// 背景见 `Design/SiteProbe-LinuxDo.md` 第一节：话题详情 `/t/{id}.json` 对匿名请求一律是
/// Cloudflare 挑战，连真浏览器都过不去；登录后的浏览器一路 200。应用的网络请求不走浏览器，
/// 走 `URLSession` —— 这条用例验的就是「把 WebView 的 cookie 和 UA 原样搬过去」够不够。
/// 够，就照 NodeSeek 的路子接；不够，话题页得整个交给 `WKWebView`，那是另一个量级的工作。
///
/// **不进自动化**：方法名不以 `test` 开头。要跑时临时改成 `test` 前缀单独跑：
///
///     xcodebuild … test -only-testing:SNGATests/LinuxDoLiveTests/testLiveSessionHandoffReachesTopicJSON
///
/// 跑起来会弹一个窗口，**由人在里面登录**（用户名密码、GitHub、通行密钥都行；Google 会被它
/// 自己拒绝，见文档第六节）。凭据只在那个窗口里，用例碰不到也不打印 —— 输出里只有状态码、
/// 字节数、cookie 的**名字**。只发 GET，不发任何写请求。
///
/// 窗口的配置和 `LoginWebView` 对 `.webView` UA 站点的配置一致：`.nonPersistent()`、
/// **一行 UA 都不设**（设了会改变客户端提示的上报方式，见 `WebViewUserAgent`）。
@MainActor
final class LinuxDoLiveTests: XCTestCase {
    private static let base = URL(string: "https://linux.do")!
    /// 等人登录的上限。通行密钥、二步验证都要时间，给宽一点。
    private static let loginTimeout: Duration = .seconds(300)

    func manualLiveSessionHandoffReachesTopicJSON() async throws {
        let (webView, window) = makeLoginWindow()
        defer { window.close() }

        let cookies = try await waitForSessionCookies(in: webView)
        let reportedUA = try await webView.evaluateJavaScript("navigator.userAgent")
        let userAgent = try XCTUnwrap(reportedUA as? String, "读不出 WebView 的 UA")
        print("登录完成。cookie 名字：\(cookies.map(\.name).sorted())")
        print("UA 长度 \(userAgent.count)")

        // 和应用里一模一样的传输：ephemeral、不用共享 cookie 容器、cookie 走显式请求头。
        let transport = URLSessionTransport()
        let jar = SessionCookieJar(cookies)

        // 第一步只拿列表，顺手取一个回复够多的话题编号，免得写死的话题哪天被删。
        let latest = try await fetchJSON("/latest.json", transport: transport, jar: jar, userAgent: userAgent)
        let topicList = try XCTUnwrap(latest["topic_list"] as? [String: Any])
        let topics = try XCTUnwrap(topicList["topics"] as? [[String: Any]])
        let topic = try XCTUnwrap(
            topics.first { ($0["posts_count"] as? Int ?? 0) > 40 && ($0["pinned"] as? Bool) != true }
                ?? topics.first,
            "列表里一个话题都没有"
        )
        let topicID = try XCTUnwrap(topic["id"] as? Int)

        // 生死线就是这一发。
        let detail = try await fetchJSON("/t/\(topicID).json", transport: transport, jar: jar, userAgent: userAgent)
        let stream = try XCTUnwrap((detail["post_stream"] as? [String: Any])?["stream"] as? [Int])
        XCTAssertFalse(stream.isEmpty, "话题拿到了，但楼层流是空的")

        // 翻页那一族也要过：第二页是按楼层编号批量取的，和详情不是同一个地址。
        if stream.count > 20 {
            let ids = stream[20..<min(40, stream.count)].map { "post_ids[]=\($0)" }.joined(separator: "&")
            let more = try await fetchJSON(
                "/t/\(topicID)/posts.json?\(ids)", transport: transport, jar: jar, userAgent: userAgent
            )
            let posts = (more["post_stream"] as? [String: Any])?["posts"] as? [Any]
            XCTAssertEqual(posts?.count, ids.split(separator: "&").count, "按编号取楼层没有给满")
        }

        // 会话真的被认出来了，而不只是「挑战放行了」—— 两件事分开验。
        let current = try await fetchJSON("/session/current.json", transport: transport, jar: jar, userAgent: userAgent)
        XCTAssertNotNil(current["current_user"], "请求过了挑战，但站点没认出这份会话")

        let csrf = try await fetchJSON("/session/csrf", transport: transport, jar: jar, userAgent: userAgent)
        XCTAssertNotNil(csrf["csrf"] as? String, "拿不到写请求要的 CSRF 令牌")
    }

    // MARK: - 登录窗口

    private func makeLoginWindow() -> (WKWebView, NSWindow) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 760), configuration: configuration)

        let window = NSWindow(
            contentRect: webView.frame,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "LinuxDoLiveTests：请登录 linux.do（登录后窗口自动关闭）"
        window.isReleasedWhenClosed = false
        window.contentView = webView
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        webView.load(URLRequest(url: Self.base.appending(path: "login")))
        return (webView, window)
    }

    /// 等到 `_t`（Discourse 的登录令牌）出现，再交出这个域下的**全部** cookie。
    ///
    /// 全收而不是挑几个：NodeSeek 上只带 `session` + `cf_clearance` 就会被挑战，
    /// 少带一个的失败和「这条路不通」长得一模一样。
    private func waitForSessionCookies(in webView: WKWebView) async throws -> [SessionCookie] {
        let store = webView.configuration.websiteDataStore.httpCookieStore
        let deadline = ContinuousClock.now + Self.loginTimeout
        let isSiteCookie: (HTTPCookie) -> Bool = { cookie in
            let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return domain == "linux.do" || domain.hasSuffix(".linux.do")
        }
        while ContinuousClock.now < deadline {
            let site = await store.allCookies().filter(isSiteCookie)
            if site.contains(where: { $0.name == "_t" && !$0.value.isEmpty }) {
                // 登录跳转后站点可能还会再换发一轮 cookie，等它落定再取。
                try await Task.sleep(for: .seconds(3))
                return await store.allCookies().filter(isSiteCookie).map(SessionCookie.init)
            }
            try await Task.sleep(for: .seconds(1))
        }
        throw XCTSkip("五分钟内没有完成登录")
    }

    // MARK: - 请求

    private func fetchJSON(
        _ pathAndQuery: String,
        transport: URLSessionTransport,
        jar: SessionCookieJar,
        userAgent: String
    ) async throws -> [String: Any] {
        let url = try XCTUnwrap(URL(string: pathAndQuery, relativeTo: Self.base)?.absoluteURL)
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(jar.header(for: url), forHTTPHeaderField: "Cookie")

        let (data, response) = try await transport.data(for: request)
        let headers = response.allHeaderFields.reduce(into: [String: String]()) {
            $0[String(describing: $1.key)] = String(describing: $1.value)
        }
        let challenged = CloudflareChallenge.isChallenge(
            status: response.statusCode, headers: headers, body: data, expectedJSON: true
        )
        // 只打路径（话题编号是公开的）、状态码和字节数，不打任何正文。
        print("[\(url.path)] \(response.statusCode) bytes=\(data.count) challenge=\(challenged)")

        XCTAssertFalse(challenged, "\(url.path) 被 Cloudflare 挑战了 —— 会话搬不过来")
        XCTAssertEqual(response.statusCode, 200, "\(url.path)")
        return try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any],
            "\(url.path) 不是 JSON 对象"
        )
    }
}
