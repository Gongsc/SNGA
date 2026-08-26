import AppKit
import SwiftUI
@preconcurrency import WebKit

enum LoginPageState: Equatable {
    case loading
    case loaded
    case failed(String)
}

struct LoginWebView: NSViewRepresentable {
    /// 去哪个站登录、认哪些 Cookie，全从这里读。
    var descriptor: ForumSiteDescriptor
    /// 具体落在哪一页。同一个站可能有好几种登录方式。
    var loginURL: URL
    var onStateChange: @MainActor (LoginPageState) -> Void
    var onAuthenticated: @MainActor (LoginCapture) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            descriptor: descriptor,
            onStateChange: onStateChange,
            onAuthenticated: onAuthenticated
        )
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        // 只有明说自报家门的站点才动 UA。要求用 WebView 真实 UA 的站点一行都不能设 ——
        // 设置本身会把 UA 标记为已覆盖并改变客户端提示的上报方式，即使设成原值也一样。
        if case .fixed = descriptor.userAgent {
            configuration.applicationNameForUserAgent = "SNGA/1.0"
        }
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        context.coordinator.startMonitoringCookies(in: webView)
        var request = URLRequest(url: loginURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 30
        webView.load(request)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.stopMonitoringCookies()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        private let descriptor: ForumSiteDescriptor
        private let onStateChange: @MainActor (LoginPageState) -> Void
        private let onAuthenticated: @MainActor (LoginCapture) -> Void
        private var completed = false
        private var cookieMonitor: Task<Void, Never>?

        init(
            descriptor: ForumSiteDescriptor,
            onStateChange: @escaping @MainActor (LoginPageState) -> Void,
            onAuthenticated: @escaping @MainActor (LoginCapture) -> Void
        ) {
            self.descriptor = descriptor
            self.onStateChange = onStateChange
            self.onAuthenticated = onAuthenticated
        }

        func startMonitoringCookies(in webView: WKWebView) {
            stopMonitoringCookies()
            cookieMonitor = Task { @MainActor [weak self, weak webView] in
                while !Task.isCancelled {
                    guard let self, let webView, !self.completed else { return }
                    self.captureCookies(from: webView)
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
        }

        func stopMonitoringCookies() {
            cookieMonitor?.cancel()
            cookieMonitor = nil
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation?) {
            onStateChange(.loading)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
            onStateChange(.loaded)
            captureCookies(from: webView)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: Error) {
            report(error)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation?, withError error: Error) {
            report(error)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            onStateChange(.failed("登录页面进程意外退出，请重试。"))
        }

        func webView(
            _ webView: WKWebView,
            runJavaScriptAlertPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping @MainActor @Sendable () -> Void
        ) {
            let alert = NSAlert()
            alert.messageText = descriptor.displayName
            alert.informativeText = message
            alert.addButton(withTitle: "好")
            present(alert, in: webView) { _ in completionHandler() }
        }

        func webView(
            _ webView: WKWebView,
            runJavaScriptConfirmPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping @MainActor @Sendable (Bool) -> Void
        ) {
            let alert = NSAlert()
            alert.messageText = descriptor.displayName
            alert.informativeText = message
            alert.addButton(withTitle: "确定")
            alert.addButton(withTitle: "取消")
            present(alert, in: webView) { response in
                completionHandler(response == .alertFirstButtonReturn)
            }
        }

        func webView(
            _ webView: WKWebView,
            runJavaScriptTextInputPanelWithPrompt prompt: String,
            defaultText: String?,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping @MainActor @Sendable (String?) -> Void
        ) {
            let field = NSTextField(string: defaultText ?? "")
            field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)

            let alert = NSAlert()
            alert.messageText = descriptor.displayName
            alert.informativeText = prompt
            alert.accessoryView = field
            alert.addButton(withTitle: "确定")
            alert.addButton(withTitle: "取消")
            present(alert, in: webView) { response in
                completionHandler(response == .alertFirstButtonReturn ? field.stringValue : nil)
            }
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            guard navigationAction.targetFrame == nil,
                  let url = navigationAction.request.url else { return nil }
            if url.scheme == "http" || url.scheme == "https" {
                NSWorkspace.shared.open(url)
            }
            return nil
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url,
                  let host = url.host?.lowercased() else {
                decisionHandler(.allow)
                return
            }
            // 站内的放行 —— 登录页之间的来回切换（比如密码登录和邮箱验证登录）走的就是这条。
            // 之前这里写死了 NGA 的域名，NodeSeek 的站内链接会被当成外链踢到浏览器。
            if descriptor.owns(host: host) || url.scheme == "about" {
                decisionHandler(.allow)
            } else if navigationAction.navigationType == .linkActivated {
                // 用户主动点开的外链交给系统浏览器；登录页嵌的第三方资源（人机验证挂件之类）
                // 不是 linkActivated，照常加载。
                decisionHandler(.cancel)
                NSWorkspace.shared.open(url)
            } else {
                decisionHandler(.allow)
            }
        }

        private func report(_ error: Error) {
            let nsError = error as NSError
            guard nsError.code != NSURLErrorCancelled else { return }
            onStateChange(.failed("无法载入\(descriptor.displayName)登录页面：\(error.localizedDescription)"))
        }

        private func present(
            _ alert: NSAlert,
            in webView: WKWebView,
            completion: @escaping @MainActor (NSApplication.ModalResponse) -> Void
        ) {
            if let window = webView.window {
                alert.beginSheetModal(for: window, completionHandler: completion)
            } else {
                completion(alert.runModal())
            }
        }

        private func captureCookies(from webView: WKWebView) {
            guard !completed else { return }
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                guard let self, !self.completed else { return }
                let descriptor = self.descriptor
                let siteCookies = cookies
                    .filter { descriptor.owns(cookieDomain: $0.domain) }
                    .map(SessionCookie.init)
                let hasSession = descriptor.sessionCookieNames.allSatisfy { name in
                    siteCookies.contains {
                        $0.name.caseInsensitiveCompare(name) == .orderedSame && !$0.value.isEmpty
                    }
                }
                guard hasSession else { return }

                switch descriptor.userIDSource {
                case let .cookie(name):
                    guard let uid = siteCookies.first(where: {
                        $0.name.caseInsensitiveCompare(name) == .orderedSame
                    }).flatMap({ Int64($0.value) }) else { return }
                    self.finish(uid: uid, cookies: siteCookies)

                case let .renderedDOM(javaScript):
                    // 编号只在渲染完的 DOM 里。Cookie 到手不代表卡片已经画出来了，
                    // 所以读不到就先不结束 —— 轮询下一轮再试。
                    Task { @MainActor [weak self, weak webView] in
                        guard let self, let webView else { return }
                        let value = try? await webView.evaluateJavaScript(javaScript)
                        guard let text = value as? String, let uid = Int64(text) else { return }
                        self.finish(uid: uid, cookies: siteCookies)
                    }
                }
            }
        }

        /// 抓取完成：停掉轮询，把结果交出去。只走一次。
        private func finish(uid: Int64, cookies: [SessionCookie]) {
            guard !completed else { return }
            completed = true
            stopMonitoringCookies()
            onAuthenticated(LoginCapture(site: descriptor.site, uid: uid, cookies: cookies))
        }
    }
}

struct LoginSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var site: ForumSite = .nga
    /// 用哪种方式登录。站点可能给不止一条路。
    var method: SiteLoginMethod = ForumSiteDescriptor.nga.loginMethods[0]
    var title: String { "\(site.displayName) · \(method.title)" }
    @State private var pageState: LoginPageState = .loading
    @State private var loadAttempt = UUID()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline)
                    Text(method.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()

            Divider()

            ZStack {
                LoginWebView(
                    descriptor: site.descriptor,
                    loginURL: method.url,
                    onStateChange: { pageState = $0 },
                    onAuthenticated: { capture in
                        Task {
                            await model.addAccount(capture: capture)
                            dismiss()
                        }
                    }
                )
                .id(loadAttempt)

                switch pageState {
                case .loading:
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("正在载入 \(site.displayName) 登录页面…")
                            .foregroundStyle(.secondary)
                    }
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityIdentifier("login-loading")
                case .loaded:
                    EmptyView()
                case let .failed(message):
                    ContentUnavailableView {
                        Label("登录页面载入失败", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("重试") {
                            pageState = .loading
                            loadAttempt = UUID()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.background)
                    .accessibilityIdentifier("login-error")
                }
            }
        }
        .frame(minWidth: 720, minHeight: 620)
    }
}
