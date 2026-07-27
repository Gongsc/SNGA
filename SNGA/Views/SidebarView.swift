import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Binding var accountToRemove: AccountSummary?

    var body: some View {
        List {
            Section("账号") {
                ForEach(model.accounts) { account in
                    Button {
                        Task { await model.selectAccount(account.id) }
                    } label: {
                        SidebarInteractiveRow(isSelected: account.id == model.activeAccountID) {
                            HStack(spacing: 8) {
                                AsyncImage(url: account.avatarURL) { image in
                                    image.resizable().scaledToFill()
                                } placeholder: {
                                    Image(systemName: "person.crop.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .frame(width: 24, height: 24)
                                .clipShape(.circle)

                                VStack(alignment: .leading, spacing: 1) {
                                    Text(account.displayName).lineLimit(1)
                                    if account.sessionState != .valid {
                                        Text(account.sessionState.title)
                                            .font(.caption2)
                                            .foregroundStyle(.red)
                                    }
                                }
                                Spacer()
                                if account.id == model.activeAccountID {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .sidebarListRow()
                    .contextMenu {
                        if account.sessionState == .requiresLogin {
                            Button("重新登录") { model.showsLogin = true }
                        }
                        Button("移除账号", role: .destructive) { accountToRemove = account }
                    }
                }
                Button {
                    model.showsLogin = true
                } label: {
                    SidebarInteractiveRow(isSelected: false) {
                        Label("添加账号", systemImage: "person.badge.plus")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .buttonStyle(.plain)
                .sidebarListRow()
            }

            if model.activeAccountID != nil {
                Section("浏览") {
                    sidebarButton(
                        "用户中心",
                        systemImage: "person.crop.circle",
                        selection: .userCenter(model.activeAccount?.ngaUID)
                    )
                    sidebarButton("全部板块", systemImage: "square.grid.2x2", selection: .directory)
                    sidebarButton("收藏夹", systemImage: "star", selection: .favorites)
                    sidebarButton(
                        "论坛消息",
                        systemImage: "tray.full",
                        selection: .messages(.privateMessages),
                        badge: model.unreadCount
                    )
                }

                Section("收藏板块") {
                    if model.favorites.isEmpty {
                        Text("暂无收藏")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.favorites, id: \.forum.id) { favorite in
                        Button {
                            Task { await model.openForum(favorite.forum) }
                        } label: {
                            SidebarInteractiveRow(
                                isSelected: model.sidebarSelection == .forum(favorite.forum.id)
                            ) {
                                HStack {
                                    Label(favorite.forum.name, systemImage: favorite.state == .localOnly ? "star.slash" : "star.fill")
                                        .lineLimit(1)
                                    Spacer()
                                    if favorite.state == .pendingAdd || favorite.state == .pendingRemove {
                                        Image(systemName: "arrow.triangle.2.circlepath")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .sidebarListRow()
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("SNGA")
    }

    @ViewBuilder
    private func sidebarButton(_ title: String, systemImage: String, selection: SidebarSelection, badge: Int = 0) -> some View {
        Button {
            model.sidebarSelection = selection
            model.selectedTopicID = nil
            model.selectedMessageID = nil
            switch selection {
            case .directory:
                Task { await model.loadForums() }
            case .favorites:
                break
            case let .userCenter(uid):
                if let uid = uid ?? model.activeAccount?.ngaUID {
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
                            .background(.tint, in: Capsule())
                            .foregroundStyle(.white)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .sidebarListRow()
    }

    private func isSelectionActive(_ selection: SidebarSelection) -> Bool {
        if case .userCenter = selection {
            guard let activeUID = model.activeAccount?.ngaUID,
                  case let .userCenter(displayedUID)? = model.sidebarSelection else {
                return false
            }
            return (displayedUID ?? activeUID) == activeUID
        }
        return model.sidebarSelection == selection
    }
}

private struct SidebarInteractiveRow<Content: View>: View {
    @Environment(\.sngaTheme) private var theme
    let isSelected: Bool
    let content: () -> Content
    @State private var isHovered = false

    init(isSelected: Bool, @ViewBuilder content: @escaping () -> Content) {
        self.isSelected = isSelected
        self.content = content
    }

    var body: some View {
        content()
            .padding(.horizontal, 7)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(backgroundColor)
            }
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .animation(.easeOut(duration: 0.12), value: isSelected)
    }

    private var backgroundColor: Color {
        if isSelected {
            return theme.accentColor.opacity(0.18)
        }
        if isHovered {
            return Color.primary.opacity(0.08)
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
