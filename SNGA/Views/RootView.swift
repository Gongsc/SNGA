import AppKit
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.sngaTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        @Bindable var model = model
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
            ToolbarItemGroup {
                if model.canReturnFromUserCenterToTopicList {
                    Button {
                        model.returnFromUserCenterToTopicList()
                    } label: {
                        Label("返回主题列表", systemImage: "chevron.left")
                    }
                    .help("返回主题列表")
                    .accessibilityIdentifier("user-center-back-to-topics")
                }
                if model.selectedForumID == nil,
                   model.sidebarSelection != .toolbox {
                    Button {
                        Task { await model.refreshCurrentSelection() }
                    } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                    .disabled(model.activeAccountID == nil || model.isLoading)
                }
            }
        }
        .toolbarVisibility(
            model.previewImageURL == nil ? .visible : .hidden,
            for: .windowToolbar
        )
        .sheet(isPresented: $model.showsLogin) {
            LoginSheet()
                .environment(model)
        }
        .alert("SNGA", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.clearError() } }
        )) {
            Button("好", role: .cancel) { model.clearError() }
        } message: {
            Text(model.errorMessage ?? "")
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
                WindowImagePreview(url: imageURL) {
                    model.previewImageURL = nil
                }
                .ignoresSafeArea(.container, edges: .top)
                .transition(
                    reduceMotion
                        ? .opacity
                        : .opacity.combined(with: .scale(scale: 0.98))
                )
                .zIndex(100)
            }
        }
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.16),
            value: model.previewImageURL
        )
    }

    private func clearToolbarFocus() {
        Task { @MainActor in
            await Task.yield()
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
    }
}

private struct WindowImagePreview: View {
    let url: URL
    let dismiss: () -> Void
    @State private var image: NSImage?
    @State private var imageData: Data?
    @State private var didFail = false
    @State private var imageActionError: String?
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
                                Button("复制图片", systemImage: "doc.on.doc") {
                                    copyImage()
                                }
                                Button("复制图片地址", systemImage: "link") {
                                    copyImageAddress()
                                }
                                Divider()
                                Button("图片另存为…", systemImage: "square.and.arrow.down") {
                                    saveImage()
                                }
                                Button("在默认浏览器中打开", systemImage: "safari") {
                                    openInBrowser()
                                }
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
        .alert(
            "图片操作失败",
            isPresented: Binding(
                get: { imageActionError != nil },
                set: { if !$0 { imageActionError = nil } }
            )
        ) {
        } message: {
            Text(imageActionError ?? "")
        }
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

    private func copyImage() {
        guard let image else { return }
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.writeObjects([image]) else {
            imageActionError = "系统剪贴板暂时无法写入图片。"
            return
        }
    }

    private func copyImageAddress() {
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(url.absoluteString, forType: .string) else {
            imageActionError = "系统剪贴板暂时无法写入图片地址。"
            return
        }
    }

    private func saveImage() {
        guard let imageData else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedFilename
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let destination = panel.url else { return }
            do {
                try imageData.write(to: destination, options: .atomic)
            } catch {
                imageActionError = error.localizedDescription
            }
        }
    }

    private func openInBrowser() {
        guard NSWorkspace.shared.open(url) else {
            imageActionError = "无法在默认浏览器中打开图片。"
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

    private var suggestedFilename: String {
        let filename = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
        return filename.isEmpty ? "NGA图片.png" : filename
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
            case .directory:
                ForumDirectoryView()
            case .favorites:
                FavoritesView()
            case .toolbox:
                ToolboxMenuView()
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

    var body: some View {
        if model.sidebarSelection == .toolbox {
            ToolboxFeedView(feed: model.selectedToolboxFeed)
        } else if model.selectedTopicID != nil {
            ThreadView()
        } else if model.selectedMessageID != nil {
            MessageDetailView()
        } else {
            ContentUnavailableView(
                "选择内容",
                systemImage: "text.bubble",
                description: Text("从左侧选择版面或消息，再打开一个主题。")
            )
        }
    }
}
