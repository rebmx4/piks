import XCTest
import AVFoundation
import CoreVideo

// Frame output is deliberately checked separately from the AVPlayer clock.
// This test uses the shipped compositor, not a simulated native bridge.
final class PreviewCutPlaybackTests: XCTestCase {
    private func plan(cut: Bool) throws -> ExportPlan {
        let spans: [(Double, Double, Double)] = cut
            ? [(0, 18.388, 9.098), (9.098, 28.164, 3.489), (12.587, 31.653, 8.347)]
            : [(0, 0, 40)]
        let duration = cut ? 20.934 : 40.0
        let items: [[String: Any]] = spans.map { at, from, dur in
            ["media": "m1", "at": at, "from": from, "dur": dur,
             "k0": Int((at * 30).rounded()), "frames": [[1280, 0, 0, 720, 0, 0, 1]]]
        }
        return try XCTUnwrap(ExportPlan(json: [
            "width": 1280, "height": 720, "fps": 30,
            "frames": Int((duration * 30).rounded()), "bitrate": 4_000_000,
            "codec": "h264", "save": false,
            "media": [["id": "m1", "url": "ryndi-media://orig/pprobe.mp4"]],
            "layers": [["items": items]],
            "sounds": spans.map { at, from, dur in
                ["media": "m1", "at": at, "from": from, "dur": dur, "volume": 1]
            },
        ]))
    }

    private func source() throws -> URL {
        try XCTUnwrap(Bundle(for: Self.self).url(forResource: "cut-4k42210",
            withExtension: "mov", subdirectory: "Fixtures"))
    }

    private func proxy(_ input: URL) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        let export = try XCTUnwrap(AVAssetExportSession(asset: AVURLAsset(url: input),
            presetName: AVAssetExportPreset1920x1080))
        export.outputURL = url
        export.outputFileType = .mp4
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            export.exportAsynchronously { done.resume() }
        }
        XCTAssertEqual(export.status, .completed, String(describing: export.error))
        guard export.status == .completed else { throw export.error ?? ExportError("proxy failed") }
        return url
    }

    @MainActor
    private func verify(_ input: URL, cut: Bool, label: String) async throws {
        let temps = TempFiles()
        defer { temps.removeAll() }
        let assembly = try NativeExporter.assemble(plan(cut: cut), ["m1": input], temps: temps)
        let item = AVPlayerItem(asset: assembly.comp)
        item.videoComposition = assembly.video
        item.audioMix = assembly.mix
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        item.add(output)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        player.automaticallyWaitsToMinimizeStalling = false
        defer { player.pause(); player.replaceCurrentItem(with: nil) }
        let readyUntil = Date().addingTimeInterval(12)
        while item.status == .unknown && Date() < readyUntil {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(item.status, .readyToPlay, String(describing: item.error))
        guard item.status == .readyToPlay else { return }
        // Cross both non-frame-aligned edits, seek backward, then resume again.
        for (start, seconds) in [(8.70, 1.4), (12.30, 1.2), (8.593, 1.4), (14.406, 1.0)] {
            player.pause()
            let seeked = await player.seek(to: CMTime(seconds: start, preferredTimescale: 30000),
                toleranceBefore: .zero, toleranceAfter: .zero)
            XCTAssertTrue(seeked, label + " seek must finish")
            player.playImmediately(atRate: 1)
            let until = Date().addingTimeInterval(seconds + 3)
            let asked = Date()
            var frames: [Double] = [], lastWall: Date?, maxGap = 0.0, firstMs = -1.0, stale = 0
            while Date() < until && item.status != .failed {
                let position = player.currentTime()
                var displayed = CMTime.invalid
                if output.hasNewPixelBuffer(forItemTime: position),
                   output.copyPixelBuffer(forItemTime: position, itemTimeForDisplay: &displayed) != nil,
                   displayed.isNumeric {
                    // VideoOutput may still return a buffered image from before
                    // seek. It is not evidence of a frame at the requested time.
                    if displayed.seconds >= start - 1.0 / 30 && displayed.seconds <= position.seconds + 0.1 {
                        frames.append(displayed.seconds)
                        if let previous = lastWall { maxGap = max(maxGap, Date().timeIntervalSince(previous)) }
                        else { firstMs = Date().timeIntervalSince(asked) * 1000 }
                        lastWall = Date()
                    } else { stale += 1 }
                }
                if position.isNumeric && position.seconds >= start + seconds { break }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            let end = player.currentTime().seconds
            print("CUT-PREVIEW \(label) start=\(start) clock=\(end) frames=\(frames.count) first=\(frames.first ?? -1) last=\(frames.last ?? -1) startupMs=\(firstMs) stale=\(stale) maxGap=\(maxGap)")
            XCTAssertNotEqual(item.status, .failed, String(describing: item.error))
            XCTAssertGreaterThan(end, start + seconds - 0.15, label + " clock")
            XCTAssertGreaterThan(frames.count, 8, label + " must produce changing video samples")
            XCTAssertGreaterThanOrEqual(firstMs, 0, label + " must return a frame at the requested source time")
            XCTAssertLessThan(firstMs, 5000, label + " must meet the shipped startup deadline")
            XCTAssertTrue(frames.contains { $0 > start + seconds - 0.25 }, label + " final frame must catch the clock")
            XCTAssertLessThan(maxGap, 1.5, label + " cannot hold a frame for seconds")
        }
    }

    @MainActor
    func test4KOriginalAndProxyAfterCutsAndRepeatedSeeks() async throws {
        let original = try source()
        let sourceTrack = try XCTUnwrap(AVURLAsset(url: original).tracks(withMediaType: .video).first)
        XCTAssertEqual(sourceTrack.naturalSize, CGSize(width: 3840, height: 2160))
        try await verify(original, cut: false, label: "original-uncut")
        async let pendingCopy = proxy(original)
        try await verify(original, cut: true, label: "original-cut-during-proxy")
        let copy = try await pendingCopy
        defer { try? FileManager.default.removeItem(at: copy) }
        try await verify(copy, cut: true, label: "proxy-cut")
    }
}
