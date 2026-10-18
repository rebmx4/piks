import XCTest

final class AppUpdateUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    private func launch(_ scenario: String, reset: Bool = true) {
        app.launchArguments = ["--wrapper-input", "minimal", "--app-update", scenario]
        if reset { app.launchArguments.append("--reset-update-dismissal") }
        app.launch()
        XCTAssertTrue(app.staticTexts["Tools:0"].waitForExistence(timeout: 15))
    }

    func testNewPublicVersionShowsBannerAndUpdateTargetsAPIKSInStore() {
        launch("newer")
        XCTAssertTrue(app.buttons["app-update-open"].waitForExistence(timeout: 5),
                      "A newer public version must show the native update banner")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "APIKS update notice"
        shot.lifetime = .keepAlways
        add(shot)
        app.buttons["app-update-open"].tap()
        XCTAssertTrue(app.staticTexts["https://apps.apple.com/app/id6794464999"].waitForExistence(timeout: 5))
    }

    func testDismissalHidesNoticeAndSurvivesRelaunchWithoutBlockingEditor() {
        launch("newer")
        XCTAssertTrue(app.buttons["app-update-dismiss"].waitForExistence(timeout: 5))
        app.buttons["app-update-dismiss"].tap()
        XCTAssertTrue(app.buttons["app-update-open"].waitForNonExistence(timeout: 3))
        app.buttons["Cut"].tap()
        XCTAssertTrue(app.staticTexts["Tools:1"].waitForExistence(timeout: 5))
        app.terminate()
        launch("newer", reset: false)
        XCTAssertTrue(app.staticTexts["update-check-complete"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["app-update-open"].exists)
    }

    func testSameVersionAndNetworkFailureLeaveEditorWithoutNotice() {
        for scenario in ["same", "offline"] {
            launch(scenario)
            XCTAssertTrue(app.staticTexts["update-check-complete"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["app-update-open"].exists)
            app.buttons["Cut"].tap()
            XCTAssertTrue(app.staticTexts["Tools:1"].waitForExistence(timeout: 5))
            app.terminate()
        }
    }

    func testReturnToForegroundChecksForAPublishedUpdate() {
        launch("foreground")
        XCTAssertTrue(app.staticTexts["update-check-complete"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["app-update-open"].exists)
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.buttons["app-update-open"].waitForExistence(timeout: 5),
                      "Returning to the app must check for a newer public version")
    }
}
