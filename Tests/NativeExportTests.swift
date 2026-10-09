import XCTest
import AVFoundation
import CoreVideo
import CoreImage

final class NativeExportTests: XCTestCase {
    private let small = CGSize(width: 96, height: 128)

    private func maskImage(inverted: Bool, feather: Bool = false) -> CIImage {
        var bytes = [UInt8](repeating: 255, count: 96 * 128 * 4)
        for y in 0..<128 { for x in 0..<96 {
            let dx = Double(x) + 0.5 - 48, dy = Double(y) + 0.5 - 64
            let distance = sqrt(dx * dx + dy * dy)
            var value: UInt8 = distance < 32 ? 255 : 0
            if feather && abs(distance - 32) < 8 { value = 128 }
            if inverted { value = 255 - value }
            let at = (y * 96 + x) * 4
            bytes[at] = value; bytes[at + 1] = value; bytes[at + 2] = value
        } }
        return CIImage(bitmapData: Data(bytes), bytesPerRow: 96 * 4, size: small, format: .RGBA8, colorSpace: nil)
    }

    private func pixels(_ image: CIImage, _ points: [(Int, Int)]) -> [[Int]] {
        var bytes = [UInt8](repeating: 0, count: 96 * 128 * 4)
        let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        bytes.withUnsafeMutableBytes { p in
            context.render(image, toBitmap: p.baseAddress!, rowBytes: 96 * 4,
                           bounds: CGRect(origin: .zero, size: small), format: .RGBA8, colorSpace: nil)
        }
        return points.map { x, y in
            let at = (y * 96 + x) * 4
            return [Int(bytes[at]), Int(bytes[at + 1]), Int(bytes[at + 2])]
        }
    }

    private func scene(inverted: Bool, feather: Bool = false, opacity: Double = 1, video: Bool = false) throws -> RenderScene {
        let red = CIImage(color: CIColor(red: 240 / 255.0, green: 40 / 255.0, blue: 20 / 255.0))
            .cropped(to: CGRect(origin: .zero, size: small))
        let local = try XCTUnwrap(ExportPlan.MaskFx(json: ["spans": [[25, 50]],
            "ci": [["name": "CIColorControls", "params": ["inputSaturation": 0]]]]))
        let item = RenderScene.Item(trackID: 1, still: video ? nil : red, at: 0, end: 3, k0: 0,
            frames: [[96, 0, 0, 128, 0, 0, opacity]], pref: .identity, fx: nil, crop: nil,
            mask: [maskImage(inverted: inverted, feather: feather)], ci: [], maskFx: true)
        let global = ExportPlan.CiStep(name: "CIColorControls", params: ["inputSaturation": 0],
                                      anim: [:], k0: 0, clamp: true, skipMasked: true)
        return RenderScene(size: small, fps: 25, layers: [[item]], overlays: [], grade: nil, luts: [],
                           ci: [global], maskFx: local)
    }

    func testMaskedEffectPreservesVisibleVideoAndSupportsInversion() throws {
        for inverted in [false, true] {
            let renderer = try scene(inverted: inverted)
            let colors = pixels(renderer.compose(at: 1, frame: { _ in XCTFail("still must not decode a video"); return nil }), [(48, 64), (8, 64)])
            let original = colors[inverted ? 1 : 0], changed = colors[inverted ? 0 : 1]
            XCTAssertGreaterThan(original[0], 230); XCTAssertLessThan(original[1], 50)
            XCTAssertLessThan((changed.max() ?? 255) - (changed.min() ?? 0), 4)
            XCTAssertGreaterThan(changed.min() ?? 0, 20, "hidden area contains the same video with the effect")
        }
    }

    func testMaskedEffectWindowEndsExactlyAndFeatherMixesOnce() throws {
        let renderer = try scene(inverted: false, feather: true, opacity: 0.5)
        let before = pixels(renderer.compose(at: 0.96, frame: { _ in nil }), [(8, 64)])
        let active = pixels(renderer.compose(at: 1, frame: { _ in nil }), [(48, 64), (8, 64), (80, 64)])
        let after = pixels(renderer.compose(at: 2, frame: { _ in nil }), [(8, 64)])
        XCTAssertLessThan(before[0].max() ?? 255, 3)
        XCTAssertLessThan(after[0].max() ?? 255, 3)
        XCTAssertLessThanOrEqual(abs(active[0][0] - 120), 3)
        XCTAssertLessThanOrEqual(abs(active[2][0] - (active[0][0] + active[1][0]) / 2), 4)
        XCTAssertLessThanOrEqual(abs(active[2][1] - (active[0][1] + active[1][1]) / 2), 4)
    }

    func testMaskedVideoUsesOneDecodedFrameForBothAreas() throws {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 96, 128, kCVPixelFormatType_32BGRA, nil, &buffer), kCVReturnSuccess)
        let pixelBuffer = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixelBuffer)).assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        for y in 0..<128 { for x in 0..<96 {
            let at = y * stride + x * 4
            base[at] = 20; base[at + 1] = 40; base[at + 2] = 240; base[at + 3] = 255
        } }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        let renderer = try scene(inverted: false, video: true)
        var reads = 0
        let image = renderer.compose(at: 1) { id in XCTAssertEqual(id, 1); reads += 1; return pixelBuffer }
        let colors = pixels(image, [(48, 64), (8, 64)])
        XCTAssertEqual(reads, 1)
        XCTAssertGreaterThan(colors[0][0], 230)
        XCTAssertGreaterThan(colors[1].min() ?? 0, 20)
    }

    func testMaskEffectPlanIsOptionalAndParsesMotionAndFrames() throws {
        let matrix: [Double] = [96, 0, 0, 128, 0, 0, 1]
        var json: [String: Any] = ["width": 96, "height": 128, "fps": 25, "frames": 75,
            "layers": [["items": [["media": "m", "at": 0, "from": 0, "dur": 3, "frames": [matrix], "mask": 0]]]]]
        let old = try XCTUnwrap(ExportPlan(json: json))
        XCTAssertNil(old.maskFx); XCTAssertFalse(old.layers[0][0].maskFx)
        json["mask_fx"] = ["spans": [[25, 50]], "ci": [], "moves": ["k0": 25, "frames": [[1.1, 0, 0, 1.1, -4.8, -6.4]]]]
        let parsed = try XCTUnwrap(ExportPlan(json: json)?.maskFx)
        XCTAssertFalse(parsed.active(24)); XCTAssertTrue(parsed.active(25)); XCTAssertFalse(parsed.active(50))
        XCTAssertEqual(parsed.moves[0][0], 1.1)
        XCTAssertEqual(parsed.k0, 25)
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
        var result: URL?, failure: [String: Any]?, progress = false
        let engine = NativeExporter(job: UUID().uuidString, plan: plan, send: { event in
            print("EXPORT-EVENT \(event)")
            if event["event"] as? String == "export-error" { failure = event }
            if event["event"] as? String == "export-progress", (event["value"] as? Double ?? 0) > 0 { progress = true }
        }, resolve: { _, callback in callback(source) })
        engine.onFinish = { result = $0; done.fulfill() }
        engine.start()
        await fulfillment(of: [done], timeout: 40)
        if result == nil { engine.cancel() }
        withExtendedLifetime(engine) {}
        XCTAssertNil(failure, String(describing: failure))
        XCTAssertTrue(progress, "at least one video frame must be encoded")
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
        XCTAssertEqual(frames, 50)
        XCTAssertTrue(visible, "export must contain decoded video, not black frames")
    }
}
