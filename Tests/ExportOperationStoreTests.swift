import Foundation
import XCTest

final class ExportOperationStoreTests: XCTestCase {
    func testNativeAndWebSaveRequestsShareOneOperationAndCannotDuplicatePhotosAfterReload() throws {
        let store = ExportOperationStore(), token = "same-export"
        let file = URL(fileURLWithPath: "/tmp/owned-result.mp4")
        XCTAssertTrue(store.beginExport(token)); XCTAssertFalse(store.beginExport(token))
        XCTAssertEqual(store.status(token)?.phase, .exporting)
        store.fileReady(token, file: file)
        XCTAssertEqual(store.status(token)?.phase, .fileReady)
        var writes = 0, completed = 0
        var commit: ExportOperationStore.Completion?
        let writer: ExportOperationStore.Writer = { _, done in writes += 1; commit = done }
        store.save(token, file: file, write: writer) { ok, _ in XCTAssertTrue(ok); completed += 1 }
        XCTAssertEqual(store.status(token)?.phase, .saving)
        let request = try XCTUnwrap(ExportPhotoRequest(["token": token, "id": "uexport_" + token]))
        store.save(request, resolve: { _ in XCTFail("already committing"); return nil }, write: writer) { ok, _ in
            XCTAssertTrue(ok); completed += 1
        }
        store.failed(token, reason: "page cancelled", cancelled: true)
        XCTAssertEqual(store.status(token)?.phase, .saving, "PhotoKit commit is not cancelled by losing the page")
        commit?(true, nil)
        XCTAssertEqual(store.status(token)?.phase, .saved); XCTAssertEqual(completed, 2)
        store.save(token, file: file, write: writer) { ok, _ in XCTAssertTrue(ok); completed += 1 }
        commit?(true, nil)
        XCTAssertEqual(writes, 1); XCTAssertEqual(completed, 3)
    }

    func testFailedCommitCanRetryAndStatusDoesNotExposeTheFilePath() {
        let store = ExportOperationStore(), file = URL(fileURLWithPath: "/tmp/private/export.mp4")
        var writes = 0
        let writer: ExportOperationStore.Writer = { _, done in writes += 1; done(writes > 1, writes == 1 ? "permission" : nil) }
        store.save("retry", file: file, write: writer) { ok, _ in XCTAssertFalse(ok) }
        XCTAssertEqual(store.status("retry")?.phase, .failed)
        store.save("retry", file: file, write: writer) { ok, _ in XCTAssertTrue(ok) }
        XCTAssertEqual(store.status("retry")?.phase, .saved)
        XCTAssertFalse(String(describing: store.status("retry")!.payload).contains("/tmp/"))
        XCTAssertFalse(store.beginExport("../invalid"))
    }

    func testLateCallbackOfFailedAttemptCannotCompleteTheRetry() {
        let store = ExportOperationStore(), file = URL(fileURLWithPath: "/tmp/result.mp4")
        var first: ExportOperationStore.Completion?, second: ExportOperationStore.Completion?
        var completed = 0
        store.save("retry-race", file: file, write: { _, done in first = done }) { ok, _ in XCTAssertFalse(ok) }
        first?(false, "retry")
        store.save("retry-race", file: file, write: { _, done in second = done }) { ok, _ in XCTAssertTrue(ok); completed += 1 }
        first?(true, nil)
        XCTAssertEqual(store.status("retry-race")?.phase, .saving); XCTAssertEqual(completed, 0)
        second?(true, nil)
        XCTAssertEqual(completed, 1); XCTAssertEqual(store.status("retry-race")?.phase, .saved)
    }
}
