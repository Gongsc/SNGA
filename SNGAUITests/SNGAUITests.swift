import XCTest

@MainActor
final class SNGAUITests: XCTestCase {
    func testUnsignedAccountShowsSidebarPromptAndManualCheckInStatistics() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--uitesting-seed"]
        app.launch()
        ensureMainWindow(in: app)

        let userCenter = app.buttons["用户中心"]
        XCTAssertTrue(userCenter.waitForExistence(timeout: 5))
        XCTAssertEqual(userCenter.value as? String, "待签到")
        let checkIn = app.buttons["user-center-check-in-button"]
        XCTAssertTrue(checkIn.waitForExistence(timeout: 5))
        checkIn.click()

        let status = app.descendants(matching: .any)["user-center-check-in-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        let statistics = status.value as? String ?? ""
        XCTAssertTrue(statistics.contains("连续签到 7 天"), "实际辅助说明：\(statistics)")
        XCTAssertTrue(statistics.contains("历史累计 43 天"), "实际辅助说明：\(statistics)")
        XCTAssertEqual(userCenter.value as? String, "")
    }

    func testPostAuthorInformationAppearsInThread() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--uitesting-seed"]
        app.launch()
        ensureMainWindow(in: app)
        let mainWindow = app.windows.firstMatch

        XCTAssertTrue(mainWindow.buttons["艾泽拉斯国家地理"].waitForExistence(timeout: 5))
        mainWindow.buttons["艾泽拉斯国家地理"].click()
        XCTAssertTrue(mainWindow.buttons["topic-9001"].waitForExistence(timeout: 5))
        mainWindow.buttons["topic-9001"].click()

        let authorName = mainWindow.descendants(matching: .any)["post-author-name-1"]
        let replyDate = mainWindow.descendants(matching: .any)["post-author-date-1"]
        let avatar = mainWindow.descendants(matching: .any)["post-author-avatar-1"]
        let level = mainWindow.descendants(matching: .any)["post-author-level-1"]
        let medals = mainWindow.descendants(matching: .any)["post-author-medals-1"]
        let location = mainWindow.descendants(matching: .any)["post-author-location-1"]
        XCTAssertTrue(authorName.waitForExistence(timeout: 5))
        XCTAssertTrue(replyDate.exists)
        XCTAssertTrue(avatar.exists)
        XCTAssertTrue(level.exists)
        XCTAssertTrue(medals.exists)
        XCTAssertTrue(location.waitForExistence(timeout: 5))
        XCTAssertFalse(mainWindow.staticTexts["于明日落下，静寂与月光"].exists)
        XCTAssertGreaterThan(authorName.frame.width, 20)
        XCTAssertGreaterThan(replyDate.frame.width, 20)
        XCTAssertEqual(authorName.frame.midY, level.frame.midY, accuracy: 3)
        XCTAssertEqual(replyDate.frame.midY, medals.frame.midY, accuracy: 3)
        XCTAssertLessThanOrEqual(avatar.frame.minY, authorName.frame.minY + 2)
        XCTAssertGreaterThanOrEqual(avatar.frame.maxY, replyDate.frame.maxY - 2)
        XCTAssertTrue(mainWindow.descendants(matching: .any)["post-author-reputation-1"].exists)
        XCTAssertTrue(mainWindow.descendants(matching: .any)["post-author-registered-1"].exists)
        XCTAssertTrue(mainWindow.descendants(matching: .any)["post-author-prestige-1"].exists)
    }

    func testRecentlyVisitedForumsAppearInVisitOrder() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--uitesting-seed"]
        app.launch()
        ensureMainWindow(in: app)

        XCTAssertTrue(app.staticTexts["最近访问"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["暂无最近访问"].exists)

        app.buttons["favorite-forum--7"].click()
        XCTAssertTrue(app.buttons["recent-forum--7"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["暂无最近访问"].exists)

        app.buttons["全部版面"].click()
        app.buttons["directory-forum-510381"].click()
        XCTAssertTrue(app.buttons["recent-forum-510381"].waitForExistence(timeout: 5))
        XCTAssertLessThan(
            app.buttons["recent-forum-510381"].frame.minY,
            app.buttons["recent-forum--7"].frame.minY
        )
    }

    /// 「关于 SNGA」也不再弹窗：菜单项把主窗口切到「设置 › 关于」。
    func testAboutMenuItemOpensAboutSettingsSection() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--uitesting-seed"]
        app.launch()
        ensureMainWindow(in: app)
        let mainWindow = app.windows.firstMatch

        let appMenu = app.menuBars.menuBarItems["SNGA"]
        appMenu.click()
        let about = appMenu.menus.menuItems["关于 SNGA"]
        XCTAssertTrue(about.waitForExistence(timeout: 2))
        about.click()

        XCTAssertTrue(
            mainWindow.descendants(matching: .any)["settings-detail-about"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertEqual(app.windows.count, 1)
        XCTAssertTrue(mainWindow.staticTexts["版本 1.8.2（1）"].exists)
        XCTAssertTrue(mainWindow.descendants(matching: .any)["about-github"].exists)
        XCTAssertTrue(mainWindow.descendants(matching: .any)["about-email"].exists)
        XCTAssertTrue(mainWindow.links["gongsc@live.cn"].exists)
    }

    func testOfficialLoginFormDisplaysJavaScriptValidation() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launch()
        ensureMainWindow(in: app)

        XCTAssertTrue(app.buttons["添加账号"].waitForExistence(timeout: 5))
        app.buttons["添加账号"].click()
        XCTAssertTrue(app.staticTexts["登录 NGA"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 15))

        let passwordField = app.secureTextFields.firstMatch
        if !passwordField.waitForExistence(timeout: 10) {
            let passwordLogin = app.links["使用密码登录"]
            XCTAssertTrue(passwordLogin.waitForExistence(timeout: 5))
            passwordLogin.click()
        }

        XCTAssertTrue(app.textFields.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(passwordField.waitForExistence(timeout: 5))
        XCTAssertTrue(app.links["登 录"].waitForExistence(timeout: 5))
        app.links["登 录"].click()
        XCTAssertTrue(app.staticTexts["需要填入用户名和密码"].waitForExistence(timeout: 5))
    }

    func testSwitchAccountBrowseFavoriteAndOpenMessage() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--uitesting-seed"]
        app.launch()
        ensureMainWindow(in: app)

        XCTAssertTrue(app.buttons["测试账号 A"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["艾泽拉斯国家地理"].waitForExistence(timeout: 5))

        app.buttons["艾泽拉斯国家地理"].firstMatch.click()
        XCTAssertTrue(app.buttons["topic-9001"].waitForExistence(timeout: 5))
        app.buttons["topic-9001"].click()
        XCTAssertTrue(app.buttons["回复话题"].waitForExistence(timeout: 5))

        app.buttons["测试账号 B"].click()
        XCTAssertTrue(app.buttons["论坛消息"].waitForExistence(timeout: 5))
        app.buttons["论坛消息"].firstMatch.click()
        XCTAssertTrue(app.buttons["全部已读"].waitForExistence(timeout: 5))
        app.buttons["全部已读"].click()
        XCTAssertTrue(app.buttons["message-7001"].waitForExistence(timeout: 5))
        app.buttons["message-7001"].click()
        XCTAssertTrue(app.staticTexts["测试消息"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["message-post-time-7002"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["reply-private-message"].waitForExistence(timeout: 5))

        app.buttons["favorite-forum--7"].click()
        XCTAssertTrue(app.buttons["topic-9001"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["reply-private-message"].exists)
    }

    func testTopicPaginationAndShareActions() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--uitesting-seed"]
        app.launch()
        ensureMainWindow(in: app)

        XCTAssertTrue(app.buttons["艾泽拉斯国家地理"].waitForExistence(timeout: 5))
        app.buttons["艾泽拉斯国家地理"].firstMatch.click()
        XCTAssertTrue(app.buttons["topic-list-scroll-to-top"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["topic-list-featured"].exists)

        let pinnedTopic = app.buttons["topic-list-pinned-topic"]
        XCTAssertTrue(pinnedTopic.waitForExistence(timeout: 5))
        pinnedTopic.click()
        XCTAssertTrue(
            app.descendants(matching: .any)["thread-topic-title"]
                .waitForExistence(timeout: 5)
        )
        let loadedPinnedTopic = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "版面置顶话题"),
            object: app.descendants(matching: .any)["thread-topic-title"]
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [loadedPinnedTopic], timeout: 5),
            .completed
        )

        let nextPage = app.buttons["topic-list-next-page"]
        XCTAssertTrue(nextPage.waitForExistence(timeout: 5))
        nextPage.click()

        let topicListLoading = app.descendants(matching: .any)[
            "topic-list-loading-indicator"
        ]
        XCTAssertTrue(topicListLoading.waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["topic-9001"].exists)

        let pageField = app.textFields["topic-list-page-field"]
        XCTAssertTrue(pageField.waitForExistence(timeout: 5))
        let reachedSecondPage = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "2"),
            object: pageField
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [reachedSecondPage], timeout: 5),
            .completed
        )
        XCTAssertTrue(topicListLoading.waitForNonExistence(timeout: 5))

        let sortOrder = app.descendants(matching: .any)["topic-list-sort-order"]
        XCTAssertTrue(sortOrder.waitForExistence(timeout: 5))
        sortOrder.click()
        let latestTopic = app.menuItems["最新话题"]
        XCTAssertTrue(latestTopic.waitForExistence(timeout: 5))
        latestTopic.click()

        XCTAssertTrue(topicListLoading.waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["topic-9001"].exists)
        let returnedToFirstPage = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "1"),
            object: pageField
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [returnedToFirstPage], timeout: 5),
            .completed
        )
        XCTAssertTrue(topicListLoading.waitForNonExistence(timeout: 5))
        XCTAssertTrue(
            app.descendants(matching: .any)["topic-list-top"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertLessThan(
            app.buttons["topic-9002"].frame.minY,
            app.buttons["topic-9001"].frame.minY
        )

        let windowWidthBeforeOpeningTopic = app.windows.firstMatch.frame.width
        XCTAssertTrue(app.buttons["topic-9001"].waitForExistence(timeout: 5))
        app.buttons["topic-9001"].click()
        XCTAssertTrue(app.buttons["thread-scroll-to-top"].waitForExistence(timeout: 5))
        XCTAssertEqual(
            app.windows.firstMatch.frame.width,
            windowWidthBeforeOpeningTopic,
            accuracy: 2
        )
        let onlyAuthor = app.descendants(matching: .any)["thread-only-author"]
        XCTAssertTrue(onlyAuthor.waitForExistence(timeout: 5))
        XCTAssertEqual(onlyAuthor.value as? String, "已关闭")
        let replyAuthor = app.buttons["回复用户"]
        XCTAssertTrue(replyAuthor.waitForExistence(timeout: 5))
        onlyAuthor.click()
        let onlyAuthorEnabled = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "已开启"),
            object: onlyAuthor
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [onlyAuthorEnabled], timeout: 5),
            .completed
        )
        XCTAssertTrue(replyAuthor.waitForNonExistence(timeout: 5))

        XCTAssertTrue(app.buttons["分享话题"].waitForExistence(timeout: 5))
        app.buttons["分享话题"].click()

        let copyLink = app.buttons["copy-topic-link"]
        XCTAssertTrue(copyLink.waitForExistence(timeout: 5))
        let openInBrowser = app.buttons["open-topic-in-browser"]
        XCTAssertTrue(openInBrowser.exists)
        let copyFrameBefore = copyLink.frame
        let browserFrameBefore = openInBrowser.frame
        copyLink.click()
        XCTAssertTrue(app.buttons["已复制"].waitForExistence(timeout: 5))
        let copiedLink = app.buttons["copy-topic-link"]
        XCTAssertEqual(copiedLink.frame.minX, copyFrameBefore.minX, accuracy: 1)
        XCTAssertEqual(copiedLink.frame.width, copyFrameBefore.width, accuracy: 1)
        XCTAssertEqual(openInBrowser.frame.minX, browserFrameBefore.minX, accuracy: 1)
        XCTAssertGreaterThanOrEqual(
            openInBrowser.frame.minX - copiedLink.frame.maxX,
            10
        )
    }

    func testImageHeavyThreadCanReturnToTop() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "--uitesting",
            "--uitesting-seed",
            "--uitesting-image-thread"
        ]
        app.launch()
        ensureMainWindow(in: app)
        let mainWindow = app.windows.firstMatch

        XCTAssertTrue(mainWindow.buttons["艾泽拉斯国家地理"].waitForExistence(timeout: 5))
        mainWindow.buttons["艾泽拉斯国家地理"].click()
        XCTAssertTrue(mainWindow.buttons["topic-9001"].waitForExistence(timeout: 5))
        mainWindow.buttons["topic-9001"].click()

        let skeleton = mainWindow.descendants(matching: .any)["thread-content-skeleton"]
        XCTAssertTrue(skeleton.waitForExistence(timeout: 2))
        let author = mainWindow.descendants(matching: .any)["post-author-name-1"]
        XCTAssertTrue(skeleton.waitForNonExistence(timeout: 8))
        XCTAssertTrue(author.waitForExistence(timeout: 5))
        XCTAssertTrue(
            mainWindow.descendants(matching: .any)["post-author-location-1"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertFalse(mainWindow.staticTexts["于明日落下，静寂与月光"].exists)
        let initialAuthorY = author.frame.minY
        let threadScroll = mainWindow.scrollViews["thread-content-scroll"]
        XCTAssertTrue(threadScroll.waitForExistence(timeout: 5))
        threadScroll.swipeUp()
        threadScroll.swipeUp()
        XCTAssertLessThan(author.frame.minY, initialAuthorY - 100)

        let scrollToTop = mainWindow.buttons["thread-scroll-to-top"]
        XCTAssertTrue(scrollToTop.waitForExistence(timeout: 5))
        scrollToTop.click()
        XCTAssertTrue(author.waitForExistence(timeout: 5))
        XCTAssertEqual(author.frame.minY, initialAuthorY, accuracy: 20)

        let nextPage = mainWindow.buttons["thread-next-page"]
        XCTAssertTrue(nextPage.waitForExistence(timeout: 5))
        nextPage.click()
        XCTAssertTrue(skeleton.waitForExistence(timeout: 2))
        XCTAssertTrue(skeleton.waitForNonExistence(timeout: 8))
        XCTAssertTrue(
            mainWindow.descendants(matching: .any)["post-author-name-101"]
                .waitForExistence(timeout: 5)
        )

        let pageField = mainWindow.textFields["thread-page-field"]
        XCTAssertTrue(pageField.waitForExistence(timeout: 5))
        pageField.click()
        app.typeKey("a", modifierFlags: .command)
        pageField.typeText("3")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(skeleton.waitForExistence(timeout: 2))
        XCTAssertTrue(skeleton.waitForNonExistence(timeout: 8))
        XCTAssertTrue(
            mainWindow.descendants(matching: .any)["post-author-name-201"]
                .waitForExistence(timeout: 5)
        )
    }

    func testInternalTopicLinkOpensInAppAndReturnsToPreviousThread() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--uitesting-seed"]
        app.launch()
        ensureMainWindow(in: app)

        XCTAssertTrue(app.buttons["艾泽拉斯国家地理"].waitForExistence(timeout: 5))
        app.buttons["艾泽拉斯国家地理"].firstMatch.click()
        XCTAssertTrue(app.buttons["topic-9001"].waitForExistence(timeout: 5))
        app.buttons["topic-9001"].click()

        let internalLink = app.links["打开站内关联话题"]
        XCTAssertTrue(internalLink.waitForExistence(timeout: 5))
        internalLink.click()

        let skeleton = app.descendants(matching: .any)["thread-content-skeleton"]
        XCTAssertTrue(skeleton.waitForExistence(timeout: 2))
        let linkedTopicContent = app.staticTexts["这是通过站内链接打开的关联话题。"]
        XCTAssertFalse(linkedTopicContent.exists)
        let backButton = app.buttons["thread-linked-topic-back"]
        XCTAssertTrue(backButton.waitForExistence(timeout: 5))
        XCTAssertTrue(skeleton.waitForNonExistence(timeout: 5))
        XCTAssertTrue(linkedTopicContent.waitForExistence(timeout: 5))
        let topicTitle = app.staticTexts["thread-topic-title"]
        XCTAssertTrue(topicTitle.waitForExistence(timeout: 5))
        XCTAssertEqual(topicTitle.label, "话题二：多账号与收藏测试")
        XCTAssertFalse(app.scrollViews.staticTexts["thread-topic-title"].exists)
        backButton.click()

        XCTAssertTrue(backButton.waitForNonExistence(timeout: 5))
        XCTAssertTrue(skeleton.waitForNonExistence(timeout: 5))
        let restoredTitle = app.staticTexts["thread-topic-title"]
        XCTAssertTrue(restoredTitle.waitForExistence(timeout: 5))
        XCTAssertEqual(restoredTitle.label, "话题一：欢迎使用 SNGA")
        XCTAssertFalse(app.scrollViews.staticTexts["thread-topic-title"].exists)
    }

    /// 原生渲染的楼层：正文点得动、点完不掉字，站内链接仍然走应用内跳转。
    ///
    /// 正文用 AppKit 文本视图渲染，而不是开了 `.textSelection` 的 SwiftUI `Text` ——
    /// 后者点击后会按自己量出来的宽度重排，最长的行多折一行，段尾被裁掉。
    func testNativePostBodyKeepsTextAfterClickAndOpensInternalLink() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--uitesting-seed"]
        app.launch()
        ensureMainWindow(in: app)
        let mainWindow = app.windows.firstMatch

        XCTAssertTrue(mainWindow.buttons["艾泽拉斯国家地理"].waitForExistence(timeout: 5))
        mainWindow.buttons["艾泽拉斯国家地理"].firstMatch.click()
        XCTAssertTrue(mainWindow.buttons["topic-9001"].waitForExistence(timeout: 5))
        mainWindow.buttons["topic-9001"].click()

        let body = mainWindow.staticTexts.matching(
            NSPredicate(format: "value CONTAINS %@", "回复成功。")
        ).firstMatch
        XCTAssertTrue(body.waitForExistence(timeout: 10))
        // 楼层要整个落在视口里，底部的分页栏会盖住最后一行。
        let scroll = mainWindow.scrollViews["thread-content-scroll"].firstMatch
        var settles = 0
        while body.frame.maxY > mainWindow.frame.maxY - 90, settles < 10 {
            scroll.scroll(byDeltaX: 0, deltaY: -120)
            Thread.sleep(forTimeInterval: 0.6)
            settles += 1
        }

        // 段落排版宽度就是可用宽度，最长的行离右边界还有富余，点击不会触发重排。
        let beforeFrame = body.frame
        body.click()
        XCTAssertEqual(body.frame.width, beforeFrame.width, accuracy: 0.5)
        XCTAssertEqual(body.frame.height, beforeFrame.height, accuracy: 0.5)
        XCTAssertTrue((body.value as? String ?? "").contains("打开原生关联话题"))

        // 链接在第二行，按段落内的相对位置点。
        body.coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: 0.8)).click()
        let topicTitle = mainWindow.staticTexts["thread-topic-title"]
        XCTAssertTrue(topicTitle.waitForExistence(timeout: 10))
        let openedLinkedTopic = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "话题二：多账号与收藏测试"),
            object: topicTitle
        )
        XCTAssertEqual(XCTWaiter.wait(for: [openedLinkedTopic], timeout: 10), .completed)
    }

    func testForumDirectorySearchFiltersForums() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--uitesting-seed"]
        app.launch()
        ensureMainWindow(in: app)

        XCTAssertTrue(app.buttons["全部版面"].waitForExistence(timeout: 5))
        app.buttons["全部版面"].click()

        let searchField = app.textFields["directory-search-field"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["directory-forum--7"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["directory-forum-510381"].exists)

        searchField.click()
        searchField.typeText("510381")

        XCTAssertEqual(searchField.value as? String, "510381")
        XCTAssertTrue(app.buttons["directory-forum-510381"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["directory-forum--7"].exists)
    }

    func testBrowseModulesUseTitlesAndBottomRefreshBars() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--uitesting-seed"]
        app.launch()
        ensureMainWindow(in: app)

        XCTAssertTrue(app.buttons["用户中心"].waitForExistence(timeout: 5))
        assertModule(
            "用户中心",
            refreshIdentifier: "user-center-refresh",
            in: app
        )

        app.buttons["全部版面"].click()
        assertModule(
            "全部版面",
            refreshIdentifier: "directory-refresh",
            in: app
        )

        app.buttons["收藏夹"].click()
        assertModule(
            "收藏夹",
            refreshIdentifier: "favorite-topics-refresh",
            in: app
        )

        XCTAssertTrue(app.buttons["favorite-forum--7"].waitForExistence(timeout: 5))
        app.buttons["favorite-forum--7"].click()

        let forumBack = app.buttons["返回全部版面"]
        XCTAssertTrue(forumBack.waitForExistence(timeout: 5))
        XCTAssertTrue(forumBack.isHittable)
        XCTAssertFalse(
            app.descendants(matching: .any)["browser-module-title"].exists
        )
        let forumTitle = app.staticTexts["topic-list-top"]
        XCTAssertTrue(forumTitle.waitForExistence(timeout: 5))
        forumBack.click()

        assertModule(
            "全部版面",
            refreshIdentifier: "directory-refresh",
            in: app
        )
        XCTAssertFalse(app.buttons["刷新"].exists)
    }

    func testForumMessagesUseTitleAndBottomRefreshBar() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--uitesting-seed"]
        app.launch()
        ensureMainWindow(in: app)

        let messages = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "论坛消息")
        ).firstMatch
        XCTAssertTrue(messages.waitForExistence(timeout: 5))
        messages.click()
        assertModule(
            "论坛消息",
            refreshIdentifier: "message-list-refresh",
            in: app
        )
        let moduleTitle = app.staticTexts["browser-module-title"]
        let firstMessage = app.buttons["message-7001"]
        XCTAssertTrue(firstMessage.waitForExistence(timeout: 5))
        XCTAssertEqual(
            moduleTitle.frame.minX,
            firstMessage.frame.minX,
            accuracy: 1
        )
        assertRefreshIsInBottomBar("mark-all-messages-read", in: app)
    }

    func testGlobalAndCurrentForumSearchEntrypoints() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--uitesting-seed"]
        app.launch()
        ensureMainWindow(in: app)

        XCTAssertTrue(app.buttons["搜索"].waitForExistence(timeout: 5))
        app.buttons["搜索"].click()
        XCTAssertTrue(app.staticTexts["范围：全部版面"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["搜索"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["刷新"].exists)
        XCTAssertFalse(app.staticTexts["勾选的版面"].exists)
        XCTAssertFalse(app.staticTexts["选择一个子版面"].exists)

        let globalField = app.textFields["global-search-field"]
        XCTAssertTrue(globalField.waitForExistence(timeout: 5))
        let globalKind = app.descendants(matching: .any)["global-search-kind"]
        let globalSubmit = app.buttons["global-search-submit"]
        assertSearchControlsStayInOneRow(
            field: globalField,
            kindPicker: globalKind,
            submitButton: globalSubmit
        )
        XCTAssertFalse(app.staticTexts["搜索类型"].exists)
        XCTAssertLessThan(
            globalField.frame.minY - app.windows.firstMatch.frame.minY,
            180
        )
        let emptyGlobalFieldFrame = globalField.frame
        globalField.click()
        globalField.typeText("全局")
        XCTAssertEqual(globalField.frame, emptyGlobalFieldFrame)
        globalField.typeText("关键词")
        XCTAssertEqual(globalField.value as? String, "全局关键词")
        globalSubmit.click()
        XCTAssertTrue(app.buttons["search-topic-9101"].waitForExistence(timeout: 5))
        assertRefreshIsInBottomBar("global-search-refresh", in: app)

        app.buttons["艾泽拉斯国家地理"].firstMatch.click()
        let currentField = app.textFields["current-forum-search-field"]
        XCTAssertTrue(currentField.waitForExistence(timeout: 5))
        let currentKind = app.descendants(matching: .any)["current-forum-search-kind"]
        let currentSubmit = app.buttons["current-forum-search-submit"]
        assertSearchControlsStayInOneRow(
            field: currentField,
            kindPicker: currentKind,
            submitButton: currentSubmit
        )
        XCTAssertFalse(app.staticTexts["搜索类型"].exists)
        XCTAssertTrue(app.staticTexts["范围：当前版面"].waitForExistence(timeout: 5))
        let emptyCurrentFieldFrame = currentField.frame
        currentField.click()
        currentField.typeText("当前版面")
        XCTAssertEqual(currentField.frame, emptyCurrentFieldFrame)
        currentField.typeText("关键词")
        XCTAssertEqual(currentField.value as? String, "当前版面关键词")
        currentSubmit.click()

        XCTAssertTrue(app.buttons["topic-9101"].waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.buttons["current-forum-search-clear"].waitForExistence(timeout: 5)
        )
    }

    func testToolboxNavigationShowsAllFeeds() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--uitesting-seed"]
        app.launch()
        ensureMainWindow(in: app)

        XCTAssertTrue(app.buttons["小工具"].waitForExistence(timeout: 5))
        app.buttons["小工具"].click()
        assertModule(
            "小工具",
            refreshIdentifier: "toolbox-refresh",
            in: app
        )

        XCTAssertTrue(app.buttons["toolbox-feed-worldBriefing"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["toolbox-feed-aiNews"].exists)
        XCTAssertTrue(app.buttons["toolbox-feed-itNews"].exists)
        XCTAssertTrue(app.buttons["toolbox-feed-douyinHot"].exists)
        XCTAssertTrue(app.buttons["toolbox-feed-rednoteHot"].exists)
        XCTAssertTrue(app.buttons["toolbox-feed-bilibiliHot"].exists)
        XCTAssertTrue(app.buttons["toolbox-feed-weiboHot"].exists)
        XCTAssertTrue(app.buttons["toolbox-feed-zhihuHot"].exists)

        app.buttons["toolbox-feed-aiNews"].click()
        XCTAssertTrue(
            app.descendants(matching: .any)["toolbox-feed-detail-aiNews"]
                .waitForExistence(timeout: 5)
        )

        app.buttons["toolbox-feed-itNews"].click()
        XCTAssertTrue(
            app.descendants(matching: .any)["toolbox-feed-detail-itNews"]
                .waitForExistence(timeout: 5)
        )

        let menu = app.scrollViews["toolbox-menu-scroll"]
        let zhihu = app.buttons["toolbox-feed-zhihuHot"]
        if !zhihu.isHittable {
            menu.swipeUp()
        }
        XCTAssertTrue(zhihu.waitForExistence(timeout: 5))
        XCTAssertTrue(zhihu.isHittable)
        zhihu.click()
        XCTAssertTrue(
            app.descendants(matching: .any)["toolbox-feed-detail-zhihuHot"]
                .waitForExistence(timeout: 5)
        )
    }

    /// 设置整个长在主窗口里：应用菜单里的「设置…」不再弹窗，而是把边栏切到
    /// 设置，中栏列分类、右栏放面板。断言全部落在主窗口内。
    ///
    /// 这里点菜单项而不是按 ⌘,：任何一个注册了 ⌘, 全局热键的第三方应用都会把
    /// 这个键抢走，键盘事件根本到不了被测应用，测试就会无缘无故地红。菜单项和
    /// 快捷键指向同一个 `Button`，点它验的是同一条路径。
    func testSettingsMenuItemOpensSettingsInMainWindow() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--uitesting-seed"]
        app.launch()
        ensureMainWindow(in: app)
        let mainWindow = app.windows.firstMatch

        let appMenu = app.menuBars.menuBarItems["SNGA"]
        appMenu.click()
        let settingsItem = appMenu.menus.menuItems["设置…"]
        XCTAssertTrue(settingsItem.waitForExistence(timeout: 2))
        settingsItem.click()

        // 只该切换主窗口里的页面，不该多开一扇窗。
        XCTAssertTrue(
            mainWindow.descendants(matching: .any)["settings-section-appearance"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertEqual(app.windows.count, 1)
        XCTAssertTrue(
            mainWindow.descendants(matching: .any)["settings-detail-appearance"]
                .waitForExistence(timeout: 5)
        )

        let toolboxSection = mainWindow.descendants(matching: .any)["settings-section-toolbox"]
        XCTAssertTrue(toolboxSection.waitForExistence(timeout: 5))
        toolboxSection.click()

        let instancePicker = mainWindow.descendants(matching: .any)["toolbox-instance-picker"]
        XCTAssertTrue(instancePicker.waitForExistence(timeout: 5))
        instancePicker.click()
        let customInstance = app.menuItems["自定义实例"]
        XCTAssertTrue(customInstance.waitForExistence(timeout: 5))
        customInstance.click()

        XCTAssertTrue(
            mainWindow.textFields["toolbox-custom-instance-field"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(
            mainWindow.descendants(matching: .any)["toolbox-instance-documentation"]
                .waitForExistence(timeout: 5)
        )

        instancePicker.click()
        let automaticInstance = app.menuItems["自动选择（推荐）"]
        XCTAssertTrue(automaticInstance.waitForExistence(timeout: 5))
        automaticInstance.click()
    }

    /// 边栏左下角的入口和 ⌘, 走的是同一条路。
    func testSidebarSettingsButtonOpensSettings() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--uitesting-seed"]
        app.launch()
        ensureMainWindow(in: app)
        let mainWindow = app.windows.firstMatch

        let settingsButton = mainWindow.descendants(matching: .any)["sidebar-settings-button"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 10))
        settingsButton.click()

        XCTAssertTrue(
            mainWindow.descendants(matching: .any)["settings-detail-appearance"]
                .waitForExistence(timeout: 5)
        )

        let logSection = mainWindow.descendants(matching: .any)["settings-section-runtimeLog"]
        XCTAssertTrue(logSection.waitForExistence(timeout: 5))
        logSection.click()
        XCTAssertTrue(
            mainWindow.descendants(matching: .any)["settings-detail-runtimeLog"]
                .waitForExistence(timeout: 5)
        )
    }

    func testAISettingsExposeCompatibleEndpointPromptAndHistoryControls() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--uitesting-seed"]
        app.launch()
        ensureMainWindow(in: app)
        let mainWindow = app.windows.firstMatch

        let settingsButton = mainWindow.descendants(matching: .any)["sidebar-settings-button"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 5))
        settingsButton.click()

        let aiSection = mainWindow.descendants(matching: .any)["settings-section-ai"]
        XCTAssertTrue(aiSection.waitForExistence(timeout: 5))
        if !aiSection.isHittable {
            mainWindow.scrollViews["settings-menu-scroll"].swipeUp()
        }
        XCTAssertTrue(aiSection.isHittable)
        aiSection.click()

        XCTAssertTrue(
            mainWindow.descendants(matching: .any)["settings-detail-ai"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(mainWindow.textFields["ai-base-url-field"].exists)
        XCTAssertTrue(mainWindow.textFields["ai-model-field"].exists)
        XCTAssertTrue(mainWindow.secureTextFields["ai-api-key-field"].exists)
        XCTAssertTrue(
            mainWindow.descendants(matching: .any)["ai-instruction-editor"].exists
        )
        XCTAssertTrue(
            mainWindow.descendants(matching: .any)["ai-topic-summary-instruction-editor"].exists
        )
        XCTAssertTrue(
            mainWindow.descendants(matching: .any)["ai-history-limit"].exists
        )

        let testConnection = mainWindow.buttons["ai-test-connection-button"]
        XCTAssertTrue(testConnection.exists)
        testConnection.click()
        let connectionStatus = mainWindow.descendants(matching: .any)[
            "ai-connection-status"
        ]
        XCTAssertTrue(connectionStatus.waitForExistence(timeout: 5))
        let statusValue = connectionStatus.value as? String ?? ""
        XCTAssertTrue(statusValue.contains("连接成功"), "实际连接状态：\(statusValue)")
        XCTAssertTrue(statusValue.contains("ui-test-model"), "实际连接状态：\(statusValue)")
    }

    func testAITopicSummaryStreamsAndMasterSwitchHidesFeatures() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--uitesting-seed"]
        app.launch()
        ensureMainWindow(in: app)
        let mainWindow = app.windows.firstMatch

        let forum = mainWindow.buttons["艾泽拉斯国家地理"]
        XCTAssertTrue(forum.waitForExistence(timeout: 8))
        forum.click()
        let topic = mainWindow.buttons["topic-9001"]
        XCTAssertTrue(topic.waitForExistence(timeout: 8))
        topic.click()

        let summarize = mainWindow.buttons["thread-ai-summary-button"]
        XCTAssertTrue(summarize.waitForExistence(timeout: 8))
        summarize.click()
        XCTAssertTrue(
            mainWindow.descendants(matching: .any)["thread-ai-summary-card"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(
            mainWindow.descendants(matching: .any)["thread-ai-summary-content"]
                .waitForExistence(timeout: 8)
        )
        XCTAssertTrue(
            mainWindow.buttons["thread-ai-summary-regenerate"].waitForExistence(timeout: 8)
        )

        mainWindow.descendants(matching: .any)["sidebar-settings-button"].click()
        let aiSection = mainWindow.descendants(matching: .any)["settings-section-ai"]
        XCTAssertTrue(aiSection.waitForExistence(timeout: 5))
        if !aiSection.isHittable {
            mainWindow.scrollViews["settings-menu-scroll"].swipeUp()
        }
        aiSection.click()

        let enabledToggle = mainWindow.descendants(matching: .any)["ai-enabled-toggle"]
        XCTAssertTrue(enabledToggle.waitForExistence(timeout: 5))
        enabledToggle.click()
        XCTAssertFalse(mainWindow.buttons["AI 画像"].waitForExistence(timeout: 1))
        XCTAssertFalse(mainWindow.textFields["ai-base-url-field"].exists)
        XCTAssertFalse(mainWindow.descendants(matching: .any)["ai-instruction-editor"].exists)
    }

    func testAIConnectionFailureShowsDiagnosticDetails() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "--uitesting",
            "--uitesting-seed",
            "--uitesting-ai-connection-failure"
        ]
        app.launch()
        ensureMainWindow(in: app)
        let mainWindow = app.windows.firstMatch

        let settingsButton = mainWindow.descendants(matching: .any)["sidebar-settings-button"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 5))
        settingsButton.click()
        let aiSection = mainWindow.descendants(matching: .any)["settings-section-ai"]
        XCTAssertTrue(aiSection.waitForExistence(timeout: 5))
        if !aiSection.isHittable {
            mainWindow.scrollViews["settings-menu-scroll"].swipeUp()
        }
        aiSection.click()

        let testConnection = mainWindow.buttons["ai-test-connection-button"]
        XCTAssertTrue(testConnection.waitForExistence(timeout: 5))
        testConnection.click()
        let connectionStatus = mainWindow.descendants(matching: .any)[
            "ai-connection-status"
        ]
        XCTAssertTrue(connectionStatus.waitForExistence(timeout: 5))
        let statusValue = connectionStatus.value as? String ?? ""
        XCTAssertTrue(statusValue.contains("连接失败"), "实际连接状态：\(statusValue)")
        XCTAssertTrue(statusValue.contains("HTTP 503"), "实际连接状态：\(statusValue)")
        XCTAssertTrue(
            statusValue.contains("req_ui_test_failure"),
            "实际连接状态：\(statusValue)"
        )
    }

    func testAIProfileGenerationHistoryRegenerationDeletionAndClear() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--uitesting-seed"]
        app.launch()
        ensureMainWindow(in: app)
        let mainWindow = app.windows.firstMatch

        let card = mainWindow.descendants(matching: .any)["user-center-ai-profile-card"]
        XCTAssertTrue(card.waitForExistence(timeout: 8))
        let generate = mainWindow.buttons["user-center-ai-generate"]
        XCTAssertTrue(generate.waitForExistence(timeout: 5))
        generate.click()

        XCTAssertTrue(
            mainWindow.descendants(matching: .any)["ai-profile-generating"]
                .waitForExistence(timeout: 3)
        )
        XCTAssertTrue(
            mainWindow.descendants(matching: .any)["ai-profile-summary"]
                .waitForExistence(timeout: 8)
        )
        XCTAssertTrue(
            mainWindow.buttons["ai-profile-regenerate"].waitForExistence(timeout: 8)
        )

        let historyModule = mainWindow.buttons["AI 画像"]
        XCTAssertTrue(historyModule.waitForExistence(timeout: 5))
        historyModule.click()
        XCTAssertTrue(
            mainWindow.descendants(matching: .any)["ai-profile-history-list"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(
            mainWindow.buttons["ai-profile-history-10001"].waitForExistence(timeout: 5)
        )

        let regenerate = mainWindow.buttons["ai-profile-regenerate"]
        XCTAssertTrue(regenerate.waitForExistence(timeout: 5))
        regenerate.click()
        XCTAssertTrue(
            mainWindow.descendants(matching: .any)["ai-profile-generating"]
                .waitForExistence(timeout: 3)
        )
        XCTAssertTrue(regenerate.waitForExistence(timeout: 8))

        let delete = mainWindow.buttons["ai-profile-delete"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.click()
        let confirmDelete = app.sheets.buttons["删除画像"]
        XCTAssertTrue(confirmDelete.waitForExistence(timeout: 3))
        confirmDelete.click()
        XCTAssertTrue(app.staticTexts["还没有 AI 用户画像"].waitForExistence(timeout: 5))

        mainWindow.buttons["用户中心"].click()
        XCTAssertTrue(generate.waitForExistence(timeout: 5))
        generate.click()
        XCTAssertTrue(
            mainWindow.buttons["ai-profile-regenerate"].waitForExistence(timeout: 8)
        )
        historyModule.click()
        let clear = mainWindow.buttons["ai-profile-clear-all"]
        XCTAssertTrue(clear.waitForExistence(timeout: 5))
        clear.click()
        let confirmClear = app.sheets.buttons["清空全部画像"]
        XCTAssertTrue(confirmClear.waitForExistence(timeout: 3))
        confirmClear.click()
        XCTAssertTrue(app.staticTexts["还没有 AI 用户画像"].waitForExistence(timeout: 5))
    }

    func testReproShapes() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--uitesting-seed", "--uitesting-shapes"]
        app.launch()
        ensureMainWindow(in: app)
        let mainWindow = app.windows.firstMatch

        XCTAssertTrue(mainWindow.buttons["艾泽拉斯国家地理"].waitForExistence(timeout: 10))
        mainWindow.buttons["艾泽拉斯国家地理"].click()
        XCTAssertTrue(mainWindow.buttons["topic-9001"].waitForExistence(timeout: 10))
        mainWindow.buttons["topic-9001"].click()
        XCTAssertTrue(
            mainWindow.buttons["thread-scroll-to-top"].waitForExistence(timeout: 15)
        )
        Thread.sleep(forTimeInterval: 1.5)
        let scroll = mainWindow.scrollViews["thread-content-scroll"].firstMatch

        // 逐个点击楼层正文，比较点击前后这一段的可见文字与版面高度。
        let probes: [(text: String, index: Int)] = [
            ("为什么解散了一批还得再组织一批", 0),
            ("短的一行", 0),
            ("加粗开头", 0),
            ("这一行带表情", 0),
            ("这一段本身就很长", 0),
            ("最里面的被引用内容", 0),
            // G/H 里同一段长正文各出现一次：0 是 #48 的裸段落，1 是 #49 的引用块。
            ("甲A之后就全是职业队了", 0),
            ("甲A之后就全是职业队了", 1)
        ]
        for (probe, index) in probes {
            let element = mainWindow.staticTexts.matching(
                NSPredicate(format: "value CONTAINS %@", probe)
            ).element(boundBy: index)
            var scrolls = 0
            while !element.exists, scrolls < 8 {
                scroll.scroll(byDeltaX: 0, deltaY: -200)
                Thread.sleep(forTimeInterval: 0.8)
                scrolls += 1
            }
            guard element.exists else {
                print("SHAPE[\(probe)#\(index)] 未找到")
                continue
            }
            // 楼层要整个落在视口里，否则截图里分不清是被裁掉还是滚出去了。
            var settles = 0
            while element.frame.maxY > mainWindow.frame.maxY - 70, settles < 8 {
                scroll.scroll(byDeltaX: 0, deltaY: -120)
                Thread.sleep(forTimeInterval: 0.8)
                settles += 1
            }
            Thread.sleep(forTimeInterval: 0.6)
            let beforeFrame = element.frame
            dumpRepro(mainWindow, name: "shape-\(probe)-\(index)-before", extra: "\(beforeFrame)")
            element.click()
            Thread.sleep(forTimeInterval: 1.2)
            let afterFrame = element.frame
            let changed = abs(beforeFrame.height - afterFrame.height) > 0.5
                || abs(beforeFrame.width - afterFrame.width) > 0.5
            print("SHAPE[\(probe)#\(index)] before=\(beforeFrame) after=\(afterFrame) changed=\(changed)")
            dumpRepro(mainWindow, name: "shape-\(probe)-\(index)", extra: "\(beforeFrame) -> \(afterFrame)")
        }
    }

    private func dumpRepro(_ window: XCUIElement, name: String, extra: String) {
        let screenshot = window.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "repro-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
        print("REPRO[\(name)] \(extra)")
    }

    private func ensureMainWindow(in app: XCUIApplication) {
        guard !app.windows.firstMatch.waitForExistence(timeout: 2) else { return }
        let fileMenu = app.menuBars.menuBarItems["File"]
        XCTAssertTrue(fileMenu.waitForExistence(timeout: 2))
        fileMenu.click()
        let newWindow = app.menuItems["New Window"]
        XCTAssertTrue(newWindow.waitForExistence(timeout: 2))
        newWindow.click()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))
    }

    private func assertModule(
        _ expectedTitle: String,
        refreshIdentifier: String,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let title = app.descendants(matching: .any)["browser-module-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5), file: file, line: line)
        XCTAssertEqual(title.label, expectedTitle, file: file, line: line)
        XCTAssertEqual(title.elementType, .staticText, file: file, line: line)
        XCTAssertFalse(
            app.buttons["browser-module-title"].exists,
            file: file,
            line: line
        )
        let window = app.windows.firstMatch
        XCTAssertLessThan(
            title.frame.midY,
            window.frame.midY,
            file: file,
            line: line
        )
        assertRefreshIsInBottomBar(
            refreshIdentifier,
            in: app,
            file: file,
            line: line
        )
    }

    private func assertRefreshIsInBottomBar(
        _ identifier: String,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let refresh = app.buttons[identifier]
        XCTAssertTrue(refresh.waitForExistence(timeout: 5), file: file, line: line)
        XCTAssertGreaterThan(
            refresh.frame.midY,
            app.windows.firstMatch.frame.midY,
            file: file,
            line: line
        )
    }

    private func assertSearchControlsStayInOneRow(
        field: XCUIElement,
        kindPicker: XCUIElement,
        submitButton: XCUIElement,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(kindPicker.waitForExistence(timeout: 5), file: file, line: line)
        XCTAssertTrue(submitButton.waitForExistence(timeout: 5), file: file, line: line)
        XCTAssertEqual(
            field.frame.midY,
            kindPicker.frame.midY,
            accuracy: 2,
            file: file,
            line: line
        )
        XCTAssertEqual(
            field.frame.midY,
            submitButton.frame.midY,
            accuracy: 2,
            file: file,
            line: line
        )
        XCTAssertLessThan(
            submitButton.frame.width,
            60,
            file: file,
            line: line
        )
    }
}
