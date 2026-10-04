import XCTest
import AuthenticationServices
import PiksCore
@testable import PiksNative

@MainActor
final class AccountTests: XCTestCase {
    func testGoogleAuthorizationBindsNonceStateAndRFC7636PKCEChallenge() throws {
        let client = "123-example.apps.googleusercontent.com"
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        let url = try GoogleOAuth.authorizationURL(clientID: client, nonce: "challenge-nonce", state: "unique-state", verifier: verifier)
        let query = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
        XCTAssertEqual(query["code_challenge"], "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        XCTAssertEqual(query["nonce"], "challenge-nonce")
        XCTAssertEqual(query["state"], "unique-state")
        XCTAssertEqual(query["scope"], "openid email")
        let redirect = "com.googleusercontent.apps.123-example:/oauth2redirect"
        XCTAssertEqual(try GoogleOAuth.code(callback: URL(string: redirect + "?state=unique-state&code=good")!, clientID: client, state: "unique-state"), "good")
        for callback in [redirect + "?state=wrong&code=good", redirect + "?state=unique-state&code=good&code=bad",
                         "evil:/oauth2redirect?state=unique-state&code=good", redirect + "?state=unique-state&error=access_denied"] {
            XCTAssertThrowsError(try GoogleOAuth.code(callback: URL(string: callback)!, clientID: client, state: "unique-state"))
        }
    }
    func testCancelledAppleLoginLeavesAccountUsableAndShowsNoError() async {
        let store = AccountStore()
        store.error = nil
        await store.receiveApple(.failure(NSError(domain: ASAuthorizationError.errorDomain, code: ASAuthorizationError.Code.canceled.rawValue)))
        XCTAssertFalse(store.busy)
        XCTAssertNil(store.error)
    }
    func testOwnerChangeCannotExposePreviousAccountCatalog() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = UUID(), second = UUID()
        let one = try ProjectRepository(root: root, owner: first), two = try ProjectRepository(root: root, owner: second)
        try one.save(Project(name: "First owner")); try two.save(Project(name: "Second owner"))
        let library = LibraryStore(owner: first, root: root)
        library.selectOwner(second)
        XCTAssertTrue(library.projects.isEmpty)
        let deadline = Date().addingTimeInterval(3)
        while library.loading && Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(library.projects.map(\.name), ["Second owner"])
        try await library.deleteAccountProjects(second)
        XCTAssertTrue(try two.catalog().isEmpty)
        XCTAssertEqual(try one.catalog().map(\.name), ["First owner"])
    }
}
