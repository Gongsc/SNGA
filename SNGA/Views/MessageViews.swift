import SwiftUI

struct MessageListView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.sngaTheme) private var theme
    let folder: MessageFolder

    var body: some View {
        VStack(spacing: 0) {
            if model.messages.isEmpty && !model.isLoading {
                ContentUnavailableView(
                    folder == .notifications ? "暂无通知" : "暂无短消息",
                    systemImage: folder == .notifications ? "bell.slash" : "bubble.left"
                )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.messages.enumerated(), id: \.element.id) { index, message in
                            Button {
                                Task { await model.openMessage(message) }
                            } label: {
                                MessageRow(
                                    message: message,
                                    isSelected: model.selectedMessageID == message.id
                                )
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("message-\(message.id.rawValue)")

                            if index < model.messages.count - 1 {
                                Divider()
                                    .padding(.leading, 54)
                                    .padding(.trailing, 14)
                            }
                        }

                        if model.messageHasMore {
                            Divider()
                                .padding(.horizontal, 14)
                            Button {
                                Task {
                                    await model.loadMessages(
                                        folder: model.messageFolder,
                                        reset: false
                                    )
                                }
                            } label: {
                                Label("加载下一页", systemImage: "arrow.down.circle")
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(theme.accentColor)
                        }
                    }
                    .background(theme.surfaceColor, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .padding(.horizontal, 18)
                    .padding(.top, 18)
                    .padding(.bottom, 18)
                }
                .refreshable {
                    await model.loadMessages(folder: folder)
                }
            }
        }
        .background(theme.backgroundColor)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle("")
        .toolbar {
            if folder == .notifications {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        model.markAllMessagesRead(in: folder)
                    } label: {
                        Label("全部已读", systemImage: "checkmark")
                    }
                    .disabled(unreadMessages.isEmpty)
                    .help(unreadMessages.isEmpty ? "当前没有未读通知" : "全部标为已读")
                    .accessibilityLabel("全部已读")
                }
            }
        }
        .task(id: folder) {
            await model.loadMessages(folder: folder)
        }
    }

    private var unreadMessages: [ForumMessage] {
        model.messages.filter(\.isUnread)
    }
}

private struct MessageRow: View {
    @Environment(\.sngaTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let message: ForumMessage
    let isSelected: Bool
    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(message.isUnread ? theme.accentColor : Color.secondary)
                    .frame(width: 24, height: 26)
                if message.isUnread {
                    Circle()
                        .fill(theme.accentColor)
                        .frame(width: 6, height: 6)
                        .offset(x: 2, y: -1)
                }
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(message.subject)
                        .font(.body)
                        .fontWeight(message.isUnread ? .semibold : .regular)
                        .lineLimit(2)
                    Spacer()
                    if let date = message.sentAt {
                        Text(date, style: .relative)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Text(secondaryText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.secondary.opacity(0.7))
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground)
        .onHover { isHovered = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovered)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isSelected)
    }

    private var icon: String {
        switch message.kind {
        case .privateMessage: "bubble.left"
        case .reply: "arrowshape.turn.up.left"
        case .quote: "quote.bubble"
        case .comment: "hand.thumbsup"
        case .mention: "at"
        case .unknown: "bell"
        }
    }

    private var secondaryText: String {
        if message.preview.isEmpty {
            return message.sender.isEmpty ? message.kind.notificationTitle : message.sender
        }
        if message.sender.isEmpty || message.preview.contains(message.sender) {
            return message.preview
        }
        return "\(message.sender) · \(message.preview)"
    }

    private var rowBackground: Color {
        if isSelected {
            return theme.accentColor.opacity(0.12)
        }
        if isHovered {
            return Color.primary.opacity(0.055)
        }
        return .clear
    }
}
