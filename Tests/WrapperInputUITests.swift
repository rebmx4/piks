import XCTest

final class WrapperInputUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--wrapper-input", "minimal"]
        app.launch()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Tools:0"].waitForExistence(timeout: 10))
    }

    func testToolTapsAndFollowingHorizontalSwipesReachThePage() {
        let web = app.webViews.firstMatch
        let start = web.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.3))
        let end = web.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.3))
        for index in 0..<9 {
            app.buttons[["Cut", "Select", "Keyframe"][index % 3]].tap()
            start.press(forDuration: 0.01, thenDragTo: end)
        }
        XCTAssertTrue(app.staticTexts["Tools:9"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Swipes:9"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Cancels:0"].exists)
    }

    func testNestedListStillScrollsWithRootScrollingDisabled() {
        let web = app.webViews.firstMatch
        let start = web.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
        let end = web.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
        start.press(forDuration: 0.01, thenDragTo: end)
        let moved = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Scroll:' AND label != 'Scroll:0'")).firstMatch
        XCTAssertTrue(moved.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Swipes:0"].exists)
    }

    func testOrdinaryModeRemainsAvailableForComparison() {
        app.terminate()
        app.launchArguments = ["--wrapper-input", "standard"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Mode:standard"].waitForExistence(timeout: 15))
        app.buttons["Cut"].tap()
        XCTAssertTrue(app.staticTexts["Tools:1"].waitForExistence(timeout: 5))
    }
}
