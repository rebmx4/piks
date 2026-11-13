import XCTest
import Foundation

final class MediaHTTPResponseTests: XCTestCase {
    func testSuffixExplicitAndOpenRanges() {
        for (range, offset, count) in [("bytes=-3", 7, 3), ("bytes=2-4", 2, 3),
                                       ("bytes=7-", 7, 3), ("bytes=7-90", 7, 3),
                                       ("bytes=-90", 0, 10)] {
            let response = MediaHTTPResponse.make(method: "GET", range: range, total: 10)
            XCTAssertEqual(response.status, 206, range)
            XCTAssertEqual(response.offset, Int64(offset), range)
            XCTAssertEqual(response.length, Int64(count), range)
            XCTAssertEqual(response.headers["Content-Range"], "bytes \(offset)-\(offset + count - 1)/10", range)
        }
    }

    func testUnsatisfiableAndMalformedRangesHaveNoBody() {
        for range in ["bytes=10-", "bytes=20-", "bytes=-0", "bytes=8-2",
                      "bytes=9223372036854775808-", "bytes=-", "bytes=a-3"] {
            let response = MediaHTTPResponse.make(method: "GET", range: range, total: 10)
            XCTAssertEqual(response.status, 416, range)
            XCTAssertEqual(response.headers["Content-Range"], "bytes */10", range)
            XCTAssertFalse(response.sendBody, range)
        }
    }

    func testFullGetIsNotTruncatedAndHeadNeverReadsABody() {
        let size: Int64 = 9 * 1024 * 1024 + 7
        let full = MediaHTTPResponse.make(method: "GET", range: nil, total: size)
        XCTAssertEqual(full.status, 200)
        XCTAssertEqual(full.length, size)
        XCTAssertEqual(full.headers["Content-Length"], String(size))
        let head = MediaHTTPResponse.make(method: "HEAD", range: "bytes=3-5", total: size)
        XCTAssertEqual(head.status, 200)
        XCTAssertEqual(head.headers["Content-Length"], String(size))
        XCTAssertFalse(head.sendBody)
    }

    func testEmptyFilesUnsupportedMethodsAndMultipleRanges() {
        let empty = MediaHTTPResponse.make(method: "GET", range: nil, total: 0)
        XCTAssertEqual(empty.status, 200)
        XCTAssertEqual(empty.length, 0)
        XCTAssertFalse(empty.sendBody)
        let range = MediaHTTPResponse.make(method: "GET", range: "bytes=0-", total: 0)
        XCTAssertEqual(range.status, 416)
        XCTAssertEqual(MediaHTTPResponse.make(method: "POST", range: nil, total: 10).status, 405)
        // Unsupported units/multiple ranges are ignored, per RFC 9110, section 14.2.
        for value in ["bytes=0-2,5-7", "items=0-3"] {
            let response = MediaHTTPResponse.make(method: "GET", range: value, total: 10)
            XCTAssertEqual(response.status, 200)
            XCTAssertEqual(response.length, 10)
        }
    }
}
