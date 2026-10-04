import XCTest
import UIKit
import CoreImage
import PiksCore
@testable import PiksNative

final class NativeRenderingTests: XCTestCase {
    func testOnDemandKeyframesReachNativeCompositor() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try ProjectRepository(root: root, owner: nil)
        let a = MediaAsset(kind: .image, originalName: "red.png", duration: 0, width: 160, height: 160)
        var clip = Clip(assetID: a.id, sourceDuration: 2)
        clip.keyframes = [TransformKeyframe(time: 0, x: -0.25, scale: 0.25),
                          TransformKeyframe(time: 2, x: 0.25, scale: 0.25)]
        let p = Project(name: "Motion", assets: [a], clips: [clip])
        try repo.save(p)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 160, height: 160)).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 160, height: 160))
        }
        try XCTUnwrap(image.pngData()).write(to: repo.assetURL(project: p.id, asset: a, mode: .original))
        let typed = try RenderPlanBuilder.build(p, mode: .export)
        let temps = TempFiles(); defer { temps.removeAll() }
        let assembly = try NativeExporter.assemble(RenderAdapter.plan(typed), RenderAdapter.files(typed, repository: repo, usage: .export), temps: temps)
        let scene = try XCTUnwrap(assembly.video.instructions.first as? RyndiInstruction).scene
        let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        func red(_ x: Int, at time: Double) -> UInt8 {
            var pixel = [UInt8](repeating: 0, count: 4)
            let frame = scene.compose(at: time, frame: { _ in nil })
            context.render(frame, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: x, y: 80, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
            return pixel[0]
        }
        XCTAssertGreaterThan(red(40, at: 0), 180)
        XCTAssertLessThan(red(110, at: 0), 20)
        XCTAssertGreaterThan(red(110, at: 1.75), 180)
        XCTAssertLessThan(red(40, at: 1.75), 20)
    }
}
