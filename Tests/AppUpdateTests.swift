import XCTest
import Foundation

final class AppUpdateTests: XCTestCase {
    func testOnlyNumericallyNewerPublicVersionProducesNotice() throws {
        let cases: [(String, String, String?)] = [
            ("1.0.1", "1.0.1", nil), ("1.0", "1.0.0", nil),
            ("1.0.1", "1.0.2", nil), ("1.0.2", "1.0.1", "1.0.2"),
            ("1.0.10", "1.0.9", "1.0.10"), ("2.0", "1.9.9", "2.0"),
        ]
        for (published, installed, expected) in cases {
            let actual = AppUpdate.available(in: try UpdateFixture.data(version: published),
                installedVersion: installed, systemVersion: "17.0")
            XCTAssertEqual(actual?.version, expected, "public \(published), installed \(installed)")
        }
    }

    func testInvalidUnrelatedOrIncompatibleStoreResultsAreIgnored() throws {
        let invalid: [Data] = [
            try UpdateFixture.data(bundle: "com.other.app"), try UpdateFixture.data(appID: 42),
            try UpdateFixture.data(minimumOS: "99.0"), try UpdateFixture.data(version: "newest"),
            Data("{\"resultCount\":0,\"results\":[]}".utf8), Data("not JSON".utf8),
        ]
        for data in invalid {
            XCTAssertNil(AppUpdate.available(in: data, installedVersion: "1.0.1", systemVersion: "17.0"))
        }
        XCTAssertNil(AppUpdate.available(in: try UpdateFixture.data(),
            installedVersion: "", systemVersion: "17.0"))
    }

    @MainActor
    func testCheckerRequestsThePublicAPIKSListingForTheRegion() async throws {
        let data = try UpdateFixture.data()
        let session = UpdateTestProtocol.session { _ in (200, data) }
        defer { session.invalidateAndCancel() }
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let checker = AppUpdateChecker(installedVersion: "1.0.1", systemVersion: "17.0",
            region: "RU", session: session, defaults: defaults)
        let notice = await checker.check()
        XCTAssertEqual(notice?.version, "1.0.2")
        let request = try XCTUnwrap(UpdateTestProtocol.requests.first)
        let url = try XCTUnwrap(request.url)
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "itunes.apple.com")
        XCTAssertEqual(url.path, "/lookup")
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(query.first { $0.name == "id" }?.value, "6794464999")
        XCTAssertEqual(query.first { $0.name == "country" }?.value, "ru")
    }

    @MainActor
    func testDismissalIsRememberedForThatVersionButNotALaterUpdate() async throws {
        let firstData = try UpdateFixture.data()
        let session = UpdateTestProtocol.session { _ in (200, firstData) }
        defer { session.invalidateAndCancel() }
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let first = AppUpdateChecker(installedVersion: "1.0.1", systemVersion: "17.0",
            region: "ru", session: session, defaults: defaults)
        let candidate = await first.check()
        first.dismiss(try XCTUnwrap(candidate))
        let reopened = AppUpdateChecker(installedVersion: "1.0.1", systemVersion: "17.0",
            region: "ru", session: session, defaults: defaults)
        let dismissed = await reopened.check()
        XCTAssertNil(dismissed)
        let laterData = try UpdateFixture.data(version: "1.0.3")
        let laterSession = UpdateTestProtocol.session { _ in (200, laterData) }
        defer { laterSession.invalidateAndCancel() }
        let later = AppUpdateChecker(installedVersion: "1.0.1", systemVersion: "17.0",
            region: "ru", session: laterSession, defaults: defaults)
        let next = await later.check()
        XCTAssertEqual(next?.version, "1.0.3")
    }

    @MainActor
    func testCachedNoticeSurvivesForegroundWithoutRepeatedRequests() async throws {
        let data = try UpdateFixture.data()
        let session = UpdateTestProtocol.session { _ in (200, data) }
        defer { session.invalidateAndCancel() }
        var now = Date(timeIntervalSince1970: 1_000_000)
        let checker = AppUpdateChecker(installedVersion: "1.0.1", systemVersion: "17.0",
            region: "ru", session: session, defaults: UserDefaults(suiteName: UUID().uuidString)!, now: { now })
        let first = await checker.check(), again = await checker.check()
        XCTAssertEqual(first?.version, "1.0.2")
        XCTAssertEqual(again?.version, "1.0.2")
        XCTAssertEqual(UpdateTestProtocol.requests.count, 1)
        now = now.addingTimeInterval(901)
        let refreshed = await checker.check()
        XCTAssertEqual(refreshed?.version, "1.0.2")
        XCTAssertEqual(UpdateTestProtocol.requests.count, 2)
    }

    @MainActor
    func testNetworkFailureCanRecoverOnAFollowingForegroundCheck() async throws {
        let session = UpdateTestProtocol.session { _ in throw URLError(.notConnectedToInternet) }
        defer { session.invalidateAndCancel() }
        var now = Date(timeIntervalSince1970: 1_000_000)
        let checker = AppUpdateChecker(installedVersion: "1.0.1", systemVersion: "17.0",
            region: "ru", session: session, defaults: UserDefaults(suiteName: UUID().uuidString)!, now: { now })
        let offline = await checker.check()
        XCTAssertNil(offline)
        let data = try UpdateFixture.data()
        let helper = UpdateTestProtocol.session { _ in (200, data) }
        defer { helper.invalidateAndCancel() }
        now = now.addingTimeInterval(61)
        let online = await checker.check()
        XCTAssertEqual(online?.version, "1.0.2")
    }

    @MainActor
    func testHTTPFailureNeverTreatsTheResponseBodyAsAnUpdate() async throws {
        let data = try UpdateFixture.data()
        let session = UpdateTestProtocol.session { _ in (503, data) }
        defer { session.invalidateAndCancel() }
        let checker = AppUpdateChecker(installedVersion: "1.0.1", systemVersion: "17.0",
            region: "ru", session: session, defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let notice = await checker.check()
        XCTAssertNil(notice)
    }
}
