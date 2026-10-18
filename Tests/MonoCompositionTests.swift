import XCTest
import AVFoundation
import CoreVideo

// The user's failing inputs are portrait HLG movies with one audio channel.
// A stereo fixture never enters the CAF conversion path used by these tests.
final class MonoCompositionTests: XCTestCase {
    private func source() throws -> URL {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "hlg-mono",
            withExtension: "mp4", subdirectory: "Fixtures"))
        let asset = AVURLAsset(url: url)
        XCTAssertEqual(ExportAudio.channels(try XCTUnwrap(asset.tracks(withMediaType: .audio).first)), 1)
        return url
    }

    private func plan(cut: Bool, preview: Bool = false) throws -> ExportPlan {
        let width = preview ? 720 : 1080, height = preview ? 1280 : 1920
        let spans: [(at: Double, from: Double, duration: Double)] = cut
            ? [(0, 0, 0.5), (0.5, 1, 0.5), (1, 2, 1)] : [(0, 0, 2)]
        let matrix: [Double] = [Double(width), 0, 0, Double(height), 0, 0, 1]
        let items: [[String: Any]] = spans.map { span in
            ["media": "m1", "at": span.at, "from": span.from, "dur": span.duration,
             "k0": Int((span.at * 30).rounded()), "frames": [matrix]]
        }
        let sounds: [[String: Any]] = spans.map { span in
            ["media": "m1", "at": span.at, "from": span.from, "dur": span.duration,
             "volume": 1, "keys": [["at": span.at, "g": 1],
                                    ["at": span.at + span.duration, "g": 1]]]
        }
        return try XCTUnwrap(ExportPlan(json: [
            "width": width, "height": height, "fps": 30, "frames": 60,
            "bitrate": 4_000_000, "codec": "h264", "save": false,
            "media": [["id": "m1", "url": "ryndi-media://orig/pmono.mp4"]],
            "layers": [["items": items]], "sounds": sounds,
        ]))
    }

    func testHLGMonoCompositionCanBeAssembledBeforeAnyCut() throws {
        let input = try source(), plan = try plan(cut: false)
        let temps = TempFiles()
        defer { temps.removeAll() }
        let composition = try NativeExporter.assemble(plan, ["m1": input], temps: temps)
        XCTAssertEqual(CMTimeGetSeconds(composition.comp.duration), 2, accuracy: 0.01)
        XCTAssertFalse(composition.comp.tracks(withMediaType: .audio).isEmpty)
        let reader = try AVAssetReader(asset: composition.comp)
        let output = AVAssetReaderAudioMixOutput(audioTracks: composition.comp.tracks(withMediaType: .audio),
            audioSettings: ExportAudio.floatPCM(channels: 2))
        output.audioMix = composition.mix
        reader.add(output)
        XCTAssertTrue(reader.startReading(), String(describing: reader.error))
        var frames = 0
        while let sample = output.copyNextSampleBuffer() { frames += CMSampleBufferGetNumSamples(sample) }
        XCTAssertEqual(reader.status, .completed, String(describing: reader.error))
        XCTAssertGreaterThan(frames, 90_000, "the assembled mono source must remain readable")
    }

    func testHLGMonoAfterScissorsExportsEveryFrameAndAudibleStereo() async throws {
        let input = try source(), plan = try plan(cut: true)
        let finished = expectation(description: "mono HLG export finishes")
        var result: URL?, failure: [String: Any]?
        let exporter = NativeExporter(job: UUID().uuidString, plan: plan, send: { event in
            if event["event"] as? String == "export-error" { failure = event }
            print("MONO-EXPORT-EVENT \(event)")
        }, resolve: { _, callback in callback(input) })
        exporter.onFinish = { result = $0; finished.fulfill() }
        exporter.start()
        await fulfillment(of: [finished], timeout: 40)
        if result == nil { exporter.cancel() }
        withExtendedLifetime(exporter) {}
        XCTAssertNil(failure, String(describing: failure))
        let url = try XCTUnwrap(result, String(describing: failure))
        defer { try? FileManager.default.removeItem(at: url) }
        try verifyExport(url)
    }

    @MainActor
    func testHLGMonoPreviewProducesFramesOnBothSidesOfCuts() async throws {
        let input = try source(), plan = try plan(cut: true, preview: true)
        let temps = TempFiles()
        defer { temps.removeAll() }
        let composition = try NativeExporter.assemble(plan, ["m1": input], temps: temps)
        let item = AVPlayerItem(asset: composition.comp)
        item.videoComposition = composition.video
        item.audioMix = composition.mix
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        item.add(output)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        player.automaticallyWaitsToMinimizeStalling = false
        defer { player.pause(); player.replaceCurrentItem(with: nil) }
        let deadline = Date().addingTimeInterval(10)
        while item.status == .unknown, Date() < deadline {
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        XCTAssertEqual(item.status, .readyToPlay, String(describing: item.error))
        guard item.status == .readyToPlay else { return }
        player.playImmediately(atRate: 1)
        var decoded: [Double] = []
        while Date() < deadline, item.status != .failed {
            if player.currentTime().isNumeric, player.currentTime().seconds >= 1.8 { break }
            var displayed = CMTime.invalid
            if output.copyPixelBuffer(forItemTime: player.currentTime(), itemTimeForDisplay: &displayed) != nil,
               displayed.isNumeric { decoded.append(displayed.seconds) }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        XCTAssertNotEqual(item.status, .failed, String(describing: item.error))
        XCTAssertGreaterThan(player.currentTime().seconds, 1.7, "native preview must advance through both cuts")
        XCTAssertTrue(decoded.contains { $0 >= 0 && $0 < 0.5 }, "first clip must produce video")
        XCTAssertTrue(decoded.contains { $0 >= 0.5 && $0 < 1 }, "clip after the first cut must produce video")
        XCTAssertTrue(decoded.contains { $0 >= 1.1 }, "clip after the second cut must produce video")
    }

    private func verifyExport(_ url: URL) throws {
        let asset = AVURLAsset(url: url)
        let video = try XCTUnwrap(asset.tracks(withMediaType: .video).first)
        let audio = try XCTUnwrap(asset.tracks(withMediaType: .audio).first)
        XCTAssertEqual(video.naturalSize, CGSize(width: 1080, height: 1920))
        XCTAssertEqual(asset.duration.seconds, 2, accuracy: 0.08)
        XCTAssertEqual(ExportAudio.channels(audio), 2)

        let videoReader = try AVAssetReader(asset: asset)
        let videoOutput = AVAssetReaderTrackOutput(track: video, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        videoReader.add(videoOutput)
        XCTAssertTrue(videoReader.startReading(), String(describing: videoReader.error))
        var videoFrames = 0
        while let sample = videoOutput.copyNextSampleBuffer() {
            XCTAssertNotNil(CMSampleBufferGetImageBuffer(sample))
            videoFrames += 1
        }
        XCTAssertEqual(videoReader.status, .completed, String(describing: videoReader.error))
        XCTAssertEqual(videoFrames, 60, "the output must decode through every cut")

        let audioReader = try AVAssetReader(asset: asset)
        let audioOutput = AVAssetReaderTrackOutput(track: audio, outputSettings: ExportAudio.floatPCM(channels: 2))
        audioReader.add(audioOutput)
        XCTAssertTrue(audioReader.startReading(), String(describing: audioReader.error))
        var samples = 0, left = 0.0, right = 0.0, difference = 0.0
        while let sample = audioOutput.copyNextSampleBuffer() {
            let pcm = try XCTUnwrap(ExportAudio.floats(sample))
            XCTAssertEqual(pcm.channels, 2)
            for i in stride(from: 0, to: pcm.data.count - 1, by: 2) {
                let a = Double(pcm.data[i]), b = Double(pcm.data[i + 1])
                left += a * a; right += b * b; difference += (a - b) * (a - b)
                samples += 1
            }
        }
        XCTAssertEqual(audioReader.status, .completed, String(describing: audioReader.error))
        XCTAssertGreaterThan(samples, 90_000)
        XCTAssertGreaterThan(sqrt(left / Double(max(1, samples))), 0.01, "left channel must be audible")
        XCTAssertGreaterThan(sqrt(right / Double(max(1, samples))), 0.01, "right channel must be audible")
        XCTAssertLessThan(sqrt(difference / Double(max(1, samples))), 0.01,
                          "mono source must sound in both output channels")
    }
}
