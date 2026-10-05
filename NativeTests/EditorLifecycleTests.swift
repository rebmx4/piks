import XCTest
import UIKit
import PiksCore
@testable import PiksNative

@MainActor
final class EditorLifecycleTests: XCTestCase {
    func testClosedEditorRejectsLateCommandsAndPickerCompletion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try ProjectRepository(root: root, owner: nil)
        let project = Project(name: "Closed project")
        try repo.save(project)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 160, height: 160)).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 160, height: 160))
        }
        let source = root.appendingPathComponent("late.png")
        try image.pngData()!.write(to: source)
        let store = EditorStore(project: project, repository: repo)
        store.close()
        store.edit(.rename("Unexpected mutation"))
        store.importFiles([source])
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(store.project.name, "Closed project")
        XCTAssertTrue(store.project.assets.isEmpty)
        XCTAssertNil(store.busy)
        XCTAssertNil(store.player.currentItem)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testLatePhotosCompletionCleansOnlyItsOwnedTemporaryCopy() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try ProjectRepository(root: root, owner: nil)
        let project = Project(name: "Closed picker")
        try repo.save(project)
        let source = root.appendingPathComponent("original.mov")
        try Data([42]).write(to: source)
        let staged = try ImportStaging.shared.copy(source)
        let store = EditorStore(project: project, repository: repo)
        XCTAssertTrue(store.beginPicking())
        store.close()
        store.finishPicking([staged], error: nil, lane: 0)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(store.project.assets.isEmpty)
        XCTAssertNil(store.busy)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }
}
