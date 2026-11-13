import Foundation
import WebKit
import XCTest

final class MediaSchemeHandlerTests: XCTestCase {
    private final class Task: NSObject, WKURLSchemeTask {
        let request: URLRequest
        var response: HTTPURLResponse?
        var body = Data()
        var receive: (() -> Void)?
        var complete: (() -> Void)?
        var error: Error?
        init(_ request: URLRequest) { self.request = request }
        func didReceive(_ response: URLResponse) { self.response = response as? HTTPURLResponse }
        func didReceive(_ data: Data) { body.append(data); receive?() }
        func didFinish() { complete?() }
        func didFailWithError(_ error: Error) { self.error = error; complete?() }
    }
    private let document = URL(string: "https://rynpro.ru/ryn-next/")!
    private let token = String(repeating: "a", count: 32)

    private func request(range: String? = nil, method: String = "GET", granted: Bool = true) -> Task {
        var request = URLRequest(url: URL(string: "ryndi-media://orig/input.mp4" + (granted ? "?__apiks_doc=\(token)" : ""))!)
        request.httpMethod = method
        if let range = range { request.setValue(range, forHTTPHeaderField: "Range") }
        return Task(request)
    }

    func testRealHandlerSendsFullFileSuffixHeadAnd416() throws {
        let bytes = Data(repeating: 7, count: 9 * 1024 * 1024 + 13)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        try bytes.write(to: url); defer { try? FileManager.default.removeItem(at: url) }
        let access = MediaDocumentAccess(token: token); access.bind(token, document: document, mainFrame: true)
        let handler = MediaSchemeHandler(access: access, document: { self.document }, resolve: { _, done in
            done(.file(url, "video/mp4")); return {}
        })
        let web = WKWebView()
        for (range, method, status, size) in [(nil, "GET", 200, bytes.count),
            ("bytes=-17", "GET", 206, 17), (nil, "HEAD", 200, 0), ("bytes=999999999-", "GET", 416, 0)] as [(String?, String, Int, Int)] {
            let task = request(range: range, method: method), done = expectation(description: method + (range ?? "full"))
            task.complete = { done.fulfill() }; handler.webView(web, start: task)
            wait(for: [done], timeout: 5)
            XCTAssertNil(task.error); XCTAssertEqual(task.response?.statusCode, status)
            XCTAssertEqual(task.body.count, size)
            XCTAssertEqual(task.body, Data(bytes.prefix(size)))
            XCTAssertEqual(task.response?.value(forHTTPHeaderField: "Access-Control-Allow-Origin"), "https://rynpro.ru")
        }
    }

    func testUngrantedTaskAndCancelledResolverCannotReadFiles() {
        let access = MediaDocumentAccess(token: token); access.bind(token, document: document, mainFrame: true)
        var resolutions = 0, cancelled = 0
        var reply: ((MediaSchemeResource?) -> Void)?
        let handler = MediaSchemeHandler(access: access, document: { self.document }, resolve: { _, done in
            resolutions += 1; reply = done; return { cancelled += 1 }
        })
        let web = WKWebView(), denied = request(granted: false)
        handler.webView(web, start: denied)
        XCTAssertEqual(denied.response?.statusCode, 403); XCTAssertEqual(resolutions, 0)
        let task = request(), late = expectation(description: "no callbacks after stop"); late.isInverted = true
        task.complete = { late.fulfill() }; task.receive = { late.fulfill() }
        handler.webView(web, start: task); handler.webView(web, stop: task)
        reply?(.data(Data([1, 2, 3]), "video/mp4"))
        wait(for: [late], timeout: 0.1)
        XCTAssertNil(task.response); XCTAssertEqual(cancelled, 1)
    }

    func testResolverConcurrencyIsBoundedAndPendingTasksAreCancelled() {
        let access = MediaDocumentAccess(token: token); access.bind(token, document: document, mainFrame: true)
        var started = 0, cancelled = 0
        let handler = MediaSchemeHandler(access: access, document: { self.document }, resolve: { _, _ in
            started += 1; return { cancelled += 1 }
        })
        let web = WKWebView(), tasks = (0..<25).map { _ in request() }
        for task in tasks { handler.webView(web, start: task) }
        XCTAssertEqual(started, 8)
        access.revoke(); handler.cancelAll()
        XCTAssertEqual(cancelled, 8)
        XCTAssertTrue(tasks.allSatisfy { $0.response == nil && $0.body.isEmpty })
    }
}
