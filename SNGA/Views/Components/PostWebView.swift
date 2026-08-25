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

    /// 缓存里每一项都是一个存活的 `WKWebView`，连同它已经解码的图片一起留在内存里，
    /// 代价远高于普通的值缓存。因此除了个数上限，还按楼层高度计费：一层几千点高的
    /// 图片楼几乎必然是重的，留一层就顶得上十几层普通回复。
    ///
    /// 高度缓存（`PostContentHeightCache`）会让重建的楼层直接落回原来的高度，
    /// 没被留住的楼层重新加载也不会让版面跳动。
    init(countLimit: Int = 20, totalHeightLimit: Int = 24_000) {
        entries.countLimit = countLimit
        entries.totalCostLimit = totalHeightLimit
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
            forKey: key as NSString,
            cost: Int(max(1, height.rounded()))
        )
    }

    func removeAll() {
        entries.removeAllObjects()
    }
}

/// 楼层测得的高度。
///
/// 高度原先只存在楼层视图的 `@State` 里，楼层视图一销毁，测量结果就随之丢失；
/// 重建时楼层从占位高度重新长起来，整页内容高度便持续伸缩 —— 表现为滚动条长度
/// 乱跳、滚动位置被反复挤动、回不到顶部。图片楼层最明显：图片本身不占位
/// （`height:auto`），一层的最终高度要等所有图片到达才成形。
///
/// 整页楼层现在一次性实例化，翻页之内不再销毁重建；但翻页、切话题、返回上一个
/// 话题都会重建整页楼层，届时把高度按楼层键留在视图之外，楼层就能直接以上次的
/// 高度落位。
@MainActor
final class PostContentHeightCache {
    static let shared = PostContentHeightCache()
    private let heights = NSCache<NSString, NSNumber>()

    /// 每项只是一个数字，因此上限按 “整个话题的楼层数” 来定，而不是可见楼层数。
    init(countLimit: Int = 600) {
        heights.countLimit = countLimit
    }

    func height(for key: String) -> CGFloat? {
        heights.object(forKey: key as NSString).map { CGFloat($0.doubleValue) }
    }

    func store(_ height: CGFloat, for key: String) {
        heights.setObject(NSNumber(value: Double(height)), forKey: key as NSString)
    }

    func removeAll() {
        heights.removeAllObjects()
    }
}

enum PostImagePolicy {
    static func applying(to html: String, hidesRemoteImages: Bool, baseURL: URL) -> String {
        guard hidesRemoteImages else { return html }
        do {
            let document = try SwiftSoup.parse(html, baseURL.absoluteString)
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
    @Environment(\.forumSiteDescriptor) private var siteDescriptor
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
            image.decoding = "async";
        });

        // 只等 `load`，不主动 `decode()`。楼层的网页视图高度等于正文全高，
        // WebKit 把整篇文档都算作可见区域，逐张 `decode()` 会在这一刻把一层里
        // 所有图片按原始像素展开成位图 —— 图大量多时就是这一下把界面顶住的。
        // 高度只需要图片的尺寸，`load` 已经够了，位图交给绘制时按需解。
        const waitForImage = (image) => new Promise((resolve) => {
            if (image.complete) {
                resolve();
                return;
            }
            image.addEventListener("load", resolve, { once: true });
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
        let themedHTML = context.coordinator.renderedHTML(for: self)
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
        webView.loadHTMLString(themedHTML, baseURL: siteDescriptor.baseURL)
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
        context.coordinator.siteDescriptor = siteDescriptor
        let themedHTML = context.coordinator.renderedHTML(for: self)
        if context.coordinator.lastHTML != themedHTML {
            context.coordinator.prepareForLoad(themedHTML)
            webView.loadHTMLString(themedHTML, baseURL: siteDescriptor.baseURL)
        }
    }

    fileprivate static func render(
        html: String,
        theme: ResolvedAppTheme,
        imageFreeMode: Bool,
        baseURL: URL
    ) -> String {
        PostImagePolicy.applying(
            to: theme.applying(to: html),
            hidesRemoteImages: imageFreeMode,
            baseURL: baseURL
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
        /// 由 `updateNSView` 灌进来 —— Coordinator 读不到环境。
        var siteDescriptor: ForumSiteDescriptor = .nga
        var lastHTML = ""
        private var renderCache: RenderCache?
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

        private struct RenderCache {
            let source: String
            let theme: ResolvedAppTheme
            let imageFreeMode: Bool
            /// 换站点就要重渲染 —— 相对地址是按它解析的。
            let baseURL: URL
            let output: String
        }

        /// `updateNSView` 会在每个 SwiftUI 更新周期对每个楼层各跑一次，而渲染要做
        /// 六次以上的全文替换，无图模式下还要完整解析一遍 HTML —— 全部在主线程。
        /// 主题与无图模式都是低频变化量，这里按输入记忆化，未变时直接复用。
        /// 相同 `Post` 值传来的 `html` 是同一份字符串存储，`==` 走的是常数时间快路径。
        @MainActor
        fileprivate func renderedHTML(for view: PostWebView) -> String {
            if let renderCache,
               renderCache.source == view.html,
               renderCache.theme == view.theme,
               renderCache.imageFreeMode == view.imageFreeMode,
               renderCache.baseURL == view.siteDescriptor.baseURL {
                return renderCache.output
            }
            let output = PostWebView.render(
                html: view.html,
                theme: view.theme,
                imageFreeMode: view.imageFreeMode,
                baseURL: view.siteDescriptor.baseURL
            )
            renderCache = RenderCache(
                source: view.html,
                theme: view.theme,
                imageFreeMode: view.imageFreeMode,
                baseURL: view.siteDescriptor.baseURL,
                output: output
            )
            return output
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
                webView.loadHTMLString(html, baseURL: siteDescriptor.baseURL)
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
            if let destination = siteDescriptor.internalDestination(for: url) {
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
    @Environment(\.forumSiteDescriptor) private var siteDescriptor
    @Environment(AppModel.self) private var model
    @Environment(\.sngaTheme) private var theme
    @AppStorage(BrowsingSettings.imageFreeModeKey) private var imageFreeMode = false
    var html: String
    /// 可原生渲染的正文。为 nil 时回退到 `WKWebView`。
    var nativeContent: PostContent? = nil
    var cacheKey: String? = nil
    var loadOrder: Int? = nil
    var onOpenInternalLink: @MainActor (NGAInternalDestination) -> Void = { _ in }
    var onContentReady: @MainActor () -> Void = {}
    private static let maximumStaggerSteps = 4
    private static let placeholderHeight: CGFloat = 24
    @State private var height: CGFloat
    @State private var isReadyToCreateWebView = false

    @MainActor
    init(
        html: String,
        nativeContent: PostContent? = nil,
        cacheKey: String? = nil,
        loadOrder: Int? = nil,
        onOpenInternalLink: @escaping @MainActor (NGAInternalDestination) -> Void = { _ in },
        onContentReady: @escaping @MainActor () -> Void = {}
    ) {
        self.html = html
        self.nativeContent = nativeContent
        self.cacheKey = cacheKey
        self.loadOrder = loadOrder
        self.onOpenInternalLink = onOpenInternalLink
        self.onContentReady = onContentReady
        // 重建楼层时直接落回上次测得的高度：先摆成占位高度再测一遍，
        // 会让滚动内容的总高度在每次重建时塌陷又长回来。
        _height = State(
            initialValue: cacheKey.flatMap(PostContentHeightCache.shared.height(for:))
                ?? Self.placeholderHeight
        )
    }

    var body: some View {
        if let nativeContent {
            nativeBody(nativeContent)
        } else {
            webViewBody
        }
    }

    /// 原生分支不需要测高，也不产生 WKWebView，因此直接汇报就绪 ——
    /// 配图各自按需加载，骨架屏不必等它们。
    private func nativeBody(_ content: PostContent) -> some View {
        PostContentView(
            content: content,
            imageFreeMode: imageFreeMode,
            onOpenLink: { url in
                if let destination = siteDescriptor.internalDestination(for: url) {
                    onOpenInternalLink(destination)
                } else {
                    NSWorkspace.shared.open(url)
                }
            }
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: content) {
            onContentReady()
        }
    }

    private var webViewBody: some View {
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
                    .accessibilityHidden(true)
            }
        }
            .frame(maxWidth: .infinity)
            .frame(height: max(height, Self.placeholderHeight))
            .onChange(of: height) { _, measured in
                guard let cacheKey else { return }
                PostContentHeightCache.shared.store(measured, for: cacheKey)
                PostContentDiagnostics.recordHeightChange(key: cacheKey, to: measured)
            }
            .task(id: loadOrder) {
                guard let loadOrder else { return }
                isReadyToCreateWebView = false
                // 错峰只是为了避免同一个 runloop 周期内集中创建 WKWebView。整页楼层
                // 一次性实例化，这些任务都在同一拍启动，但绝大多数楼层走原生渲染，
                // 一页通常只剩一两层网页视图，要错开的量本就不大，因此给延迟封顶 ——
                // 不封顶的话，一页里唯一那层网页视图只因为排在第 20 层，就要凭空
                // 多等 400ms 才开始渲染。
                let staggerSteps = min(loadOrder, Self.maximumStaggerSteps)
                if staggerSteps > 0 {
                    try? await Task.sleep(for: .milliseconds(staggerSteps * 20))
                }
                guard !Task.isCancelled else { return }
                isReadyToCreateWebView = true
            }
    }
}
