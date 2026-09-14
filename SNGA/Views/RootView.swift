import AppKit
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.sngaTheme) private var theme
    @Environment(\.sngaFonts) private var fonts
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        @Bindable var model = model
        @Bindable var session = model.session
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 210, ideal: 245)
                .background(theme.backgroundColor)
        } content: {
            ContentColumnView(
                reservesSidebarToggleSpace: columnVisibility == .doubleColumn
            )
                .navigationSplitViewColumnWidth(min: 320, ideal: 400)
                .background(theme.backgroundColor)
        } detail: {
            DetailColumnView()
                .background(theme.backgroundColor)
        }
        .navigationSplitViewStyle(.balanced)
        // 正文渲染要按当前账号所属的站点解析相对地址和站内链接。
        .environment(
            \.forumSiteDescriptor,
            (model.session.activeService?.site ?? .nga).descriptor
        )
        .background(theme.backgroundColor)
        .tint(theme.accentColor)
        .toolbar {
            if model.canReturnFromUserCenter {
                ToolbarItem(placement: .navigation) {
                    Button {
                        model.returnFromUserCenter()
                    } label: {
                        Label(model.userCenterReturnTitle, systemImage: "chevron.left")
                    }
                    .help(model.userCenterReturnTitle)
                    .accessibilityIdentifier("user-center-back-to-topics")
                }
            }

            if let browserModuleTitle {
                ToolbarItem(placement: .navigation) {
                    Text(browserModuleTitle)
                        .font(.title2.bold())
                        .lineLimit(1)
                        .padding(.leading, browserModuleTitleLeadingInset)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("browser-module-title")
                }
                .sharedBackgroundVisibility(.hidden)
            }
        }
        .toolbarVisibility(
            model.previewImageURL == nil ? .visible : .hidden,
            for: .windowToolbar
        )
        .sheet(isPresented: $session.showsLogin) {
            LoginSheet(site: model.session.loginSite, method: model.session.loginMethod)
                .environment(model)
        }
        .alert("SNGA", isPresented: Binding(
            get: { model.session.errorMessage != nil },
            set: { if !$0 { model.session.clearError() } }
        )) {
            Button("好", role: .cancel) { model.session.clearError() }
        } message: {
            Text(model.session.errorMessage ?? "")
        }
        .alert("图片操作失败", isPresented: Binding(
            get: { model.imageActionError != nil },
            set: { if !$0 { model.imageActionError = nil } }
        )) {
            Button("好", role: .cancel) { model.imageActionError = nil }
        } message: {
            Text(model.imageActionError ?? "")
        }
        .task {
            await model.bootstrap()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                guard !Task.isCancelled else { return }
                await model.performMaintenance()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await model.performMaintenance() }
            }
        }
        .onChange(of: columnVisibility) {
            clearToolbarFocus()
        }
        .onChange(of: fonts) {
            // 缓存里那些数字和存活的 WKWebView 都是按旧字号排出来的版。留着的话，
            // 改完字号回到话题，整页楼层会先按旧高度落位再跳一次。
            PostWebViewCache.shared.removeAll()
            PostContentHeightCache.shared.removeAll()
        }
        .onAppear {
            clearToolbarFocus()
        }
        .onReceive(NotificationCenter.default.publisher(for: .sngaOpenMessage)) { notification in
            let accountID = notification.userInfo?["accountID"] as? String ?? ""
            let messageID = notification.userInfo?["messageID"] as? String ?? ""
            let messageFolder = notification.userInfo?["messageFolder"] as? String ?? ""
            Task {
                await model.handleNotification(
                    accountIDString: accountID,
                    messageIDString: messageID,
                    messageFolderString: messageFolder
                )
            }
        }
        .overlay {
            if let imageURL = model.previewImageURL {
                WindowImagePreview(
                    url: imageURL,
                    onError: { model.imageActionError = $0 },
                    dismiss: { model.previewImageURL = nil }
                )
                .ignoresSafeArea(.container, edges: .top)
                .zIndex(100)
            }
        }
    }

    private func clearToolbarFocus() {
        Task { @MainActor in
            await Task.yield()
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
    }

    private var browserModuleTitle: String? {
        switch model.sidebarSelection {
        case .userCenter, .none:
            "用户中心"
        case .aiProfiles:
            "AI 画像"
        case .directory:
            "全部版面"
        case .search:
            "搜索"
        case .favorites:
            "收藏夹"
        case .topicHistory:
            "浏览历史"
        case .addAccount:
            "添加账号"
        case .toolbox:
            "小工具"
        case .settings:
            "设置"
        case .forum:
            nil
        case let .messages(folder):
            folder == .notifications ? "论坛消息" : folder.title
        }
    }

    private var browserModuleTitleLeadingInset: CGFloat {
        model.canReturnFromUserCenter ? 0 : 10
    }
}

private struct WindowImagePreview: View {
    let url: URL
    let onError: @MainActor (String) -> Void
    let dismiss: () -> Void
    @State private var image: NSImage?
    @State private var svgData: Data?
    @State private var imageData: Data?
    @State private var didFail = false
    @State private var zoomScale: CGFloat = 1
    @State private var magnificationStartScale: CGFloat = 1

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Button(action: dismiss) {
                    Color.black.opacity(0.9)
                        .ignoresSafeArea()
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭图片预览")

                Group {
                    if let svgData {
                        // 矢量图交给 WebKit：`NSImage` 画出来是一团糊，
                        // 原因写在 `SVGImage` 上。
                        SVGImageView(data: svgData, baseURL: url)
                            .frame(
                                maxWidth: max(120, proxy.size.width - 80),
                                maxHeight: max(120, proxy.size.height - 80)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .shadow(color: .black.opacity(0.5), radius: 20)
                            .contextMenu {
                                PostImageContextMenu(
                                    url: url,
                                    data: imageData,
                                    onError: onError
                                )
                            }
                            .accessibilityLabel("矢量图预览")
                    } else if let image {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                            .frame(
                                maxWidth: max(120, proxy.size.width - 80),
                                maxHeight: max(120, proxy.size.height - 80)
                            )
                            .scaleEffect(zoomScale)
                            .shadow(color: .black.opacity(0.5), radius: 20)
                            .gesture(
                                MagnifyGesture()
                                    .onChanged { value in
                                        zoomScale = clampedZoom(
                                            magnificationStartScale * value.magnification
                                        )
                                    }
                                    .onEnded { _ in
                                        magnificationStartScale = zoomScale
                                    }
                            )
                            .contextMenu {
                                PostImageContextMenu(
                                    url: url,
                                    image: image,
                                    data: imageData,
                                    onError: onError
                                )
                            }
                    } else if didFail {
                        ContentUnavailableView {
                            Label("图片载入失败", systemImage: "photo.badge.exclamationmark")
                        } description: {
                            Text("可以尝试在默认浏览器中打开。")
                        } actions: {
                            Button("在默认浏览器中打开") {
                                openInBrowser()
                            }
                        }
                        .foregroundStyle(.white)
                    } else {
                        ProgressView("正在载入图片…")
                            .controlSize(.large)
                            .foregroundStyle(.white)
                    }
                }

                VStack {
                    HStack(spacing: 10) {
                        Spacer()
                        Button(
                            "在浏览器中打开",
                            systemImage: "safari",
                            action: openInBrowser
                        )
                        Button(action: dismiss) {
                            Label("关闭", systemImage: "xmark")
                        }
                        .keyboardShortcut(.cancelAction)
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(18)
                    Spacer()
                }

                // 矢量图那条路不装这个监听：它会把滚轮事件整个吃掉，而 WebKit
                // 自己的滚动和捏合缩放正是那边要用的东西 —— 一份比窗口高的报告，
                // 滚不动就只看得见开头几行。
                if svgData == nil {
                    MouseWheelZoomMonitor { delta in
                        zoom(withScrollDelta: delta)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityHidden(true)
                }
            }
        }
        .task(id: url) {
            await loadImage()
        }
        .onExitCommand(perform: dismiss)
        .accessibilityLabel("图片预览")
        // 矢量图的缩放归 WebKit 管，这里报不出它此刻是多少。
        .accessibilityValue(svgData == nil ? "缩放 \(Int((zoomScale * 100).rounded()))%" : "")
    }

    private func loadImage() async {
        image = nil
        svgData = nil
        imageData = nil
        didFail = false
        zoomScale = 1
        magnificationStartScale = 1
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard !Task.isCancelled,
                  let response = response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode) else {
                throw URLError(.cannotDecodeContentData)
            }
            // SVG 要先认出来再分路。认反了的话 `NSImage` 也会「成功」——
            // 它解得出那份 SVG，只是解出来是一张 74×46 点的画布。
            if SVGImage.isSVG(data: data, mimeType: response.mimeType, url: url) {
                imageData = data
                svgData = data
                return
            }
            guard let decodedImage = NSImage(data: data) else {
                throw URLError(.cannotDecodeContentData)
            }
            imageData = data
            image = decodedImage
        } catch {
            guard !Task.isCancelled else { return }
            didFail = true
        }
    }

    private func openInBrowser() {
        guard NSWorkspace.shared.open(url) else {
            onError("无法在默认浏览器中打开图片。")
            return
        }
    }

    private func zoom(withScrollDelta delta: CGFloat) {
        guard image != nil, abs(delta) > 0.01 else { return }
        zoomScale = clampedZoom(zoomScale * exp(delta * 0.018))
        magnificationStartScale = zoomScale
    }

    private func clampedZoom(_ proposedScale: CGFloat) -> CGFloat {
        min(max(proposedScale, 0.25), 5)
    }
}

private struct ContentColumnView: View {
    @Environment(AppModel.self) private var model
    let reservesSidebarToggleSpace: Bool

    var body: some View {
        Group {
            switch model.sidebarSelection {
            case let .userCenter(uid):
                UserCenterView(uid: uid)
            case .none:
                UserCenterView(uid: nil)
            case .aiProfiles:
                AIProfileMenuView()
            case .directory:
                ForumDirectoryView()
            case .search:
                GlobalForumSearchView()
            case .favorites:
                FavoritesView()
            case .topicHistory:
                TopicHistoryView()
            case .addAccount:
                AddAccountView()
            case .toolbox:
                ToolboxMenuView()
            case .settings:
                SettingsMenuView()
            case let .forum(forumID):
                TopicListView(
                    forumID: forumID,
                    reservesSidebarToggleSpace: reservesSidebarToggleSpace
                )
            case let .messages(folder):
                MessageListView(folder: folder)
            }
        }
    }
}

private struct DetailColumnView: View {
    @Environment(AppModel.self) private var model
    @Environment(ToolboxStore.self) private var toolbox

    var body: some View {
        if model.sidebarSelection == .settings {
            SettingsDetailView(section: model.selectedSettingsSection)
        } else if model.sidebarSelection == .toolbox {
            ToolboxFeedView(feed: toolbox.selectedFeed)
        } else if showsAIProfileDetail {
            AIProfileDetailView()
        } else if model.thread.selectedTopicID != nil {
            ThreadView()
        } else if model.messaging.selectedMessageID != nil {
            MessageDetailView()
        } else {
            ContentUnavailableView(
                "选择内容",
                systemImage: "text.bubble",
                description: Text("从左侧选择版面或消息，再打开一个话题。")
            )
        }
    }

    private var showsAIProfileDetail: Bool {
        guard AISettings.isEnabled else { return false }
        if model.sidebarSelection == .aiProfiles { return true }
        guard case .userCenter = model.sidebarSelection else { return false }
        return model.aiProfiles.isShowingDetail
    }
}
