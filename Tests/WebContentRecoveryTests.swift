import Foundation
import XCTest

final class WebContentRecoveryTests: XCTestCase {
    func testOnlyOneAutomaticReloadInTheWindowEvenIfTheFirstReloadLoaded() {
        var recovery = WebContentRecovery()
        let url = URL(string: "https://rynpro.ru/ryn-next/?project=kept")!
        XCTAssertEqual(recovery.terminated(at: url, now: 100), .reload(url))
        recovery.loaded()
        XCTAssertEqual(recovery.terminated(at: url, now: 102), .showError)
        XCTAssertEqual(recovery.terminated(at: url, now: 161), .reload(url))
    }

    func testExplicitRetryIsAllowedAndForeignDocumentsNeverRegainPrivileges() {
        var recovery = WebContentRecovery()
        let url = URL(string: "https://rynpro.ru/ryn/")!
        XCTAssertEqual(recovery.retry(at: url), .reload(url))
        for invalid in [nil, URL(string: "https://rynpro.ru/other/"), URL(string: "https://example.org/ryn/")] {
            XCTAssertEqual(recovery.retry(at: invalid), .showError)
            XCTAssertEqual(recovery.terminated(at: invalid), .showError)
        }
    }
}
