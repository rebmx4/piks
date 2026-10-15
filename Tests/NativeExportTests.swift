import XCTest
import AVFoundation
import CoreVideo
import CoreImage

final class NativeExportTests: XCTestCase {
    private func scene(_ ranges: [(Double, Double)] = [(0, 2)],
                       presentation: ExportPresentation? = nil) -> RenderScene {
        let items = ranges.map { at, end in
            RenderScene.Item(trackID: 7, still: nil, at: at, end: end, k0: Int(at * 25),
                frames: [[4, 0, 0, 4, 0, 0, 1]], pref: .identity, fx: nil, crop: nil, mask: [], ci: [])
        }
        return RenderScene(size: CGSize(width: 4, height: 4), fps: 25, layers: [items],
                           overlays: [], grade: nil, luts: [], presentation: presentation)
    }

    private func pixelBuffer(red: UInt8) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 4, 4, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &buffer), kCVReturnSuccess)
        let out = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(out, [])
        defer { CVPixelBufferUnlockBaseAddress(out, []) }
        let bytes = try XCTUnwrap(CVPixelBufferGetBaseAddress(out)).assumingMemoryBound(to: UInt8.self)
        let row = CVPixelBufferGetBytesPerRow(out)
        for y in 0..<4 { for x in 0..<4 {
            let at = y * row + x * 4
            bytes[at] = 0; bytes[at + 1] = 0; bytes[at + 2] = red; bytes[at + 3] = 255
        } }
        return out
    }

    private func red(_ image: CIImage) -> UInt8 {
        var pixel = [UInt8](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes { bytes in
            CIContext(options: [.cacheIntermediates: false]).render(image,
                toBitmap: bytes.baseAddress!, rowBytes: 4,
                bounds: CGRect(x: 2, y: 2, width: 1, height: 1), format: .RGBA8,
                colorSpace: CGColorSpaceCreateDeviceRGB())
        }
        return pixel[0]
    }

    func testMissingActiveVideoFrameIsAnError() throws {
        XCTAssertThrowsError(try scene().compose(at: 0.2) { _ in nil },
                             "missing decoded video must not be accepted as a successful black frame")
    }

    func testMissingFrameAfterBackwardSeekIsAnError() throws {
        let scene = scene(), source = try pixelBuffer(red: 220)
        XCTAssertGreaterThan(red(try scene.compose(at: 1.2) { _ in source }), 100)
        XCTAssertThrowsError(try scene.compose(at: 0.4) { _ in nil },
                             "a previous future frame cannot satisfy a backwards seek")
    }

    func testIntentionalGapDoesNotReuseAnOldClipFrame() throws {
        let scene = scene([(0, 0.5)]), source = try pixelBuffer(red: 220)
        _ = try scene.compose(at: 0.4) { _ in source }
        XCTAssertEqual(red(try scene.compose(at: 0.8) { _ in nil }), 0,
                       "an empty timeline interval must keep its intentional background")
    }

    func testMissingFrameCannotReuseThePreviousClip() throws {
        let scene = scene([(0, 0.5), (0.5, 2)]), source = try pixelBuffer(red: 220)
        _ = try scene.compose(at: 0.4) { _ in source }
        XCTAssertThrowsError(try scene.compose(at: 0.52) { _ in nil },
                             "a frame from another cut cannot replace the requested source")
    }

    func testOneForwardMissingFrameOfSameClipCanUseDecodedFrame() throws {
        let scene = scene(), source = try pixelBuffer(red: 220)
        _ = try scene.compose(at: 0.12) { _ in source }
        XCTAssertGreaterThan(red(try scene.compose(at: 0.16) { _ in nil }), 100)
    }

    func testAcceleratedExportCanBridgeOneMissingOutputFrame() throws {
        let presentation = try XCTUnwrap(ExportPresentation(json:
            ["rate": 1.1, "foregroundScale": 0.9, "backgroundGain": 0.5]))
        let scene = scene(presentation: presentation), source = try pixelBuffer(red: 220)
        _ = try scene.compose(at: 0.16) { _ in source }
        // Source indices jump 4 -> 6, but only one output frame is missing.
        XCTAssertNoThrow(try scene.compose(at: 0.20) { _ in nil })
        XCTAssertThrowsError(try scene.compose(at: 0.24) { _ in nil })
    }

    func testSlowerExportCannotFreezeSeveralMissingOutputFrames() throws {
        let presentation = try XCTUnwrap(ExportPresentation(json:
            ["rate": 0.5, "foregroundScale": 0.9, "backgroundGain": 0.5]))
        let scene = scene(presentation: presentation), source = try pixelBuffer(red: 220)
        _ = try scene.compose(at: 0.16) { _ in source }
        XCTAssertNoThrow(try scene.compose(at: 0.20) { _ in nil })
        XCTAssertThrowsError(try scene.compose(at: 0.24) { _ in nil })
    }

    func testDecodedBlackVideoFrameIsNotAnError() throws {
        let scene = scene(), source = try pixelBuffer(red: 0)
        XCTAssertEqual(red(try scene.compose(at: 0.2) { _ in source }), 0)
    }

    func testMissingOverlayFrameDoesNotProduceAPartialComposition() throws {
        let base = scene(), source = try pixelBuffer(red: 220)
        let overlay = RenderScene.Item(trackID: 8, still: nil, at: 0, end: 2, k0: 0,
            frames: [[4, 0, 0, 4, 0, 0, 1]], pref: .identity, fx: nil, crop: nil, mask: [], ci: [])
        let layered = RenderScene(size: base.size, fps: base.fps, layers: [base.layers[0], [overlay]],
                                  overlays: [], grade: nil, luts: [])
        XCTAssertThrowsError(try layered.compose(at: 0.2) { track in track == 7 ? source : nil })
    }

    func testProlongedMissingFrameCannotFreezeAnOldImage() throws {
        let scene = scene(), source = try pixelBuffer(red: 220)
        _ = try scene.compose(at: 0.12) { _ in source }
        XCTAssertThrowsError(try scene.compose(at: 0.24) { _ in nil })
    }

    func testOutputPixelBufferPoolCanAllocateAFrame() throws {
        var attributes = RyndiCompositor().requiredPixelBufferAttributesForRenderContext
        attributes[kCVPixelBufferWidthKey as String] = 720
        attributes[kCVPixelBufferHeightKey as String] = 1280
        var pool: CVPixelBufferPool?
        XCTAssertEqual(CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool), kCVReturnSuccess)
        var frame: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferPoolCreatePixelBuffer(nil, try XCTUnwrap(pool), &frame), kCVReturnSuccess)
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(try XCTUnwrap(frame)), kCVPixelFormatType_32BGRA)
    }

    private func export(cut: Bool) async throws -> URL {
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "portrait-full-range", withExtension: "mp4", subdirectory: "Fixtures"))
        // Контракт nativeplan: единичный кадр -> пиксели выхода, не
        // пиксели исходника -> пиксели выхода (RenderScene.placement).
        let matrix: [Double] = [1080, 0, 0, 1920, 0, 0, 1]
        func item(_ at: Double, _ from: Double, _ duration: Double) -> [String: Any] {
            ["media": "m1", "at": at, "from": from, "dur": duration, "k0": Int(at * 25), "frames": [matrix]]
        }
        let items = cut ? [item(0, 0, 1), item(1, 1, 1)] : [item(0, 0, 2)]
        let plan = try XCTUnwrap(ExportPlan(json: ["width": 1080, "height": 1920, "fps": 25, "frames": 50,
            "bitrate": 9_000_000, "codec": "h264", "save": false,
            "media": [["id": "m1", "url": "ryndi-media://orig/pfixture.mp4"]],
            "layers": [["items": items]],
            "sounds": [["media": "m1", "at": 0, "from": 0, "dur": 2, "volume": 1]]]))
        let done = expectation(description: "native export")
        var result: URL?, failure: [String: Any]?
        let engine = NativeExporter(job: UUID().uuidString, plan: plan, send: { event in
            print("EXPORT-EVENT \(event)")
            if event["event"] as? String == "export-error" { failure = event }
        }, resolve: { _, callback in callback(source) })
        engine.onFinish = { result = $0; done.fulfill() }
        engine.start()
        await fulfillment(of: [done], timeout: 40)
        if result == nil { engine.cancel() }
        withExtendedLifetime(engine) {}
        XCTAssertNil(failure, String(describing: failure))
        // A short export can finish before a positive throttled progress event.
        // verify() checks encoded frames by decoding the resulting file.
        return try XCTUnwrap(result, String(describing: failure))
    }

    func testPortraitFullRangeExportsWithStereoSound() async throws { try verify(await export(cut: false)) }
    func testPortraitFullRangeExportsAfterScissorsWithStereoSound() async throws { try verify(await export(cut: true)) }

    private func verify(_ url: URL) throws {
        defer { try? FileManager.default.removeItem(at: url) }
        let asset = AVURLAsset(url: url)
        let video = try XCTUnwrap(asset.tracks(withMediaType: .video).first)
        let sound = try XCTUnwrap(asset.tracks(withMediaType: .audio).first)
        XCTAssertEqual(video.naturalSize.width, 1080)
        XCTAssertEqual(video.naturalSize.height, 1920)
        XCTAssertEqual(CMTimeGetSeconds(asset.duration), 2, accuracy: 0.08)
        XCTAssertEqual(ExportAudio.channels(sound), 2)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: video, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output); XCTAssertTrue(reader.startReading())
        var frames = 0, visible = false
        while let sample = output.copyNextSampleBuffer() {
            frames += 1
            if let image = CMSampleBufferGetImageBuffer(sample) {
                CVPixelBufferLockBaseAddress(image, .readOnly)
                if let base = CVPixelBufferGetBaseAddress(image) {
                    let row = CVPixelBufferGetBytesPerRow(image), pixels = base.assumingMemoryBound(to: UInt8.self)
                    for y in stride(from: 200, to: 1500, by: 170) {
                        let at = y * row + 400 * 4
                        if Int(pixels[at]) + Int(pixels[at + 1]) + Int(pixels[at + 2]) > 30 { visible = true }
                    }
                }
                CVPixelBufferUnlockBaseAddress(image, .readOnly)
            }
        }
        XCTAssertEqual(reader.status, .completed, String(describing: reader.error))
        XCTAssertEqual(frames, 50, "export must contain all 50 decoded video frames")
        XCTAssertTrue(visible, "export must contain decoded video, not black frames")
    }
}
