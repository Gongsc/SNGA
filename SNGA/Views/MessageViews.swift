import SwiftUI

struct MessageListView: View {
    @Environment(AppModel.self) private var model
    let folder: MessageFolder

    var body: some View {
        VStack(spacing: 0) {
            Picker("消息分类", selection: Binding(
                get: { model.messageFolder },
                set: { newValue in
                    model.messageFolder = newValue
                    model.sidebarSelection = .messages(newValue)
                    model.selectedMessageID = nil
                    model.selectedTopicID = nil
                    model.currentMessage = nil
                    model.currentTopic = nil
                }
            )) {
                ForEach(MessageFolder.allCases) { folder in
                    Text(folder.title).tag(folder)
                }
            }
            .pickerStyle(.segmented)
            .padding()
            Divider()
            if model.messages.isEmpty && !model.isLoading {
                ContentUnavailableView("暂无消息", systemImage: "tray")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(model.messages) { message in
                        Button {
                            Task { await model.openMessage(message) }
                        } label: {
                            MessageRow(message: message)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("message-\(message.id.rawValue)")
                    }
                    if model.messageHasMore {
                        HStack {
                            Spacer()
                            Button("加载下一页") {
                                Task { await model.loadMessages(folder: model.messageFolder, reset: false) }
                            }
                            Spacer()
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle("论坛消息")
        .task(id: folder) {
            await model.loadMessages(folder: folder)
        }
    }
}

private struct MessageRow: View {
    @Environment(\.sngaTheme) private var theme
    let message: ForumMessage

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: icon)
                .foregroundStyle(message.isUnread ? theme.accentColor : Color.gray)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(message.subject).fontWeight(message.isUnread ? .semibold : .regular).lineLimit(2)
                    Spacer()
                    Text(message.isUnread ? "未读" : "已读")
                        .font(.caption2)
                        .foregroundStyle(message.isUnread ? theme.accentColor : Color.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            message.isUnread
                                ? theme.accentColor.opacity(0.12)
                                : Color.secondary.opacity(0.08),
                            in: Capsule()
                        )
                    if let date = message.sentAt { Text(date, style: .relative).font(.caption).foregroundStyle(.secondary) }
                }
                if !message.sender.isEmpty {
                    Text(message.sender).font(.caption).foregroundStyle(.secondary)
                }
                Text(message.preview).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }

    private var icon: String {
        switch message.kind {
        case .privateMessage: "envelope"
        case .reply: "arrowshape.turn.up.left"
        case .quote: "quote.bubble"
        case .mention: "at"
        case .unknown: "bell"
        }
    }
}

struct MessageDetailView: View {
    @Environment(AppModel.self) private var model
    @State private var showsReply = false

    var body: some View {
        Group {
            if let message = model.currentMessage {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(message.subject).font(.title2.bold())
                        if !message.sender.isEmpty {
                            LabeledContent("来自", value: message.sender)
                        }
                        if let html = message.html {
                            PostBodyView(html: html)
                        } else {
                            Text(message.preview)
                        }
                    }
                    .padding()
                }
                .toolbar {
                    if message.kind == .privateMessage {
                        ToolbarItem {
                            Button("回复", systemImage: "arrowshape.turn.up.left") { showsReply = true }
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
