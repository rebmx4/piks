import Foundation
import XCTest
@testable import PiksCore

final class EditingTests: XCTestCase {
    func fixture() -> Project {
        let asset = MediaAsset(kind: .video, originalName: "source.mov", duration: 12,
                               width: 3840, height: 2160, hasAudio: true)
        return Project(name: "4K project", assets: [asset], clips: [Clip(assetID: asset.id, sourceDuration: 12)])
    }

    func testSplitUsesOriginalSecondsAtDoubleSpeed() throws {
        var project = fixture()
        project.clips[0].speed = 2
        let originalID = project.clips[0].id
        var history = EditorHistory(project: project)
        try history.apply(.split(originalID, at: 2))
        XCTAssertEqual(history.project.clips.count, 2)
        XCTAssertEqual(history.project.clips[0].sourceDuration, 4)
        XCTAssertEqual(history.project.clips[1].sourceStart, 4)
        XCTAssertEqual(history.project.clips[1].sourceDuration, 8)
        XCTAssertEqual(history.project.duration, 6)
        XCTAssertNotEqual(history.project.clips[0].id, history.project.clips[1].id)
    }

    func testFailedMutationDoesNotEnterUndoHistory() throws {
        var history = EditorHistory(project: fixture())
        let before = history.project
        XCTAssertThrowsError(try history.apply(.trim(before.clips[0].id, from: 10, duration: 9)))
        XCTAssertEqual(history.project, before)
        XCTAssertFalse(history.canUndo)
    }

    func testSpeedRetimesFollowingMainClipsButNotOverlay() throws {
        var project = fixture()
        let id = project.clips[0].id
        project.clips.append(Clip(assetID: project.assets[0].id, at: 12, sourceDuration: 4))
        project.clips.append(Clip(assetID: project.assets[0].id, lane: 1, at: 5, sourceDuration: 3))
        var history = EditorHistory(project: project)
        try history.apply(.speed(id, 2))
        XCTAssertEqual(history.project.clips[1].at, 6)
        XCTAssertEqual(history.project.clips[2].at, 5)
    }

    func testUndoRedoRestoresEditAndAdvancesRevision() throws {
        var history = EditorHistory(project: fixture())
        let id = history.project.clips[0].id
        try history.apply(.trim(id, from: 2, duration: 6))
        let revision = history.project.revision
        history.undo()
        XCTAssertEqual(history.project.clips[0].sourceStart, 0)
        XCTAssertGreaterThan(history.project.revision, revision)
        history.redo()
        XCTAssertEqual(history.project.clips[0].sourceStart, 2)
        XCTAssertEqual(history.project.duration, 6)
    }

    func testGestureTransactionProducesOneUndoEntry() throws {
        var history = EditorHistory(project: fixture())
        let id = history.project.clips[0].id
        history.beginTransaction()
        try history.apply(.trim(id, from: 1, duration: 9))
        try history.apply(.trim(id, from: 2, duration: 7))
        history.endTransaction()
        history.undo()
        XCTAssertEqual(history.project.clips[0].sourceStart, 0)
        XCTAssertEqual(history.project.duration, 12)
        XCTAssertFalse(history.canUndo)
    }

    func testDeleteClosesMainGapAndKeepsOverlayPosition() throws {
        var project = fixture()
        project.clips.append(Clip(assetID: project.assets[0].id, at: 12, sourceDuration: 3))
        project.clips.append(Clip(assetID: project.assets[0].id, lane: 1, at: 4, sourceDuration: 2))
        var history = EditorHistory(project: project)
        try history.apply(.delete(project.clips[0].id))
        XCTAssertEqual(history.project.clips[0].at, 0)
        XCTAssertEqual(history.project.clips[1].at, 4)
    }

    func testRejectsNonfiniteSpeedAndOutOfRangeKeyframes() throws {
        let p = fixture()
        var history = EditorHistory(project: p)
        XCTAssertThrowsError(try history.apply(.speed(p.clips[0].id, .nan)))
        var invalid = p
        invalid.clips[0].keyframes = [TransformKeyframe(time: -1)]
        XCTAssertThrowsError(try invalid.validate())
    }

    func testSplitInterpolatesAndRebasesKeyframesWithoutJump() throws {
        var project = fixture()
        project.clips[0].keyframes = [TransformKeyframe(time: 0, x: 0), TransformKeyframe(time: 12, x: 1)]
        var history = EditorHistory(project: project)
        try history.apply(.split(project.clips[0].id, at: 4))
        XCTAssertEqual(history.project.clips[0].transform(at: 4).x, 1.0 / 3, accuracy: 0.0001)
        XCTAssertEqual(history.project.clips[1].transform(at: 0).x, 1.0 / 3, accuracy: 0.0001)
        XCTAssertEqual(history.project.clips[1].transform(at: 8).x, 1, accuracy: 0.0001)
    }

    func testVeryLargeProjectHistoryIsBounded() throws {
        var history = EditorHistory(project: fixture(), limit: 3)
        let id = history.project.clips[0].id
        for speed in [2.0, 3, 4, 5, 6] { try history.apply(.speed(id, speed)) }
        for _ in 0..<3 { history.undo() }
        XCTAssertFalse(history.canUndo)
        XCTAssertEqual(history.project.clips[0].speed, 3)
    }
}
