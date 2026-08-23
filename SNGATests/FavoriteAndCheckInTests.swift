import Foundation
import SwiftData
import XCTest
@testable import SNGA

final class FavoriteAndCheckInTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: RecentForumSettings.maximumCountKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: RecentForumSettings.maximumCountKey)
        super.tearDown()
    }

    @MainActor
    func testRecentForumsAreOrderedDeduplicatedPersistedAndAccountScoped() async throws {
        let schema = Schema([
            AccountRecord.self,
            FavoriteRecord.self,
            DraftRecord.self,
            SubforumPreferenceRecord.self,
            RecentForumRecord.self
        ])
        let configuration = ModelConfiguration(
            "RecentForumTests",
            schema: schema,
            isStoredInMemoryOnly: true
        )
        let container = try ModelContainer(
            for: schema,
            configurations: [configuration]
        )
        let firstAccountID = AccountID(rawValue: UUID())
        let secondAccountID = AccountID(rawValue: UUID())
        let firstIconURL = try XCTUnwrap(
            URL(string: "https://img4.nga.cn/ngabbs/nga_classic/f/app/414.png")
        )
        let secondIconURL = try XCTUnwrap(
            URL(string: "https://img4.nga.cn/ngabbs/nga_classic/f/app/35925536.png")
        )
        let firstForum = Forum(
            id: ForumID(rawValue: 414),
            name: "综合游戏讨论区",
            iconURL: firstIconURL
        )
        let secondForum = Forum(
            id: ForumID(stid: 35_925_536),
            name: "幻兽帕鲁"
        )
        let model = AppModel(container: container)
        model.session.activeAccountID = firstAccountID

        await model.openForum(firstForum)
        await model.openForum(secondForum)
        await model.openForum(Forum(id: firstForum.id, name: firstForum.name))

        XCTAssertEqual(model.browsing.recentForums.map(\.id), [firstForum.id, secondForum.id])
        XCTAssertEqual(model.browsing.recentForums.first?.iconURL, firstIconURL)

        let restoredModel = AppModel(container: container)
        restoredModel.session.activeAccountID = firstAccountID
        restoredModel.browsing.forums = [
            Forum(
                id: secondForum.id,
                name: secondForum.name,
                iconURL: secondIconURL
            )
        ]
        restoredModel.browsing.loadRecentForums()
        XCTAssertEqual(restoredModel.browsing.recentForums.map(\.id), [firstForum.id, secondForum.id])
        XCTAssertEqual(restoredModel.browsing.recentForums.map(\.iconURL), [firstIconURL, secondIconURL])

        restoredModel.session.activeAccountID = secondAccountID
        restoredModel.browsing.loadRecentForums()
        XCTAssertTrue(restoredModel.browsing.recentForums.isEmpty)
    }

    @MainActor
    func testRecentForumLimitPrunesOlderRecordsForEveryAccount() async throws {
        let schema = Schema([
            AccountRecord.self,
            FavoriteRecord.self,
            DraftRecord.self,
            SubforumPreferenceRecord.self,
            RecentForumRecord.self
        ])
        let configuration = ModelConfiguration(
            "RecentForumLimitTests",
            schema: schema,
            isStoredInMemoryOnly: true
        )
        let container = try ModelContainer(
            for: schema,
            configurations: [configuration]
        )
        let accountID = AccountID(rawValue: UUID())
        let secondAccountID = AccountID(rawValue: UUID())
        let model = AppModel(container: container)
        model.session.activeAccountID = accountID

        await model.openForum(Forum(id: ForumID(rawValue: 1), name: "版面一"))
        await model.openForum(Forum(id: ForumID(rawValue: 2), name: "版面二"))
        await model.openForum(Forum(id: ForumID(rawValue: 3), name: "版面三"))

        model.session.activeAccountID = secondAccountID
        await model.openForum(Forum(id: ForumID(rawValue: 11), name: "版面十一"))
        await model.openForum(Forum(id: ForumID(rawValue: 12), name: "版面十二"))
        await model.openForum(Forum(id: ForumID(rawValue: 13), name: "版面十三"))

        model.browsing.updateRecentForumLimit(2)

        XCTAssertEqual(model.browsing.recentForums.map(\.id), [
            ForumID(rawValue: 13),
            ForumID(rawValue: 12)
        ])

        let restoredModel = AppModel(container: container)
        restoredModel.session.activeAccountID = accountID
        restoredModel.browsing.loadRecentForums()
        XCTAssertEqual(restoredModel.browsing.recentForums.map(\.id), [
            ForumID(rawValue: 3),
            ForumID(rawValue: 2)
        ])
        restoredModel.session.activeAccountID = secondAccountID
        restoredModel.browsing.loadRecentForums()
        XCTAssertEqual(restoredModel.browsing.recentForums.map(\.id), [
            ForumID(rawValue: 13),
            ForumID(rawValue: 12)
        ])
    }

    @MainActor
    func testLinkedTopicNavigationRestoresCompleteThreadHistory() throws {
        let schema = Schema([
            AccountRecord.self,
            FavoriteRecord.self,
            DraftRecord.self,
            SubforumPreferenceRecord.self,
            RecentForumRecord.self
        ])
        let configuration = ModelConfiguration(
            "ThreadNavigationTests",
            schema: schema,
            isStoredInMemoryOnly: true
        )
        let container = try ModelContainer(
            for: schema,
            configurations: [configuration]
        )
        let model = AppModel(container: container)
        let forumID = ForumID(rawValue: -7)
        let topicA = Topic(
            id: TopicID(rawValue: 101),
            forumID: forumID,
            subject: "起始主题",
            author: "Alice",
            replyCount: 30
        )
        let postA = Post(
            id: PostID(rawValue: 1),
            topicID: topicA.id,
            floor: 0,
            author: "Alice",
            html: "<p>A</p>"
        )
        model.thread.selectedTopicID = topicA.id
        model.thread.currentTopic = topicA
        model.thread.posts = [postA]
        model.thread.page = 2
        model.thread.hasMore = true
        model.thread.totalPages = 4

        let topicB = Topic(
            id: TopicID(rawValue: 202),
            forumID: forumID,
            subject: "第二个主题",
            author: "Bob",
            replyCount: 2
        )
        let postB = Post(
            id: PostID(rawValue: 2),
            topicID: topicB.id,
            floor: 0,
            author: "Bob",
            html: "<p>B</p>"
        )
        XCTAssertTrue(
            model.thread.beginLinkedTopicNavigation(to: ThreadPage(
                topic: topicB,
                posts: [postB],
                page: 3,
                hasMore: false,
                totalPages: 3
            ))
        )
        XCTAssertEqual(model.thread.previousThreadTitle, "起始主题")

        let topicC = Topic(
            id: TopicID(rawValue: 303),
            forumID: forumID,
            subject: "第三个主题",
            author: "Carol",
            replyCount: 0
        )
        XCTAssertTrue(model.thread.beginLinkedTopicNavigation(to: ThreadPage(
            topic: topicC,
            posts: [],
            page: 1,
            hasMore: false,
            totalPages: 1
        )))
        XCTAssertTrue(model.thread.returnToPreviousThread())
        XCTAssertEqual(model.thread.currentTopic, topicB)
        XCTAssertEqual(model.thread.posts, [postB])
        XCTAssertEqual(model.thread.page, 3)

        XCTAssertTrue(model.thread.returnToPreviousThread())
        XCTAssertEqual(model.thread.currentTopic, topicA)
        XCTAssertEqual(model.thread.posts, [postA])
        XCTAssertEqual(model.thread.page, 2)
        XCTAssertEqual(model.thread.totalPages, 4)
        XCTAssertFalse(model.thread.canReturnToPreviousThread)
    }

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

    func testCheckInSuccessMessageHidesInternalTaskProgressValues() {
        XCTAssertEqual(
            CheckInPolicy.userFacingSuccessMessage(
                from: "36379260 12 2324 20669 14 20669 14 20669 3 1785774438 签到成功 (任务进度更新) 1785774438"
            ),
            "签到成功（任务进度已更新）"
        )
        XCTAssertEqual(
            CheckInPolicy.userFacingSuccessMessage(
                from: "今日已签到（服务器时间 2026-07-24 09:23:50）"
            ),
            "今日已签到（服务器时间 2026-07-24 09:23:50）"
        )
    }

    @MainActor
    func testCheckInStatusRefreshDoesNotSignInAndManualActionRefreshesStatistics() async throws {
        let schema = Schema([AccountRecord.self])
        let configuration = ModelConfiguration(
            "CheckInStatusTests",
            schema: schema,
            isStoredInMemoryOnly: true
        )
        let container = try ModelContainer(
            for: schema,
            configurations: [configuration]
        )
        let session = AppSession(
            container: container,
            sessionStore: LocalSessionStore.shared,
            notificationService: .shared
        )
        let record = AccountRecord(
            ngaUID: 10_001,
            displayName: "签到测试账号",
            isCurrent: true
        )
        session.context.insert(record)
        try session.context.save()
        session.accounts = [record.summary()]
        session.activeAccountID = record.accountID
        let service = DebugForumService(accountID: record.accountID)
        session.setService(service, for: record.accountID)

        await session.refreshCheckInStatuses()

        let initialCheckInRequests = await service.debugCheckInRequestCount()
        let initialStatusRequests = await service.debugCheckInStatusRequestCount()
        XCTAssertEqual(initialCheckInRequests, 0)
        XCTAssertEqual(initialStatusRequests, 1)
        guard case let .notCheckedIn(statistics) = session.activeAccountCheckInStatus else {
            return XCTFail("启动维护应只查询，并显示未签到状态")
        }
        XCTAssertEqual(statistics.consecutiveDays, 6)
        XCTAssertEqual(statistics.totalDays, 42)

        await session.checkInActiveAccount()

        let finalCheckInRequests = await service.debugCheckInRequestCount()
        let finalStatusRequests = await service.debugCheckInStatusRequestCount()
        XCTAssertEqual(finalCheckInRequests, 1)
        XCTAssertEqual(finalStatusRequests, 2)
        guard case let .checkedIn(updatedStatistics, _) = session.activeAccountCheckInStatus else {
            return XCTFail("手动签到后应刷新并展示统计")
        }
        XCTAssertEqual(updatedStatistics.consecutiveDays, 7)
        XCTAssertEqual(updatedStatistics.totalDays, 43)
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

final class ToolboxAPIParserTests: XCTestCase {
    func testParsesWorldBriefingMetadataAndFiltersBlankNews() throws {
        let data = Data(
            """
            {
              "code": 200,
              "message": "获取成功",
              "data": {
                "date": "2026-07-28",
                "news": ["第一条新闻", "  ", "第二条新闻"],
                "image": "https://example.com/daily.png",
                "cover": "https://example.com/cover.png",
                "tip": "保持好奇",
                "link": "https://example.com/source",
                "day_of_week": "星期二",
                "lunar_date": "丙午年六月十五",
                "updated_at": 1785206253792
              }
            }
            """.utf8
        )

        let result = try ToolboxAPIParser.worldBriefing(from: data)

        XCTAssertEqual(result.date, "2026-07-28")
        XCTAssertEqual(result.news, ["第一条新闻", "第二条新闻"])
        XCTAssertEqual(result.dayOfWeek, "星期二")
        XCTAssertEqual(result.lunarDate, "丙午年六月十五")
        XCTAssertEqual(result.tip, "保持好奇")
        XCTAssertEqual(result.imageURL?.absoluteString, "https://example.com/daily.png")
        XCTAssertEqual(result.sourceURL?.absoluteString, "https://example.com/source")
        XCTAssertEqual(
            try XCTUnwrap(result.updatedAt).timeIntervalSince1970,
            1_785_206_253.792,
            accuracy: 0.001
        )
    }

    func testParsesAIArticlesAndSupportsEmptyDailyFeed() throws {
        let populated = Data(
            """
            {
              "code": 200,
              "message": "获取成功",
              "data": {
                "date": "2026-07-28",
                "news": [{
                  "title": "新的 AI 模型",
                  "detail": "模型能力说明",
                  "link": "https://example.com/ai",
                  "source": "测试来源",
                  "date": "2026-07-28"
                }]
              }
            }
            """.utf8
        )
        let empty = Data(
            """
            {
              "code": 200,
              "message": "获取成功",
              "data": {"date": "2026-07-28", "news": []}
            }
            """.utf8
        )

        let articles = try ToolboxAPIParser.aiNews(from: populated)

        XCTAssertEqual(articles.count, 1)
        XCTAssertEqual(articles[0].title, "新的 AI 模型")
        XCTAssertEqual(articles[0].summary, "模型能力说明")
        XCTAssertEqual(articles[0].source, "测试来源")
        XCTAssertEqual(articles[0].link?.absoluteString, "https://example.com/ai")
        XCTAssertEqual(try ToolboxAPIParser.aiNews(from: empty), [])
    }

    func testParsesRealtimeITArticlesAndRejectsFailedEnvelope() throws {
        let data = Data(
            """
            {
              "code": 200,
              "message": "获取成功",
              "data": [{
                "title": "实时科技新闻",
                "description": "新闻摘要",
                "link": "https://www.ithome.com/0/1/2.htm",
                "created": "2026-07-28 11:10:14",
                "created_at": 1785208214000
              }]
            }
            """.utf8
        )
        let failed = Data(
            """
            {"code": 503, "message": "上游服务不可用", "data": []}
            """.utf8
        )

        let articles = try ToolboxAPIParser.itNews(from: data)

        XCTAssertEqual(articles.count, 1)
        XCTAssertEqual(articles[0].title, "实时科技新闻")
        XCTAssertEqual(articles[0].source, "IT之家")
        XCTAssertEqual(articles[0].publishedText, "2026-07-28 11:10:14")
        XCTAssertEqual(
            try XCTUnwrap(articles[0].publishedAt).timeIntervalSince1970,
            1_785_208_214,
            accuracy: 0.001
        )
        XCTAssertThrowsError(try ToolboxAPIParser.itNews(from: failed)) { error in
            XCTAssertEqual(error as? ToolboxAPIError, .service("上游服务不可用"))
        }
    }

    func testParsesDouyinRednoteAndBilibiliHotLists() throws {
        let douyin = Data(
            """
            {
              "code": 200,
              "message": "获取成功",
              "data": [{
                "title": "抖音热点",
                "hot_value": 12050789,
                "link": "https://www.douyin.com/search/test",
                "active_time_at": 1785239248000
              }]
            }
            """.utf8
        )
        let rednote = Data(
            """
            {
              "code": 200,
              "message": "获取成功",
              "data": [{
                "rank": 3,
                "title": "小红书热点",
                "score": "910.4w",
                "word_type": "热",
                "link": "https://www.xiaohongshu.com/search_result?keyword=test"
              }]
            }
            """.utf8
        )
        let bilibili = Data(
            """
            {
              "code": 200,
              "message": "获取成功",
              "data": [{
                "title": "哔哩哔哩热搜",
                "link": "https://search.bilibili.com/all?keyword=test"
              }]
            }
            """.utf8
        )

        let douyinArticles = try ToolboxAPIParser.douyinHot(from: douyin)
        XCTAssertEqual(douyinArticles.first?.rank, 1)
        XCTAssertEqual(douyinArticles.first?.source, "抖音")
        XCTAssertEqual(douyinArticles.first?.publishedText, "热度 1205.1 万")
        XCTAssertEqual(
            try XCTUnwrap(douyinArticles.first?.publishedAt).timeIntervalSince1970,
            1_785_239_248,
            accuracy: 0.001
        )

        let rednoteArticles = try ToolboxAPIParser.rednoteHot(from: rednote)
        XCTAssertEqual(rednoteArticles.first?.rank, 3)
        XCTAssertEqual(rednoteArticles.first?.source, "小红书")
        XCTAssertEqual(rednoteArticles.first?.publishedText, "热度 910.4w · 热")

        let bilibiliArticles = try ToolboxAPIParser.bilibiliHot(from: bilibili)
        XCTAssertEqual(bilibiliArticles.first?.rank, 1)
        XCTAssertEqual(bilibiliArticles.first?.source, "哔哩哔哩")
        XCTAssertEqual(
            bilibiliArticles.first?.link?.absoluteString,
            "https://search.bilibili.com/all?keyword=test"
        )
    }

    func testParsesWeiboAndZhihuHotLists() throws {
        let weibo = Data(
            """
            {
              "code": 200,
              "message": "获取成功",
              "data": [{
                "title": "微博热搜",
                "hot_value": 2283800,
                "link": "https://s.weibo.com/weibo?q=test"
              }]
            }
            """.utf8
        )
        let zhihu = Data(
            """
            {
              "code": 200,
              "message": "获取成功",
              "data": [{
                "title": "知乎热门问题",
                "detail": "问题的详细说明",
                "hot_value_desc": "1713 万热度",
                "created_at": 1784956439000,
                "created": "2026/07/25 13:13:59",
                "link": "https://www.zhihu.com/question/1"
              }]
            }
            """.utf8
        )

        let weiboArticles = try ToolboxAPIParser.weiboHot(from: weibo)
        XCTAssertEqual(weiboArticles.first?.rank, 1)
        XCTAssertEqual(weiboArticles.first?.source, "微博")
        XCTAssertEqual(weiboArticles.first?.publishedText, "热度 228.4 万")

        let zhihuArticles = try ToolboxAPIParser.zhihuHot(from: zhihu)
        XCTAssertEqual(zhihuArticles.first?.rank, 1)
        XCTAssertEqual(zhihuArticles.first?.summary, "问题的详细说明")
        XCTAssertEqual(zhihuArticles.first?.source, "知乎")
        XCTAssertEqual(zhihuArticles.first?.publishedText, "1713 万热度")
        XCTAssertEqual(
            try XCTUnwrap(zhihuArticles.first?.publishedAt).timeIntervalSince1970,
            1_784_956_439,
            accuracy: 0.001
        )
    }

    func testToolboxServiceFallsBackToOfficialBackupInstance() async throws {
        let transport = ToolboxFallbackTransport()
        let service = ToolboxAPIService(
            transport: transport,
            baseURLs: [
                ToolboxInstanceSettings.primaryBaseURL,
                ToolboxInstanceSettings.officialBackupBaseURL
            ]
        )

        let content = try await service.load(.bilibiliHot)

        guard case let .articles(articles) = content else {
            return XCTFail("哔哩哔哩热搜应解析为文章列表")
        }
        let requestedHosts = await transport.requestedHosts()
        XCTAssertEqual(articles.first?.title, "备用实例热搜")
        XCTAssertEqual(
            requestedHosts,
            ["60s.viki.moe", "60s.b23.run"]
        )
    }

    func testToolboxInstanceSettingsValidateAndPrioritizeCustomBaseURL() throws {
        XCTAssertEqual(
            ToolboxInstanceSettings.normalizedBaseURL(
                from: "  https://example.com/60s/  "
            )?.absoluteString,
            "https://example.com/60s"
        )
        XCTAssertNil(
            ToolboxInstanceSettings.normalizedBaseURL(
                from: "ftp://example.com"
            )
        )
        XCTAssertNil(
            ToolboxInstanceSettings.normalizedBaseURL(
                from: "https://example.com?token=secret"
            )
        )

        let customURLs = ToolboxInstanceSettings.configuredBaseURLs(
            selectionRawValue: ToolboxInstanceChoice.custom.rawValue,
            customBaseURLString: "https://example.com/60s/"
        )
        XCTAssertEqual(
            customURLs.map(\.absoluteString),
            ["https://example.com/60s"]
        )

        let backupURLs = ToolboxInstanceSettings.configuredBaseURLs(
            selectionRawValue: ToolboxInstanceChoice.officialBackup.rawValue,
            customBaseURLString: ""
        )
        XCTAssertEqual(
            backupURLs.map(\.absoluteString),
            ["https://60s.b23.run"]
        )
    }

    func testToolboxServiceAppendsEndpointToCustomBasePath() async throws {
        let transport = ToolboxURLRecordingTransport()
        let service = ToolboxAPIService(
            transport: transport,
            baseURLs: [try XCTUnwrap(URL(string: "https://example.com/60s"))]
        )

        _ = try await service.load(.bilibiliHot)

        let requestedURLs = await transport.requestedURLs()
        XCTAssertEqual(
            requestedURLs.map(\.absoluteString),
            ["https://example.com/60s/v2/bili"]
        )
    }

    func testToolboxImageClipboardRecognizesImageData() throws {
        let pngData = try XCTUnwrap(Data(
            base64Encoded:
                "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        ))

        XCTAssertEqual(
            ToolboxImageClipboard.pasteboardType(for: pngData)?.rawValue,
            "public.png"
        )
        XCTAssertNil(
            ToolboxImageClipboard.pasteboardType(
                for: Data("not an image".utf8)
            )
        )
    }
}

final class ForumDirectorySearchTests: XCTestCase {
    private let categories = [
        ForumCategory(
            id: "综合讨论",
            name: "综合讨论",
            forums: [
                Forum(
                    id: ForumID(rawValue: 7),
                    name: "艾泽拉斯国家地理",
                    subtitle: "魔兽世界综合讨论",
                    category: "综合讨论"
                )
            ]
        ),
        ForumCategory(
            id: "游戏社区",
            name: "游戏社区",
            forums: [
                Forum(
                    id: ForumID(rawValue: 510381),
                    name: "晴风村",
                    subtitle: "FINAL FANTASY XIV",
                    category: "游戏社区"
                ),
                Forum(
                    id: ForumID(stid: 35925536),
                    name: "二次元综合",
                    category: "游戏社区"
                )
            ]
        )
    ]

    func testEmptyQueryKeepsAllCategoriesAndForums() {
        XCTAssertEqual(
            ForumDirectorySearch.filter(categories, query: " \n "),
            categories
        )
    }

    func testSearchMatchesNameSubtitleCategoryAndForumIdentifier() {
        XCTAssertEqual(
            ForumDirectorySearch.filter(categories, query: "艾泽")
                .flatMap(\.forums)
                .map(\.name),
            ["艾泽拉斯国家地理"]
        )
        XCTAssertEqual(
            ForumDirectorySearch.filter(categories, query: "final xiv")
                .flatMap(\.forums)
                .map(\.name),
            ["晴风村"]
        )
        XCTAssertEqual(
            ForumDirectorySearch.filter(categories, query: "综合讨论")
                .flatMap(\.forums)
                .map(\.name),
            ["艾泽拉斯国家地理"]
        )
        XCTAssertEqual(
            ForumDirectorySearch.filter(categories, query: "fid 510381")
                .flatMap(\.forums)
                .map(\.name),
            ["晴风村"]
        )
        XCTAssertEqual(
            ForumDirectorySearch.filter(categories, query: "stid 35925536")
                .flatMap(\.forums)
                .map(\.name),
            ["二次元综合"]
        )
    }

    func testSearchReturnsOnlyCategoriesContainingMatches() {
        let result = ForumDirectorySearch.filter(categories, query: "不存在的版面")

        XCTAssertTrue(result.isEmpty)
    }
}

private actor ToolboxFallbackTransport: HTTPTransport {
    private var hosts: [String] = []

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let host = request.url?.host ?? ""
        hosts.append(host)
        let body: String
        if host == "60s.viki.moe" {
            body = #"{"code":500,"message":"上游服务不可用","data":[]}"#
        } else {
            body = """
            {
              "code": 200,
              "message": "获取成功",
              "data": [{
                "title": "备用实例热搜",
                "link": "https://search.bilibili.com/all?keyword=test"
              }]
            }
            """
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (Data(body.utf8), response)
    }

    func requestedHosts() -> [String] {
        hosts
    }
}

private actor ToolboxURLRecordingTransport: HTTPTransport {
    private var urls: [URL] = []

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        urls.append(request.url!)
        let body = """
        {
          "code": 200,
          "message": "获取成功",
          "data": [{
            "title": "自定义实例热搜",
            "link": "https://search.bilibili.com/all?keyword=test"
          }]
        }
        """
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (Data(body.utf8), response)
    }

    func requestedURLs() -> [URL] {
        urls
    }
}
