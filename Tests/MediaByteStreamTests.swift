import Foundation
import XCTest

final class MediaByteStreamTests: XCTestCase {
    private func file(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try data.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testFullFileLargerThanTwoChunksAndSuffixAreExact() throws {
        let data = Data((0..<(9 * 1024 * 1024 + 7)).map { UInt8($0 % 251) })
        let url = try file(data)
        for range in [nil, "bytes=-1031"] as [String?] {
            let done = expectation(description: "all bytes delivered")
            var chunks: [Data] = []
            let response = MediaHTTPResponse.make(method: "GET", range: range, total: Int64(data.count))
            let stream = MediaByteStream(file: url, response: response, receive: { chunks.append($0) },
                finish: { done.fulfill() }, fail: { XCTFail("\($0)"); done.fulfill() })
            stream.start(); wait(for: [done], timeout: 5)
            XCTAssertEqual(chunks.reduce(Data(), +), range == nil ? data : Data(data.suffix(1031)))
            XCTAssertTrue(chunks.allSatisfy { $0.count <= MediaByteStream.chunkLimit })
        }
    }

    func testCancelBetweenChunksStopsDeliveryAndFinish() throws {
        let url = try file(Data(repeating: 8, count: MediaByteStream.chunkLimit * 3))
        let first = expectation(description: "first chunk"), unexpected = expectation(description: "late callback")
        unexpected.isInverted = true
        let response = MediaHTTPResponse.make(method: "GET", range: nil, total: Int64(MediaByteStream.chunkLimit * 3))
        var stream: MediaByteStream!
        var received = 0
        stream = MediaByteStream(file: url, response: response, receive: { _ in
            received += 1
            if received == 1 { stream.cancel(); first.fulfill() } else { unexpected.fulfill() }
        }, finish: { unexpected.fulfill() }, fail: { _ in unexpected.fulfill() })
        stream.start(); wait(for: [first, unexpected], timeout: 0.3)
        XCTAssertEqual(received, 1)
        stream = nil
    }

    func testCancelBeforeStartDoesNotOpenOrRespond() {
        let unexpected = expectation(description: "callback after cancellation"); unexpected.isInverted = true
        let stream = MediaByteStream(file: URL(fileURLWithPath: "/does-not-exist"),
            response: .make(method: "GET", range: nil, total: 10), receive: { _ in unexpected.fulfill() },
            finish: { unexpected.fulfill() }, fail: { _ in unexpected.fulfill() })
        stream.cancel(); stream.start(); wait(for: [unexpected], timeout: 0.1)
    }

    func testHeadDoesNotOpenFileAndEarlyEofFails() throws {
        let head = expectation(description: "HEAD finishes without a file")
        let noFile = MediaByteStream(file: URL(fileURLWithPath: "/does-not-exist"),
            response: .make(method: "HEAD", range: nil, total: 90), receive: { _ in XCTFail("HEAD body") },
            finish: { head.fulfill() }, fail: { XCTFail("\($0)"); head.fulfill() })
        noFile.start(); wait(for: [head], timeout: 2)
        let eof = expectation(description: "truncated file is an error")
        let stream = MediaByteStream(file: try file(Data([1, 2, 3])),
            response: .make(method: "GET", range: nil, total: 90), receive: { _ in },
            finish: { XCTFail("a short body must not succeed"); eof.fulfill() }, fail: { _ in eof.fulfill() })
        stream.start(); wait(for: [eof], timeout: 2)
    }

    func testNextChunkIsNotReadBeforeTheConsumerReturns() throws {
        let size = MediaByteStream.chunkLimit
        let url = try file(Data(repeating: 1, count: size * 2))
        let done = expectation(description: "backpressure")
        var n = 0
        let stream = MediaByteStream(file: url, response: .make(method: "GET", range: nil, total: Int64(size * 2)),
            receive: { data in
                n += 1
                if n == 1 {
                    do {
                        let writer = try FileHandle(forWritingTo: url)
                        try writer.seek(toOffset: UInt64(size))
                        try writer.write(contentsOf: Data(repeating: 9, count: size)); try writer.close()
                    } catch { XCTFail("\(error)") }
                } else { XCTAssertEqual(data, Data(repeating: 9, count: size)) }
            }, finish: { done.fulfill() }, fail: { XCTFail("\($0)"); done.fulfill() })
        stream.start(); wait(for: [done], timeout: 3)
        XCTAssertEqual(n, 2)
    }
}
