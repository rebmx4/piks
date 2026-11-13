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
}
