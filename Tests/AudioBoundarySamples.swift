import AVFoundation
import MediaToolbox
import XCTest

// Test-only PCM measurement. No microphone or audio recording is used.
final class AudioBoundarySamples {
    struct Window {
        let name: String
        let start: Double
        let end: Double
    }
    struct Reading {
        var count = 0
        var square = 0.0
        var peak = 0.0
        var firstNonzero: Double?
        var rms: Double { sqrt(square / Double(max(1, count))) }
    }
    let windows: [Window]
    private let lock = NSLock()
    private var readings: [Reading]
    private var format = AudioStreamBasicDescription()
    private var failures: [String] = []
    var errors: [String] {
        lock.lock()
        defer { lock.unlock() }
        return failures
    }
    private func recordError(_ value: String) {
        lock.lock()
        failures.append(value)
        lock.unlock()
    }

    init(_ windows: [Window]) {
        self.windows = windows
        readings = windows.map { _ in Reading() }
    }

    func consume(_ values: UnsafeBufferPointer<Float>, channels: Int, start: Double, rate: Double) {
        lock.lock()
        defer { lock.unlock() }
        for w in windows.indices {
            let low = max(0, Int(ceil((windows[w].start - start) * rate))) * channels
            let high = min(values.count, max(0, Int(ceil((windows[w].end - start) * rate))) * channels)
            if high <= low { continue }
            for i in low..<high {
                let value = abs(Double(values[i]))
                readings[w].count += 1
                readings[w].square += value * value
                readings[w].peak = max(readings[w].peak, value)
                if value > 0.00001 && readings[w].firstNonzero == nil {
                    readings[w].firstNonzero = start + Double(i / channels) / rate
                }
            }
        }
    }

    func consume(_ sample: CMSampleBuffer) throws {
        let description = try XCTUnwrap(CMSampleBufferGetFormatDescription(sample))
        let asbd = try XCTUnwrap(CMAudioFormatDescriptionGetStreamBasicDescription(description)).pointee
        let data = try XCTUnwrap(CMSampleBufferGetDataBuffer(sample))
        var values = [Float](repeating: 0, count: CMBlockBufferGetDataLength(data) / 4)
        let status = values.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(data, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
        }
        XCTAssertEqual(status, kCMBlockBufferNoErr)
        values.withUnsafeBufferPointer {
            consume($0, channels: Int(asbd.mChannelsPerFrame),
                    start: CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)), rate: asbd.mSampleRate)
        }
    }

    func snapshot() -> [Reading] {
        lock.lock()
        defer { lock.unlock() }
        return readings
    }

    func printReport(_ label: String) {
        let rows = zip(windows, snapshot()).map { window, reading -> [String: Any] in
            ["window": window.name, "from": window.start, "to": window.end,
             "samples": reading.count, "rms": reading.rms, "peak": reading.peak,
             "firstNonzero": reading.firstNonzero as Any]
        }
        let object: [String: Any] = ["case": label, "windows": rows, "errors": errors]
        // JSONSerialization cannot encode Optional.none.
        let safeRows = rows.map { row -> [String: Any] in
            var row = row
            if let value = row["firstNonzero"] as? Double { row["firstNonzero"] = value }
            else { row["firstNonzero"] = NSNull() }
            return row
        }
        var safe = object
        safe["windows"] = safeRows
        if let data = try? JSONSerialization.data(withJSONObject: safe, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) { print("MUTE-PCM " + text) }
    }

    private func prepare(_ value: AudioStreamBasicDescription) {
        format = value
        if value.mFormatID != kAudioFormatLinearPCM || value.mBitsPerChannel != 32 ||
            value.mFormatFlags & kAudioFormatFlagIsFloat == 0 {
            recordError("Unexpected tap PCM format")
        }
    }

    private func consume(_ buffers: UnsafeMutablePointer<AudioBufferList>, frames: CMItemCount, range: CMTimeRange) {
        guard format.mSampleRate > 0, format.mFormatFlags & kAudioFormatFlagIsFloat != 0 else { return }
        let start = CMTimeGetSeconds(range.start)
        guard start.isFinite else { return }
        for buffer in UnsafeMutableAudioBufferListPointer(buffers) {
            guard let data = buffer.mData else { continue }
            let channels = max(1, Int(buffer.mNumberChannels))
            let count = min(Int(buffer.mDataByteSize) / 4, Int(frames) * channels)
            consume(UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: count),
                    channels: channels, start: start, rate: format.mSampleRate)
        }
    }

    func makeSourceTap() throws -> MTAudioProcessingTap {
        let owner = Unmanaged.passRetained(self)
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: owner.toOpaque(),
            init: { _, info, storage in storage.pointee = info },
            finalize: { tap in
                Unmanaged<AudioBoundarySamples>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
            },
            prepare: { tap, _, format in
                Unmanaged<AudioBoundarySamples>.fromOpaque(MTAudioProcessingTapGetStorage(tap))
                    .takeUnretainedValue().prepare(format.pointee)
            },
            unprepare: nil,
            process: { tap, frames, _, buffers, outFrames, outFlags in
                var range = CMTimeRange.invalid
                let status = MTAudioProcessingTapGetSourceAudio(tap, frames, buffers, outFlags, &range, outFrames)
                let owner = Unmanaged<AudioBoundarySamples>.fromOpaque(MTAudioProcessingTapGetStorage(tap))
                    .takeUnretainedValue()
                if status == noErr { owner.consume(buffers, frames: outFrames.pointee, range: range) }
                else { owner.recordError("Tap source status \(status)") }
            })
        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks,
                                               kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
        if status != noErr { owner.release() }
        XCTAssertEqual(status, noErr)
        return try XCTUnwrap(tap)
    }
}
