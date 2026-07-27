import AppKit
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.sngaTheme) private var theme
    @State private var accountToRemove: AccountSummary?
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        @Bindable var model = model
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(accountToRemove: $accountToRemove)
                .navigationSplitViewColumnWidth(min: 210, ideal: 245)
        } content: {
            ContentColumnView(
                reservesSidebarToggleSpace: columnVisibility == .doubleColumn
            )
                .navigationSplitViewColumnWidth(min: 320, ideal: 400)
        } detail: {
            DetailColumnView()
        }
        .navigationSplitViewStyle(.balanced)
        .tint(theme.accentColor)
        .toolbar {
            ToolbarItemGroup {
                if model.isLoading {
                    ProgressView().controlSize(.small)
                }
                if model.canReturnFromUserCenterToTopicList {
                    Button {
                        model.returnFromUserCenterToTopicList()
                    } label: {
                        Label("返回主题列表", systemImage: "chevron.left")
                    }
                    .help("返回主题列表")
                    .accessibilityIdentifier("user-center-back-to-topics")
                }
                if model.selectedForumID == nil {
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
        .confirmationDialog(
            "移除账号？",
            isPresented: Binding(
                get: { accountToRemove != nil },
                set: { if !$0 { accountToRemove = nil } }
            ),
            presenting: accountToRemove
        ) { account in
            Button("移除 \(account.displayName)", role: .destructive) {
                Task { await model.removeAccount(account.id) }
                accountToRemove = nil
            }
            Button("取消", role: .cancel) { accountToRemove = nil }
        } message: { _ in
            Text("会删除此账号的会话、收藏和草稿，不能撤销。")
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
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
                .zIndex(100)
            }
        }
        .animation(.easeOut(duration: 0.16), value: model.previewImageURL)
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

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black.opacity(0.9)
                    .ignoresSafeArea()
                    .onTapGesture(perform: dismiss)

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
                            .shadow(color: .black.opacity(0.5), radius: 20)
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
                                    NSWorkspace.shared.open(url)
                                }
                            }
                    } else if didFail {
                        ContentUnavailableView {
                            Label("图片载入失败", systemImage: "photo.badge.exclamationmark")
                        } description: {
                            Text("可以尝试在默认浏览器中打开。")
                        } actions: {
                            Button("在默认浏览器中打开") {
                                NSWorkspace.shared.open(url)
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
                        Button {
                            NSWorkspace.shared.open(url)
                        } label: {
                            Label("在浏览器中打开", systemImage: "safari")
                        }
                        Button(action: dismiss) {
                            Label("关闭", systemImage: "xmark")
                        }
                        .keyboardShortcut(.cancelAction)
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(18)
                    Spacer()
                }
            }
        }
        .task(id: url) {
            await loadImage()
        }
        .onExitCommand(perform: dismiss)
        .accessibilityLabel("图片预览")
    }

    private func loadImage() async {
        image = nil
        imageData = nil
        didFail = false
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
        NSPasteboard.general.writeObjects([image])
    }

    private func copyImageAddress() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    private func saveImage() {
        guard let imageData else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedFilename
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let destination = panel.url else { return }
            try? imageData.write(to: destination, options: .atomic)
        }
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
        if model.selectedTopicID != nil {
            ThreadView()
        } else if model.selectedMessageID != nil {
            MessageDetailView()
        } else {
            ContentUnavailableView(
                "选择内容",
                systemImage: "text.bubble",
                description: Text("从左侧选择板块或消息，再打开一个主题。")
            )
        }
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(AppTheme.storageKey) private var selectedThemeRaw = AppTheme.system.rawValue
    @AppStorage(RuntimeLogSettings.enabledKey) private var runtimeLogEnabled = false
    @State private var accountToRemove: AccountSummary?
    @State private var loginRequest: SettingsLoginRequest?
    @State private var runtimeLogPath = RuntimeLogSettings.displayPath
    @State private var runtimeLogError: String?

    var body: some View {
        Form {
            Section("外观") {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 104), spacing: 10)],
                    spacing: 10
                ) {
                    ForEach(AppTheme.allCases) { theme in
                        ThemeChoiceCard(
                            theme: theme,
                            isSelected: selectedThemeRaw == theme.rawValue
                        ) {
                            selectedThemeRaw = theme.rawValue
                        }
                    }
                }
                Text(AppTheme.resolve(selectedThemeRaw).description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("账号") {
                if model.accounts.isEmpty {
                    Text("尚未添加账号")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.accounts) { account in
                    HStack(spacing: 10) {
                        AsyncImage(url: account.avatarURL) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            Image(systemName: "person.crop.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .frame(width: 28, height: 28)
                        .clipShape(.circle)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(account.displayName)
                            Text(account.sessionState.title)
                                .font(.caption)
                                .foregroundStyle(account.sessionState == .valid ? Color.secondary : Color.red)
                        }
                        Spacer()
                        Button("重新登录") {
                            loginRequest = SettingsLoginRequest(title: "重新登录 \(account.displayName)")
                        }
                        .controlSize(.small)
                        Button("移除", role: .destructive) {
                            accountToRemove = account
                        }
                        .controlSize(.small)
                    }
                }
                Button("添加账号", systemImage: "person.badge.plus") {
                    loginRequest = SettingsLoginRequest(title: "登录 NGA")
                }
            }
            Section("后台行为") {
                LabeledContent("消息检查", value: "应用运行时每 5 分钟")
                LabeledContent("每日签到", value: "启动、回到前台及跨日时")
                Text("退出 SNGA 后不会运行签到或消息轮询。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("运行日志") {
                Toggle("启用运行日志", isOn: $runtimeLogEnabled)
                    .onChange(of: runtimeLogEnabled) { _, isEnabled in
                        guard isEnabled else { return }
                        Task {
                            await RuntimeLogger.shared.log(
                                category: "configuration",
                                "Runtime logging enabled"
                            )
                        }
                    }

                LabeledContent("输出目录") {
                    Text(runtimeLogPath)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }

                HStack {
                    Button("选择目录…", systemImage: "folder") {
                        chooseRuntimeLogDirectory()
                    }
                    if RuntimeLogSettings.selectedDirectoryURL != nil {
                        Button("恢复默认") {
                            RuntimeLogSettings.useDefaultDirectory()
                            runtimeLogPath = RuntimeLogSettings.displayPath
                        }
                    }
                }

                Text("每天生成一个 SNGA-日期.log 文件。请求正文、Cookie 和登录令牌不会写入日志。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 620, height: 540)
        .sheet(item: $loginRequest) { request in
            LoginSheet(title: request.title)
                .environment(model)
        }
        .confirmationDialog(
            "移除账号？",
            isPresented: Binding(
                get: { accountToRemove != nil },
                set: { if !$0 { accountToRemove = nil } }
            ),
            presenting: accountToRemove
        ) { account in
            Button("移除 \(account.displayName)", role: .destructive) {
                Task { await model.removeAccount(account.id) }
                accountToRemove = nil
            }
            Button("取消", role: .cancel) { accountToRemove = nil }
        } message: { _ in
            Text("会删除此账号的本地会话、收藏和草稿，不能撤销。")
        }
        .alert(
            "无法使用日志目录",
            isPresented: Binding(
                get: { runtimeLogError != nil },
                set: { if !$0 { runtimeLogError = nil } }
            )
        ) {
            Button("好") { runtimeLogError = nil }
        } message: {
            Text(runtimeLogError ?? "")
        }
    }

    private func chooseRuntimeLogDirectory() {
        let panel = NSOpenPanel()
        panel.title = "选择运行日志输出目录"
        panel.prompt = "选择"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = RuntimeLogSettings.outputDirectoryURL
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try RuntimeLogSettings.selectDirectory(url)
            runtimeLogPath = RuntimeLogSettings.displayPath
            if runtimeLogEnabled {
                Task {
                    await RuntimeLogger.shared.log(
                        category: "configuration",
                        "Log output directory changed"
                    )
                }
            }
        } catch {
            runtimeLogError = error.localizedDescription
        }
    }
}

private struct ThemeChoiceCard: View {
    let theme: AppTheme
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Image(systemName: theme.systemImage)
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(theme.accentColor)
                    }
                }
                .font(.title3)

                Text(theme.displayName)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Circle().fill(theme.accentColor)
                    Circle().fill(theme.previewForeground.opacity(0.68))
                    Circle().fill(theme.previewForeground.opacity(0.25))
                }
                .frame(height: 8)
            }
            .foregroundStyle(theme.previewForeground)
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
            .background(theme.previewBackground, in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(
                        isSelected ? theme.accentColor : Color.secondary.opacity(0.22),
                        lineWidth: isSelected ? 2 : 1
                    )
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(theme.displayName)
        .accessibilityValue(isSelected ? "已选择" : "")
    }
}

private struct SettingsLoginRequest: Identifiable {
    let id = UUID()
    var title: String
}
