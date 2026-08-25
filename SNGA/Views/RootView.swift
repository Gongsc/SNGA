import AppKit
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.sngaTheme) private var theme
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
        .background(theme.backgroundColor)
        .tint(theme.accentColor)
        .toolbar {
            if model.canReturnFromUserCenterToTopicList {
                ToolbarItem(placement: .navigation) {
                    Button {
                        model.returnFromUserCenterToTopicList()
                    } label: {
                        Label("返回话题列表", systemImage: "chevron.left")
                    }
                    .help("返回话题列表")
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
            LoginSheet()
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
        model.canReturnFromUserCenterToTopicList ? 0 : 10
    }
}

private struct WindowImagePreview: View {
    let url: URL
    let onError: @MainActor (String) -> Void
    let dismiss: () -> Void
    @State private var image: NSImage?
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
                    if let image {
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

                MouseWheelZoomMonitor { delta in
                    zoom(withScrollDelta: delta)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityHidden(true)
            }
        }
        .task(id: url) {
            await loadImage()
        }
        .onExitCommand(perform: dismiss)
        .accessibilityLabel("图片预览")
        .accessibilityValue("缩放 \(Int((zoomScale * 100).rounded()))%")
    }

    private func loadImage() async {
        image = nil
        imageData = nil
        didFail = false
        zoomScale = 1
        magnificationStartScale = 1
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard !Task.isCancelled,
                  let response = response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode),
                  let decodedImage = NSImage(data: data) else {
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
