import XCTest
import AVFoundation
import CoreImage

final class ExportPresentationTests: XCTestCase {
    private let options: [String: Any] = ["rate": 1.1, "foregroundScale": 0.9, "backgroundGain": 0.5]

    private func fixture() throws -> URL {
        try XCTUnwrap(Bundle(for: Self.self).url(forResource: "export-presentation", withExtension: "mp4",
                                                subdirectory: "Fixtures"))
    }

    private func json(presentation: [String: Any]? = nil, frameCount: Int = 55) -> [String: Any] {
        let matrix: [Double] = [180, 0, 0, 320, 0, 0, 1]
        let duration = Double(frameCount) / 25
        var plan: [String: Any] = ["width": 180, "height": 320, "fps": 25, "frames": frameCount,
            "codec": "h264", "bitrate": 500_000, "save": false,
            "media": [["id": "m1", "url": "ryndi-media://orig/pfixture.mp4"]],
            "layers": [["items": [["media": "m1", "at": 0, "from": 0, "dur": duration,
                                   "k0": 0, "frames": [matrix]]]]],
            "sounds": [["media": "m1", "at": 0, "from": 0, "dur": duration, "volume": 1]]]
        if let presentation = presentation { plan["presentation"] = presentation }
        return plan
    }

    private func color(_ image: CIImage, x: Int, y: Int) -> [UInt8] {
        var pixel = [UInt8](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes { bytes in
            CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()]).render(image,
                toBitmap: bytes.baseAddress!, rowBytes: 4, bounds: CGRect(x: x, y: y, width: 1, height: 1),
                format: .RGBA8, colorSpace: nil)
        }
        return pixel
    }

    func testFrameCentersTheCompleteMontageOverItsDarkenedFrame() throws {
        let image = CIImage(color: CIColor(red: 0.8, green: 0.4, blue: 0.2))
            .cropped(to: CGRect(x: 0, y: 0, width: 100, height: 200))
        let item = RenderScene.Item(trackID: kCMPersistentTrackID_Invalid, still: image, at: 0, end: 2.2,
            k0: 0, frames: [[100, 0, 0, 200, 0, 0, 1]], pref: .identity, fx: nil, crop: nil, mask: [], ci: [])
        let scene = RenderScene(size: CGSize(width: 100, height: 200), fps: 25, layers: [[item]],
            overlays: [], grade: nil, luts: [], presentation: try XCTUnwrap(ExportPresentation(json: options)))
        let frame = try scene.compose(at: 0.2) { _ in XCTFail("a still needs no video decoder"); return nil }
        XCTAssertEqual(frame.extent, CGRect(x: 0, y: 0, width: 100, height: 200))
        XCTAssertEqual(Double(color(frame, x: 50, y: 100)[0]), 204, accuracy: 3)
        for point in [(1, 100), (98, 100), (50, 1), (50, 198)] {
            XCTAssertEqual(Double(color(frame, x: point.0, y: point.1)[0]), 102, accuracy: 3)
        }
        XCTAssertGreaterThan(color(frame, x: 6, y: 100)[0], 190)
        XCTAssertGreaterThan(color(frame, x: 50, y: 11)[0], 190)
    }

    func testCaptionClockAndPlacementFollowTheSameSpeedAndFrame() throws {
        let image = CIImage(color: CIColor(red: 1, green: 0, blue: 0))
            .cropped(to: CGRect(x: 0, y: 0, width: 100, height: 200))
        let blue = CIImage(color: CIColor(red: 0, green: 0, blue: 1))
            .cropped(to: CGRect(x: 0, y: 0, width: 20, height: 20))
        let item = RenderScene.Item(trackID: kCMPersistentTrackID_Invalid, still: image, at: 0, end: 2.2,
            k0: 0, frames: [[100, 0, 0, 200, 0, 0, 1]], pref: .identity, fx: nil, crop: nil, mask: [], ci: [])
        let scene = RenderScene(size: CGSize(width: 100, height: 200), fps: 25, layers: [[item]],
            overlays: [RenderScene.Overlay(image: blue, at: 1.05, end: 1.15)], grade: nil, luts: [],
            presentation: try XCTUnwrap(ExportPresentation(json: options)))
        let before = try scene.compose(at: 0.9) { _ in nil }
        XCTAssertGreaterThan(color(before, x: 10, y: 15)[0], 240)
        let caption = try scene.compose(at: 1.0) { _ in nil } // source clock: 1.1 seconds
        XCTAssertGreaterThan(color(caption, x: 10, y: 15)[2], 240)
        XCTAssertLessThan(color(caption, x: 10, y: 15)[0], 10)
        XCTAssertEqual(Double(color(caption, x: 1, y: 1)[2]), 127.5, accuracy: 3)
    }

    func testCompositionAndVolumeRampsShareTheOutputClock() throws {
        var raw = json(presentation: options)
        raw["sounds"] = [["media": "m1", "at": 0, "from": 0, "dur": 2.2, "volume": 1,
                           "keys": [["at": 0, "g": 0], ["at": 1.1, "g": 1], ["at": 2.2, "g": 0]]]]
        let plan = try XCTUnwrap(ExportPlan(json: raw)), temps = TempFiles()
        defer { temps.removeAll() }
        let assembly = try NativeExporter.assemble(plan, ["m1": fixture()], temps: temps)
        XCTAssertEqual(CMTimeGetSeconds(assembly.total), 2, accuracy: 0.0001)
        for kind in [AVMediaType.video, .audio] {
            let track = try XCTUnwrap(assembly.comp.tracks(withMediaType: kind).first)
            let segment = try XCTUnwrap(track.segments.first { !$0.isEmpty })
            XCTAssertEqual(CMTimeGetSeconds(segment.timeMapping.source.duration), 2.2, accuracy: 0.001)
            XCTAssertEqual(CMTimeGetSeconds(segment.timeMapping.target.duration), 2, accuracy: 0.001)
        }
        let input = try XCTUnwrap(assembly.mix.inputParameters.first)
        var start: Float = -1, end: Float = -1, range = CMTimeRange.invalid
        XCTAssertTrue(input.getVolumeRamp(for: CMTime(seconds: 0.5, preferredTimescale: 60000),
                                           startVolume: &start, endVolume: &end, timeRange: &range))
        XCTAssertEqual(start, 0, accuracy: 0.001)
        XCTAssertEqual(end, 1, accuracy: 0.001)
        XCTAssertEqual(CMTimeGetSeconds(range.start), 0, accuracy: 0.0001)
        XCTAssertEqual(CMTimeGetSeconds(range.duration), 1, accuracy: 0.0001)
    }

    func testFractionalDurationDoesNotRoundToTheOriginalVideoFrameRate() throws {
        let presentation = try XCTUnwrap(ExportPresentation(json: options))
        let minute = CMTime(value: 1800, timescale: 30)
        XCTAssertEqual(CMTimeGetSeconds(presentation.outputTime(minute)), 54.5454545, accuracy: 0.0001)
    }

    func testMalformedPresentationIsRejectedAndLegacyPlansRemainUnchanged() throws {
        let plain = try XCTUnwrap(ExportPlan(json: json()))
        XCTAssertNil(plain.presentation)
        let invalidValues: [(String, Double)] = [("rate", 0), ("rate", .infinity), ("foregroundScale", 0),
                                                ("foregroundScale", 1.1), ("backgroundGain", -1)]
        for pair in invalidValues {
            var invalid = options
            invalid[pair.0] = pair.1
            XCTAssertNil(ExportPlan(json: json(presentation: invalid)))
        }
    }

    func testEncodedPresentationHasSynchronizedContentAndNoSourceDescriptiveMetadata() async throws {
        let source = try fixture(), input = AVURLAsset(url: source)
        let sourceValues = input.availableMetadataFormats.flatMap { input.metadata(forFormat: $0) }
            .compactMap { $0.stringValue }
        XCTAssertTrue(sourceValues.contains("SOURCE_PRESENTATION_SENTINEL"), "fixture must contain old metadata")
        let plan = try XCTUnwrap(ExportPlan(json: json(presentation: options, frameCount: 275)))
        let finished = expectation(description: "encoded presentation")
        var result: URL?, failure: String?
        let engine = NativeExporter(job: UUID().uuidString, plan: plan, send: { event in
            if event["event"] as? String == "export-error" { failure = event["reason"] as? String }
        }, resolve: { _, reply in reply(source) })
        engine.onFinish = { result = $0; finished.fulfill() }
        engine.start()
        await fulfillment(of: [finished], timeout: 40)
        withExtendedLifetime(engine) {}
        XCTAssertNil(failure)
        let url = try XCTUnwrap(result, failure ?? "no exported file")
        defer { try? FileManager.default.removeItem(at: url) }
        let output = AVURLAsset(url: url)
        XCTAssertEqual(CMTimeGetSeconds(output.duration), 10, accuracy: 0.04)
        let tracks = output.tracks
        XCTAssertEqual(tracks.filter { $0.mediaType == .audio }.count, 1, "no duplicate audio")
        let metadata = output.availableMetadataFormats.flatMap { output.metadata(forFormat: $0) } +
            tracks.flatMap { track in track.availableMetadataFormats.flatMap { track.metadata(forFormat: $0) } }
        for value in metadata.compactMap({ $0.stringValue }) {
            XCTAssertFalse(value.contains("SOURCE_PRESENTATION"), value)
            XCTAssertFalse(value.contains("2001-01-01"), value)
        }
        try verifyVideo(output)
        try verifyAudio(output)
    }

    private func verifyVideo(_ asset: AVAsset) throws {
        let track = try XCTUnwrap(asset.tracks(withMediaType: .video).first)
        XCTAssertEqual(track.naturalSize, CGSize(width: 180, height: 320))
        let reader = try AVAssetReader(asset: asset)
        let video = AVAssetReaderTrackOutput(track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(video)
        XCTAssertTrue(reader.startReading())
        var count = 0, red = false, blue = false
        while let sample = video.copyNextSampleBuffer() {
            count += 1
            let t = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let image = CIImage(cvPixelBuffer: buffer)
            if abs(t - 0.6) < 0.01 {
                let center = color(image, x: 90, y: 160), edge = color(image, x: 1, y: 160)
                red = center[0] > 220 && center[2] < 30 && edge[0] > 90 && edge[0] < 160
            }
            // Source is still red here. Only a real speed change reaches blue.
            if abs(t - 5.08) < 0.01 {
                let center = color(image, x: 90, y: 160)
                blue = center[2] > 220 && center[0] < 30
            }
        }
        XCTAssertEqual(reader.status, .completed, String(describing: reader.error))
        XCTAssertEqual(count, 250)
        XCTAssertTrue(red, "first part must stay red with a darkened border")
        XCTAssertTrue(blue, "the second source section must start near output second 5, before source second 5.5")
    }

    private func verifyAudio(_ asset: AVAsset) throws {
        let track = try XCTUnwrap(asset.tracks(withMediaType: .audio).first)
        let reader = try AVAssetReader(asset: asset)
        let audio = AVAssetReaderTrackOutput(track: track, outputSettings: ExportAudio.floatPCM(channels: 2))
        reader.add(audio)
        XCTAssertTrue(reader.startReading())
        var quiet: Double = 0, loud: Double = 0, nq = 0, nl = 0
        while let sample = audio.copyNextSampleBuffer() {
            guard let data = CMSampleBufferGetDataBuffer(sample) else { continue }
            var values = [Float](repeating: 0, count: CMBlockBufferGetDataLength(data) / 4)
            let status = values.withUnsafeMutableBytes { bytes in
                CMBlockBufferCopyDataBytes(data, atOffset: 0, dataLength: bytes.count, destination: bytes.baseAddress!)
            }
            XCTAssertEqual(status, kCMBlockBufferNoErr)
            let start = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
            for i in stride(from: 0, to: values.count, by: 2) {
                let t = start + Double(i / 2) / 48000
                let square = Double(values[i]) * Double(values[i])
                if t >= 0.2 && t < 0.7 { quiet += square; nq += 1 }
                // Source is silent until 5.5; the accelerated signal starts at 5.
                if t >= 5.15 && t < 5.4 { loud += square; nl += 1 }
            }
        }
        XCTAssertEqual(reader.status, .completed, String(describing: reader.error))
        XCTAssertGreaterThan(nq, 20000)
        XCTAssertGreaterThan(nl, 10000)
        XCTAssertLessThan(sqrt(quiet / Double(max(1, nq))), 0.003)
        XCTAssertGreaterThan(sqrt(loud / Double(max(1, nl))), 0.05,
                             "audio must reach the same accelerated source section as the video")
    }
}
