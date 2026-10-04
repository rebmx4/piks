import Foundation
import XCTest
@testable import PiksCore

final class StorageTests: XCTestCase {
    var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    func testSaveAndReopenKeepsOriginalMetadataAndSeparateOwner() throws {
        let owner = UUID()
        let one = try ProjectRepository(root: root, owner: owner)
        let asset = MediaAsset(kind: .video, originalName: "4K.mov", duration: 10, width: 3840, height: 2160)
        let p = Project(name: "Фильм", assets: [asset], clips: [Clip(assetID: asset.id, sourceDuration: 10)])
        try one.save(p)
        XCTAssertEqual(try one.load(p.id), p)
        XCTAssertEqual(try one.catalog().count, 1)
        let another = try ProjectRepository(root: root, owner: UUID())
        XCTAssertEqual(try another.catalog().count, 0)
        XCTAssertThrowsError(try another.load(p.id))
    }

    func testCorruptMainManifestRecoversPreviousValidSave() throws {
        let repo = try ProjectRepository(root: root, owner: nil)
        var p = Project(name: "Before")
        try repo.save(p)
        p.name = "After"
        p.revision += 1
        try repo.save(p)
        try Data("interrupted".utf8).write(to: repo.projectURL(p.id).appendingPathComponent("project.json"))
        XCTAssertEqual(try repo.load(p.id).name, "Before")
        XCTAssertEqual(try repo.catalog().count, 1)
    }

    func testInvalidSavePreservesLastValidProject() throws {
        let repo = try ProjectRepository(root: root, owner: nil)
        var p = Project(name: "Valid")
        try repo.save(p)
        p.width = -2
        XCTAssertThrowsError(try repo.save(p))
        XCTAssertEqual(try repo.load(p.id).name, "Valid")
    }

    func testPreviewPrefersProxyExportRequiresOriginal() throws {
        let repo = try ProjectRepository(root: root, owner: nil)
        let p = Project(name: "Assets")
        try repo.save(p)
        let asset = MediaAsset(kind: .video, originalName: "clip.mov", duration: 4, width: 3840, height: 2160)
        let original = try repo.assetURL(project: p.id, asset: asset, mode: .original)
        let proxy = try repo.assetURL(project: p.id, asset: asset, mode: .proxy)
        try Data([1]).write(to: original)
        XCTAssertEqual(try repo.resolve(project: p.id, asset: asset, usage: .preview), original)
        try Data([2]).write(to: proxy)
        XCTAssertEqual(try repo.resolve(project: p.id, asset: asset, usage: .preview), proxy)
        XCTAssertEqual(try repo.resolve(project: p.id, asset: asset, usage: .export), original)
        try FileManager.default.removeItem(at: original)
        XCTAssertThrowsError(try repo.resolve(project: p.id, asset: asset, usage: .export))
        XCTAssertEqual(try repo.resolve(project: p.id, asset: asset, usage: .preview), proxy)
    }

    func testSourceFilenameCannotEscapeProjectDirectory() throws {
        let repo = try ProjectRepository(root: root, owner: nil)
        let p = Project(name: "Safe")
        try repo.save(p)
        let asset = MediaAsset(kind: .video, originalName: "../../outside.mov", duration: 1, width: 10, height: 10)
        let url = try repo.assetURL(project: p.id, asset: asset, mode: .original)
        XCTAssertTrue(url.path.hasPrefix(repo.projectURL(p.id).path + "/"))
        XCTAssertEqual(url.lastPathComponent, asset.id.uuidString + ".mov")
    }

    func testStaleRevisionCannotOverwriteNewerSave() throws {
        let repo = try ProjectRepository(root: root, owner: nil)
        var p = Project(name: "Newest")
        p.revision = 10
        try repo.save(p)
        p.name = "Stale"
        p.revision = 9
        XCTAssertThrowsError(try repo.save(p))
        XCTAssertEqual(try repo.load(p.id).name, "Newest")
    }
}
