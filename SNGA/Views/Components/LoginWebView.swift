import AppKit
import SwiftUI
@preconcurrency import WebKit

enum LoginPageState: Equatable {
    case loading
    case loaded
    case failed(String)
}

struct LoginWebView: NSViewRepresentable {
    var onStateChange: @MainActor (LoginPageState) -> Void
    var onAuthenticated: @MainActor (LoginCapture) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onStateChange: onStateChange, onAuthenticated: onAuthenticated)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        configuration.applicationNameForUserAgent = "SNGA/1.0"
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        context.coordinator.startMonitoringCookies(in: webView)
        let url = URL(string: "https://bbs.nga.cn/nuke.php?__lib=login&__act=account&login")!
        var request = URLRequest(url: url)
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
        private let onStateChange: @MainActor (LoginPageState) -> Void
        private let onAuthenticated: @MainActor (LoginCapture) -> Void
        private var completed = false
        private var cookieMonitor: Task<Void, Never>?

        init(
            onStateChange: @escaping @MainActor (LoginPageState) -> Void,
            onAuthenticated: @escaping @MainActor (LoginCapture) -> Void
        ) {
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
            alert.messageText = "NGA"
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
            alert.messageText = "NGA"
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
            alert.messageText = "NGA"
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
            if host == "nga.cn" || host.hasSuffix(".nga.cn") || url.scheme == "about" {
                decisionHandler(.allow)
            } else if navigationAction.navigationType == .linkActivated {
                decisionHandler(.cancel)
                NSWorkspace.shared.open(url)
            } else {
                decisionHandler(.allow)
            }
        }

        private func report(_ error: Error) {
            let nsError = error as NSError
            guard nsError.code != NSURLErrorCancelled else { return }
            onStateChange(.failed("无法载入 NGA 登录页面：\(error.localizedDescription)"))
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
                let ngaCookies = cookies.filter { cookie in
                    let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
                    return domain == "nga.cn" || domain.hasSuffix(".nga.cn")
                }.map(SessionCookie.init)
                let uidCookie = ngaCookies.first { $0.name.caseInsensitiveCompare("ngaPassportUid") == .orderedSame }
                let credentialCookie = ngaCookies.first { $0.name.caseInsensitiveCompare("ngaPassportCid") == .orderedSame }
                guard let uid = uidCookie.flatMap({ Int64($0.value) }), credentialCookie != nil else { return }
                self.completed = true
                self.stopMonitoringCookies()
                Task { @MainActor in
                    self.onAuthenticated(LoginCapture(uid: uid, cookies: ngaCookies))
                }
            }
        }
    }
}

struct LoginSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var title = "登录 NGA"
    @State private var pageState: LoginPageState = .loading
    @State private var loadAttempt = UUID()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline)
                    Text("登录过程由 NGA 官方页面完成，SNGA 不读取或保存密码。")
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
                        Text("正在载入 NGA 登录页面…")
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
