import XCTest

@MainActor
final class SNGAUITests: XCTestCase {
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

    func testAboutWindowShowsProjectLinks() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--uitesting-seed"]
        app.launch()
        ensureMainWindow(in: app)

        let appMenu = app.menuBars.menuBarItems["SNGA"]
        appMenu.click()
        let about = appMenu.menus.menuItems["关于 SNGA"]
        XCTAssertTrue(about.waitForExistence(timeout: 2))
        about.click()

        XCTAssertTrue(app.windows["关于 SNGA"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["版本 1.6.1（1）"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["about-github"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["about-email"].exists)
        XCTAssertTrue(app.links["gongsc@live.cn"].exists)
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
        XCTAssertTrue(app.buttons["回复主题"].waitForExistence(timeout: 5))

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

        let sortOrder = app.descendants(matching: .any)["topic-list-sort-order"]
        XCTAssertTrue(sortOrder.waitForExistence(timeout: 5))
        sortOrder.click()
        let latestTopic = app.menuItems["最新话题"]
        XCTAssertTrue(latestTopic.waitForExistence(timeout: 5))
        latestTopic.click()

        let skeleton = app.descendants(matching: .any)["topic-list-skeleton"]
        XCTAssertTrue(skeleton.waitForExistence(timeout: 2))
        let returnedToFirstPage = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "1"),
            object: pageField
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [returnedToFirstPage], timeout: 5),
            .completed
        )
        XCTAssertTrue(skeleton.waitForNonExistence(timeout: 5))
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

        XCTAssertTrue(app.buttons["分享主题"].waitForExistence(timeout: 5))
        app.buttons["分享主题"].click()

        let copyLink = app.buttons["copy-topic-link"]
        XCTAssertTrue(copyLink.waitForExistence(timeout: 5))
        let openInBrowser = app.buttons["open-topic-in-browser"]
        XCTAssertTrue(openInBrowser.exists)
        copyLink.click()
        XCTAssertTrue(app.buttons["已复制"].waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(
            openInBrowser.frame.minX - copyLink.frame.maxX,
            10
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

        let internalLink = app.links["打开站内关联主题"]
        XCTAssertTrue(internalLink.waitForExistence(timeout: 5))
        internalLink.click()

        let skeleton = app.descendants(matching: .any)["thread-content-skeleton"]
        XCTAssertTrue(skeleton.waitForExistence(timeout: 2))
        let backButton = app.buttons["thread-linked-topic-back"]
        XCTAssertTrue(backButton.waitForExistence(timeout: 5))
        XCTAssertTrue(skeleton.waitForNonExistence(timeout: 5))
        let topicTitle = app.staticTexts["thread-topic-title"]
        XCTAssertTrue(topicTitle.waitForExistence(timeout: 5))
        XCTAssertEqual(topicTitle.label, "主题二：多账号与收藏测试")
        XCTAssertFalse(app.scrollViews.staticTexts["thread-topic-title"].exists)
        backButton.click()

        XCTAssertTrue(backButton.waitForNonExistence(timeout: 5))
        XCTAssertTrue(skeleton.waitForNonExistence(timeout: 5))
        let restoredTitle = app.staticTexts["thread-topic-title"]
        XCTAssertTrue(restoredTitle.waitForExistence(timeout: 5))
        XCTAssertEqual(restoredTitle.label, "主题一：欢迎使用 SNGA")
        XCTAssertFalse(app.scrollViews.staticTexts["thread-topic-title"].exists)
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

    func testToolboxInstanceSettingsShowCustomURLAndDocumentation() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--uitesting-seed"]
        app.launch()
        ensureMainWindow(in: app)

        app.typeKey(",", modifierFlags: .command)

        let instancePicker = app.descendants(matching: .any)["toolbox-instance-picker"]
        XCTAssertTrue(instancePicker.waitForExistence(timeout: 5))
        instancePicker.click()
        let customInstance = app.menuItems["自定义实例"]
        XCTAssertTrue(customInstance.waitForExistence(timeout: 5))
        customInstance.click()

        XCTAssertTrue(
            app.textFields["toolbox-custom-instance-field"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["toolbox-instance-documentation"]
                .waitForExistence(timeout: 5)
        )

        instancePicker.click()
        let automaticInstance = app.menuItems["自动选择（推荐）"]
        XCTAssertTrue(automaticInstance.waitForExistence(timeout: 5))
        automaticInstance.click()
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
