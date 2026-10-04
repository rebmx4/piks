import XCTest
import AVFoundation
import UIKit
import PiksCore
@testable import PiksNative

final class MediaIntegrationTests: XCTestCase {
    @MainActor
    func export(_ project: Project, repository: ProjectRepository) async throws -> URL {
        let typed = try RenderPlanBuilder.build(project, mode: .export)
        let files = try RenderAdapter.files(typed, repository: repository, usage: .export)
        let finished = expectation(description: "Native file export")
        var result: URL?
        var failure: String?
        let job = NativeExporter(job: UUID().uuidString, plan: try RenderAdapter.plan(typed, codec: "h264"),
            send: { event in
                if event["event"] as? String == "export-error" { failure = event["reason"] as? String }
            }, resolve: { id, done in done(files[id]) })
        job.onFinish = { url in result = url; finished.fulfill() }
        job.start()
        await fulfillment(of: [finished], timeout: 120)
        withExtendedLifetime(job) {}
        XCTAssertNil(failure, failure ?? "")
        return try XCTUnwrap(result, failure ?? "Exporter did not produce a file")
    }

    func pixel(_ url: URL, at seconds: Double) throws -> [UInt8] {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let frame = try generator.copyCGImage(at: CMTime(seconds: seconds, preferredTimescale: 30), actualTime: nil)
        var bytes = [UInt8](repeating: 0, count: 4)
        try bytes.withUnsafeMutableBytes { raw in
            let context = try XCTUnwrap(CGContext(data: raw.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(frame, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return bytes
    }

    func photo(_ url: URL, color: UIColor) throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 160, height: 160)).image { c in
            color.setFill(); c.fill(CGRect(x: 0, y: 0, width: 160, height: 160))
        }
        try XCTUnwrap(image.pngData()).write(to: url)
    }

    func movie(_ url: URL, width: Int, height: Int, color: UIColor) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
                                                                        AVVideoWidthKey: width, AVVideoHeightKey: height])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height])
        writer.add(input); XCTAssertTrue(writer.startWriting()); writer.startSession(atSourceTime: .zero)
        var pixel: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &pixel), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixel)
        CVPixelBufferLockBaseAddress(buffer, [])
        let context = try XCTUnwrap(CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
        context.setFillColor(color.cgColor); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        let done = DispatchSemaphore(value: 0)
        var frame = 0
        var finishing = false
        input.requestMediaDataWhenReady(on: DispatchQueue(label: "piks.tests.movie-writer")) {
            while input.isReadyForMoreMediaData && !finishing {
                if frame == 12 || writer.status != .writing {
                    finishing = true; input.markAsFinished()
                    writer.finishWriting { done.signal() }; return
                }
                guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)) else {
                    finishing = true; writer.cancelWriting(); done.signal(); return
                }
                frame += 1
            }
        }
        let completed = done.wait(timeout: .now() + 120)
        if completed != .success { writer.cancelWriting() }
        XCTAssertEqual(completed, .success)
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

    func testActual4KFileUsesOriginalPixelsInsteadOfBlueProxy() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try ProjectRepository(root: root, owner: nil)
        let a = MediaAsset(kind: .video, originalName: "4k.mov", duration: 0.4, width: 3840, height: 2160)
        let p = Project(name: "4K", assets: [a], clips: [Clip(assetID: a.id, sourceDuration: 0.3)])
        try repo.save(p)
        try movie(repo.assetURL(project: p.id, asset: a, mode: .original), width: 3840, height: 2160, color: .red)
        try movie(repo.assetURL(project: p.id, asset: a, mode: .proxy), width: 160, height: 90, color: .blue)
        let result = try await export(p, repository: repo)
        defer { try? FileManager.default.removeItem(at: result) }
        let track = try XCTUnwrap(AVURLAsset(url: result).tracks(withMediaType: .video).first)
        XCTAssertEqual(track.naturalSize, CGSize(width: 3840, height: 2160))
        let rgb = try pixel(result, at: 0.1)
        XCTAssertGreaterThan(rgb[0], 180)
        XCTAssertLessThan(rgb[2], 80)
    }

    func testActualPhotoFileContainsStillNearItsEnd() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try ProjectRepository(root: root, owner: nil)
        let a = MediaAsset(kind: .image, originalName: "photo.png", duration: 0, width: 160, height: 160)
        let p = Project(name: "Still", assets: [a], clips: [Clip(assetID: a.id, sourceDuration: 2)])
        try repo.save(p); try photo(repo.assetURL(project: p.id, asset: a, mode: .original), color: .green)
        let result = try await export(p, repository: repo)
        defer { try? FileManager.default.removeItem(at: result) }
        XCTAssertEqual(AVURLAsset(url: result).duration.seconds, 2, accuracy: 0.04)
        let rgb = try pixel(result, at: 1.5)
        XCTAssertGreaterThan(rgb[1], 180)
        XCTAssertLessThan(rgb[0], 80)
    }

    func testDeliberateTimelineGapExportsBlackInsteadOfPreviousStill() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try ProjectRepository(root: root, owner: nil)
        let red = MediaAsset(kind: .image, originalName: "red.png", duration: 0, width: 160, height: 160)
        let green = MediaAsset(kind: .image, originalName: "green.png", duration: 0, width: 160, height: 160)
        let p = Project(name: "Gap", assets: [red, green], clips: [
            Clip(assetID: red.id, sourceDuration: 0.3), Clip(assetID: green.id, at: 1, sourceDuration: 0.3)])
        try repo.save(p)
        try photo(repo.assetURL(project: p.id, asset: red, mode: .original), color: .red)
        try photo(repo.assetURL(project: p.id, asset: green, mode: .original), color: .green)
        let result = try await export(p, repository: repo)
        defer { try? FileManager.default.removeItem(at: result) }
        let rgb = try pixel(result, at: 0.6)
        XCTAssertLessThan(Int(rgb[0]) + Int(rgb[1]) + Int(rgb[2]), 40)
    }

    @MainActor
    func testCancelledExportCompletesOnceWithoutAFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try ProjectRepository(root: root, owner: nil)
        let a = MediaAsset(kind: .image, originalName: "photo.png", duration: 0, width: 160, height: 160)
        let p = Project(name: "Cancel", assets: [a], clips: [Clip(assetID: a.id, sourceDuration: 2)])
        try repo.save(p); try photo(repo.assetURL(project: p.id, asset: a, mode: .original), color: .green)
        let typed = try RenderPlanBuilder.build(p, mode: .export)
        let files = try RenderAdapter.files(typed, repository: repo, usage: .export)
        let finished = expectation(description: "Cancellation")
        finished.assertForOverFulfill = true
        var events: [String] = []
        let job = NativeExporter(job: UUID().uuidString, plan: try RenderAdapter.plan(typed),
            send: { event in if let name = event["event"] as? String { events.append(name) } },
            resolve: { id, done in done(files[id]) })
        job.onFinish = { url in XCTAssertNil(url); finished.fulfill() }
        job.start(); job.cancel()
        await fulfillment(of: [finished], timeout: 10)
        withExtendedLifetime(job) {}
        XCTAssertEqual(events.filter { $0 == "export-cancelled" }.count, 1)
        XCTAssertFalse(events.contains("export-done"))
        XCTAssertFalse(events.contains("export-error"))
    }
}
