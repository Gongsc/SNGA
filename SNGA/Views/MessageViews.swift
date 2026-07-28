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
                        ForEach(Array(model.messages.enumerated()), id: \.element.id) { index, message in
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
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .animation(.easeOut(duration: 0.12), value: isSelected)
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

struct MessageDetailView: View {
    @Environment(AppModel.self) private var model
    @State private var showsReply = false

    var body: some View {
        Group {
            if let message = model.currentMessage {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        MessageDetailHeader(
                            message: message,
                            postCount: detailPosts(for: message).count
                        )
                        ForEach(
                            Array(detailPosts(for: message).enumerated()),
                            id: \.element.id
                        ) { index, post in
                            MessagePostRow(
                                post: post,
                                number: index + 1,
                                fallbackText: message.posts.isEmpty ? message.preview : ""
                            )
                        }
                    }
                    .padding()
                }
                .toolbar {
                    if message.kind == .privateMessage {
                        ToolbarItem {
                            Button("回复", systemImage: "arrowshape.turn.up.left") { showsReply = true }
                                .accessibilityIdentifier("reply-private-message")
                        }
                    }
                }
                .sheet(isPresented: $showsReply) {
                    MessageReplyView(message: message)
                        .environment(model)
                }
            } else if model.isLoading {
                ProgressView()
            } else {
                ContentUnavailableView("无法显示消息", systemImage: "envelope.badge")
            }
        }
        .navigationTitle("消息详情")
    }

    private func detailPosts(for message: ForumMessage) -> [ForumMessagePost] {
        if !message.posts.isEmpty {
            return message.posts
        }
        return [
            ForumMessagePost(
                id: message.id,
                author: message.sender,
                sentAt: message.sentAt,
                html: message.html ?? ""
            )
        ]
    }
}

private struct MessageDetailHeader: View {
    let message: ForumMessage
    let postCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message.subject)
                .font(.title2.bold())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 14) {
                if !message.sender.isEmpty {
                    Label(message.sender, systemImage: "person")
                }
                Label("\(postCount) 条消息", systemImage: "bubble.left")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(.separator.opacity(0.5))
        }
    }
}

private struct MessagePostRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.sngaTheme) private var theme
    let post: ForumMessagePost
    let number: Int
    let fallbackText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                if let authorUID {
                    Button {
                        openAuthorProfile(uid: authorUID)
                    } label: {
                        authorAvatar
                    }
                    .buttonStyle(.plain)
                    .contentShape(.circle)
                    .help("查看用户信息")
                } else {
                    authorAvatar
                }

                VStack(alignment: .leading, spacing: 1) {
                    if let authorUID {
                        Button {
                            openAuthorProfile(uid: authorUID)
                        } label: {
                            authorName
                        }
                        .buttonStyle(.plain)
                        .help("查看用户信息")
                    } else {
                        authorName
                    }

                    if let date = post.sentAt {
                        Text(
                            date,
                            format: .dateTime
                                .year()
                                .month(.twoDigits)
                                .day(.twoDigits)
                                .hour(.twoDigits(amPM: .omitted))
                                .minute(.twoDigits)
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("message-post-time-\(post.id.rawValue)")
                    }
                }

                Spacer()
                Text("#\(number)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if !post.html.isEmpty {
                PostBodyView(html: post.html)
            } else {
                Text(fallbackText)
                    .textSelection(.enabled)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surfaceColor, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(nsColor: .separatorColor).opacity(0.5))
        }
    }

    private var authorUID: Int64? {
        guard let authorUID = post.authorUID, authorUID > 0 else { return nil }
        return authorUID
    }

    private var authorName: some View {
        Text(post.author.isEmpty ? "未知用户" : post.author)
            .fontWeight(.semibold)
    }

    private var authorAvatar: some View {
        AsyncImage(url: post.avatarURL) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Image(systemName: "person.crop.circle.fill")
                .foregroundStyle(.secondary)
        }
        .frame(width: 30, height: 30)
        .clipShape(.circle)
    }

    private func openAuthorProfile(uid: Int64) {
        Task {
            await model.openUserCenter(
                uid: uid,
                fallbackName: post.author,
                fallbackAvatarURL: post.avatarURL,
                preservingForumContext: true
            )
        }
    }
}

private struct MessageReplyView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let message: ForumMessage
    @State private var content = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading) {
                    Text("回复私信").font(.headline)
                    Text(message.subject).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("取消") { dismiss() }
                Button("发送") {
                    Task {
                        if await model.replyToMessage(id: message.id, content: content) { dismiss() }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isSubmitting)
            }
            .padding()
            Divider()
            TextEditor(text: $content)
                .font(.body)
                .padding()
        }
        .frame(minWidth: 640, minHeight: 420)
    }
}
