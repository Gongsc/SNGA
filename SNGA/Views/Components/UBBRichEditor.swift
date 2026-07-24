import AppKit
import SwiftUI
@preconcurrency import WebKit

enum UBBEditorAction: Equatable {
    case undo
    case redo
    case bold
    case italic
    case underline
    case strike
    case quote
    case code
    case collapse(title: String)
    case link(url: String)
    case image(url: String)
    case color(String)
    case fontSize(String)
    case align(String)
    case removeFormat
    case insertUBB(String)

    fileprivate var payload: [String: Any] {
        switch self {
        case .undo:
            ["name": "undo"]
        case .redo:
            ["name": "redo"]
        case .bold:
            ["name": "bold"]
        case .italic:
            ["name": "italic"]
        case .underline:
            ["name": "underline"]
        case .strike:
            ["name": "strike"]
        case .quote:
            ["name": "quote"]
        case .code:
            ["name": "code"]
        case let .collapse(title):
            ["name": "collapse", "value": title]
        case let .link(url):
            ["name": "link", "value": url]
        case let .image(url):
            ["name": "image", "value": url]
        case let .color(value):
            ["name": "color", "value": value]
        case let .fontSize(value):
            ["name": "fontSize", "value": value]
        case let .align(value):
            ["name": "align", "value": value]
        case .removeFormat:
            ["name": "removeFormat"]
        case let .insertUBB(value):
            ["name": "insertUBB", "value": value]
        }
    }
}

struct UBBEditorCommand: Equatable {
    let id = UUID()
    let action: UBBEditorAction
}

struct NGAEmoticon: Identifiable, Hashable {
    let family: String
    let name: String
    let fileName: String

    var id: String { "\(family):\(name)" }
    var code: String { "[s:\(family):\(name)]" }
    var imageURL: URL? {
        URL(string: "https://img4.nga.178.com/ngabbs/post/smile/\(fileName)")
    }

    static let common: [NGAEmoticon] = {
        let names = [
            "blink", "goodjob", "上", "中枪", "偷笑", "冷", "凌乱", "反对", "吓",
            "吻", "呆", "咦", "哦", "哭", "哭1", "哭笑", "哼", "喘", "喷", "嘲笑",
            "嘲笑1", "囧", "委屈", "心", "忧伤", "怒", "怕", "惊", "愁", "抓狂",
            "抠鼻", "擦汗", "无语", "晕", "汗", "瞎", "羞", "羡慕", "花痴", "茶",
            "衰", "计划通", "赞同", "闪光", "黑枪"
        ]
        return names.enumerated().map {
            NGAEmoticon(family: "ac", name: $0.element, fileName: "ac\($0.offset).png")
        }
    }()
}

struct UBBRichEditor: NSViewRepresentable {
    @Binding var content: String
    var command: UBBEditorCommand?
    var theme: AppTheme

    private static let messageName = "sngaUBBChanged"

    func makeCoordinator() -> Coordinator {
        Coordinator(content: $content)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.userContentController.add(context.coordinator, name: Self.messageName)

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        let themedHTML = theme.applying(to: Self.editorHTML)
        context.coordinator.lastTheme = theme
        webView.loadHTMLString(themedHTML, baseURL: nil)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.contentBinding = $content

        if context.coordinator.lastTheme != theme {
            context.coordinator.lastTheme = theme
            context.coordinator.isReady = false
            webView.loadHTMLString(theme.applying(to: Self.editorHTML), baseURL: nil)
            return
        }

        if context.coordinator.isReady,
           context.coordinator.lastUBB != content {
            context.coordinator.setUBB(content, in: webView)
        }

        if let command,
           context.coordinator.lastCommandID != command.id {
            context.coordinator.lastCommandID = command.id
            context.coordinator.execute(command.action, in: webView)
        }
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.navigationDelegate = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: messageName)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var contentBinding: Binding<String>
        var lastUBB = ""
        var lastCommandID: UUID?
        var isReady = false
        var pendingAction: UBBEditorAction?
        var lastTheme = AppTheme.system

        init(content: Binding<String>) {
            contentBinding = content
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
            isReady = true
            setUBB(contentBinding.wrappedValue, in: webView)
            if let pendingAction {
                self.pendingAction = nil
                execute(pendingAction, in: webView)
            }
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == UBBRichEditor.messageName,
                  let value = message.body as? String else {
                return
            }
            lastUBB = value
            Task { @MainActor [weak self] in
                guard let self, self.contentBinding.wrappedValue != value else { return }
                self.contentBinding.wrappedValue = value
            }
        }

        func setUBB(_ value: String, in webView: WKWebView) {
            lastUBB = value
            guard let argument = Self.javascriptLiteral(value) else { return }
            webView.evaluateJavaScript("window.sngaEditor.setUBB(\(argument));")
        }

        func execute(_ action: UBBEditorAction, in webView: WKWebView) {
            guard isReady else {
                pendingAction = action
                return
            }
            guard JSONSerialization.isValidJSONObject(action.payload),
                  let data = try? JSONSerialization.data(withJSONObject: action.payload),
                  let json = String(data: data, encoding: .utf8) else {
                return
            }
            webView.evaluateJavaScript("window.sngaEditor.execute(\(json));")
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            if navigationAction.navigationType == .linkActivated {
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }

        private static func javascriptLiteral(_ value: String) -> String? {
            guard let data = try? JSONSerialization.data(withJSONObject: [value]),
                  let json = String(data: data, encoding: .utf8) else {
                return nil
            }
            return String(json.dropFirst().dropLast())
        }
    }

    private static let editorHTML = #"""
    <!doctype html>
    <html>
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width,initial-scale=1">
      <meta http-equiv="Content-Security-Policy"
            content="default-src 'none'; img-src https: data:; style-src 'unsafe-inline'; script-src 'unsafe-inline'">
      <style>
        :root { color-scheme: light dark; --snga-accent:#b06d00; --snga-highlight:#d59b3a; --snga-smile-backdrop-system:transparent; --snga-smile-backdrop:var(--snga-smile-backdrop-system); }
        @media (prefers-color-scheme: dark) {
          :root { --snga-smile-backdrop-system:rgba(255,255,255,.88); }
        }
        html, body { height: 100%; margin: 0; background: transparent; }
        body {
          font: 15px/1.55 -apple-system, BlinkMacSystemFont, sans-serif;
          color: CanvasText;
        }
        #editor {
          box-sizing: border-box;
          min-height: 100%;
          padding: 14px 16px 80px;
          outline: none;
          overflow-wrap: anywhere;
          white-space: normal;
        }
        #editor:empty::before {
          content: attr(data-placeholder);
          color: color-mix(in srgb, CanvasText 38%, transparent);
          pointer-events: none;
        }
        blockquote {
          margin: 8px 0;
          padding: 7px 10px;
          border-left: 3px solid var(--snga-highlight);
          background: color-mix(in srgb, CanvasText 7%, transparent);
        }
        pre {
          margin: 8px 0;
          padding: 8px 10px;
          white-space: pre-wrap;
          border-radius: 6px;
          background: color-mix(in srgb, CanvasText 8%, transparent);
          font: 13px/1.5 ui-monospace, SFMono-Regular, Menlo, monospace;
        }
        details {
          margin: 8px 0;
          padding: 6px 10px;
          border: 1px solid color-mix(in srgb, CanvasText 20%, transparent);
          border-radius: 6px;
        }
        summary { cursor: pointer; font-weight: 600; }
        a { color: var(--snga-accent); }
        img { max-width: 100%; height: auto; vertical-align: middle; }
        img.nga-smile {
          max-width: 64px;
          max-height: 64px;
          background: var(--snga-smile-backdrop);
          border-radius: 6px;
        }
      </style>
    </head>
    <body>
      <div id="editor" contenteditable="true" spellcheck="true"
           data-placeholder="输入回复内容…"></div>
      <script>
      (() => {
        const editor = document.getElementById("editor");
        const smiles = {
          "blink":0,"goodjob":1,"上":2,"中枪":3,"偷笑":4,"冷":5,"凌乱":6,
          "反对":7,"吓":8,"吻":9,"呆":10,"咦":11,"哦":12,"哭":13,"哭1":14,
          "哭笑":15,"哼":16,"喘":17,"喷":18,"嘲笑":19,"嘲笑1":20,"囧":21,
          "委屈":22,"心":23,"忧伤":24,"怒":25,"怕":26,"惊":27,"愁":28,
          "抓狂":29,"抠鼻":30,"擦汗":31,"无语":32,"晕":33,"汗":34,"瞎":35,
          "羞":36,"羡慕":37,"花痴":38,"茶":39,"衰":40,"计划通":41,
          "赞同":42,"闪光":43,"黑枪":44
        };
        let savedRange = null;
        let applyingSource = false;

        const escapeHTML = (value) => String(value)
          .replaceAll("&", "&amp;")
          .replaceAll("<", "&lt;")
          .replaceAll(">", "&gt;")
          .replaceAll('"', "&quot;");

        const escapeAttribute = (value) => escapeHTML(value).replaceAll("'", "&#39;");

        function replacePaired(value, expression, transform) {
          let result = value;
          for (let pass = 0; pass < 12; pass += 1) {
            const next = result.replace(expression, transform);
            if (next === result) break;
            result = next;
          }
          return result;
        }

        function safeColor(value) {
          const normalized = decodeEntities(value).trim().toLowerCase();
          const names = [
            "skyblue","royalblue","blue","darkblue","orange","orangered","crimson","red",
            "firebrick","darkred","green","limegreen","seagreen","teal","deeppink","tomato",
            "coral","purple","indigo","burlywood","sandybrown","sienna","chocolate","silver",
            "gray","black","white"
          ];
          if (names.includes(normalized) || /^#[0-9a-f]{3}([0-9a-f]{3})?$/.test(normalized)) {
            return normalized;
          }
          return "inherit";
        }

        function safeSize(value) {
          const normalized = decodeEntities(value).trim();
          if (/^(?:[5-9][0-9]|1[0-9]{2}|2[0-9]{2}|300)%$/.test(normalized)) {
            return normalized;
          }
          return "100%";
        }

        function safeURL(value) {
          try {
            const parsed = new URL(decodeEntities(value).trim());
            return ["http:", "https:"].includes(parsed.protocol) ? parsed.href : "";
          } catch (_) {
            return "";
          }
        }

        function ubbToHTML(source) {
          let value = escapeHTML(String(source).replaceAll("\r\n", "\n").replaceAll("\r", "\n"));

          value = value.replace(/\[s:ac:([^\]]+)\]/gi, (whole, name) => {
            const decodedName = decodeEntities(name);
            const index = smiles[decodedName];
            if (index === undefined) {
              return `<span data-ubb-code="${escapeAttribute(whole)}">${whole}</span>`;
            }
            const src = `https://img4.nga.178.com/ngabbs/post/smile/ac${index}.png`;
            return `<img class="nga-smile" src="${src}" alt="${escapeAttribute(decodedName)}" data-ubb-code="${escapeAttribute(whole)}">`;
          });
          value = replacePaired(
            value,
            /\[img(?:=[^\]]*)?\]([\s\S]*?)\[\/img\]/gi,
            (_, url) => {
              const safe = safeURL(url);
              return safe
                ? `<img src="${escapeAttribute(safe)}" alt="帖子图片" data-ubb-image="true">`
                : escapeHTML(decodeEntities(url));
            }
          );
          value = replacePaired(
            value,
            /\[url=([^\]]+)\]([\s\S]*?)\[\/url\]/gi,
            (_, url, body) => {
              const safe = safeURL(url);
              return safe
                ? `<a href="${escapeAttribute(safe)}" data-ubb-url="${escapeAttribute(safe)}">${body}</a>`
                : body;
            }
          );
          value = replacePaired(
            value,
            /\[url\]([\s\S]*?)\[\/url\]/gi,
            (_, url) => {
              const safe = safeURL(url);
              return safe
                ? `<a href="${escapeAttribute(safe)}" data-ubb-url="${escapeAttribute(safe)}">${url}</a>`
                : url;
            }
          );
          value = replacePaired(
            value,
            /\[code\]([\s\S]*?)\[\/code\]/gi,
            (_, body) => `<pre data-ubb-block="code">${body}</pre>`
          );
          value = replacePaired(
            value,
            /\[collapse(?:=([^\]]*))?\]([\s\S]*?)\[\/collapse\]/gi,
            (_, title, body) => `<details open data-ubb-block="collapse" data-title="${escapeAttribute(decodeEntities(title || ""))}"><summary>${title || "折叠内容"}</summary><div>${body}</div></details>`
          );
          value = replacePaired(
            value,
            /\[quote(?:=[^\]]*)?\]([\s\S]*?)\[\/quote\]/gi,
            (_, body) => `<blockquote data-ubb-block="quote">${body}</blockquote>`
          );

          const tags = [
            ["b", "strong"], ["i", "em"], ["u", "u"], ["s", "s"], ["del", "s"]
          ];
          for (const [ubb, html] of tags) {
            value = replacePaired(
              value,
              new RegExp(`\\[${ubb}\\]([\\s\\S]*?)\\[\\/${ubb}\\]`, "gi"),
              (_, body) => `<${html}>${body}</${html}>`
            );
          }
          value = replacePaired(
            value,
            /\[color=([^\]]+)\]([\s\S]*?)\[\/color\]/gi,
            (_, color, body) => {
              const safe = safeColor(color);
              return `<span style="color:${safe}" data-ubb-tag="color" data-ubb-value="${escapeAttribute(safe)}">${body}</span>`;
            }
          );
          value = replacePaired(
            value,
            /\[size=([^\]]+)\]([\s\S]*?)\[\/size\]/gi,
            (_, size, body) => {
              const safe = safeSize(size);
              return `<span style="font-size:${safe}" data-ubb-tag="size" data-ubb-value="${escapeAttribute(safe)}">${body}</span>`;
            }
          );
          value = replacePaired(
            value,
            /\[align=(left|center|right)\]([\s\S]*?)\[\/align\]/gi,
            (_, align, body) => `<div style="text-align:${align}" data-ubb-tag="align" data-ubb-value="${align}">${body}</div>`
          );
          return value.replaceAll("\n", "<br>");
        }

        function decodeEntities(value) {
          const text = document.createElement("textarea");
          text.innerHTML = value;
          return text.value;
        }

        function childUBB(node, excluded) {
          return Array.from(node.childNodes)
            .filter((child) => child !== excluded)
            .map(nodeToUBB)
            .join("");
        }

        function blockValue(value) {
          return value.endsWith("\n") ? value : value + "\n";
        }

        function nodeToUBB(node) {
          if (node.nodeType === Node.TEXT_NODE) {
            return (node.nodeValue || "").replaceAll("\u200B", "");
          }
          if (node.nodeType !== Node.ELEMENT_NODE) return "";

          const element = node;
          const tag = element.tagName.toLowerCase();
          if (tag === "br") return "\n";
          if (tag === "img") {
            const code = element.dataset.ubbCode;
            if (code) return code;
            const source = element.getAttribute("src") || "";
            return source ? `[img]${source}[/img]` : "";
          }

          const children = childUBB(element);
          if (tag === "strong" || tag === "b") return `[b]${children}[/b]`;
          if (tag === "em" || tag === "i") return `[i]${children}[/i]`;
          if (tag === "u") return `[u]${children}[/u]`;
          if (tag === "s" || tag === "strike" || tag === "del") return `[s]${children}[/s]`;
          if (tag === "a") {
            const url = element.dataset.ubbUrl || element.getAttribute("href") || "";
            return url ? `[url=${url}]${children || url}[/url]` : children;
          }
          if (tag === "blockquote") return blockValue(`[quote]${children.replace(/\n$/, "")}[/quote]`);
          if (tag === "pre") return blockValue(`[code]${children.replace(/\n$/, "")}[/code]`);
          if (tag === "details") {
            const summary = element.querySelector(":scope > summary");
            const body = childUBB(element, summary).replace(/\n$/, "");
            const title = element.dataset.title || (summary ? summary.textContent : "");
            const opening = title && title !== "折叠内容" ? `[collapse=${title}]` : "[collapse]";
            return blockValue(`${opening}${body}[/collapse]`);
          }

          if (element.dataset.ubbTag) {
            const ubbTag = element.dataset.ubbTag;
            const ubbValue = element.dataset.ubbValue || "";
            const result = `[${ubbTag}=${ubbValue}]${children.replace(/\n$/, "")}[/${ubbTag}]`;
            return ubbTag === "align" ? blockValue(result) : result;
          }
          if (tag === "font") {
            const color = element.getAttribute("color");
            if (color) return `[color=${color}]${children}[/color]`;
            const size = element.getAttribute("size");
            if (size) return `[size=${size}]${children}[/size]`;
          }

          const alignment = element.style && element.style.textAlign;
          if (alignment && ["left", "center", "right"].includes(alignment)) {
            return blockValue(`[align=${alignment}]${children.replace(/\n$/, "")}[/align]`);
          }
          if (tag === "div" || tag === "p" || tag === "li") return blockValue(children);
          return children;
        }

        function currentUBB() {
          return childUBB(editor)
            .replace(/\n{3,}/g, "\n\n")
            .replace(/\n+$/, "");
        }

        function notify() {
          if (applyingSource) return;
          window.webkit.messageHandlers.sngaUBBChanged.postMessage(currentUBB());
        }

        function saveSelection() {
          const selection = window.getSelection();
          if (!selection || selection.rangeCount === 0) return;
          const range = selection.getRangeAt(0);
          if (editor.contains(range.commonAncestorContainer)) {
            savedRange = range.cloneRange();
          }
        }

        function restoreSelection() {
          editor.focus();
          if (!savedRange) return;
          const selection = window.getSelection();
          selection.removeAllRanges();
          selection.addRange(savedRange);
        }

        function selectedText() {
          const selection = window.getSelection();
          return selection ? selection.toString() : "";
        }

        function insertHTML(html) {
          restoreSelection();
          document.execCommand("insertHTML", false, html);
          saveSelection();
          notify();
        }

        editor.addEventListener("input", () => {
          saveSelection();
          notify();
        });
        editor.addEventListener("paste", (event) => {
          event.preventDefault();
          const text = event.clipboardData ? event.clipboardData.getData("text/plain") : "";
          document.execCommand("insertText", false, text);
        });
        editor.addEventListener("drop", (event) => {
          event.preventDefault();
          const text = event.dataTransfer ? event.dataTransfer.getData("text/plain") : "";
          if (text) document.execCommand("insertText", false, text);
        });
        editor.addEventListener("click", (event) => {
          if (event.target && event.target.closest && event.target.closest("a")) {
            event.preventDefault();
          }
        });
        editor.addEventListener("keyup", saveSelection);
        editor.addEventListener("mouseup", saveSelection);
        document.addEventListener("selectionchange", saveSelection);

        window.sngaEditor = {
          setUBB(value) {
            const next = String(value || "");
            if (currentUBB() === next) return;
            applyingSource = true;
            editor.innerHTML = ubbToHTML(next);
            applyingSource = false;
          },
          execute(command) {
            if (!command || !command.name) return;
            restoreSelection();
            const value = command.value == null ? "" : String(command.value);
            switch (command.name) {
              case "undo": document.execCommand("undo"); break;
              case "redo": document.execCommand("redo"); break;
              case "bold": document.execCommand("bold"); break;
              case "italic": document.execCommand("italic"); break;
              case "underline": document.execCommand("underline"); break;
              case "strike": document.execCommand("strikeThrough"); break;
              case "color": document.execCommand("foreColor", false, value); break;
              case "fontSize":
                document.execCommand("fontSize", false, "7");
                editor.querySelectorAll('font[size="7"]').forEach((font) => {
                  const span = document.createElement("span");
                  span.style.fontSize = safeSize(value);
                  span.dataset.ubbTag = "size";
                  span.dataset.ubbValue = safeSize(value);
                  while (font.firstChild) span.appendChild(font.firstChild);
                  font.replaceWith(span);
                });
                break;
              case "align":
                document.execCommand(
                  value === "center" ? "justifyCenter" : value === "right" ? "justifyRight" : "justifyLeft"
                );
                break;
              case "quote":
                document.execCommand("formatBlock", false, "blockquote");
                break;
              case "code":
                document.execCommand("formatBlock", false, "pre");
                break;
              case "collapse": {
                const body = selectedText() || "折叠内容";
                const title = value || "折叠内容";
                insertHTML(`<details open data-ubb-block="collapse" data-title="${escapeAttribute(value)}"><summary>${escapeHTML(title)}</summary><div>${escapeHTML(body)}</div></details><br>`);
                return;
              }
              case "link": {
                const safe = safeURL(value);
                if (!safe) return;
                if (selectedText()) {
                  document.execCommand("createLink", false, safe);
                  const selection = window.getSelection();
                  const anchor = selection && selection.anchorNode
                    ? (selection.anchorNode.parentElement && selection.anchorNode.parentElement.closest("a"))
                    : null;
                  if (anchor) anchor.dataset.ubbUrl = safe;
                } else {
                  insertHTML(`<a href="${escapeAttribute(safe)}" data-ubb-url="${escapeAttribute(safe)}">${escapeHTML(safe)}</a>`);
                  return;
                }
                break;
              }
              case "image": {
                const safe = safeURL(value);
                if (safe) insertHTML(`<img src="${escapeAttribute(safe)}" alt="帖子图片" data-ubb-image="true">`);
                return;
              }
              case "removeFormat":
                document.execCommand("removeFormat");
                break;
              case "insertUBB":
                insertHTML(ubbToHTML(value));
                return;
            }
            saveSelection();
            notify();
          }
        };
      })();
      </script>
    </body>
    </html>
    """#
}

struct NGAEmoticonPicker: View {
    var insert: (NGAEmoticon) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var searchText = ""

    private var results: [NGAEmoticon] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return NGAEmoticon.common }
        return NGAEmoticon.common.filter {
            $0.name.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(spacing: 10) {
            TextField("搜索表情", text: $searchText)
                .textFieldStyle(.roundedBorder)

            ScrollView {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.fixed(42), spacing: 6), count: 8),
                    spacing: 6
                ) {
                    ForEach(results) { emoticon in
                        Button {
                            insert(emoticon)
                        } label: {
                            AsyncImage(url: emoticon.imageURL) { image in
                                image
                                    .resizable()
                                    .scaledToFit()
                            } placeholder: {
                                ProgressView()
                                    .controlSize(.mini)
                            }
                            .frame(width: 30, height: 30)
                            .background {
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(
                                        colorScheme == .dark
                                            ? Color.white.opacity(0.88)
                                            : Color.clear
                                    )
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(emoticon.name)
                    }
                }
                .padding(4)
            }
        }
        .padding(12)
        .frame(width: 410, height: 300)
    }
}
