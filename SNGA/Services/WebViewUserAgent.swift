import Foundation
import WebKit

/// 读出 `WKWebView` 自报的 User-Agent。
///
/// 有的站点不接受应用自报家门。NodeSeek 站前的 Cloudflare 会拿请求头里的 UA 去和页面 JS 环境
/// （`navigator.userAgentData`、`Sec-CH-UA`）交叉核对，而后者由 `WKWebView` 按它真实的引擎版本
/// 上报 —— 两边对不上，挑战就再发一次，永远勾不完。所以对这类站点，原生请求必须用**这个**值。
///
/// 一并要守的规矩：那种站点的登录 `WKWebView` **一行 UA 都不能设**。设置 UA 会把它标记为已覆盖
/// 并改变客户端提示的上报方式，**因此把它设成它本来就有的值也不是空操作**。
@MainActor
enum WebViewUserAgent {
    private static var cached: String?

    /// 取一次就记住：同一个进程里这个值不会变，而每次问都要建一个 `WKWebView`。
    static func resolve() async -> String? {
        if let cached { return cached }
        let webView = WKWebView(frame: .zero)
        let result = try? await webView.evaluateJavaScript("navigator.userAgent")
        guard let value = result as? String, !value.isEmpty else { return nil }
        cached = value
        return value
    }

    /// 测试用：清掉缓存，让下一次重新读。
    static func resetForTesting() {
        cached = nil
    }
}
