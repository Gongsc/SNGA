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
        XCTAssertTrue(app.buttons["message-7001"].waitForExistence(timeout: 5))
        app.buttons["message-7001"].click()
        XCTAssertTrue(app.staticTexts["测试消息"].waitForExistence(timeout: 5))
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
        XCTAssertEqual(pageField.value as? String, "2")

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
