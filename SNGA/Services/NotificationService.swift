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
