import XCTest
import AVFoundation
import CoreVideo

final class NativeExportTests: XCTestCase {
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

    func testArrayIsNotAValidOutputPixelFormat() {
        let attributes: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA],
            kCVPixelBufferWidthKey as String: 720, kCVPixelBufferHeightKey as String: 1280]
        var pool: CVPixelBufferPool?
        XCTAssertNotEqual(CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool), kCVReturnSuccess)
    }

    private func export(cut: Bool) throws -> URL {
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "portrait-full-range", withExtension: "mp4", subdirectory: "Fixtures"))
        let matrix: [Double] = [1.5, 0, 0, 1.5, 0, 0, 1]
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
            if event["event"] as? String == "export-error" { failure = event }
            if event["event"] as? String == "export-progress", (event["value"] as? Double ?? 0) > 0 { progress = true }
        }, resolve: { _, callback in callback(source) })
        engine.onFinish = { result = $0; done.fulfill() }
        engine.start()
        wait(for: [done], timeout: 40)
        XCTAssertNil(failure, String(describing: failure))
        XCTAssertTrue(progress, "at least one video frame must be encoded")
        return try XCTUnwrap(result, String(describing: failure))
    }

    func testPortraitFullRangeExportsWithStereoSound() throws { try verify(export(cut: false)) }
    func testPortraitFullRangeExportsAfterScissorsWithStereoSound() throws { try verify(export(cut: true)) }

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
