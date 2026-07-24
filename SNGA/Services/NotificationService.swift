@preconcurrency import UserNotifications
import Foundation

actor NotificationService {
    static let shared = NotificationService()
    private var requestedAuthorization = false

    func requestAuthorizationIfNeeded() async {
        guard !requestedAuthorization else { return }
        requestedAuthorization = true
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
    }

    func notify(account: AccountSummary, message: ForumMessage) async {
        await requestAuthorizationIfNeeded()
        let content = UNMutableNotificationContent()
        content.title = "SNGA · \(account.displayName)"
        content.body = message.kind.notificationTitle
        content.sound = .default
        content.userInfo = [
            "accountID": account.id.description,
            "messageID": String(message.id.rawValue)
        ]
        let request = UNNotificationRequest(
            identifier: "\(account.id.description):\(message.id.rawValue)",
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }
}

extension Notification.Name {
    static let sngaOpenMessage = Notification.Name("cn.snga.client.openMessage")
}
