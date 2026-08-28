import Foundation

/// 楼层正文进 `WKWebView` 时套的那层文档。
///
/// 原本整份骨架 —— doctype、CSP、视口、`:root` 上的主题变量、正文字体 —— 都写死在
/// `NGAParser` 里。于是接第二个站点时，NodeSeek 的正文只有一段裸 body：没有字体、
/// 没有配色、连主题替换要认的那几个记号都没有，深色下就是白底黑字。
///
/// 抽出来之后两边共用同一层外壳，各自只补自己那份 CSS。
enum PostDocument {

    /// 把一段已经清洗过的正文包成完整文档。
    ///
    /// - Parameter extraCSS: 站点自己的样式，接在基础样式后面。同名规则后来的赢，
    ///   所以各站可以覆盖基础里的任何一条。
    static func html(body: String, extraCSS: String = "") -> String {
        """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="\(contentSecurityPolicy)">
        <style>
        \(baseStyleSheet)
        \(extraCSS)
        </style></head><body><main id="snga-post-content">\(body)</main></body></html>
        """
    }

    /// 正文是别人写的，所以默认什么都不许加载，只放行图片和内联样式。
    static let contentSecurityPolicy =
        "default-src 'none'; img-src https: data:; style-src 'unsafe-inline'; " +
        "font-src 'none'; media-src https:"

    /// 两个站都要的那一份。
    ///
    /// `:root` 里那几个变量名和默认值不能随便改 —— `ResolvedAppTheme.applying(to:)`
    /// 是按这几个字符串做替换来上主题的，改了名字主题就静默失效。
    static let baseStyleSheet = """
    :root{color-scheme:light dark;--snga-accent:#b06d00;--snga-highlight:#d59b3a;--snga-quote-rail:color-mix(in srgb,CanvasText 42%,transparent);--snga-smile-backdrop-system:transparent;--snga-smile-backdrop:var(--snga-smile-backdrop-system)}@media(prefers-color-scheme:dark){:root{--snga-smile-backdrop-system:rgba(255,255,255,.88)}}html,body{width:100%;max-width:100%;overflow-x:hidden;overflow-y:hidden}body{font:14px -apple-system,BlinkMacSystemFont,sans-serif;margin:0;color:CanvasText;background:transparent;overflow-wrap:anywhere;line-height:1.55}
    #snga-post-content{display:flow-root;width:100%;max-width:100%;min-height:1px}#snga-post-content>:first-child{margin-top:0}#snga-post-content>:last-child:not(blockquote){margin-bottom:0}p{margin:6px 0}
    img{max-width:100%;height:auto;vertical-align:middle}table{width:100%;max-width:100%;border-collapse:collapse;table-layout:auto}td,th{min-width:0;border:1px solid color-mix(in srgb,CanvasText 20%,transparent);padding:6px;vertical-align:top;overflow-wrap:anywhere}
    ul,ol{margin:8px 0;padding-left:1.6em}li{margin:4px 0}hr{height:1px;margin:12px 0;border:0;background:color-mix(in srgb,CanvasText 22%,transparent)}
    blockquote{margin:8px 0 12px;padding:7px 11px;border-left:3px solid var(--snga-quote-rail);border-radius:0 6px 6px 0;background:color-mix(in srgb,CanvasText 6%,transparent)}a{color:var(--snga-accent)}pre,code{white-space:pre-wrap}
    details{margin:8px 0;padding:6px 10px;border:1px solid color-mix(in srgb,CanvasText 18%,transparent);border-radius:6px}summary{cursor:pointer;font-weight:600}
    .snga-image-placeholder{display:inline-flex;align-items:center;justify-content:center;box-sizing:border-box;min-width:132px;min-height:58px;max-width:100%;margin:3px 0;padding:10px 14px;border:1px dashed color-mix(in srgb,var(--snga-accent) 55%,CanvasText 20%);border-radius:7px;color:var(--snga-accent);background:color-mix(in srgb,var(--snga-accent) 8%,transparent);cursor:pointer;user-select:none}.snga-image-placeholder:hover,.snga-image-placeholder:focus{background:color-mix(in srgb,var(--snga-accent) 15%,transparent);outline:1px solid color-mix(in srgb,var(--snga-accent) 45%,transparent);outline-offset:1px}
    @media(max-width:700px){table,thead,tbody,tfoot{display:block;width:100%}tr{display:grid;grid-template-columns:repeat(auto-fit,minmax(160px,1fr));gap:8px;margin:8px 0}td,th{display:block;width:auto!important;min-width:0;border-radius:6px}}
    """

    /// NodeSeek 的正文是 Markdown 渲染出来的 HTML，要的东西和 UBB 那套完全不同：
    /// 没有表情、没有颜色标签，但有代码块、行内代码和表格。
    static let markdownStyleSheet = """
    pre{margin:8px 0;padding:10px 12px;border-radius:7px;background:color-mix(in srgb,CanvasText 8%,transparent);overflow-x:auto}
    pre code{display:block;padding:0;background:none;font:12.5px ui-monospace,SFMono-Regular,Menlo,monospace}
    code{padding:1px 5px;border-radius:4px;background:color-mix(in srgb,CanvasText 10%,transparent);font:12.5px ui-monospace,SFMono-Regular,Menlo,monospace}
    h1,h2,h3,h4,h5,h6{margin:14px 0 8px;line-height:1.3}h1{font-size:1.5em}h2{font-size:1.3em}h3{font-size:1.15em}h4,h5,h6{font-size:1em}
    th{background:color-mix(in srgb,CanvasText 7%,transparent);font-weight:650;text-align:left}
    del{opacity:.7}
    .sticker{max-width:120px;max-height:120px;vertical-align:middle}
    .ns-tabs{display:flex;flex-wrap:wrap;gap:0;margin:10px 0;border:1px solid color-mix(in srgb,CanvasText 16%,transparent);border-radius:8px;overflow:hidden}
    .ns-tabs input{position:absolute;opacity:0;pointer-events:none}
    .ns-tabs .ns-tab{order:-1;padding:7px 12px;border-bottom:1px solid color-mix(in srgb,CanvasText 16%,transparent);background:color-mix(in srgb,CanvasText 5%,transparent);cursor:pointer;font-weight:600;white-space:nowrap;user-select:none}
    .ns-tabs input:checked+.ns-tab{background:transparent;border-bottom-color:transparent;color:var(--snga-accent)}
    .ns-tabs input:focus-visible+.ns-tab{outline:2px solid var(--snga-accent);outline-offset:-2px}
    .ns-tabs .ns-tab-panel{order:0;display:none;width:100%;box-sizing:border-box;padding:10px 12px}
    .ns-tabs input:checked+.ns-tab+.ns-tab-panel{display:block}
    .ns-tabs .ns-tab-panel>:first-child{margin-top:0}.ns-tabs .ns-tab-panel>:last-child{margin-bottom:0}
    """
}
