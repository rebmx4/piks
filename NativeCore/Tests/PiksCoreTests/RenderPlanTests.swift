import Foundation
import XCTest
@testable import PiksCore

final class RenderPlanTests: XCTestCase {
    func fixture() -> Project {
        let a = MediaAsset(kind: .video, originalName: "4k.mov", duration: 10, width: 3840, height: 2160, hasAudio: true)
        return Project(name: "4K", assets: [a], clips: [Clip(assetID: a.id, sourceDuration: 10)])
    }
    func testExportRetains4KButPreviewIsLimitedTo1080ShortEdge() throws {
        let p = fixture()
        let export = try RenderPlanBuilder.build(p, mode: .export)
        let preview = try RenderPlanBuilder.build(p, mode: .preview)
        XCTAssertEqual(export.width, 3840)
        XCTAssertEqual(export.height, 2160)
        XCTAssertEqual(preview.width, 1920)
        XCTAssertEqual(preview.height, 1080)
        XCTAssertEqual(export.frames, 300)
    }
    func testPlacementFitsPortraitIntoLandscapeAndSharesProxyGeometry() throws {
        var p = fixture()
        p.assets[0].width = 2160; p.assets[0].height = 3840
        let full = try RenderPlanBuilder.build(p, mode: .export)
        let small = try RenderPlanBuilder.build(p, mode: .preview)
        let f = full.layers[0][0].transforms[0], s = small.layers[0][0].transforms[0]
        XCTAssertEqual(f[0], 1215, accuracy: 0.01)
        XCTAssertEqual(f[3], 2160, accuracy: 0.01)
        XCTAssertEqual(f[4], 1312.5, accuracy: 0.01)
        XCTAssertEqual(f[0] / Double(full.width), s[0] / Double(small.width), accuracy: 0.0001)
    }
    func testAudioSpeedAndFadesUseTimelineNotSourceTime() throws {
        var p = fixture()
        p.clips[0].speed = 2; p.clips[0].volume = 1.5
        p.clips[0].fadeIn = 1; p.clips[0].fadeOut = 1
        let plan = try RenderPlanBuilder.build(p, mode: .export)
        XCTAssertEqual(plan.sounds[0].sourceDuration, 10)
        XCTAssertEqual(plan.sounds[0].duration, 5)
        XCTAssertEqual(plan.sounds[0].gains, [GainPoint(time: 0, gain: 0), GainPoint(time: 1, gain: 1.5),
                                           GainPoint(time: 4, gain: 1.5), GainPoint(time: 5, gain: 0)])
    }
    func testKeyframesAreEvaluatedAtOutputTimeAndRespectOpacity() throws {
        var p = fixture()
        p.clips[0].keyframes = [TransformKeyframe(time: 0, scale: 1), TransformKeyframe(time: 10, scale: 2, opacity: 0)]
        let plan = try RenderPlanBuilder.build(p, mode: .export)
        let middle = plan.layers[0][0].matrix(at: 5)
        XCTAssertEqual(middle[0], 5760, accuracy: 0.01)
        XCTAssertEqual(middle[6], 0.5, accuracy: 0.0001)
    }
    func testMutedVideoDoesNotCreateSoundAndAudioLaneNeverCreatesVisualItem() throws {
        var p = fixture()
        p.clips[0].muted = true
        let a = MediaAsset(kind: .audio, originalName: "music.wav", duration: 10, width: 0, height: 0, hasAudio: true)
        p.assets.append(a); p.clips.append(Clip(assetID: a.id, lane: -1, sourceDuration: 10))
        let plan = try RenderPlanBuilder.build(p, mode: .export)
        XCTAssertEqual(plan.sounds.count, 1)
        XCTAssertEqual(plan.layers.flatMap { $0 }.count, 1)
        XCTAssertEqual(plan.sounds[0].assetID, a.id)
    }
    func testConstantTransformDoesNotAllocatePerFrameTable() throws {
        var p = fixture()
        p.assets[0].duration = 3600; p.clips[0].sourceDuration = 3600
        let plan = try RenderPlanBuilder.build(p, mode: .export)
        XCTAssertEqual(plan.layers[0][0].transforms.count, 1)
        XCTAssertEqual(plan.frames, 108000)
    }

    func testHourLongAnimationDoesNotBakeEveryOutputFrame() throws {
        var p = fixture()
        p.assets[0].duration = 3600; p.clips[0].sourceDuration = 3600
        p.clips[0].keyframes = [TransformKeyframe(time: 0), TransformKeyframe(time: 3600, scale: 2, rotation: 90)]
        let plan = try RenderPlanBuilder.build(p, mode: .export)
        XCTAssertEqual(plan.layers[0][0].transforms.count, 1, "Keep animation parameters and evaluate the current frame on demand")
        XCTAssertEqual(plan.frames, 108000)
        let middle = plan.layers[0][0].matrix(at: 1800)
        XCTAssertEqual(middle[0], 3840 * 1.5 * cos(.pi / 4), accuracy: 0.01)
        XCTAssertEqual(middle[1], middle[0], accuracy: 0.01)
        XCTAssertEqual(plan.layers[0][0].matrix(at: 3600)[6], 1)
    }
}
