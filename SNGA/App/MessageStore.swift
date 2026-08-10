import Foundation
import Observation
import SwiftData

/// 打开一条消息之后，调用方还需要做什么。
enum MessageOpenOutcome: Sendable {
    case handled
    /// 该消息指向一个话题，跨域跳转由调用方协调。
    case requestsTopic(id: TopicID, subject: String, author: String)
}

/// 消息域：私信与提醒的列表、详情、已读状态与未读计数。
@MainActor
@Observable
final class MessageStore {
    var messages: [ForumMessage] = []
    var currentMessage: ForumMessage?
    var selectedMessageID: MessageID?
    var messageFolder: MessageFolder = .privateMessages
    var messagePage = 1
    var messageHasMore = false
    var unreadCount = 0
    /// 私信回复的提交状态。此前与话题回复共用一个标志，两处互相干扰。
    var isSubmitting = false

    @ObservationIgnored private let session: AppSession
    @ObservationIgnored private let messageListRequests = RequestSlot()
    @ObservationIgnored private let messageDetailRequests = RequestSlot()
    @ObservationIgnored private var messageUnreadCounts: [MessageFolder: Int] = [:]
    /// 侧栏选择属于导航状态，不归本域所有；只需要「用户是否还停在这个信箱」这一个判断。
    @ObservationIgnored private var isFolderStillSelected: (MessageFolder) -> Bool = { _ in true }

    init(session: AppSession) {
        self.session = session
    }

    func provideSelectionCheck(_ check: @escaping (MessageFolder) -> Bool) {
        isFolderStillSelected = check
    }

    func reset() {
        messages = []
        currentMessage = nil
        selectedMessageID = nil
        messagePage = 1
        messageHasMore = false
        unreadCount = 0
        messageUnreadCounts = [:]
        messageListRequests.invalidate()
        messageDetailRequests.invalidate()
    }

    private func merged<T: Identifiable>(
        _ existing: [T],
        _ incoming: [T]
    ) -> [T] where T.ID: Hashable {
        var seen = Set(existing.map(\.id))
        return existing + incoming.filter { seen.insert($0.id).inserted }
    }

    func load(folder: MessageFolder, reset: Bool = true) async {
        guard let service = session.activeService else { return }
        let requestAccountID = service.accountID
        let ticket = messageListRequests.begin()
        messageFolder = folder
        let page = reset ? 1 : messagePage + 1
        await session.withLoading(isCurrent: { ticket.isCurrent }) {
            var result: MessagePage
            if folder == .notifications {
                result = try await unifiedMessageFeedPage(
                    service: service,
                    page: page,
                    accountID: requestAccountID
                )
            } else {
                result = try await service.messages(folder: folder, page: page)
                result.messages = applyingPersistedReadState(
                    to: result.messages,
                    folder: folder,
                    accountID: requestAccountID
                )
            }
            guard session.activeAccountID == requestAccountID,
                  ticket.isCurrent,
                  isFolderStillSelected(folder),
                  messageFolder == folder else {
                return
            }
            messages = reset ? result.messages : merged(messages, result.messages)
            messagePage = page
            messageHasMore = result.hasMore
            if folder == .notifications {
                messageUnreadCounts[.privateMessages] = messages.filter {
                    $0.kind == .privateMessage && $0.isUnread
                }.count
            }
            setUnreadCount(messages.filter(\.isUnread).count, for: folder)
        }
    }

    /// 打开一条消息。若它指向一个话题，本域不做跳转，交由调用方协调。
    func open(_ message: ForumMessage) async -> MessageOpenOutcome {
        selectedMessageID = message.id
        let folder = messageFolder
        if folder == .notifications {
            markMessageRead(message, folder: folder)
            if message.kind == .privateMessage {
                guard let service = session.activeService else { return .handled }
                let requestAccountID = service.accountID
                let ticket = messageDetailRequests.begin()
                await session.withLoading(isCurrent: { ticket.isCurrent }) {
                    let result = try await service.message(id: message.id)
                    guard session.activeAccountID == requestAccountID,
                          ticket.isCurrent,
                          selectedMessageID == message.id else {
                        return
                    }
                    currentMessage = result
                }
            } else if let topicID = message.topicID {
                selectedMessageID = nil
                currentMessage = nil
                return .requestsTopic(
                    id: topicID,
                    subject: message.subject,
                    author: message.sender
                )
            } else {
                currentMessage = messages.first(where: { $0.id == message.id }) ?? message
            }
            return .handled
        }
        guard let service = session.activeService else { return .handled }
        let requestAccountID = service.accountID
        let ticket = messageDetailRequests.begin()
        await session.withLoading(isCurrent: { ticket.isCurrent }) {
            let result = try await service.message(id: message.id)
            guard session.activeAccountID == requestAccountID,
                  ticket.isCurrent,
                  selectedMessageID == message.id else {
                return
            }
            currentMessage = result
            markMessageRead(message, folder: folder)
        }
        return .handled
    }

    func markAllRead(in folder: MessageFolder) {
        let unreadMessages = messages.filter(\.isUnread)
        guard messageFolder == folder, !unreadMessages.isEmpty else { return }

        for index in messages.indices {
            messages[index].isUnread = false
        }
        currentMessage?.isUnread = false
        setUnreadCount(0, for: folder)

        guard folder == .notifications,
              let activeAccountID = session.activeAccountID,
              let record = accountRecord(id: activeAccountID) else {
            return
        }
        let newKeys = unreadMessages.flatMap { message in
            var keys = [
                UnreadMessagePolicy.key(folder: folder, messageID: message.id)
            ]
            if message.kind == .privateMessage {
                keys.append(UnreadMessagePolicy.key(
                    folder: .privateMessages,
                    messageID: message.id
                ))
            }
            return keys
        }
        var accumulated = Set<String>()
        record.readNotificationKeys = Array(
            (newKeys + record.readNotificationKeys)
                .filter { accumulated.insert($0).inserted }
                .prefix(UnreadMessagePolicy.maximumSeenKeyCount)
        )
        // 通知流中的短消息也属于“全部已读”的范围，避免侧栏保留重复角标。
        messageUnreadCounts[.privateMessages] = 0
        refreshUnreadCount()
        try? session.context.save()
    }



    func reply(id: MessageID, content: String) async -> Bool {
        guard let service = session.activeService, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            try await service.replyMessage(id: id, content: content)
            session.statusMessage = "私信回复已发送"
            session.statusMessageIsError = false
            return true
        } catch {
            session.present(error)
            return false
        }
    }

    func poll() async {
        let records = (try? session.context.fetch(FetchDescriptor<AccountRecord>())) ?? []
        for record in records where record.sessionState == .valid {
            guard let service = session.service(for: record.accountID) else { continue }
            do {
                async let privateMessages = service.messages(folder: .privateMessages, page: 1)
                async let notifications = service.messages(folder: .notifications, page: 1)
                var pages = try await [privateMessages, notifications]
                if let inboxIndex = pages.firstIndex(where: { $0.folder == .privateMessages }) {
                    pages[inboxIndex].messages = applyingPersistedReadState(
                        to: pages[inboxIndex].messages,
                        folder: .privateMessages,
                        accountID: record.accountID
                    )
                }
                if let notificationIndex = pages.firstIndex(where: { $0.folder == .notifications }) {
                    pages[notificationIndex].messages.removeAll { $0.kind == .privateMessage }
                    pages[notificationIndex].messages = applyingPersistedReadState(
                        to: pages[notificationIndex].messages,
                        folder: .notifications,
                        accountID: record.accountID
                    )
                }
                let update = UnreadMessagePolicy.update(
                    pages: pages,
                    previouslySeenKeys: record.seenUnreadMessageKeys
                )
                record.seenUnreadMessageKeys = update.seenKeys
                record.unreadBaseline = update.unreadCount
                if record.accountID == session.activeAccountID {
                    let inboxUnread = pages
                        .first(where: { $0.folder == .privateMessages })?
                        .messages.filter(\.isUnread).count ?? 0
                    let notificationUnread = pages
                        .first(where: { $0.folder == .notifications })?
                        .messages.filter(\.isUnread).count ?? 0
                    messageUnreadCounts[.privateMessages] = inboxUnread
                    messageUnreadCounts[.notifications] = inboxUnread + notificationUnread
                    refreshUnreadCount()
                }
                let account = record.summary()
                for item in update.newMessages {
                    await session.notificationService.notify(
                        account: account,
                        folder: item.folder,
                        message: item.message
                    )
                }
            } catch {
                // 私信或提醒接口偶发返回未登录时，只跳过本轮轮询。
                // 论坛浏览仍可验证账号有效，后台接口不能单独使整个账号失效。
            }
        }
        try? session.context.save()
    }

    private func unifiedMessageFeedPage(
        service: any NGAForumService,
        page: Int,
        accountID: AccountID
    ) async throws -> MessagePage {
        if page > 1 {
            var inbox = try await service.messages(folder: .privateMessages, page: page)
            inbox.messages = applyingPersistedReadState(
                to: inbox.messages,
                folder: .privateMessages,
                accountID: accountID
            )
            return UnifiedMessageFeedPolicy.merging(notifications: nil, inbox: inbox)
        }

        async let notificationRequest: MessagePage? =
            try? await service.messages(folder: .notifications, page: 1)
        do {
            var inbox = try await service.messages(folder: .privateMessages, page: 1)
            inbox.messages = applyingPersistedReadState(
                to: inbox.messages,
                folder: .privateMessages,
                accountID: accountID
            )
            var notifications = await notificationRequest
            if var notificationPage = notifications {
                notificationPage.messages = applyingPersistedReadState(
                    to: notificationPage.messages,
                    folder: .notifications,
                    accountID: accountID
                )
                notifications = notificationPage
            }
            return UnifiedMessageFeedPolicy.merging(
                notifications: notifications,
                inbox: inbox
            )
        } catch {
            guard var notifications = await notificationRequest else {
                throw error
            }
            notifications.messages = applyingPersistedReadState(
                to: notifications.messages,
                folder: .notifications,
                accountID: accountID
            )
            return UnifiedMessageFeedPolicy.merging(
                notifications: notifications,
                inbox: nil
            )
        }
    }

    private func applyingPersistedReadState(
        to messages: [ForumMessage],
        folder: MessageFolder,
        accountID: AccountID
    ) -> [ForumMessage] {
        guard let record = accountRecord(id: accountID) else {
            return messages
        }
        // 提醒接口在读取后会清除服务端未读计数；在用户实际打开提醒前，
        // 用本地状态保留未读标记。短消息则仅应用用户明确标记的本地已读状态。
        return NotificationReadPolicy.applying(
            to: messages,
            folder: folder,
            readKeys: record.readNotificationKeys,
            previouslyUnreadKeys: record.seenUnreadMessageKeys ?? []
        )
    }

    private func markMessageRead(_ message: ForumMessage, folder: MessageFolder) {
        guard message.isUnread else { return }
        if let index = messages.firstIndex(where: { $0.id == message.id }) {
            messages[index].isUnread = false
        }
        if currentMessage?.id == message.id {
            currentMessage?.isUnread = false
        }
        setUnreadCount(max(0, (messageUnreadCounts[folder] ?? 0) - 1), for: folder)

        guard let activeAccountID = session.activeAccountID,
              let record = accountRecord(id: activeAccountID) else {
            return
        }
        var newKeys = [
            UnreadMessagePolicy.key(folder: folder, messageID: message.id)
        ]
        if folder == .notifications, message.kind == .privateMessage {
            newKeys.append(UnreadMessagePolicy.key(
                folder: .privateMessages,
                messageID: message.id
            ))
            messageUnreadCounts[.privateMessages] = max(
                0,
                (messageUnreadCounts[.privateMessages] ?? 0) - 1
            )
            refreshUnreadCount()
        }
        let newKeySet = Set(newKeys)
        var keys = record.readNotificationKeys.filter { !newKeySet.contains($0) }
        keys.insert(contentsOf: newKeys, at: 0)
        record.readNotificationKeys = Array(keys.prefix(UnreadMessagePolicy.maximumSeenKeyCount))
        try? session.context.save()
    }

    private func setUnreadCount(_ count: Int, for folder: MessageFolder) {
        messageUnreadCounts[folder] = max(0, count)
        refreshUnreadCount()
    }

    private func refreshUnreadCount() {
        // “通知”已合并回复、评价、@ 和短消息；取最大值可避免短消息收件箱
        // 与通知流同时加载后把同一批未读重复计数。
        unreadCount = messageUnreadCounts.values.max() ?? 0
    }

    private func accountRecord(id: AccountID) -> AccountRecord? {
        ((try? session.context.fetch(FetchDescriptor<AccountRecord>())) ?? [])
            .first { $0.accountID == id }
    }
}
