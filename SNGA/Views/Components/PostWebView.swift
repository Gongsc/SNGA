import AppKit
import SwiftUI
import SwiftSoup
@preconcurrency import WebKit

@MainActor
final class PostWebViewCache {
    final class Entry {
        let webView: WKWebView
        let html: String
        let height: CGFloat

        init(webView: WKWebView, html: String, height: CGFloat) {
            self.webView = webView
            self.html = html
            self.height = height
        }
    }

    static let shared = PostWebViewCache()
    private let entries = NSCache<NSString, Entry>()

    init(countLimit: Int = 60) {
        entries.countLimit = countLimit
    }

    func take(for key: String, matching html: String) -> Entry? {
        let cacheKey = key as NSString
        guard let entry = entries.object(forKey: cacheKey) else { return nil }
        entries.removeObject(forKey: cacheKey)
        return entry.html == html ? entry : nil
    }

    func store(
        _ webView: WKWebView,
        html: String,
        height: CGFloat,
        for key: String
    ) {
        entries.setObject(
            Entry(webView: webView, html: html, height: height),
            forKey: key as NSString
        )
    }

    func removeAll() {
        entries.removeAllObjects()
    }
}

enum PostImagePolicy {
    static func applying(to html: String, hidesRemoteImages: Bool) -> String {
        guard hidesRemoteImages else { return html }
        do {
            let document = try SwiftSoup.parse(html, NGAEndpoint.baseURL.absoluteString)
            for image in try document.select("img") {
                let source = try image.attr("src")
                guard !source.isEmpty, !isEmoticon(image, source: source) else { continue }

                let placeholder = try Element(Tag.valueOf("span"), image.getBaseUri())
                    .attr("class", "snga-image-placeholder")
                    .attr("data-snga-src", source)
                    .attr("data-snga-alt", try image.attr("alt"))
                    .attr("data-snga-class", try image.className())
                    .attr("role", "button")
                    .attr("tabindex", "0")
                    .attr("title", "点击加载图片")
                    .attr("aria-label", "图片，点击加载")
                    .text("▧ 图片 · 点击加载")
                try image.replaceWith(placeholder)
            }
            return try document.outerHtml()
        } catch {
            return html
        }
    }

    private static func isEmoticon(_ image: Element, source: String) -> Bool {
        image.hasClass("nga-smile")
            || source.localizedCaseInsensitiveContains("/ngabbs/post/smile/")
    }
}

struct PostWebView: NSViewRepresentable {
    private static let heightMessageName = "sngaContentHeightChanged"
    private static let imageMessageName = "sngaImageClicked"
    private static let contentReadyMessageName = "sngaContentReady"
    @MainActor private static let sharedDataStore = WKWebsiteDataStore.nonPersistent()
    private static let heightObserverScript = """
    (() => {
        if (window.__sngaHeightObserverInstalled) return;
        window.__sngaHeightObserverInstalled = true;

        let notificationTimer = 0;
        let lastReportedHeight = 0;
        const measuredHeight = () => {
            const content = document.getElementById("snga-post-content") || document.body;
            if (!content) return 0;
            const rect = content.getBoundingClientRect();
            return Math.ceil(Math.max(0, rect.height, content.scrollHeight));
        };
        const notify = () => {
            window.clearTimeout(notificationTimer);
            notificationTimer = window.setTimeout(() => {
                notificationTimer = 0;
                requestAnimationFrame(() => {
                    const height = measuredHeight();
                    if (Math.abs(height - lastReportedHeight) <= 0.5) return;
                    lastReportedHeight = height;
                    window.webkit.messageHandlers.sngaContentHeightChanged.postMessage(height);
                });
            }, 80);
        };

        const content = document.getElementById("snga-post-content") || document.body;
        if (!content) return;
        const observer = new ResizeObserver(notify);
        observer.observe(content);
        window.__sngaHeightObserver = observer;
        document.addEventListener("toggle", notify, true);
        document.addEventListener("load", notify, true);
        notify();
    })();
    """
    private static let imageInteractionScript = """
    (() => {
        if (window.__sngaImageInteractionInstalled) return;
        window.__sngaImageInteractionInstalled = true;

        const prepareImages = (root) => {
            root.querySelectorAll?.("img").forEach((image) => {
                image.style.cursor = "zoom-in";
                image.draggable = false;
                image.setAttribute("title", "点击查看大图");
            });
        };

        const loadDeferredImage = (placeholder) => {
            const source = placeholder.getAttribute("data-snga-src");
            if (!source) return;
            const image = document.createElement("img");
            const alt = placeholder.getAttribute("data-snga-alt");
            const originalClass = placeholder.getAttribute("data-snga-class");
            if (alt) image.setAttribute("alt", alt);
            if (originalClass) image.setAttribute("class", originalClass);
            image.setAttribute("loading", "eager");
            image.setAttribute("decoding", "async");
            image.setAttribute("referrerpolicy", "no-referrer");
            image.draggable = false;
            image.style.cursor = "zoom-in";
            image.setAttribute("title", "点击查看大图");
            placeholder.replaceWith(image);
            image.src = source;
        };

        prepareImages(document);
        document.addEventListener("click", (event) => {
            if (!(event.target instanceof Element)) return;
            const placeholder = event.target.closest(".snga-image-placeholder");
            if (placeholder) {
                event.preventDefault();
                event.stopPropagation();
                loadDeferredImage(placeholder);
                return;
            }
            const image = event.target.closest("img");
            if (!image) return;
            const source = image.currentSrc || image.src;
            if (!source) return;
            event.preventDefault();
            event.stopPropagation();
            window.webkit.messageHandlers.sngaImageClicked.postMessage(source);
        }, true);
        document.addEventListener("keydown", (event) => {
            if (!(event.target instanceof Element)) return;
            if (event.key !== "Enter" && event.key !== " ") return;
            const placeholder = event.target.closest(".snga-image-placeholder");
            if (!placeholder) return;
            event.preventDefault();
            event.stopPropagation();
            loadDeferredImage(placeholder);
        }, true);
    })();
    """
    private static let contentReadyScript = """
    (() => {
        if (window.__sngaContentReadyInstalled) return;
        window.__sngaContentReadyInstalled = true;

        const images = Array.from(document.images);
        images.forEach((image) => {
            image.loading = "eager";
            image.decoding = "async";
        });

        const waitForImage = (image) => new Promise((resolve) => {
            const finish = () => {
                if (typeof image.decode !== "function") {
                    resolve();
                    return;
                }
                image.decode().catch(() => {}).finally(resolve);
            };
            if (image.complete) {
                finish();
                return;
            }
            image.addEventListener("load", finish, { once: true });
            image.addEventListener("error", resolve, { once: true });
        });

        const imagesReady = Promise.all(images.map(waitForImage));
        const timeout = new Promise((resolve) => window.setTimeout(resolve, 15000));
        Promise.race([imagesReady, timeout])
            .then(() => new Promise(requestAnimationFrame))
            .then(() => new Promise(requestAnimationFrame))
            .then(() => {
                const content = document.getElementById("snga-post-content") || document.body;
                if (!content) return;
                const rect = content.getBoundingClientRect();
                const height = Math.ceil(Math.max(0, rect.height, content.scrollHeight));
                window.webkit.messageHandlers.sngaContentReady.postMessage(height);
            });
    })();
    """
    static let randomBlockCarouselScript = """
    (() => {
        if (window.__sngaRandomBlockCarouselInstalled) return;
        window.__sngaRandomBlockCarouselInstalled = true;

        const activate = (carousel, selectedIndex) => {
            const panels = Array.from(carousel.children).filter((element) =>
                element.classList.contains("nga-random-block-panel")
            );
            const buttons = Array.from(
                carousel.querySelectorAll(".nga-random-block-button")
            );
            if (selectedIndex < 0 || selectedIndex >= panels.length) return;
            panels.forEach((panel, index) => {
                const isSelected = index === selectedIndex;
                panel.classList.toggle("snga-is-active", isSelected);
                panel.setAttribute("aria-hidden", isSelected ? "false" : "true");
            });
            buttons.forEach((button, index) => {
                const isSelected = index === selectedIndex;
                button.classList.toggle("snga-is-active", isSelected);
                button.setAttribute("aria-pressed", isSelected ? "true" : "false");
            });
        };

        document.querySelectorAll(".nga-random-block-carousel").forEach((carousel) => {
            const buttons = Array.from(
                carousel.querySelectorAll(".nga-random-block-button")
            );
            const selectedIndex = Math.max(
                0,
                buttons.findIndex((button) => button.classList.contains("snga-is-active"))
            );
            activate(carousel, selectedIndex);
        });

        document.addEventListener("click", (event) => {
            if (!(event.target instanceof Element)) return;
            const button = event.target.closest(".nga-random-block-button");
            if (!button) return;
            const carousel = button.closest(".nga-random-block-carousel");
            const selectedIndex = Number.parseInt(
                button.getAttribute("data-snga-random-block-index") || "",
                10
            );
            if (!carousel || !Number.isInteger(selectedIndex)) return;
            event.preventDefault();
            event.stopPropagation();
            activate(carousel, selectedIndex);
        });
    })();
    """

    var html: String
    var theme: ResolvedAppTheme
    var imageFreeMode: Bool
    var cacheKey: String?
    @Binding var contentHeight: CGFloat
    var onOpenInternalLink: @MainActor (NGAInternalDestination) -> Void = { _ in }
    var onOpenImage: @MainActor (URL) -> Void = { _ in }
    var onContentReady: @MainActor () -> Void = {}

    func makeCoordinator() -> Coordinator {
        Coordinator(
            height: $contentHeight,
            cacheKey: cacheKey,
            onOpenInternalLink: onOpenInternalLink,
            onOpenImage: onOpenImage,
            onContentReady: onContentReady
        )
    }

    func makeNSView(context: Context) -> WKWebView {
        let themedHTML = renderedHTML
        if let cacheKey,
           let cached = PostWebViewCache.shared.take(
               for: cacheKey,
               matching: themedHTML
           ) {
            let webView = cached.webView
            installMessageHandlers(
                on: webView.configuration.userContentController,
                coordinator: context.coordinator
            )
            configure(
                webView,
                coordinator: context.coordinator
            )
            context.coordinator.prepareForLoad(themedHTML)
            context.coordinator.height = cached.height
            context.coordinator.scheduleMeasurements(
                webView,
                delays: [0.05, 0.25]
            )
            let coordinator = context.coordinator
            Task { @MainActor in
                await Task.yield()
                coordinator.reportContentReady(height: cached.height)
            }
            return webView
        }

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = Self.sharedDataStore
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        installMessageHandlers(
            on: configuration.userContentController,
            coordinator: context.coordinator
        )
        configuration.userContentController.addUserScript(WKUserScript(
            source: Self.heightObserverScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))
        configuration.userContentController.addUserScript(WKUserScript(
            source: Self.imageInteractionScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))
        configuration.userContentController.addUserScript(WKUserScript(
            source: Self.randomBlockCarouselScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))
        configuration.userContentController.addUserScript(WKUserScript(
            source: Self.contentReadyScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))
        let webView = PassthroughWebView(frame: .zero, configuration: configuration)
        configure(webView, coordinator: context.coordinator)
        webView.setValue(false, forKey: "drawsBackground")
        context.coordinator.prepareForLoad(themedHTML)
        webView.loadHTMLString(themedHTML, baseURL: NGAEndpoint.baseURL)
        return webView
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        let cachedHTML = coordinator.lastHTML
        let cachedHeight = coordinator.height
        coordinator.invalidate()
        webView.navigationDelegate = nil
        (webView as? PassthroughWebView)?.onContentMayResize = nil
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: heightMessageName
        )
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: imageMessageName
        )
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: contentReadyMessageName
        )
        if let cacheKey = coordinator.cacheKey, !cachedHTML.isEmpty {
            PostWebViewCache.shared.store(
                webView,
                html: cachedHTML,
                height: cachedHeight,
                for: cacheKey
            )
        } else {
            webView.stopLoading()
            webView.configuration.userContentController.removeAllUserScripts()
        }
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let themedHTML = renderedHTML
        if context.coordinator.lastHTML != themedHTML {
            context.coordinator.prepareForLoad(themedHTML)
            webView.loadHTMLString(themedHTML, baseURL: NGAEndpoint.baseURL)
        }
    }

    private var renderedHTML: String {
        PostImagePolicy.applying(
            to: theme.applying(to: html),
            hidesRemoteImages: imageFreeMode
        )
    }

    private func installMessageHandlers(
        on controller: WKUserContentController,
        coordinator: Coordinator
    ) {
        controller.add(
            coordinator,
            name: Self.heightMessageName
        )
        controller.add(
            coordinator,
            name: Self.imageMessageName
        )
        controller.add(
            coordinator,
            name: Self.contentReadyMessageName
        )
    }

    private func configure(
        _ webView: WKWebView,
        coordinator: Coordinator
    ) {
        webView.navigationDelegate = coordinator
        (webView as? PassthroughWebView)?.onContentMayResize = {
            [weak coordinator, weak webView] in
            guard let coordinator, let webView else { return }
            coordinator.scheduleMeasurements(webView, delays: [0.05, 0.25])
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        @Binding var height: CGFloat
        let cacheKey: String?
        let onOpenInternalLink: @MainActor (NGAInternalDestination) -> Void
        let onOpenImage: @MainActor (URL) -> Void
        let onContentReady: @MainActor () -> Void
        var lastHTML = ""
        private var documentGeneration = 0
        private var isInvalidated = false
        private var measurementInFlight = false
        private var measurementRequested = false
        private var measurementTask: Task<Void, Never>?
        private var hasReportedContentReady = false
        private var processRecoveryDates: [Date] = []

        init(
            height: Binding<CGFloat>,
            cacheKey: String?,
            onOpenInternalLink: @escaping @MainActor (NGAInternalDestination) -> Void,
            onOpenImage: @escaping @MainActor (URL) -> Void,
            onContentReady: @escaping @MainActor () -> Void
        ) {
            _height = height
            self.cacheKey = cacheKey
            self.onOpenInternalLink = onOpenInternalLink
            self.onOpenImage = onOpenImage
            self.onContentReady = onContentReady
        }

        @MainActor
        fileprivate func prepareForLoad(_ html: String) {
            documentGeneration += 1
            isInvalidated = false
            measurementInFlight = false
            measurementRequested = false
            measurementTask?.cancel()
            measurementTask = nil
            hasReportedContentReady = false
            lastHTML = html
        }

        @MainActor
        fileprivate func invalidate() {
            documentGeneration += 1
            isInvalidated = true
            measurementInFlight = false
            measurementRequested = false
            measurementTask?.cancel()
            measurementTask = nil
            hasReportedContentReady = false
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
            // 远程图片和折叠内容会继续触发 ResizeObserver；这里只保留少量兜底复测。
            scheduleMeasurements(webView, delays: [0, 0.25, 1.0])
        }

        @MainActor
        fileprivate func scheduleMeasurements(_ webView: WKWebView, delays: [Double] = [0]) {
            guard !isInvalidated else { return }
            measurementTask?.cancel()
            let generation = documentGeneration
            let targets = delays.isEmpty ? [0] : delays.sorted()
            measurementTask = Task { @MainActor [weak self, weak webView] in
                var previousDelay = 0.0
                for targetDelay in targets {
                    let interval = max(0, targetDelay - previousDelay)
                    if interval > 0 {
                        try? await Task.sleep(for: .seconds(interval))
                    }
                    guard !Task.isCancelled,
                          let self,
                          let webView,
                          !self.isInvalidated,
                          self.documentGeneration == generation else {
                        return
                    }
                    self.measure(webView)
                    previousDelay = targetDelay
                }
            }
        }

        @MainActor
        fileprivate func measure(_ webView: WKWebView) {
            guard !isInvalidated else { return }
            if measurementInFlight {
                measurementRequested = true
                return
            }
            measurementInFlight = true
            measurementRequested = false
            let generation = documentGeneration
            let script = """
            (() => {
                const content = document.getElementById("snga-post-content") || document.body;
                if (!content) return 0;
                const rect = content.getBoundingClientRect();
                return Math.ceil(Math.max(0, rect.height, content.scrollHeight));
            })()
            """
            webView.evaluateJavaScript(script) { [weak self, weak webView] result, _ in
                Task { @MainActor in
                    guard let self,
                          !self.isInvalidated,
                          self.documentGeneration == generation else {
                        return
                    }
                    self.measurementInFlight = false
                    if let number = result as? NSNumber {
                        self.applyMeasuredHeight(CGFloat(truncating: number))
                    }
                    if self.measurementRequested, let webView {
                        self.measurementRequested = false
                        self.scheduleMeasurements(webView, delays: [0.05])
                    }
                }
            }
        }

        @MainActor
        private func applyMeasuredHeight(_ measured: CGFloat) {
            let normalizedHeight = max(22, measured)
            if abs(height - normalizedHeight) > 0.5 {
                height = normalizedHeight
            }
        }

        @MainActor
        fileprivate func reportContentReady(height measured: CGFloat) {
            guard !isInvalidated, !hasReportedContentReady else { return }
            applyMeasuredHeight(measured)
            hasReportedContentReady = true
            onContentReady()
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            Task { @MainActor [weak self, weak webView] in
                guard let self, let webView, !self.isInvalidated else { return }
                let cutoff = Date().addingTimeInterval(-60)
                self.processRecoveryDates.removeAll { $0 < cutoff }
                guard self.processRecoveryDates.count < 2 else { return }
                self.processRecoveryDates.append(Date())
                let html = self.lastHTML
                self.prepareForLoad(html)
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled, !self.isInvalidated else { return }
                webView.loadHTMLString(html, baseURL: NGAEndpoint.baseURL)
            }
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            if message.name == PostWebView.imageMessageName,
               let rawURL = message.body as? String,
               let url = URL(string: rawURL),
               ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                Task { @MainActor [weak self] in
                    self?.onOpenImage(url)
                }
                return
            }
            if message.name == PostWebView.contentReadyMessageName,
               let number = message.body as? NSNumber {
                Task { @MainActor [weak self] in
                    self?.reportContentReady(height: CGFloat(truncating: number))
                }
                return
            }
            guard message.name == PostWebView.heightMessageName,
                  let webView = message.webView else { return }
            Task { @MainActor [weak self, weak webView] in
                guard let self, let webView else { return }
                if let number = message.body as? NSNumber {
                    self.applyMeasuredHeight(CGFloat(truncating: number))
                } else {
                    self.scheduleMeasurements(webView, delays: [0.05])
                }
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            guard navigationAction.navigationType == .linkActivated,
                  let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }
            decisionHandler(.cancel)
            if let destination = NGAInternalLink.destination(for: url) {
                Task { @MainActor in onOpenInternalLink(destination) }
            } else {
                NSWorkspace.shared.open(url)
            }
        }
    }
}

private final class PassthroughWebView: WKWebView {
    var onContentMayResize: (@MainActor () -> Void)?
    private var lastMeasuredWidth: CGFloat = 0

    override func layout() {
        super.layout()
        let width = bounds.width
        guard width > 0, abs(width - lastMeasuredWidth) > 1 else { return }
        lastMeasuredWidth = width
        Task { @MainActor [weak self] in
            self?.onContentMayResize?()
        }
    }

    override func scrollWheel(with event: NSEvent) {
        var ancestor = superview
        while let view = ancestor {
            if let outerScrollView = view as? NSScrollView {
                outerScrollView.scrollWheel(with: event)
                return
            }
            ancestor = view.superview
        }
        super.scrollWheel(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        Task { @MainActor [weak self] in
            self?.onContentMayResize?()
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let menu = super.menu(for: event) else { return nil }
        localize(menu)
        return menu
    }

    private func localize(_ menu: NSMenu) {
        for item in menu.items {
            item.title = PostContextMenuLocalization.localizedTitle(item.title)
            if let submenu = item.submenu {
                localize(submenu)
            }
        }
    }
}

enum PostContextMenuLocalization {
    private static let exactTitles = [
        "Open Image in New Window": "在新窗口中打开图片",
        "Open Image in New Tab": "在新标签页中打开图片",
        "Save Image As…": "图片另存为…",
        "Save Image As...": "图片另存为…",
        "Download Image": "下载图片",
        "Copy Image": "复制图片",
        "Copy Image Address": "复制图片地址",
        "Add Image to Photos": "将图片添加到“照片”",
        "Share Image": "分享图片",
        "Reload Image": "重新载入图片",
        "Open With": "打开方式",
        "Open Link": "打开链接",
        "Open Link in New Window": "在新窗口中打开链接",
        "Open Link in New Tab": "在新标签页中打开链接",
        "Download Linked File": "下载链接文件",
        "Copy Link": "复制链接",
        "Copy Link Address": "复制链接地址",
        "Copy": "复制",
        "Select All": "全选",
        "Look Up": "查询",
        "Share": "分享",
        "Inspect Element": "检查元素"
    ]

    static func localizedTitle(_ title: String) -> String {
        if let localized = exactTitles[title] {
            return localized
        }
        if title.hasPrefix("Look Up “") {
            return title.replacingOccurrences(of: "Look Up ", with: "查询")
        }
        if title.hasPrefix("Search Web for “") {
            return title.replacingOccurrences(of: "Search Web for ", with: "在网页中搜索")
        }
        if title.hasPrefix("Search with ") {
            return "使用\(title.dropFirst("Search with ".count))搜索"
        }
        return title
    }
}

struct PostBodyView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.sngaTheme) private var theme
    @AppStorage(BrowsingSettings.imageFreeModeKey) private var imageFreeMode = false
    var html: String
    var cacheKey: String? = nil
    var loadOrder: Int? = nil
    var onOpenInternalLink: @MainActor (NGAInternalDestination) -> Void = { _ in }
    var onContentReady: @MainActor () -> Void = {}
    @State private var height: CGFloat = 24
    @State private var isReadyToCreateWebView = false

    var body: some View {
        Group {
            if loadOrder == nil || isReadyToCreateWebView {
                PostWebView(
                    html: html,
                    theme: theme,
                    imageFreeMode: imageFreeMode,
                    cacheKey: cacheKey,
                    contentHeight: $height,
                    onOpenInternalLink: onOpenInternalLink,
                    onOpenImage: { url in
                        model.previewImageURL = url
                    },
                    onContentReady: onContentReady
                )
            } else {
                Color.clear
                    .frame(height: 24)
                    .accessibilityHidden(true)
            }
        }
            .frame(maxWidth: .infinity)
            .frame(height: max(height, 24))
            .task(id: loadOrder) {
                guard let loadOrder else { return }
                isReadyToCreateWebView = false
                try? await Task.sleep(for: .milliseconds(loadOrder * 20))
                guard !Task.isCancelled else { return }
                isReadyToCreateWebView = true
            }
    }
}
