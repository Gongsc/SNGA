import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.sngaTheme) private var theme

    var body: some View {
        List {
            Section("账号") {
                ForEach(model.session.accounts) { account in
                    SidebarAccountButton(account: account)
                }
                Button {
                    model.session.showsLogin = true
                } label: {
                    SidebarInteractiveRow(isSelected: false) {
                        Label("添加账号", systemImage: "person.badge.plus")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .buttonStyle(.plain)
                .sidebarListRow()
            }

            if model.session.activeAccountID != nil {
                Section("浏览") {
                    sidebarButton(
                        "用户中心",
                        systemImage: "person.crop.circle",
                        selection: .userCenter(model.session.activeAccount?.ngaUID)
                    )
                    sidebarButton("全部版面", systemImage: "square.grid.2x2", selection: .directory)
                    sidebarButton("搜索", systemImage: "magnifyingglass", selection: .search)
                    sidebarButton("收藏夹", systemImage: "star", selection: .favorites)
                    sidebarButton("小工具", systemImage: "wrench.and.screwdriver", selection: .toolbox)
                    sidebarButton(
                        "论坛消息",
                        systemImage: "bell",
                        selection: .messages(.notifications),
                        badge: model.messaging.unreadCount
                    )
                }

                Section("最近访问") {
                    if model.browsing.recentForums.isEmpty {
                        Text("暂无最近访问")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.browsing.recentForums) { forum in
                        Button {
                            Task { await model.openForum(forum) }
                        } label: {
                            SidebarInteractiveRow(
                                isSelected: model.sidebarSelection == .forum(forum.id)
                            ) {
                                HStack(spacing: 8) {
                                    SidebarForumIcon(forum: forum)

                                    Text(forum.name)
                                        .lineLimit(1)
                                    Spacer()
                                    if model.browsing.isRefreshingTopics,
                                       model.selectedForumID == forum.id {
                                        ProgressView()
                                            .controlSize(.small)
                                            .accessibilityLabel("正在刷新\(forum.name)")
                                    }
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .sidebarListRow()
                        .accessibilityIdentifier(
                            "recent-forum-\(forum.id.description)"
                        )
                    }
                }

                Section("收藏版面") {
                    if model.favorite.favorites.isEmpty {
                        Text("暂无收藏")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.favorite.favorites, id: \.forum.id) { favorite in
                        Button {
                            Task { await model.openForum(favorite.forum) }
                        } label: {
                            SidebarInteractiveRow(
                                isSelected: model.sidebarSelection == .forum(favorite.forum.id)
                            ) {
                                HStack(spacing: 8) {
                                    SidebarForumIcon(forum: favorite.forum)

                                    Text(favorite.forum.name)
                                        .lineLimit(1)
                                    Spacer()
                                    if model.browsing.isRefreshingTopics,
                                       model.selectedForumID == favorite.forum.id {
                                        ProgressView()
                                            .controlSize(.small)
                                            .accessibilityLabel("正在刷新\(favorite.forum.name)")
                                            .accessibilityIdentifier(
                                                "favorite-forum-refreshing-\(favorite.forum.id.description)"
                                            )
                                    } else if favorite.state == .pendingAdd || favorite.state == .pendingRemove {
                                        Image(systemName: "arrow.triangle.2.circlepath")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .sidebarListRow()
                        .accessibilityIdentifier(
                            "favorite-forum-\(favorite.forum.id.description)"
                        )
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(theme.backgroundColor)
        .navigationTitle("SNGA")
    }

    @ViewBuilder
    private func sidebarButton(_ title: String, systemImage: String, selection: SidebarSelection, badge: Int = 0) -> some View {
        Button {
            model.sidebarSelection = selection
            model.thread.selectedTopicID = nil
            model.messaging.selectedMessageID = nil
            switch selection {
            case .directory:
                Task { await model.browsing.loadForums() }
            case .search:
                model.clearForumSearch()
            case .favorites, .toolbox:
                break
            case let .userCenter(uid):
                if let uid = uid ?? model.session.activeAccount?.ngaUID {
                    Task { await model.openUserCenter(uid: uid) }
                }
            case .forum, .messages:
                break
            }
        } label: {
            SidebarInteractiveRow(isSelected: isSelectionActive(selection)) {
                HStack {
                    Label(title, systemImage: systemImage)
                    Spacer()
                    if badge > 0 {
                        Text("\(badge)")
                            .font(.caption.monospacedDigit())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            // 底色和字色取自同一个主题，别一个跟 `.tint`
                            // 走、另一个写死。
                            .background(theme.accentColor, in: Capsule())
                            .foregroundStyle(theme.onAccentColor)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .sidebarListRow()
    }

    private func isSelectionActive(_ selection: SidebarSelection) -> Bool {
        if case .userCenter = selection {
            guard let activeUID = model.session.activeAccount?.ngaUID,
                  case let .userCenter(displayedUID)? = model.sidebarSelection else {
                return false
            }
            return (displayedUID ?? activeUID) == activeUID
        }
        return model.sidebarSelection == selection
    }
}

private struct SidebarForumIcon: View {
    let forum: Forum

    var body: some View {
        AsyncImage(url: forum.iconURL) { image in
            image
                .resizable()
                .scaledToFit()
        } placeholder: {
            Image(systemName: forum.id.isSubforum ? "text.document" : "bubble.left.and.bubble.right")
                .resizable()
                .scaledToFit()
                .foregroundStyle(.secondary)
                .padding(3)
        }
        .frame(width: 24, height: 24)
        .accessibilityHidden(true)
    }
}

private struct SidebarAccountButton: View {
    @Environment(AppModel.self) private var model
    let account: AccountSummary
    @State private var showsRemoveConfirmation = false

    var body: some View {
        Button {
            Task { await model.selectAccount(account.id) }
        } label: {
            SidebarInteractiveRow(isSelected: account.id == model.session.activeAccountID) {
                HStack(spacing: 8) {
                    AsyncImage(url: account.avatarURL) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Image(systemName: "person.crop.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: 24, height: 24)
                    .clipShape(.circle)
                    .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(account.displayName).lineLimit(1)
                        if account.sessionState != .valid {
                            Text(account.sessionState.title)
                                .font(.caption2)
                                .foregroundStyle(.red)
                        }
                    }
                    Spacer()
                    if account.id == model.session.activeAccountID {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.tint)
                            .accessibilityLabel("当前账号")
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .sidebarListRow()
        .contextMenu {
            if account.sessionState == .requiresLogin {
                Button("重新登录") { model.session.showsLogin = true }
            }
            Button("移除账号", role: .destructive) {
                showsRemoveConfirmation = true
            }
        }
        .confirmationDialog(
            "移除账号？",
            isPresented: $showsRemoveConfirmation,
            titleVisibility: .visible
        ) {
            Button("移除 \(account.displayName)", role: .destructive) {
                Task { await model.removeAccount(account.id) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会删除此账号的会话、收藏、最近访问和草稿，不能撤销。")
        }
    }
}

private struct SidebarInteractiveRow<Content: View>: View {
    @Environment(\.sngaTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let isSelected: Bool
    @ViewBuilder let content: Content
    @State private var isHovered = false

    var body: some View {
        content
            .padding(.horizontal, 7)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(backgroundColor)
            }
            .onHover { isHovered = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovered)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isSelected)
    }

    private var backgroundColor: Color {
        if isSelected {
            return theme.accentColor.opacity(0.18)
        }
        if isHovered {
            return theme.hoverFillColor
        }
        return .clear
    }
}

private extension View {
    func sidebarListRow() -> some View {
        listRowInsets(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6))
            .listRowBackground(Color.clear)
    }
}
