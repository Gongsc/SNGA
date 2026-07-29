import XCTest

@MainActor
final class SNGAUITests: XCTestCase {
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

        let favoriteForum = app.buttons["favorite-forum--7"]
        XCTAssertTrue(favoriteForum.waitForExistence(timeout: 5))
        favoriteForum.click()

        let refreshing = app.descendants(matching: .any)["topic-list-refreshing"]
        XCTAssertTrue(refreshing.waitForExistence(timeout: 2))
        let returnedToFirstPage = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "1"),
            object: pageField
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [returnedToFirstPage], timeout: 5),
            .completed
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["topic-list-top"]
                .waitForExistence(timeout: 5)
        )

        XCTAssertTrue(app.buttons["topic-9001"].waitForExistence(timeout: 5))
        app.buttons["topic-9001"].click()
        XCTAssertTrue(app.buttons["thread-scroll-to-top"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["分享主题"].waitForExistence(timeout: 5))
        app.buttons["分享主题"].click()

        let copyLink = app.buttons["copy-topic-link"]
        XCTAssertTrue(copyLink.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["open-topic-in-browser"].exists)
        copyLink.click()
        XCTAssertTrue(app.buttons["已复制"].waitForExistence(timeout: 5))
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

        let backButton = app.buttons["thread-linked-topic-back"]
        XCTAssertTrue(backButton.waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.staticTexts["主题二：多账号与收藏测试"]
                .waitForExistence(timeout: 5)
        )
        backButton.click()

        XCTAssertTrue(
            app.staticTexts["主题一：欢迎使用 SNGA"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertFalse(backButton.exists)
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

    func testToolboxNavigationShowsAllFeeds() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--uitesting-seed"]
        app.launch()
        ensureMainWindow(in: app)

        XCTAssertTrue(app.buttons["小工具"].waitForExistence(timeout: 5))
        app.buttons["小工具"].click()

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
}
