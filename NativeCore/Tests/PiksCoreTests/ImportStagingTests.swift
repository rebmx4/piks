import Foundation
import XCTest
@testable import PiksCore

final class ImportStagingTests: XCTestCase {
    func testPickedFileKeepsNameAndCleanupPreservesExternalSource() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("My holiday.mov")
        try Data([1, 2, 3]).write(to: source)
        let staging = ImportStaging(root: root.appendingPathComponent("staged"))
        let copy = try staging.copy(source)
        XCTAssertEqual(copy.lastPathComponent, source.lastPathComponent)
        XCTAssertEqual(try Data(contentsOf: copy), Data([1, 2, 3]))
        staging.remove([copy, source])
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }
    func testRepeatedFilenamesAreStagedSeparatelyAndCleanupIsIdempotent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("video.mov")
        try Data([42]).write(to: source)
        let staging = ImportStaging(root: root.appendingPathComponent("staged"))
        let one = try staging.copy(source), two = try staging.copy(source)
        XCTAssertNotEqual(one, two)
        staging.remove([one]); XCTAssertTrue(FileManager.default.fileExists(atPath: two.path))
        staging.remove([one, two]); staging.remove([two])
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("staged").path).isEmpty)
    }
    func testSymbolicLinksCannotBecomeOwnedExternalFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let external = root.appendingPathComponent("external.mov"), link = root.appendingPathComponent("link.mov")
        try Data([7]).write(to: external)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: external)
        let staging = ImportStaging(root: root.appendingPathComponent("staged"))
        XCTAssertThrowsError(try staging.copy(link))
        staging.remove([external, link])
        XCTAssertTrue(FileManager.default.fileExists(atPath: external.path))
    }
}
