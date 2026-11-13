import Foundation
import XCTest

final class MediaDocumentAccessTests: XCTestCase {
    let document = URL(string: "https://rynpro.ru/ryn-next/")!
    let token = String(repeating: "a", count: 32)

    private func request(_ host: String = "orig", token: String) -> URL {
        URL(string: "ryndi-media://\(host)/source.mp4?__apiks_doc=\(token)")!
    }

    func testGrantIsRequiredAndRevokedAcrossDocuments() {
        let access = MediaDocumentAccess(), url = request(token: token)
        XCTAssertFalse(access.allows(url, method: "GET", origin: nil, document: document))
        XCTAssertTrue(access.bind(token, document: document, mainFrame: true))
        XCTAssertTrue(access.allows(url, method: "GET", origin: nil, document: document))
        XCTAssertTrue(access.allows(url, method: "HEAD", origin: "https://rynpro.ru", document: document))
        access.revoke()
        XCTAssertFalse(access.allows(url, method: "GET", origin: nil, document: document))
        let next = String(repeating: "b", count: 32)
        XCTAssertTrue(access.bind(next, document: document, mainFrame: true))
        XCTAssertFalse(access.allows(url, method: "GET", origin: nil, document: document))
        XCTAssertTrue(access.allows(request(token: next), method: "GET", origin: nil, document: document))
    }

    func testUnknownHostsDirectReadsAndOtherOriginsAreDenied() {
        let access = MediaDocumentAccess()
        XCTAssertFalse(access.bind(token, document: document, mainFrame: false))
        XCTAssertFalse(access.bind(token, document: URL(string: "https://rynpro.ru/other/"), mainFrame: true))
        XCTAssertTrue(access.bind(token, document: document, mainFrame: true))
        for value in ["ryndi-media://orig/source.mp4", request("unexpected", token: token).absoluteString,
                      "ryndi-media://orig/dir/source.mp4?__apiks_doc=\(token)",
                      "ryndi-media://orig/source.mp4?__apiks_doc=\(token)&__apiks_doc=\(token)"] {
            XCTAssertFalse(access.allows(URL(string: value), method: "GET", origin: nil, document: document), value)
        }
        XCTAssertFalse(access.allows(request(token: token), method: "POST", origin: nil, document: document))
        XCTAssertFalse(access.allows(request(token: token), method: "GET", origin: "https://evil.example", document: document))
        XCTAssertFalse(access.allows(request(token: token), method: "GET", origin: "null", document: document))
        XCTAssertFalse(access.allows(request(token: token), method: "GET", origin: nil,
            document: URL(string: "https://rynpro.ru/ryn/")))
    }
}
