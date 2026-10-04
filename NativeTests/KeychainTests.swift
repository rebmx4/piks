import XCTest
@testable import PiksNative

final class KeychainTests: XCTestCase {
    func testSessionPersistsOnlyInItsOwnKeychainServiceAndCanBeDeleted() throws {
        let id = "com.piks.app.native.tests." + UUID().uuidString
        let first = KeychainVault(service: id), other = KeychainVault(service: id + ".other")
        defer { try? first.write(nil); try? other.write(nil) }
        let secret = Data("temporary-session".utf8)
        try first.write(secret)
        XCTAssertEqual(try KeychainVault(service: id).read(), secret)
        XCTAssertNil(try other.read())
        try first.write(Data("rotated-session".utf8))
        XCTAssertEqual(try first.read(), Data("rotated-session".utf8))
        try first.write(nil)
        XCTAssertNil(try first.read())
    }
}
