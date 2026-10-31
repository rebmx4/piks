import XCTest

final class MediaRequestTests: XCTestCase {
    func testCoalescesOneFileAndCancelsOnlyTheLastConsumer() {
        let requests = MediaRequests<String>()
        var starts = 0, stops = 0, results: [String?] = []
        let start: MediaRequests<String>.Start = { _, _ in starts += 1; return { stops += 1 } }
        let cancelA = requests.request("file", timeout: 1, start: start) { results.append($0) }
        let cancelB = requests.request("file", timeout: 1, start: start) { results.append($0) }
        XCTAssertEqual(starts, 1)
        cancelA()
        XCTAssertEqual(stops, 0)
        XCTAssertEqual(results.count, 1)
        cancelB()
        XCTAssertEqual(stops, 1)
        XCTAssertEqual(results.count, 2)
    }

    func testTimeoutFinishesOnceAndLateFileDoesNotFinishRetry() {
        let requests = MediaRequests<String>()
        let timedOut = expectation(description: "the missing response ends")
        var oldReply: ((String?) -> Void)?, results: [String?] = [], stops = 0
        _ = requests.request("file", timeout: 0.02, start: { _, finish in
            oldReply = finish
            return { stops += 1 }
        }) { results.append($0); timedOut.fulfill() }
        wait(for: [timedOut], timeout: 1)
        XCTAssertEqual(stops, 1)
        XCTAssertEqual(results.count, 1)
        XCTAssertNil(results[0])
        var nextReply: ((String?) -> Void)?
        _ = requests.request("file", timeout: 1, start: { _, finish in nextReply = finish; return {} }) {
            results.append($0)
        }
        oldReply?("stale")
        XCTAssertEqual(results.count, 1)
        nextReply?("current")
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[1], "current")
    }

    func testProgressAndSynchronousCompletionDoNotLeakDeadlineOrCancellation() {
        let requests = MediaRequests<String>()
        var progress: [Double] = [], results: [String?] = [], stops = 0
        let cancel = requests.request("file", timeout: 0.01, progress: { progress.append($0) },
                                      start: { report, finish in
            report(0.5); finish("ready"); return { stops += 1 }
        }) { results.append($0) }
        cancel()
        XCTAssertEqual(progress, [0.5])
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0], "ready")
        XCTAssertEqual(stops, 0)
    }
}
