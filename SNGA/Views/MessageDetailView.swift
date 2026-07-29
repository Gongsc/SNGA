import SwiftUI

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
                            detailPosts(for: message).enumerated(),
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
                        Label {
                            Text("查看 \(authorDisplayName) 的用户信息")
                        } icon: {
                            authorAvatar
                        }
                        .labelStyle(.iconOnly)
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

    private var authorDisplayName: String {
        post.author.isEmpty ? "未知用户" : post.author
    }

    private var authorName: some View {
        Text(authorDisplayName)
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
