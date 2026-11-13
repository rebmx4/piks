import Foundation
import AVFoundation
import XCTest

final class NativeSourceProbeTests: XCTestCase {
    func testReadsActualFramesAndReportsTheActualSourceCodec() throws {
        let file = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "export-red", withExtension: "mp4", subdirectory: "Fixtures"))
        let result = NativeSourceProbe.decode(file)
        XCTAssertEqual(result["decoded"] as? Bool, true)
        XCTAssertEqual(result["frames"] as? Int, 3)
        XCTAssertTrue((result["codec"] as? String ?? "").hasPrefix("avc1."))
        XCTAssertGreaterThan(result["width"] as? Int ?? 0, 0)
        XCTAssertNil(result["code"])
    }

    func testFailureDoesNotExposeAFilePathOrClaimCompatibility() {
        let result = NativeSourceProbe.decode(URL(fileURLWithPath: "/private-does-not-exist/user-video.mp4"))
        XCTAssertEqual(result["decoded"] as? Bool, false)
        XCTAssertEqual(result["frames"] as? Int, 0)
        XCTAssertNotNil(result["code"])
        XCTAssertFalse(String(describing: result).contains("user-video"))
    }
}
