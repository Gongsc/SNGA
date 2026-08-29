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

    /// 终端报告的排版。
    ///
    /// 报告按终端排版：一个汉字算两列。而网页的等宽字体里，**Menlo 的拉丁字宽是
    /// 0.6021em，汉字是 1em** —— 比值 1.66 而不是 2。每出现一个汉字，后面的列就左移
    /// 0.2 个字位，标签字数一多整张表就斜了。
    ///
    /// 每个汉字补 `2 × 0.6021 − 1 = 0.2042em`，正好凑成两个拉丁字位。
    /// 哪些字要补由 `ANSIText.markingWideCharacters` 圈出来，两者必须一起改。
    ///
    /// 字体写死 Menlo，不用 `ui-monospace`：上面那个常数是按 Menlo 的字宽算的，
    /// 换一个字宽不同的字体，补出来的就是另一个数。Menlo 每台 Mac 都有。
    static let terminalStyleSheet = """
    pre code{font-family:Menlo,"PingFang SC",monospace}
    .ns-w{letter-spacing:0.2042em}
    """

    /// 终端输出的调色板。
    ///
    /// 黑和白不用字面的黑白：正文的明暗跟着系统走，写死的黑字在深色下、白字在浅色下
    /// 都会看不见。这两个改用 `CanvasText` 的深浅，其余六色沿用终端惯例，
    /// 并在深色下换一组更亮的 —— 终端的标准色在深底上偏暗。
    static let ansiStyleSheet = """
    .ansi-b{font-weight:700}.ansi-d{opacity:.65}.ansi-i{font-style:italic}
    .ansi-u{text-decoration:underline}.ansi-s{text-decoration:line-through}
    :root{--ansi-0:color-mix(in srgb,CanvasText 70%,transparent);--ansi-1:#c0392b;--ansi-2:#1e8449;--ansi-3:#b7791f;--ansi-4:#2471a3;--ansi-5:#8e44ad;--ansi-6:#128f8f;--ansi-7:color-mix(in srgb,CanvasText 45%,transparent)}
    @media(prefers-color-scheme:dark){:root{--ansi-1:#ff6b6b;--ansi-2:#5cd48a;--ansi-3:#e8c06a;--ansi-4:#6cb6ff;--ansi-5:#d08bf5;--ansi-6:#4ad4d4}}
    .ansi-fg-0,.ansi-fgb-0{color:var(--ansi-0)}.ansi-fg-1,.ansi-fgb-1{color:var(--ansi-1)}
    .ansi-fg-2,.ansi-fgb-2{color:var(--ansi-2)}.ansi-fg-3,.ansi-fgb-3{color:var(--ansi-3)}
    .ansi-fg-4,.ansi-fgb-4{color:var(--ansi-4)}.ansi-fg-5,.ansi-fgb-5{color:var(--ansi-5)}
    .ansi-fg-6,.ansi-fgb-6{color:var(--ansi-6)}.ansi-fg-7,.ansi-fgb-7{color:var(--ansi-7)}
    .ansi-bg-0,.ansi-bgb-0{background:var(--ansi-0)}.ansi-bg-1,.ansi-bgb-1{background:var(--ansi-1)}
    .ansi-bg-2,.ansi-bgb-2{background:var(--ansi-2)}.ansi-bg-3,.ansi-bgb-3{background:var(--ansi-3)}
    .ansi-bg-4,.ansi-bgb-4{background:var(--ansi-4)}.ansi-bg-5,.ansi-bgb-5{background:var(--ansi-5)}
    .ansi-bg-6,.ansi-bgb-6{background:var(--ansi-6)}.ansi-bg-7,.ansi-bgb-7{background:var(--ansi-7)}
    [class*="ansi-bg-"]{color:Canvas;padding:0 2px;border-radius:2px}
    """
}
