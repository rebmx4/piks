import Foundation
import WebKit
import XCTest

final class MediaDocumentScriptTests: XCTestCase {
    private final class Receiver: NSObject, WKScriptMessageHandler {
        var receive: ((WKScriptMessage) -> Void)?
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) { receive?(message) }
    }

    func testRealWebKitScopesLegacyImageURLsWithoutChangingTheURLSeenByTheEditor() {
        let document = URL(string: "https://rynpro.ru/ryn-next/")!, access = MediaDocumentAccess()
        let ready = expectation(description: "bootstrap grant"), loaded = expectation(description: "scoped image")
        let receiver = Receiver(), config = WKWebViewConfiguration()
        config.userContentController.add(receiver, name: "ryndi")
        config.userContentController.addUserScript(WKUserScript(source: MediaDocumentScript.source,
            injectionTime: .atDocumentStart, forMainFrameOnly: true))
        var resolutions = 0
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+j8N8AAAAASUVORK5CYII=")!
        let handler = MediaSchemeHandler(access: access, document: { document }, resolve: { url, done in
            XCTAssertNotNil(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "__apiks_doc" })
            resolutions += 1; done(.data(png, "image/png")); return {}
        })
        config.setURLSchemeHandler(handler, forURLScheme: "ryndi-media")
        let web = WKWebView(frame: .zero, configuration: config)
        receiver.receive = { message in
            guard let body = message.body as? [String: Any] else { return }
            if body["cmd"] as? String == "document-ready" {
                XCTAssertTrue(EditorTrustPolicy.allows(message.frameInfo.request.url, mainFrame: message.frameInfo.isMainFrame))
                XCTAssertTrue(access.bind(body["token"] as? String ?? "", document: message.frameInfo.request.url,
                    mainFrame: message.frameInfo.isMainFrame)); ready.fulfill()
            } else if body["cmd"] as? String == "loaded" {
                XCTAssertEqual(body["src"] as? String, "ryndi-media://orig/image.png")
                XCTAssertEqual(body["attribute"] as? String, "ryndi-media://orig/image.png")
                loaded.fulfill()
            } else if body["cmd"] as? String == "failed" { XCTFail("scoped image did not load"); loaded.fulfill() }
        }
        web.loadHTMLString("""
        <script>
        const image = new Image();
        image.onload = () => window.webkit.messageHandlers.ryndi.postMessage({cmd:'loaded', src:image.src, attribute:image.getAttribute('src')});
        image.onerror = () => window.webkit.messageHandlers.ryndi.postMessage({cmd:'failed'});
        image.src = 'ryndi-media://orig/image.png'; document.documentElement.appendChild(image);
        </script>
        """, baseURL: document)
        wait(for: [ready, loaded], timeout: 20)
        XCTAssertEqual(resolutions, 1)
        web.stopLoading(); config.userContentController.removeScriptMessageHandler(forName: "ryndi")
    }
}
