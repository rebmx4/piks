import AVFoundation
import XCTest

final class MuteBoundaryTests: XCTestCase {
    private struct Cut {
        let at: Double
        let muted: Double
        var end: Double { at + muted }
        var total: Double { end + 0.3 }
        var windows: [AudioBoundarySamples.Window] {
            [ .init(name: "before", start: at - 0.1, end: at - 0.01),
              .init(name: "muted-first-10ms", start: at, end: at + 0.01),
              .init(name: "muted-first-100ms", start: at, end: at + 0.1),
              .init(name: "muted-later", start: at + 0.12, end: end - 0.01),
              .init(name: "restored", start: end + 0.03, end: end + 0.2) ]
        }
    }
    private let short = Cut(at: 0.508, muted: 0.257)
    private let reported = Cut(at: 33.009, muted: 2.44)

    func testDecodedMixIsSilentFromFirstSampleAtShortCutAndRestoresNextClip() async throws {
        try await verifyReader(short)
    }

    func testDecodedMixIsSilentAtReportedFractionalCut() async throws {
        try await verifyReader(reported)
    }

    func testPlayerPostMixIsSilentAtShortCut() async throws {
        try await verifyPlayer(short)
    }

    func testPlayerPostMixIsSilentAtReportedCutAfterSeek() async throws {
        try await verifyPlayer(reported)
    }

    func testExplicitVolumeStepsAreSilentAtShortCut() async throws {
        try await verifyReader(short, steps: true)
    }

    func testExplicitVolumeStepsAreSilentAtReportedCut() async throws {
        try await verifyReader(reported, steps: true)
    }

    func testPostMixTapCanObserveAnEntirelyMutedTrack() async throws {
        try await verifyPlayer(short, wholeMute: true)
    }

    func testEncodedExportIsSilentAtShortCut() async throws {
        let cut = short
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let audio = try await toneSource(folder), video = try fixture()
        let plan = try makePlan(cut)
        let done = expectation(description: "export mute boundary")
        var output: URL?, failure: [String: Any]?
        let exporter = NativeExporter(job: UUID().uuidString, plan: plan, send: {
            if $0["event"] as? String == "export-error" { failure = $0 }
        }, resolve: { id, callback in callback(id == "tone" ? audio : video) })
        exporter.onFinish = { output = $0; done.fulfill() }
        exporter.start()
        await fulfillment(of: [done], timeout: 45)
        if output == nil { exporter.cancel() }
        withExtendedLifetime(exporter) {}
        XCTAssertNil(failure, String(describing: failure))
        let url = try XCTUnwrap(output, String(describing: failure))
        defer { try? FileManager.default.removeItem(at: url) }
        let asset = AVURLAsset(url: url)
        let reader = try AVAssetReader(asset: asset)
        let track = try XCTUnwrap(asset.tracks(withMediaType: .audio).first)
        let pcm = AVAssetReaderTrackOutput(track: track, outputSettings: ExportAudio.floatPCM(channels: 2))
        reader.add(pcm)
        let samples = AudioBoundarySamples(cut.windows)
        XCTAssertTrue(reader.startReading(), String(describing: reader.error))
        while let buffer = pcm.copyNextSampleBuffer() { try samples.consume(buffer) }
        XCTAssertEqual(reader.status, .completed, String(describing: reader.error))
        samples.printReport("encoded-export-short")
        check(samples, silence: 0.003)
    }

    private func fixture() throws -> URL {
        try XCTUnwrap(Bundle(for: Self.self).url(forResource: "portrait-full-range", withExtension: "mp4",
                                                subdirectory: "Fixtures"))
    }

    private func makePlan(_ cut: Cut) throws -> ExportPlan {
        func sound(_ at: Double, _ from: Double, _ dur: Double, _ gain: Double) -> [String: Any] {
            ["media": "tone", "at": at, "from": from, "dur": dur, "volume": gain,
             "keys": [["at": at, "g": gain], ["at": at + dur, "g": gain]]]
        }
        let start = max(0, cut.at - 2.998)
        let matrix: [Double] = [180, 0, 0, 320, 0, 0, 1]
        return try XCTUnwrap(ExportPlan(json: [
            "width": 180, "height": 320, "fps": 30, "frames": Int(ceil(cut.total * 30)),
            "codec": "h264", "bitrate": 500_000, "save": false,
            "media": [["id": "video", "url": "ryndi-media://orig/video.mp4"],
                      ["id": "tone", "url": "ryndi-media://orig/tone.m4a"]],
            "layers": [["items": [["media": "video", "at": 0, "from": 0, "dur": min(1, cut.total),
                                     "k0": 0, "frames": [matrix]]]]],
            "sounds": [sound(start, 0, cut.at - start, 1),
                       sound(cut.at, 3.5, cut.muted, 0), sound(cut.end, 6.5, 0.3, 1)] ]))
    }

    private func toneSource(_ folder: URL) async throws -> URL {
        let caf = folder.appendingPathComponent("tones.caf")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8 * 48000))
        buffer.frameLength = buffer.frameCapacity
        let data = try XCTUnwrap(buffer.floatChannelData)
        for frame in 0..<Int(buffer.frameLength) {
            let t = Double(frame) / 48000
            let frequency = t < 3 ? 440.0 : t < 6 ? 880.0 : 1320.0
            let value = Float(0.15 * sin(2 * Double.pi * frequency * t))
            data[0][frame] = value
            data[1][frame] = value
        }
        do { let file = try AVAudioFile(forWriting: caf, settings: format.settings); try file.write(from: buffer) }
        let asset = AVURLAsset(url: caf)
        let encoder = try XCTUnwrap(AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A))
        let url = folder.appendingPathComponent("tone.m4a")
        encoder.outputURL = url
        encoder.outputFileType = .m4a
        let done = expectation(description: "encode AAC fixture")
        encoder.exportAsynchronously { done.fulfill() }
        await fulfillment(of: [done], timeout: 20)
        XCTAssertEqual(encoder.status, .completed, String(describing: encoder.error))
        return url
    }

    private func useSteps(_ cut: Cut, in assembly: PlanAssembly) throws {
        let track = try XCTUnwrap(assembly.comp.tracks(withMediaType: .audio).first)
        let parameters = AVMutableAudioMixInputParameters(track: track)
        parameters.setVolume(1, at: .zero)
        parameters.setVolume(0, at: CMTime(seconds: cut.at, preferredTimescale: 30000))
        parameters.setVolume(1, at: CMTime(seconds: cut.end, preferredTimescale: 30000))
        assembly.mix.inputParameters = [parameters]
    }

    private func printRamps(_ cut: Cut, in assembly: PlanAssembly, label: String) {
        guard let parameters = assembly.mix.inputParameters.first else { return }
        for position in [cut.at - 0.01, cut.at + 0.001, cut.at + 0.05, cut.end + 0.1] {
            var from: Float = -1, to: Float = -1, range = CMTimeRange.invalid
            let found = parameters.getVolumeRamp(for: CMTime(seconds: position, preferredTimescale: 30000),
                                                  startVolume: &from, endVolume: &to, timeRange: &range)
            print("MUTE-RAMP \(label) at=\(position) found=\(found) from=\(from) to=\(to) " +
                  "start=\(CMTimeGetSeconds(range.start)) dur=\(CMTimeGetSeconds(range.duration))")
        }
    }

    private func verifyReader(_ cut: Cut, steps: Bool = false) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let audio = try await toneSource(folder), temps = TempFiles()
        defer { temps.removeAll() }
        let assembly = try NativeExporter.assemble(makePlan(cut), ["video": fixture(), "tone": audio], temps: temps)
        if steps { try useSteps(cut, in: assembly) }
        let label = "decoded-mix-\(cut.at)" + (steps ? "-steps" : "")
        printRamps(cut, in: assembly, label: label)
        let reader = try AVAssetReader(asset: assembly.comp)
        let pcm = AVAssetReaderAudioMixOutput(audioTracks: assembly.comp.tracks(withMediaType: .audio),
                                             audioSettings: ExportAudio.floatPCM(channels: 2))
        pcm.audioMix = assembly.mix
        reader.timeRange = CMTimeRange(start: CMTime(seconds: max(0, cut.at - 0.15), preferredTimescale: 30000),
                                       end: assembly.total)
        reader.add(pcm)
        let samples = AudioBoundarySamples(cut.windows)
        XCTAssertTrue(reader.startReading(), String(describing: reader.error))
        while let buffer = pcm.copyNextSampleBuffer() { try samples.consume(buffer) }
        XCTAssertEqual(reader.status, .completed, String(describing: reader.error))
        samples.printReport(label)
        check(samples, silence: 0.00001)
    }

    private func verifyPlayer(_ cut: Cut, wholeMute: Bool = false) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let audio = try await toneSource(folder), temps = TempFiles()
        defer { temps.removeAll() }
        let assembly = try NativeExporter.assemble(makePlan(cut), ["video": fixture(), "tone": audio], temps: temps)
        if wholeMute {
            let track = try XCTUnwrap(assembly.comp.tracks(withMediaType: .audio).first)
            let parameters = AVMutableAudioMixInputParameters(track: track)
            parameters.setVolume(0, at: .zero)
            assembly.mix.inputParameters = [parameters]
        }
        let windows = wholeMute ? cut.windows.map {
            AudioBoundarySamples.Window(name: "muted-control-" + $0.name, start: $0.start, end: $0.end)
        } : cut.windows
        let samples = AudioBoundarySamples(windows)
        // There is one non-overlapping source track, as in the reported cut.
        XCTAssertEqual(assembly.mix.inputParameters.count, 1)
        for parameter in assembly.mix.inputParameters {
            let mutable = try XCTUnwrap(parameter as? AVMutableAudioMixInputParameters)
            mutable.audioTapProcessor = try samples.makePostMixTap()
        }
        let item = AVPlayerItem(asset: assembly.comp)
        item.audioMix = assembly.mix
        item.audioTimePitchAlgorithm = .spectral
        item.forwardPlaybackEndTime = assembly.total
        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = false
        defer { player.pause(); player.replaceCurrentItem(with: nil) }
        let sought = expectation(description: "seek before mute boundary")
        player.seek(to: CMTime(seconds: max(0, cut.at - 0.2), preferredTimescale: 30000),
                    toleranceBefore: .zero, toleranceAfter: .zero) { _ in sought.fulfill() }
        await fulfillment(of: [sought], timeout: 15)
        let ended = expectation(description: "native player reaches restored clip")
        let token = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                                                           object: item, queue: .main) { _ in ended.fulfill() }
        defer { NotificationCenter.default.removeObserver(token) }
        player.playImmediately(atRate: 1)
        await fulfillment(of: [ended], timeout: cut.muted + 15)
        player.pause()
        withExtendedLifetime(samples) {}
        XCTAssertNil(item.error, String(describing: item.error))
        samples.printReport("avplayer-post-mix-\(cut.at)" + (wholeMute ? "-whole-muted-control" : ""))
        XCTAssertTrue(samples.errors.isEmpty, samples.errors.joined(separator: ", "))
        check(samples, silence: 0.00001)
    }

    private func check(_ samples: AudioBoundarySamples, silence: Double,
                       file: StaticString = #filePath, line: UInt = #line) {
        for (window, reading) in zip(samples.windows, samples.snapshot()) {
            XCTAssertGreaterThan(reading.count, 400, "missing PCM in \(window.name)", file: file, line: line)
            if window.name.hasPrefix("muted") {
                XCTAssertLessThan(reading.rms, silence, "audible muted clip: \(window.name)", file: file, line: line)
            } else {
                XCTAssertGreaterThan(reading.rms, 0.025, "audible control must produce sound: \(window.name)", file: file, line: line)
            }
        }
    }
}
