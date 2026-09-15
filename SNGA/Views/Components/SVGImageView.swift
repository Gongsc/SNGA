import AppKit
import SwiftUI
import WebKit

/// 一张 SVG 是不是 SVG，以及怎么把它画出来。
///
/// **AppKit 和 ImageIO 都画不了论坛上常见的那种 SVG。** 实测 NodeSeek 上到处
/// 贴的 IP 体检报告（`report.check.place/ip/*.svg`）：
///
/// - `CGImageSourceCreateWithData` 压根不认它 —— `CGImageSourceGetType` 返回 nil，
///   连尺寸都问不出来。楼层里那条原生配图的路走的正是 ImageIO，所以那边是**整张
///   图不出现**，不是画糊。
/// - `NSImage(data:)` 认，用的是私有的 `_NSSVGImageRep`，但它把根元素上的
///   `width="74ch" height="46em"` 当成点数：解出来是一张 **74×46 点**的画布，
///   里面却是一整份十四号字的终端报告。于是每一行叠在上一行上，`scaledToFit`
///   再把这团东西放大到满屏 —— 就是那块糊掉的灰。
///
/// 这两条都不是能绕过去的参数问题：那份 SVG 没有 `viewBox`，尺寸只写在 `ch` /
/// `em` 里，而 `ch` 要按字宽算、`em` 要按字号算，得先有一个排版引擎。WebKit 正好
/// 是一个 —— 浏览器里打开同一个地址就是对的，所以这里也交给它。
enum SVGImage {
    /// 这份数据是不是 SVG。
    ///
    /// 三道依次放宽：响应头说的、地址后缀、以及开头那一段里有没有 `<svg`。
    /// 最后一道是给那些用 `application/octet-stream` 发图、地址上又没有后缀的
    /// 图床准备的 —— 认漏了的后果是回到上面说的那两种坏样子。
    static func isSVG(data: Data, mimeType: String?, url: URL) -> Bool {
        if let mimeType,
           mimeType.lowercased().hasPrefix("image/svg") {
            return true
        }
        if url.pathExtension.lowercased() == "svg" {
            return true
        }
        return looksLikeSVGMarkup(data)
    }

    /// 开头那一段里有没有 `<svg`。
    ///
    /// 只看前 1 KB：SVG 的根元素必定在文件最前面（前面顶多有 XML 声明、
    /// DOCTYPE 和注释），而位图格式的头几个字节是二进制魔数，不会撞上这四个字符。
    static func looksLikeSVGMarkup(_ data: Data) -> Bool {
        let head = data.prefix(1024)
        guard let text = String(data: head, encoding: .utf8)
            ?? String(data: head, encoding: .isoLatin1) else {
            return false
        }
        return text.range(of: "<svg", options: .caseInsensitive) != nil
    }
}

/// 用 WebKit 画一张 SVG。
///
/// 缩放交给 WebKit 自己（`allowsMagnification`）：矢量图放大该是重新排一遍版，
/// 而不是把画好的位图拉大 —— 应用里那套 `scaleEffect` 缩放对位图够用，
/// 对这种一整页字的报告只会糊成一片。
struct SVGImageView: NSViewRepresentable {
    let data: Data
    /// 原图地址。只当作解析相对引用的基准，不会再去取一次。
    let baseURL: URL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // 论坛上的 SVG 是别人写的，规格上允许夹带 `<script>`。这里只要它画出来，
        // 不要它跑代码 —— 和楼层正文那张网页视图同一个设置。
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsMagnification = true
        // 底下是预览的黑底。SVG 自己带背景的（终端报告那种）照样盖得住，
        // 不带背景的则透出黑底，而不是凭空多一块白。
        webView.setValue(false, forKey: "drawsBackground")
        webView.loadHTMLString(Self.wrapper(for: data), baseURL: baseURL)
        return webView
    }

    /// 把 SVG 裹进一张只管居中和缩放的页面。
    ///
    /// 直接 `load(data:mimeType:"image/svg+xml")` 也画得对（两条都实测过，画面
    /// 逐像素一致），但那样它是一份**文档**：按自己的固有尺寸摆在左上角，比窗口
    /// 大就出滚动条，比窗口小就留一大片空。裹一层之后 `max-width/max-height`
    /// 负责缩到窗口里，flex 负责居中 —— 和位图那条路看起来是同一回事。
    ///
    /// 用 `<img>` 而不是把标记原样贴进 body，还顺手多一道边界：`<img>` 里的 SVG
    /// 在 WebKit 里既跑不了脚本，也取不了外部资源，连里面的链接都点不动。
    /// 论坛上的图是别人写的，少一条能出去的路就少一条。
    ///
    /// 页面自己不画底色（`drawsBackground` 也关着），透出的是预览那层黑 ——
    /// 自带黑底的终端报告照样盖得住，不带底的也不会凭空多一块白。
    private static func wrapper(for data: Data) -> String {
        """
        <!doctype html><meta charset="utf-8">
        <style>
        html,body{margin:0;height:100%}
        body{display:flex;align-items:center;justify-content:center}
        img{max-width:100%;max-height:100%}
        </style>
        <img src="data:image/svg+xml;base64,\(data.base64EncodedString())">
        """
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            // 灌进去的那张包装页是 `.other`，放行。
            //
            // 其余一律不在预览里跳转。`<img>` 里的 SVG 本来就点不动链接
            // （那份报告里真的有几条：抬头的项目地址、坐标那一行的地图），
            // JavaScript 也关着 —— 这道是兜底，万一哪天包装法改了，
            // 预览也不至于变成一个能跑到别的网站上去的浏览器。
            guard navigationAction.navigationType != .other else {
                decisionHandler(.allow)
                return
            }
            decisionHandler(.cancel)
            guard navigationAction.navigationType == .linkActivated,
                  let url = navigationAction.request.url else {
                return
            }
            NSWorkspace.shared.open(url)
        }
    }
}
