import XCTest
import AVFoundation
import CoreImage
import AudioToolbox

// Реальные видео и звук, без подмены декодера или кодировщика.
final class ReverseMediaTests: XCTestCase {
    private func waitForInput(_ input: AVAssetWriterInput) {
        let deadline = Date().addingTimeInterval(10)
        while !input.isReadyForMoreMediaData && Date() < deadline { Thread.sleep(forTimeInterval: 0.002) }
    }
    private func fixture(_ dir: URL, sound: Bool = true, width: Int = 320, height: Int = 180,
                         fps: Int32 = 10, seconds: Int = 2, motion: Bool = false) throws -> URL {
        let started = Date(), frames = Int(fps) * seconds
        let duration = CMTime(seconds: Double(seconds), preferredTimescale: 600)
        let videoURL = dir.appendingPathComponent("video.mov")
        let writer = try AVAssetWriter(outputURL: videoURL, fileType: .mov)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAllowFrameReorderingKey: false]])
        video.transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: CGFloat(height), ty: 0)
        writer.add(video)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferCGImageCompatibilityKey as String: true, kCVPixelBufferCGBitmapContextCompatibilityKey as String: true])
        XCTAssertTrue(writer.startWriting()); writer.startSession(atSourceTime: .zero)
        func solid(_ color: UInt32, bar: Int? = nil) throws -> CVPixelBuffer {
            var raw: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &raw), kCVReturnSuccess)
            let pixels = try XCTUnwrap(raw)
            CVPixelBufferLockBaseAddress(pixels, [])
            let base = CVPixelBufferGetBaseAddress(pixels)!
            let stride = CVPixelBufferGetBytesPerRow(pixels)
            var row = [UInt32](repeating: color, count: width)
            if let bar = bar {
                for x in bar..<min(width, bar + max(1, width / 20)) { row[x] = 0xffffffff }
            }
            row.withUnsafeBytes { bytes in
                for y in 0..<height { memcpy(base.advanced(by: y * stride), bytes.baseAddress!, width * 4) }
            }
            CVPixelBufferUnlockBaseAddress(pixels, [])
            return pixels
        }
        let red = try solid(0xffff0000), blue = try solid(0xff0000ff)
        for k in 0..<frames {
            try autoreleasepool {
                let pixels = motion ? try solid(k < frames / 2 ? 0xffff0000 : 0xff0000ff,
                    bar: (k * max(1, width / 37)) % (width - max(1, width / 20))) : (k < frames / 2 ? red : blue)
                waitForInput(video)
                XCTAssertTrue(adaptor.append(pixels, withPresentationTime: CMTime(value: Int64(k), timescale: fps)))
            }
        }
        video.markAsFinished(); writer.endSession(atSourceTime: duration)
        let finished = DispatchSemaphore(value: 0); writer.finishWriting { finished.signal() }
        XCTAssertEqual(finished.wait(timeout: .now() + 20), .success)
        XCTAssertEqual(writer.status, .completed, writer.error?.localizedDescription ?? "")
        print("reverse fixture: video \(width)x\(height), \(seconds)s, \(Date().timeIntervalSince(started))s")
        if !sound { return videoURL }
        let audioURL = dir.appendingPathComponent("sound.caf")
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false)!
        do {
            let file = try AVAudioFile(forWriting: audioURL, settings: format.settings)
            let count = seconds * 48000
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
            buffer.frameLength = AVAudioFrameCount(count)
            for k in 0..<count {
                let t = Double(k) / 48000, hz = k < count / 2 ? 400.0 : 900.0
                let v = Float(sin(2 * .pi * hz * t))
                buffer.floatChannelData![0][k] = v * 0.4; buffer.floatChannelData![1][k] = v * 0.08
            }
            try file.write(from: buffer)
        }
        let vAsset = AVURLAsset(url: videoURL), aAsset = AVURLAsset(url: audioURL)
        let composition = AVMutableComposition()
        let vt = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
        let original = vAsset.tracks(withMediaType: .video)[0]
        try vt.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: original, at: .zero)
        vt.preferredTransform = original.preferredTransform
        let at = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
        try at.insertTimeRange(CMTimeRange(start: .zero, duration: duration),
                               of: aAsset.tracks(withMediaType: .audio)[0], at: .zero)
        let result = dir.appendingPathComponent("source.mp4")
        let preset = width >= 1920 ? AVAssetExportPreset1920x1080 : AVAssetExportPresetHighestQuality
        let export = try XCTUnwrap(AVAssetExportSession(asset: composition, presetName: preset))
        export.outputURL = result; export.outputFileType = .mp4
        export.shouldOptimizeForNetworkUse = true
        let exported = DispatchSemaphore(value: 0); export.exportAsynchronously { exported.signal() }
        XCTAssertEqual(exported.wait(timeout: .now() + 30), .success)
        XCTAssertEqual(export.status, .completed, export.error?.localizedDescription ?? "")
        print("reverse fixture: AAC proxy exported, \(Date().timeIntervalSince(started))s")
        return result
    }
    private func directory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("reverse-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private func color(_ url: URL, at t: Double) throws -> [UInt8] {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url)); generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        let image = try generator.copyCGImage(at: CMTime(seconds: t, preferredTimescale: 600000), actualTime: nil)
        var bytes = [UInt8](repeating: 0, count: 4)
        bytes.withUnsafeMutableBytes {
            let ctx = CGContext(data: $0.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return bytes
    }
    private func audio(_ url: URL, from: Double) throws -> [[Float]] {
        let asset = AVURLAsset(url: url), reader = try AVAssetReader(asset: asset)
        let track = try XCTUnwrap(asset.tracks(withMediaType: .audio).first)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false])
        reader.timeRange = CMTimeRange(start: CMTime(seconds: from, preferredTimescale: 600000),
                                      duration: CMTime(seconds: 0.2, preferredTimescale: 600000))
        reader.add(out); XCTAssertTrue(reader.startReading())
        var channels = [[Float](), [Float]()]
        while let sample = out.copyNextSampleBuffer() {
            let n = CMSampleBufferGetNumSamples(sample), block = try XCTUnwrap(CMSampleBufferGetDataBuffer(sample))
            var data = [Float](repeating: 0, count: n * 2)
            let status = data.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0,
                dataLength: n * 8, destination: $0.baseAddress!) }
            XCTAssertEqual(status, kCMBlockBufferNoErr)
            for i in 0..<n { channels[0].append(data[i * 2]); channels[1].append(data[i * 2 + 1]) }
        }
        return channels
    }
    private func power(_ samples: [Float], hz: Double) -> Double {
        var re = 0.0, im = 0.0
        for (k, s) in samples.enumerated() { let a = 2 * .pi * hz * Double(k) / 48000; re += Double(s) * cos(a); im += Double(s) * sin(a) }
        return re * re + im * im
    }
    func testNativeErrorDiagnosticsPreserveUnderlyingCause() throws {
        let cause = NSError(domain: NSOSStatusErrorDomain, code: -12345,
                            userInfo: ["NSDebugDescription": "decoder test failure"])
        let error = NSError(domain: AVFoundationErrorDomain, code: -11800,
                            userInfo: [NSUnderlyingErrorKey: cause])
        let details = ReverseMedia().failureDetails(error)
        let chain = try XCTUnwrap(details["errors"] as? [[String: Any]])
        XCTAssertEqual(chain.count, 2)
        XCTAssertEqual(chain[0]["domain"] as? String, AVFoundationErrorDomain)
        XCTAssertEqual(chain[0]["code"] as? Int, -11800)
        XCTAssertEqual(chain[1]["code"] as? Int, -12345)
        XCTAssertEqual(chain[1]["debugDescription"] as? String, "decoder test failure")
        XCTAssertTrue(JSONSerialization.isValidJSONObject(details), "диагностика должна передаваться через мост без потери NSError")
    }
    func test1080AACReverseAcrossDecoderBlocks() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = try fixture(dir, width: 1920, height: 1080, fps: 30)
        let asset = AVURLAsset(url: source), sound = try XCTUnwrap(asset.tracks(withMediaType: .audio).first)
        let desc = try XCTUnwrap(sound.formatDescriptions.first) as! CMAudioFormatDescription
        let format = try XCTUnwrap(CMAudioFormatDescriptionGetStreamBasicDescription(desc))
        XCTAssertEqual(format.pointee.mFormatID, kAudioFormatMPEG4AAC, "проверяем сжатый AAC-звук, как в лёгкой копии")
        let originalSize = try FileManager.default.attributesOfItem(atPath: source.path)[.size] as? NSNumber
        let destination = dir.appendingPathComponent("reversed-1080.mp4"), engine = ReverseMedia(), started = Date()
        let info: ReverseMedia.Info
        do { info = try engine.run(source: source, destination: destination, from: 0.2, duration: 1.6, progress: { _ in }) }
        catch { XCTFail("1080p AAC reverse: \(engine.failureDetails(error))"); throw error }
        XCTAssertLessThan(Date().timeIntervalSince(started), 25, "реверс проходит несколько блоков без ожидания таймаута")
        XCTAssertEqual(info.width, 1080); XCTAssertEqual(info.height, 1920)
        XCTAssertEqual(AVURLAsset(url: destination).duration.seconds, 1.6, accuracy: 0.05)
        let first = try color(destination, at: 0.1), last = try color(destination, at: 1.5)
        XCTAssertGreaterThan(first[2], 180); XCTAssertGreaterThan(last[0], 180)
        let early = try audio(destination, from: 0.12), late = try audio(destination, from: 1.1)
        XCTAssertGreaterThan(power(early[0], hz: 900), power(early[0], hz: 400) * 4)
        XCTAssertGreaterThan(power(late[0], hz: 400), power(late[0], hz: 900) * 4)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: source.path)[.size] as? NSNumber, originalSize)
    }
    func test15SecondMovingAACProxyFullAndTrimmedReverse() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        // Та же конфигурация MP4-копии, что у PreviewCopies: 1080p, AAC,
        // optimizeForNetworkUse. Движение и длинный звук пересекают много блоков.
        let source = try fixture(dir, width: 1920, height: 1080, fps: 30, seconds: 15, motion: true)
        let asset = AVURLAsset(url: source)
        let inputSize = try FileManager.default.attributesOfItem(atPath: source.path)[.size] as? NSNumber
        let track = try XCTUnwrap(asset.tracks(withMediaType: .video).first)
        XCTAssertEqual(track.naturalSize, CGSize(width: 1920, height: 1080))
        let audioTrack = try XCTUnwrap(asset.tracks(withMediaType: .audio).first)
        let description = try XCTUnwrap(audioTrack.formatDescriptions.first) as! CMAudioFormatDescription
        let format = try XCTUnwrap(CMAudioFormatDescriptionGetStreamBasicDescription(description))
        XCTAssertEqual(format.pointee.mFormatID, kAudioFormatMPEG4AAC)
        XCTAssertTrue([44100.0, 48000.0].contains(format.pointee.mSampleRate), "1080p-предустановка может пересчитать звук в 44,1 кГц")
        XCTAssertEqual(format.pointee.mChannelsPerFrame, 2)
        for (index, range) in [(0.0, 15.0), (0.6, 13.7)].enumerated() {
            let destination = dir.appendingPathComponent("long-\(index).mp4"), engine = ReverseMedia(), started = Date()
            let info: ReverseMedia.Info
            do { info = try engine.run(source: source, destination: destination, from: range.0,
                                      duration: range.1, progress: { _ in }) }
            catch { XCTFail("15s AAC reverse: \(engine.failureDetails(error))"); throw error }
            print("reverse long: from \(range.0), duration \(range.1), \(Date().timeIntervalSince(started))s")
            XCTAssertLessThan(Date().timeIntervalSince(started), 60)
            XCTAssertEqual(info.width, 1080); XCTAssertEqual(info.height, 1920)
            XCTAssertEqual(AVURLAsset(url: destination).duration.seconds, range.1, accuracy: 0.05)
            let written = try videoTimes(destination)
            XCTAssertEqual(written.count, Int((range.1 * 30).rounded()), "ни один видеокадр не должен потеряться или дублироваться на границе блока")
            XCTAssertTrue(zip(written, written.dropFirst()).allSatisfy { pair in CMTimeCompare(pair.0, pair.1) < 0 },
                          "временные отметки видео должны строго возрастать")
            let first = try color(destination, at: 0.12), last = try color(destination, at: range.1 - 0.12)
            XCTAssertGreaterThan(first[2], 180); XCTAssertGreaterThan(last[0], 180)
            let early = try audio(destination, from: 0.12), late = try audio(destination, from: range.1 - 0.32)
            XCTAssertGreaterThan(power(early[0], hz: 900), power(early[0], hz: 400) * 4)
            XCTAssertGreaterThan(power(late[0], hz: 400), power(late[0], hz: 900) * 4)
            let left = early[0].reduce(0.0) { $0 + Double($1 * $1) }, right = early[1].reduce(0.0) { $0 + Double($1 * $1) }
            XCTAssertGreaterThan(left, right * 3)
        }
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: source.path)[.size] as? NSNumber, inputSize)
    }
    private func videoTimes(_ url: URL) throws -> [CMTime] {
        let asset = AVURLAsset(url: url), reader = try AVAssetReader(asset: asset)
        let track = try XCTUnwrap(asset.tracks(withMediaType: .video).first)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output); XCTAssertTrue(reader.startReading())
        var times: [CMTime] = []
        while let sample = output.copyNextSampleBuffer() { times.append(CMSampleBufferGetPresentationTimeStamp(sample)) }
        XCTAssertEqual(reader.status, .completed, reader.error?.localizedDescription ?? "")
        // Сжатые пакеты читаются в порядке декодирования, который для HEVC
        // может отличаться от порядка показа. Проверяем уникальные PTS показа.
        return times.sorted { CMTimeCompare($0, $1) < 0 }
    }
    func testTrimmedReversePreservesResolutionAndReversesVideoAndStereoAudio() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = try fixture(dir), destination = dir.appendingPathComponent("reversed.mp4")
        let originalSize = try FileManager.default.attributesOfItem(atPath: source.path)[.size] as? NSNumber
        let started = Date()
        let info = try ReverseMedia().run(source: source, destination: destination, from: 0.5, duration: 1, progress: { _ in })
        XCTAssertLessThan(Date().timeIntervalSince(started), 25, "короткий реверс со звуком не должен ждать таймаут кодировщика")
        XCTAssertEqual(info.duration, 1)
        let originalTrack = AVURLAsset(url: source).tracks(withMediaType: .video)[0]
        let originalDimensions = originalTrack.naturalSize.applying(originalTrack.preferredTransform)
        XCTAssertEqual(info.width, Int(abs(originalDimensions.width))); XCTAssertEqual(info.height, Int(abs(originalDimensions.height)))
        XCTAssertEqual(AVURLAsset(url: destination).duration.seconds, 1, accuracy: 0.05)
        let first = try color(destination, at: 0.1), last = try color(destination, at: 0.9)
        XCTAssertGreaterThan(first[2], 180, "первым должен быть синий кадр конца фрагмента")
        XCTAssertLessThan(first[0], 70)
        XCTAssertGreaterThan(last[0], 180, "последним должен быть красный кадр начала фрагмента")
        let early = try audio(destination, from: 0.12), late = try audio(destination, from: 0.68)
        XCTAssertGreaterThan(power(early[0], hz: 900), power(early[0], hz: 400) * 4)
        XCTAssertGreaterThan(power(late[0], hz: 400), power(late[0], hz: 900) * 4)
        let left = early[0].reduce(0.0) { $0 + Double($1 * $1) }, right = early[1].reduce(0.0) { $0 + Double($1 * $1) }
        XCTAssertGreaterThan(left, right * 3, "каналы должны сохранить свои места")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: source.path)[.size] as? NSNumber, originalSize)
    }
    func testSilentVideoAndCancellation() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = try fixture(dir, sound: false), destination = dir.appendingPathComponent("silent.mp4")
        _ = try ReverseMedia().run(source: source, destination: destination, from: 0, duration: 0.5, progress: { _ in })
        XCTAssertTrue(AVURLAsset(url: destination).tracks(withMediaType: .audio).isEmpty)
        let cancelled = ReverseMedia(); cancelled.cancel()
        let unused = dir.appendingPathComponent("cancelled.mp4")
        XCTAssertThrowsError(try cancelled.run(source: source, destination: unused, from: 0, duration: 0.5, progress: { _ in }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: unused.path))
    }
}
