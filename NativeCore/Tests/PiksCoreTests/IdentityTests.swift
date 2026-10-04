import XCTest
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import PiksCore

private final class MemoryVault: SessionVault, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    func read() throws -> Data? { lock.lock(); defer { lock.unlock() }; return data }
    func write(_ value: Data?) throws { lock.lock(); defer { lock.unlock() }; data = value }
}

private actor IdentityTransport {
    var paths: [String] = []
    var refreshes = 0
    var failRefresh = false
    let user = UUID()
    func response(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        paths.append(request.url!.path)
        XCTAssertEqual(request.url!.scheme, "https")
        var status = 200
        var object: [String: Any]
        if request.url!.path.hasSuffix("refresh") {
            refreshes += 1
            try await Task.sleep(nanoseconds: 40_000_000)
            if failRefresh { status = 401; object = ["error": "Сессия истекла."] }
            else { object = session(expires: Date().timeIntervalSince1970 + 900) }
        } else if request.url!.path.hasSuffix("login") {
            object = session(expires: Date().timeIntervalSince1970 - 1)
        } else if request.url!.path.hasSuffix("capabilities") {
            object = ["apple": false, "google": false, "email": false]
        } else if request.url!.path.hasSuffix("delete") || request.url!.path.hasSuffix("logout") {
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer " + String(repeating: "a", count: 32))
            object = ["ok": true]
        } else { status = 404; object = ["error": "Нет адреса"] }
        return (try JSONSerialization.data(withJSONObject: object),
                HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
    func session(expires: Double) -> [String: Any] {
        ["user": ["id": user.uuidString, "email": "me@example.test"], "accessToken": String(repeating: "a", count: 32),
         "refreshToken": String(repeating: "r", count: 48), "expiresAt": expires]
    }
    func rejectRefresh() { failRefresh = true }
}

final class IdentityTests: XCTestCase {
    private func client(_ transport: IdentityTransport, vault: MemoryVault = MemoryVault()) throws -> IdentityClient {
        try IdentityClient(baseURL: URL(string: "https://example.test/piks-auth/")!, vault: vault,
                           transport: { try await transport.response($0) })
    }
    func testIdentityServiceRequiresHTTPSWithoutEmbeddedCredentials() throws {
        for url in ["http://example.test/", "https://user:pass@example.test/", "https://example.test/?token=secret"] {
            XCTAssertThrowsError(try IdentityClient(baseURL: URL(string: url)!, vault: MemoryVault()))
        }
    }
    func testCapabilitiesUseOnlyConfiguredIdentityPath() async throws {
        let t = IdentityTransport(), c = try client(t)
        let caps = try await c.capabilities()
        XCTAssertFalse(caps.email)
        let paths = await t.paths
        XCTAssertEqual(paths, ["/piks-auth/v1/capabilities"])
    }
    func testSessionRestoresFromVaultWithoutNetworkForOfflineCatalog() async throws {
        let t = IdentityTransport(), vault = MemoryVault(), c = try client(t, vault: vault)
        let loggedIn = try await c.login(email: "me@example.test", password: "example password")
        let restored = try client(t, vault: vault)
        let session = await restored.currentSession()
        XCTAssertEqual(session?.user.id, loggedIn.user.id)
        let paths = await t.paths
        XCTAssertEqual(paths.count, 1)
    }
    func testConcurrentRefreshUsesOneRotatingTokenRequest() async throws {
        let t = IdentityTransport(), c = try client(t)
        _ = try await c.login(email: "me@example.test", password: "example password")
        async let first = c.accessToken()
        async let second = c.accessToken()
        let values = try await [first, second]
        XCTAssertEqual(values[0], values[1])
        let count = await t.refreshes
        XCTAssertEqual(count, 1)
    }
    func testRejectedRefreshClearsKeychainSession() async throws {
        let t = IdentityTransport(), vault = MemoryVault(), c = try client(t, vault: vault)
        _ = try await c.login(email: "me@example.test", password: "example password")
        await t.rejectRefresh()
        do { _ = try await c.accessToken(); XCTFail("Refresh must be rejected") } catch {}
        let session = await c.currentSession()
        XCTAssertNil(session)
        XCTAssertNil(try vault.read())
    }
    func testDeletionUsesBearerAndClearsLocalSession() async throws {
        let t = IdentityTransport(), vault = MemoryVault(), c = try client(t, vault: vault)
        _ = try await c.login(email: "me@example.test", password: "example password")
        try await c.deleteAccount()
        let session = await c.currentSession()
        XCTAssertNil(session)
        XCTAssertNil(try vault.read())
        let paths = await t.paths
        XCTAssertEqual(paths.last, "/piks-auth/v1/account/delete")
    }
}
