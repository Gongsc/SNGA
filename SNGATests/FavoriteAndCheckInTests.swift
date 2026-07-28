import Foundation
import XCTest
@testable import SNGA

final class FavoriteAndCheckInTests: XCTestCase {
    func testOptimisticVoteStateUpdatesCountsAndSelection() {
        let initial = PostVoteState(upvoteCount: 12, downvoteCount: 3, userVote: nil)

        let upvoted = initial.optimisticallyApplying(.up)
        XCTAssertEqual(upvoted, PostVoteState(upvoteCount: 13, downvoteCount: 3, userVote: .up))
        XCTAssertEqual(
            upvoted.optimisticallyApplying(.up),
            PostVoteState(upvoteCount: 12, downvoteCount: 3, userVote: nil)
        )
        XCTAssertEqual(
            upvoted.optimisticallyApplying(.down),
            PostVoteState(upvoteCount: 12, downvoteCount: 4, userVote: .down)
        )
    }

    func testAppThemeFallsBackAndAppliesWebPalette() {
        XCTAssertEqual(AppTheme.resolve("unknown-theme"), .system)

        let html = """
        <style>
        :root{color-scheme:light dark;--snga-accent:#b06d00;--snga-highlight:#d59b3a;--snga-smile-backdrop:var(--snga-smile-backdrop-system)}
        </style>
        """
        let themed = AppTheme.midnight.applying(to: html)

        XCTAssertTrue(themed.contains("color-scheme:dark"))
        XCTAssertTrue(themed.contains("--snga-accent:#52d6e8"))
        XCTAssertTrue(themed.contains("--snga-highlight:#278fa5"))
        XCTAssertTrue(themed.contains("--snga-smile-backdrop:rgba(255,255,255,.88)"))
        XCTAssertFalse(themed.contains("color-scheme:light dark"))

        let custom = AppTheme.custom.resolved(
            customBackgroundHex: "#263238",
            customAccentHex: "#80CBC4"
        )
        let customHTML = custom.applying(to: html)
        XCTAssertEqual(custom.preferredColorScheme, .dark)
        XCTAssertTrue(customHTML.contains("color-scheme:dark"))
        XCTAssertTrue(customHTML.contains("--snga-accent:#80CBC4"))
        XCTAssertTrue(customHTML.contains("--snga-smile-backdrop:rgba(255,255,255,.88)"))
    }

    func testPendingLocalOperationsWinDuringMerge() {
        let one = Forum(id: ForumID(rawValue: 1), name: "一号板块")
        let two = Forum(id: ForumID(rawValue: 2), name: "二号板块")
        let three = Forum(id: ForumID(rawValue: 3), name: "三号板块")
        let local = [
            FavoriteSnapshot(forum: one, order: 0, state: .pendingRemove),
            FavoriteSnapshot(forum: two, order: 1, state: .pendingAdd)
        ]

        let result = FavoriteSyncEngine.merge(server: [one, three], local: local)

        XCTAssertEqual(result.visible.map(\.forum.id), [two.id, three.id])
        XCTAssertEqual(result.pendingAdds, [two.id])
        XCTAssertEqual(result.pendingRemovals, [one.id])
    }

    func testServerAdditionsKeepLocalOrder() {
        let localForum = Forum(id: ForumID(rawValue: 1), name: "本地")
        let serverForum = Forum(id: ForumID(rawValue: 2), name: "站端")
        let result = FavoriteSyncEngine.merge(
            server: [localForum, serverForum],
            local: [FavoriteSnapshot(forum: localForum, order: 4, state: .synced)]
        )
        XCTAssertEqual(result.visible.map(\.forum.id), [localForum.id, serverForum.id])
        XCTAssertEqual(result.visible.map(\.order), [4, 5])
    }

    func testCheckInUsesBeijingCalendarDay() throws {
        let formatter = ISO8601DateFormatter()
        let beforeMidnightUTC = try XCTUnwrap(formatter.date(from: "2026-07-22T15:59:59Z"))
        let afterMidnightUTC = try XCTUnwrap(formatter.date(from: "2026-07-22T16:00:01Z"))

        XCTAssertEqual(CheckInPolicy.dayKey(for: beforeMidnightUTC), "2026-07-22")
        XCTAssertEqual(CheckInPolicy.dayKey(for: afterMidnightUTC), "2026-07-23")
        XCTAssertFalse(CheckInPolicy.shouldCheckIn(lastSuccessfulDay: "2026-07-23", now: afterMidnightUTC))
        XCTAssertTrue(CheckInPolicy.shouldCheckIn(lastSuccessfulDay: "2026-07-22", now: afterMidnightUTC))
    }

    func testSubforumPreferenceKeepsSelectionIncludingExplicitEmptyChoice() {
        let accountID = AccountID(rawValue: UUID())
        let parentForumID = ForumID(rawValue: 414)
        let selectedForumIDs: Set<ForumID> = [
            ForumID(rawValue: 614),
            ForumID(stid: 35_925_536)
        ]
        let record = SubforumPreferenceRecord(
            accountID: accountID,
            parentForumID: parentForumID,
            selectedForumIDs: selectedForumIDs
        )

        XCTAssertEqual(record.selectedForumIDs, selectedForumIDs)
        XCTAssertEqual(
            record.id,
            SubforumPreferenceRecord.recordID(
                accountID: accountID,
                parentForumID: parentForumID
            )
        )

        record.selectedForumIDs = []
        XCTAssertEqual(record.selectedForumIDs, [])
        XCTAssertEqual(record.selectedForumIDsRaw, "")
    }

    func testUnreadMessagePolicyEstablishesFirstBaselineWithoutNotifying() {
        let inbox = MessagePage(
            folder: .privateMessages,
            messages: [
                ForumMessage(
                    id: MessageID(rawValue: 10),
                    kind: .privateMessage,
                    sender: "甲",
                    subject: "私信",
                    preview: "",
                    isUnread: true
                )
            ],
            page: 1,
            hasMore: false
        )

        let update = UnreadMessagePolicy.update(
            pages: [inbox],
            previouslySeenKeys: nil
        )

        XCTAssertTrue(update.newMessages.isEmpty)
        XCTAssertEqual(update.seenKeys, ["inbox:10"])
        XCTAssertEqual(update.unreadCount, 1)
    }

    func testUnreadMessagePolicyDetectsReplacementWhenCountDoesNotChange() {
        let inbox = MessagePage(
            folder: .privateMessages,
            messages: [
                ForumMessage(
                    id: MessageID(rawValue: 11),
                    kind: .privateMessage,
                    sender: "乙",
                    subject: "新私信",
                    preview: "",
                    isUnread: true
                )
            ],
            page: 1,
            hasMore: false
        )

        let update = UnreadMessagePolicy.update(
            pages: [inbox],
            previouslySeenKeys: ["inbox:10"]
        )

        XCTAssertEqual(update.newMessages.map(\.message.id), [MessageID(rawValue: 11)])
        XCTAssertEqual(update.newMessages.map(\.folder), [.privateMessages])
        XCTAssertEqual(update.unreadCount, 1)
        XCTAssertEqual(update.seenKeys, ["inbox:11", "inbox:10"])
    }

    func testUnreadMessagePolicyKeepsFoldersDistinct() {
        let reminders = MessagePage(
            folder: .notifications,
            messages: [
                ForumMessage(
                    id: MessageID(rawValue: 10),
                    kind: .mention,
                    sender: "丙",
                    subject: "提醒",
                    preview: "",
                    isUnread: true
                )
            ],
            page: 1,
            hasMore: false
        )

        let update = UnreadMessagePolicy.update(
            pages: [reminders],
            previouslySeenKeys: ["inbox:10"]
        )

        XCTAssertEqual(update.newMessages.map(\.folder), [.notifications])
        XCTAssertEqual(update.seenKeys.first, "reminders:10")
    }

    func testNotificationReadPolicyKeepsUnreadUntilUserOpensIt() {
        let message = ForumMessage(
            id: MessageID(rawValue: 99),
            kind: .mention,
            sender: "Alice",
            subject: "提醒",
            preview: "有人提到了你",
            isUnread: false
        )
        let key = UnreadMessagePolicy.key(folder: .notifications, messageID: message.id)

        let stillUnread = NotificationReadPolicy.applying(
            to: [message],
            folder: .notifications,
            readKeys: [],
            previouslyUnreadKeys: [key]
        )
        XCTAssertEqual(stillUnread.first?.isUnread, true)

        let opened = NotificationReadPolicy.applying(
            to: stillUnread,
            folder: .notifications,
            readKeys: [key],
            previouslyUnreadKeys: [key]
        )
        XCTAssertEqual(opened.first?.isUnread, false)
    }

    func testNotificationReadPolicyAppliesExplicitReadStateToInboxMessage() {
        let message = ForumMessage(
            id: MessageID(rawValue: 100),
            kind: .privateMessage,
            sender: "Bob",
            subject: "短消息",
            preview: "这是一条短消息",
            isUnread: true
        )
        let key = UnreadMessagePolicy.key(
            folder: .privateMessages,
            messageID: message.id
        )

        let opened = NotificationReadPolicy.applying(
            to: [message],
            folder: .privateMessages,
            readKeys: [key],
            previouslyUnreadKeys: [key]
        )

        XCTAssertEqual(opened.first?.isUnread, false)
    }

    func testUnifiedMessageFeedCombinesNotificationsAndInbox() {
        let notifications = MessagePage(
            folder: .notifications,
            messages: [
                ForumMessage(
                    id: MessageID(rawValue: 1),
                    kind: .reply,
                    sender: "甲",
                    subject: "有人回复了你",
                    preview: "回复内容",
                    sentAt: Date(timeIntervalSince1970: 200),
                    isUnread: true
                ),
                ForumMessage(
                    id: MessageID(rawValue: 2),
                    kind: .privateMessage,
                    sender: "乙",
                    subject: "短消息提醒占位",
                    preview: "",
                    sentAt: Date(timeIntervalSince1970: 300),
                    isUnread: true
                )
            ],
            page: 1,
            hasMore: false
        )
        let inbox = MessagePage(
            folder: .privateMessages,
            messages: [
                ForumMessage(
                    id: MessageID(rawValue: 42),
                    kind: .privateMessage,
                    sender: "乙",
                    subject: "真实短消息会话",
                    preview: "短消息内容",
                    sentAt: Date(timeIntervalSince1970: 100),
                    isUnread: true
                )
            ],
            page: 1,
            hasMore: true
        )

        let result = UnifiedMessageFeedPolicy.merging(
            notifications: notifications,
            inbox: inbox
        )

        XCTAssertEqual(result.folder, .notifications)
        XCTAssertEqual(result.messages.map(\.id), [
            MessageID(rawValue: 1),
            MessageID(rawValue: 42)
        ])
        XCTAssertEqual(result.messages.map(\.kind), [.reply, .privateMessage])
        XCTAssertTrue(result.hasMore)
    }

    func testUnifiedMessageFeedStillShowsInboxWhenNotificationsAreEmpty() {
        let inbox = MessagePage(
            folder: .privateMessages,
            messages: [
                ForumMessage(
                    id: MessageID(rawValue: 88),
                    kind: .privateMessage,
                    sender: "丙",
                    subject: "只有短消息",
                    preview: "仍应显示",
                    isUnread: false
                )
            ],
            page: 1,
            hasMore: false
        )

        let result = UnifiedMessageFeedPolicy.merging(
            notifications: nil,
            inbox: inbox
        )

        XCTAssertEqual(result.messages.map(\.id), [MessageID(rawValue: 88)])
    }
}
