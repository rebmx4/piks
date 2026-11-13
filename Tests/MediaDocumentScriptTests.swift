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
        let frame = expectation(description: "iframe has no grant")
        let receiver = Receiver(), config = WKWebViewConfiguration()
        config.userContentController.add(receiver, name: "ryndi")
        config.userContentController.addUserScript(WKUserScript(source: MediaDocumentScript.source(token: access.bootstrapToken),
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
                XCTAssertEqual(body["canvas"] as? Bool, true, "the new CORS policy must keep canvas/WebGL input readable")
                loaded.fulfill()
            } else if body["cmd"] as? String == "frame" {
                XCTAssertEqual(body["src"] as? String, "ryndi-media://orig/blocked.png"); frame.fulfill()
            } else if body["cmd"] as? String == "failed" { XCTFail("scoped image did not load"); loaded.fulfill() }
        }
        web.loadSimulatedRequest(URLRequest(url: document), responseHTML: """
        <script>
        const image = new Image(); image.crossOrigin = 'anonymous';
        image.onload = () => {
          const canvas = document.createElement('canvas'); canvas.width = canvas.height = 1;
          let readable = false;
          try { const ctx = canvas.getContext('2d'); ctx.drawImage(image,0,0); ctx.getImageData(0,0,1,1); readable = true; } catch {}
          window.webkit.messageHandlers.ryndi.postMessage({cmd:'loaded', src:image.src, attribute:image.getAttribute('src'), canvas:readable});
        };
        image.onerror = () => window.webkit.messageHandlers.ryndi.postMessage({cmd:'failed'});
        image.src = 'ryndi-media://orig/image.png'; document.documentElement.appendChild(image);
        const frame = document.createElement('iframe');
        frame.src = 'ryndi-media://orig/blocked.png'; document.documentElement.appendChild(frame);
        // A blocked frame need not emit load. Observe the actual URL after the
        // DOM mutation checkpoint instead; an accidentally scoped URL fails.
        queueMicrotask(() => window.webkit.messageHandlers.ryndi.postMessage({cmd:'frame', src:frame.src}));
        </script>
        """)
        wait(for: [ready, loaded, frame], timeout: 20)
        XCTAssertEqual(resolutions, 1)
        let old = access.bootstrapToken
        access.revoke(); handler.cancelAll()
        XCTAssertFalse(access.bind(old, document: document, mainFrame: true))
        let rebound = expectation(description: "cached document rebinds"), reloaded = expectation(description: "image uses new grant")
        receiver.receive = { message in
            guard let body = message.body as? [String: Any] else { return }
            if body["cmd"] as? String == "document-ready" {
                XCTAssertTrue(access.bind(body["token"] as? String ?? "", document: message.frameInfo.request.url,
                    mainFrame: message.frameInfo.isMainFrame)); rebound.fulfill()
            } else if body["cmd"] as? String == "loaded" {
                XCTAssertEqual(body["canvas"] as? Bool, true); reloaded.fulfill()
            }
            else if body["cmd"] as? String == "failed" { XCTFail("rebound image did not load"); reloaded.fulfill() }
        }
        web.evaluateJavaScript("window.__apiksMediaDocument('\(access.bootstrapToken)');", completionHandler: nil)
        wait(for: [rebound, reloaded], timeout: 10)
        XCTAssertEqual(resolutions, 2)
        web.stopLoading(); config.userContentController.removeScriptMessageHandler(forName: "ryndi")
    }
}
