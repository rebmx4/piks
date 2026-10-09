import XCTest

final class WrapperInputModeTests: XCTestCase {
    func testAppStoreIgnoresSavedComparisonMode() {
        let suite = "wrapper-input-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("minimal", forKey: WrapperInputMode.preferenceKey)
        XCTAssertEqual(WrapperInputMode.load(defaults: defaults, comparisonAvailable: false), .standard)
    }

    func testTestFlightRestoresTheChosenOrdinaryMode() {
        let suite = "wrapper-input-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("standard", forKey: WrapperInputMode.preferenceKey)
        XCTAssertEqual(WrapperInputMode.load(defaults: defaults, comparisonAvailable: true), .standard)
    }

    func testNewOrInvalidComparisonPreferenceUsesMinimalMode() {
        let suite = "wrapper-input-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(WrapperInputMode.load(defaults: defaults, comparisonAvailable: true), .minimal)
        defaults.set("obsolete-value", forKey: WrapperInputMode.preferenceKey)
        XCTAssertEqual(WrapperInputMode.load(defaults: defaults, comparisonAvailable: true), .minimal)
    }
}
