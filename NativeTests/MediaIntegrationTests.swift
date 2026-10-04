import XCTest
import AVFoundation
import UIKit
import PiksCore
@testable import PiksNative

final class MediaIntegrationTests: XCTestCase {
    func movie(_ url: URL, width: Int, height: Int, color: UIColor) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
                                                                        AVVideoWidthKey: width, AVVideoHeightKey: height])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height])
        writer.add(input); XCTAssertTrue(writer.startWriting()); writer.startSession(atSourceTime: .zero)
        for i in 0..<12 {
            var pixel: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &pixel), kCVReturnSuccess)
            let buffer = try XCTUnwrap(pixel)
            CVPixelBufferLockBaseAddress(buffer, [])
            let context = try XCTUnwrap(CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
            context.setFillColor(color.cgColor); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            let deadline = Date().addingTimeInterval(10)
            while !input.isReadyForMoreMediaData && Date() < deadline { usleep(1000) }
            XCTAssertTrue(adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(i), timescale: 30)))
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0); writer.finishWriting { done.signal() }
        XCTAssertEqual(done.wait(timeout: .now() + 20), .success)
        XCTAssertEqual(writer.status, .completed)
    }

    func testCompositionResolvesOriginalAndPreservesExportDimensions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try ProjectRepository(root: root, owner: nil)
        let a = MediaAsset(kind: .video, originalName: "original.mov", duration: 0.4, width: 320, height: 180)
        let project = Project(name: "Original", assets: [a], clips: [Clip(assetID: a.id, sourceDuration: 0.3)])
        try repo.save(project)
        try movie(repo.assetURL(project: project.id, asset: a, mode: .original), width: 320, height: 180, color: .red)
        try movie(repo.assetURL(project: project.id, asset: a, mode: .proxy), width: 80, height: 48, color: .blue)
        let typed = try RenderPlanBuilder.build(project, mode: .export)
        let plan = try RenderAdapter.plan(typed)
        let files = try RenderAdapter.files(typed, repository: repo, usage: .export)
        XCTAssertTrue(files[a.id.uuidString]!.path.contains("originals"))
        let temps = TempFiles(); defer { temps.removeAll() }
        let assembly = try NativeExporter.assemble(plan, files, temps: temps)
        XCTAssertEqual(assembly.video.renderSize, CGSize(width: 320, height: 180))
        XCTAssertEqual(assembly.total.seconds, 0.3, accuracy: 0.001)
    }

    func testPhotoOnlyCompositionHasAClockAndRendersWithoutVideo() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try ProjectRepository(root: root, owner: nil)
        let a = MediaAsset(kind: .image, originalName: "photo.png", duration: 0, width: 160, height: 160)
        let p = Project(name: "Photo", assets: [a], clips: [Clip(assetID: a.id, sourceDuration: 2)])
        try repo.save(p)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 160, height: 160)).image { c in
            UIColor.green.setFill(); c.fill(CGRect(x: 0, y: 0, width: 160, height: 160))
        }
        try image.pngData()!.write(to: repo.assetURL(project: p.id, asset: a, mode: .original))
        let typed = try RenderPlanBuilder.build(p, mode: .export)
        let temps = TempFiles(); defer { temps.removeAll() }
        let assembled = try NativeExporter.assemble(RenderAdapter.plan(typed), RenderAdapter.files(typed, repository: repo, usage: .export), temps: temps)
        XCTAssertFalse(assembled.comp.tracks(withMediaType: .video).isEmpty)
        XCTAssertEqual(assembled.total.seconds, 2, accuracy: 0.001)
    }
}
