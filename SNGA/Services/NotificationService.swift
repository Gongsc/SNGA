@preconcurrency import UserNotifications
import Foundation

struct PolledMessage: Sendable {
    var folder: MessageFolder
    var message: ForumMessage
}

struct UnreadMessageUpdate: Sendable {
    var newMessages: [PolledMessage]
    var seenKeys: [String]
    var unreadCount: Int
}

enum UnreadMessagePolicy {
    static let maximumSeenKeyCount = 200

    static func update(
        pages: [MessagePage],
        previouslySeenKeys: [String]?
    ) -> UnreadMessageUpdate {
        let unread = pages.flatMap { page in
            page.messages
                .filter(\.isUnread)
                .map { PolledMessage(folder: page.folder, message: $0) }
        }
        let currentKeys = unread.map { key(folder: $0.folder, messageID: $0.message.id) }
        let previousSet = Set(previouslySeenKeys ?? [])
        let newMessages = previouslySeenKeys == nil
            ? []
            : unread.filter { !previousSet.contains(key(folder: $0.folder, messageID: $0.message.id)) }

        var accumulated = Set<String>()
        let seenKeys = (currentKeys + (previouslySeenKeys ?? []))
            .filter { accumulated.insert($0).inserted }
            .prefix(maximumSeenKeyCount)

        return UnreadMessageUpdate(
            newMessages: newMessages,
            seenKeys: Array(seenKeys),
            unreadCount: unread.count
        )
    }

    static func key(folder: MessageFolder, messageID: MessageID) -> String {
        "\(folder.rawValue):\(messageID.rawValue)"
    }
}

enum NotificationReadPolicy {
    static func applying(
        to messages: [ForumMessage],
        folder: MessageFolder,
        readKeys: [String],
        previouslyUnreadKeys: [String]
    ) -> [ForumMessage] {
        let readSet = Set(readKeys)
        let unreadSet = Set(previouslyUnreadKeys)
        return messages.map { message in
            var value = message
            let key = UnreadMessagePolicy.key(folder: folder, messageID: message.id)
            if readSet.contains(key) {
                value.isUnread = false
            } else if folder == .notifications, unreadSet.contains(key) {
                value.isUnread = true
            }
            return value
        }
    }
}

enum UnifiedMessageFeedPolicy {
    static func merging(
        notifications: MessagePage?,
        inbox: MessagePage?
    ) -> MessagePage {
        let notificationMessages = notifications?.messages.filter {
            $0.kind != .privateMessage
        } ?? []
        let inboxMessages = inbox?.messages ?? []
        var seen = Set<MessageID>()
        let messages = (notificationMessages + inboxMessages)
            .sorted {
                ($0.sentAt ?? .distantPast) > ($1.sentAt ?? .distantPast)
            }
            .filter { seen.insert($0.id).inserted }

        return MessagePage(
            folder: .notifications,
            messages: messages,
            page: inbox?.page ?? 1,
            hasMore: inbox?.hasMore ?? false
        )
    }
}

actor NotificationService {
    static let shared = NotificationService()
    private var requestedAuthorization = false

    func requestAuthorizationIfNeeded() async {
        guard !requestedAuthorization else { return }
        requestedAuthorization = true
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
    }

    func notify(account: AccountSummary, folder: MessageFolder, message: ForumMessage) async {
        await requestAuthorizationIfNeeded()
        let content = UNMutableNotificationContent()
        content.title = "SNGA · \(account.displayName)"
        content.body = message.kind.notificationTitle
        content.sound = .default
        content.userInfo = [
            "accountID": account.id.description,
            "messageID": String(message.id.rawValue),
            "messageFolder": folder.rawValue
        ]
        let request = UNNotificationRequest(
            identifier: "\(account.id.description):\(folder.rawValue):\(message.id.rawValue)",
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }
}

extension Notification.Name {
    static let sngaOpenMessage = Notification.Name("cn.snga.client.openMessage")
}
