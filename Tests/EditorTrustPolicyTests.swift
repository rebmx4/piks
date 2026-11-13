import XCTest
import Foundation

final class EditorTrustPolicyTests: XCTestCase {
    func testOnlyMainFrameEditorDocumentsAreAllowed() {
        for value in ["https://rynpro.ru/ryn", "https://rynpro.ru/ryn/",
                      "https://rynpro.ru:443/ryn-next/?project=1#edit",
                      "https://rynpro.ru/ryn-next/index.html"] {
            XCTAssertTrue(EditorTrustPolicy.allows(URL(string: value), mainFrame: true), value)
            XCTAssertFalse(EditorTrustPolicy.allows(URL(string: value), mainFrame: false), value)
        }
        for value in ["http://rynpro.ru/ryn/", "https://sub.rynpro.ru/ryn/",
                      "https://example.org/ryn/", "https://rynpro.ru:444/ryn/",
                      "https://rynpro.ru/other/", "https://rynpro.ru/ryn-next-evil/",
                      "file:///ryn/", "https://rynpro.ru/ryn/../other/",
                      "https://rynpro.ru/ryn/%2e%2e/other/",
                      "https://rynpro.ru/ryn/%2f..%2fother/",
                      "https://user:password@rynpro.ru/ryn/"] {
            XCTAssertFalse(EditorTrustPolicy.allows(URL(string: value), mainFrame: true), value)
        }
        XCTAssertFalse(EditorTrustPolicy.allows(nil, mainFrame: true))
    }

    func testCaptureRequiresTheSameSecurityOriginAndMainFrame() {
        let url = URL(string: "https://rynpro.ru/ryn-next/")
        XCTAssertTrue(EditorTrustPolicy.allowsCapture(url, mainFrame: true,
            originScheme: "https", originHost: "rynpro.ru", originPort: 443))
        for (scheme, host, port, main) in [("http", "rynpro.ru", 0, true),
            ("https", "example.org", 443, true), ("https", "rynpro.ru", 444, true),
            ("https", "rynpro.ru", 443, false)] {
            XCTAssertFalse(EditorTrustPolicy.allowsCapture(url, mainFrame: main,
                originScheme: scheme, originHost: host, originPort: port))
        }
        XCTAssertEqual(EditorTrustPolicy.site(url, mainFrame: true), .test)
        XCTAssertEqual(EditorTrustPolicy.site(URL(string: "https://rynpro.ru/ryn/"), mainFrame: true), .stable)
    }
}
