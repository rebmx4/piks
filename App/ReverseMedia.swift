import Foundation
import AVFoundation
import AudioToolbox
import VideoToolbox

// Реверс локального фрагмента. Декодированные кадры держим только коротким
// блоком, PCM-звук — одной секундой; готовый файл играет обычный AVPlayer.
// Оригинал не перезаписывается. У результата те же разрешение, поворот и HDR.
final class ReverseMedia {
    struct Info {
        let duration: Double
        let width: Int
        let height: Int
        let fps: Double
        let transfer: String
    }
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    private struct Frame {
        let start: CMTime
        let end: CMTime
    }
    private let lock = NSLock()
    private var cancelled = false
    private var currentWriter: AVAssetWriter?
    private var context: [String: Any] = ["phase": "not-started"]
    private final class AudioFeed {
        private let lock = NSLock()
        private var failure: Error?
        func fail(_ error: Error) { lock.lock(); failure = error; lock.unlock() }
        func check() throws { lock.lock(); let error = failure; lock.unlock(); if let error = error { throw error } }
    }

    func cancel() {
        lock.lock(); cancelled = true; let w = currentWriter; lock.unlock()
        w?.cancelWriting()
    }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    private func check() throws {
        if isCancelled { throw Failure(message: "Реверсия отменена") }
    }
    private func time(_ t: Double) -> CMTime { CMTime(seconds: t, preferredTimescale: 600000) }

    private func mark(_ phase: String, _ fields: [String: Any] = [:]) {
        lock.lock(); defer { lock.unlock() }
        context["phase"] = phase
        context.merge(fields) { _, new in new }
    }

    private static func errorChain(_ error: Error) -> [[String: Any]] {
        var errors: [[String: Any]] = [], current: NSError? = error as NSError
        while let cause = current, errors.count < 5 {
            var entry: [String: Any] = ["domain": cause.domain, "code": cause.code,
                                      "description": String(cause.localizedDescription.prefix(800))]
            for (key, name) in [(NSLocalizedFailureReasonErrorKey, "failureReason"),
                                ("NSDebugDescription", "debugDescription")] {
                if let value = cause.userInfo[key] as? String { entry[name] = String(value.prefix(800)) }
            }
            errors.append(entry)
            current = cause.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return errors
    }

    func failureDetails(_ error: Error) -> [String: Any] {
        lock.lock(); var details = context; lock.unlock()
        details["errors"] = Self.errorChain(error)
        return details
    }

    private func audioFailure(_ error: Error, phase: String) {
        let details: [String: Any] = ["phase": phase, "errors": Self.errorChain(error)]
        lock.lock(); context["audioFailure"] = details; lock.unlock()
    }

    func run(source: URL, destination: URL, from: Double, duration: Double,
             progress: @escaping (Double) -> Void) throws -> Info {
        mark("source-open")
        try check()
        let asset = AVURLAsset(url: source)
        guard from.isFinite, duration.isFinite, from >= 0, duration > 0,
              from + duration <= asset.duration.seconds + 0.05,
              let track = asset.tracks(withMediaType: .video).first else {
            throw Failure(message: "Неверный участок видео для реверсии")
        }
        let width = Int(abs(track.naturalSize.width)), height = Int(abs(track.naturalSize.height))
        guard width > 0, height > 0 else { throw Failure(message: "Не удалось прочитать размер видео") }
        let fps = max(1, min(240, Double(track.nominalFrameRate > 0 ? track.nominalFrameRate : 30)))
        let ext = track.formatDescriptions.first.map { $0 as! CMFormatDescription }
        let transfer = ext.flatMap { CMFormatDescriptionGetExtension($0, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String } ?? ""
        let hdr = transfer == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String)
            || transfer == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String)
        let pixelFormat = hdr ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        mark("source-format", ["from": from, "duration": duration, "width": width, "height": height, "fps": fps,
                               "sourceCodec": ext.map { CMFormatDescriptionGetMediaSubType($0) } ?? 0,
                               "pixelFormat": pixelFormat, "writerCodec": "hevc", "transfer": transfer])
        let rangeStart = time(from), rangeEnd = time(from + duration)
        mark("video-index")
        let frames = try frameTimes(asset: asset, track: track, from: rangeStart, to: rangeEnd, fps: fps)
        mark("video-index-ready", ["sourceFrames": frames.count])
        let token = UUID().uuidString
        let dir = destination.deletingLastPathComponent()
        let part = dir.appendingPathComponent("reverse-\(token).part.mp4")
        let pcm = dir.appendingPathComponent("reverse-\(token).pcm.caf")
        var committed = false
        defer {
            try? FileManager.default.removeItem(at: part)
            try? FileManager.default.removeItem(at: pcm)
            if !committed { currentWriter?.cancelWriting() }
            lock.lock(); currentWriter = nil; lock.unlock()
        }
        let audioFormat = try asset.tracks(withMediaType: .audio).first.map {
            try reverseAudio(asset: asset, track: $0, from: from, duration: duration, to: pcm, progress: progress)
        }
        try check()
        mark("writer-create")
        let writer = try AVAssetWriter(outputURL: part, fileType: .mp4)
        lock.lock(); currentWriter = writer; lock.unlock()
        writer.shouldOptimizeForNetworkUse = true
        let bitrate = Int(max(8_000_000, max(Double(track.estimatedDataRate) * 1.2, Double(width * height) * fps * 0.22)))
        var compression: [String: Any] = [AVVideoAverageBitRateKey: bitrate, AVVideoMaxKeyFrameIntervalKey: max(1, Int(fps)),
                                        AVVideoAllowFrameReorderingKey: false]
        if hdr { compression[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main10_AutoLevel as String }
        var settings: [String: Any] = [AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width, AVVideoHeightKey: height, AVVideoCompressionPropertiesKey: compression]
        if let desc = ext {
            var color: [String: Any] = [:]
            for (sourceKey, destinationKey) in [(kCMFormatDescriptionExtension_ColorPrimaries, AVVideoColorPrimariesKey),
                (kCMFormatDescriptionExtension_TransferFunction, AVVideoTransferFunctionKey),
                (kCMFormatDescriptionExtension_YCbCrMatrix, AVVideoYCbCrMatrixKey)] {
                if let value = CMFormatDescriptionGetExtension(desc, extensionKey: sourceKey) { color[destinationKey] = value }
            }
            if !color.isEmpty { settings[AVVideoColorPropertiesKey] = color }
        }
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        video.expectsMediaDataInRealTime = false; video.transform = track.preferredTransform
        guard writer.canAdd(video) else { throw Failure(message: "Телефон не кодирует обратное видео в исходном формате") }
        writer.add(video)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: pixelFormat])
        var audio: AVAssetWriterInput?, audioReader: AVAssetReader?, audioOutput: AVAssetReaderTrackOutput?
        if let format = audioFormat {
            mark("audio-reader", ["sampleRate": format.sampleRate, "channels": format.channelCount])
            let sound = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: format.sampleRate, AVNumberOfChannelsKey: format.channelCount, AVEncoderBitRateKey: 256000])
            sound.expectsMediaDataInRealTime = false
            guard writer.canAdd(sound) else { throw Failure(message: "Не удалось подготовить обратный звук") }
            writer.add(sound); audio = sound
            let a = AVURLAsset(url: pcm)
            guard let t = a.tracks(withMediaType: .audio).first else { throw Failure(message: "Обратный звук не сохранился") }
            let reader = try AVAssetReader(asset: a), out = AVAssetReaderTrackOutput(track: t, outputSettings: pcmSettings(format))
            reader.add(out)
            guard reader.startReading() else { throw reader.error ?? Failure(message: "Не удалось открыть обратный звук") }
            audioReader = reader; audioOutput = out
        }
        defer { audioReader?.cancelReading() }
        mark("writer-start")
        guard writer.startWriting() else { throw writer.error ?? Failure(message: "Кодировщик реверсии не запустился") }
        writer.startSession(atSourceTime: .zero)
        // Две независимые подачи: writer может ждать звук, пока видеовход
        // не готов, и наоборот. Последовательная подача стопорила оба входа.
        let audioGroup = DispatchGroup(), feed = AudioFeed()
        if let sound = audio, let out = audioOutput, let reader = audioReader {
            audioGroup.enter()
            DispatchQueue(label: "ryndi.reverse.audio", qos: .userInitiated).async {
                defer { audioGroup.leave() }
                var phase = "audio-read"
                do {
                    while let sample = out.copyNextSampleBuffer() {
                        phase = "audio-write"
                        try autoreleasepool {
                            try self.wait(sound, writer)
                            guard sound.append(sample) else { throw writer.error ?? Failure(message: "Обратный звук не записался") }
                        }
                        phase = "audio-read"
                    }
                    if reader.status == .failed { throw reader.error ?? Failure(message: "Обратный звук не прочитан") }
                    sound.markAsFinished()
                } catch { self.audioFailure(error, phase: phase); feed.fail(error); writer.cancelWriting() }
            }
        }
        var audioDone = false
        defer {
            if !audioDone { writer.cancelWriting(); audioReader?.cancelReading() }
            audioGroup.wait()
        }
        // Консервативный предел 64 МБ: не зависит от длины исходника.
        let blockFrames = max(1, (64 * 1024 * 1024) / max(1, width * height * 4))
        var upper = frames.count, count = 0
        var lastOutputTime = CMTime.invalid
        while upper > 0 {
            try check()
            try feed.check()
            let lower = max(0, upper - blockFrames), block = Array(frames[lower..<upper])
            let lo = block[0].start, hi = block[block.count - 1].end
            try autoreleasepool {
                mark("video-read", ["blockFrom": lo.seconds, "blockTo": hi.seconds, "writtenFrames": count])
                let reader = try AVAssetReader(asset: asset)
                // Границы — реальные границы кадров из индекса. Произвольная
                // граница по секундам резала один кадр на два разных sample,
                // добавляла дубли и приводила к InvalidTimeStamp (-16364).
                reader.timeRange = CMTimeRange(start: lo, end: hi)
                let out = AVAssetReaderTrackOutput(track: track,
                    outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: pixelFormat])
                out.alwaysCopiesSampleData = false
                reader.add(out)
                guard reader.startReading() else { throw reader.error ?? Failure(message: "Кадры видео не читаются") }
                defer { reader.cancelReading() }
                let wanted = Set(block.map { frameKey($0.start) })
                var samples: [Int64: CMSampleBuffer] = [:]
                while let sample = out.copyNextSampleBuffer() {
                    try check()
                    let key = frameKey(CMSampleBufferGetPresentationTimeStamp(sample))
                    if wanted.contains(key), samples[key] == nil { samples[key] = sample }
                }
                if reader.status == .failed { throw reader.error ?? Failure(message: "Чтение кадров прервалось") }
                mark("video-write", ["decodedFrames": samples.count])
                guard samples.count == block.count else { throw Failure(message: "Декодер не вернул все кадры блока реверсии") }
                for frame in block.reversed() {
                    try check()
                    let sourceStart = CMTimeCompare(frame.start, rangeStart) < 0 ? rangeStart : frame.start
                    let sourceEnd = CMTimeCompare(frame.end, rangeEnd) > 0 ? rangeEnd : frame.end
                    guard CMTimeCompare(sourceEnd, sourceStart) > 0,
                          let sample = samples[frameKey(frame.start)],
                          let pixels = CMSampleBufferGetImageBuffer(sample) else { continue }
                    let outputTime = CMTimeSubtract(rangeEnd, sourceEnd)
                    guard !lastOutputTime.isValid || CMTimeCompare(outputTime, lastOutputTime) > 0 else {
                        throw Failure(message: "Временные отметки реверсии не возрастают")
                    }
                    mark("video-write", ["sourceTime": frame.start.seconds,
                                         "sourceDuration": CMTimeSubtract(frame.end, frame.start).seconds,
                                         "outputTime": outputTime.seconds,
                                         "previousOutputTime": lastOutputTime.isValid ? lastOutputTime.seconds : -1])
                    try wait(video, writer)
                    guard adaptor.append(pixels, withPresentationTime: outputTime) else {
                        throw writer.error ?? Failure(message: "Обратный кадр не записался")
                    }
                    lastOutputTime = outputTime; count += 1
                }
            }
            upper = lower
            progress(0.25 + 0.74 * Double(frames.count - upper) / Double(frames.count))
        }
        guard count > 0 else { throw Failure(message: "Выбранный участок не содержит читаемых кадров") }
        video.markAsFinished()
        mark("audio-finish", ["writtenFrames": count])
        while audioGroup.wait(timeout: .now() + 0.1) == .timedOut { try check(); try feed.check() }
        audioDone = true; try feed.check()
        mark("writer-finish")
        writer.endSession(atSourceTime: time(duration))
        let finished = DispatchSemaphore(value: 0)
        writer.finishWriting { finished.signal() }
        while finished.wait(timeout: .now() + 0.1) == .timedOut { try check() }
        try check()
        guard writer.status == .completed else { throw writer.error ?? Failure(message: "Реверсия не сохранилась") }
        mark("result-file")
        // destination — новый номер, случайный для каждого запроса. Чужой
        // файл не перезаписываем даже при ошибке клиента.
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw Failure(message: "Файл реверсии уже существует") }
        try FileManager.default.moveItem(at: part, to: destination); committed = true
        let size = track.naturalSize.applying(track.preferredTransform)
        progress(1)
        return Info(duration: duration, width: Int(abs(size.width)), height: Int(abs(size.height)), fps: fps,
                    transfer: hdr ? (transfer == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String) ? "hlg" : "pq") : "")
    }

    private func frameKey(_ at: CMTime) -> Int64 {
        CMTimeConvertScale(at, timescale: 600000, method: .roundHalfAwayFromZero).value
    }

    // Только временные отметки и ссылки на сэмплы, без чтения/декодирования
    // пикселей. Индекс един для всех блоков и сохраняет переменный FPS.
    private func frameTimes(asset: AVAsset, track: AVAssetTrack, from: CMTime, to end: CMTime,
                            fps: Double) throws -> [Frame] {
        let reader = try AVAssetReader(asset: asset), out = AVAssetReaderSampleReferenceOutput(track: track)
        guard reader.canAdd(out) else { throw Failure(message: "Временные отметки видео недоступны") }
        reader.add(out)
        guard reader.startReading() else { throw reader.error ?? Failure(message: "Временные отметки видео не читаются") }
        defer { reader.cancelReading() }
        var frames: [Frame] = []
        while let sample = out.copyNextSampleBuffer() {
            try check()
            for index in 0..<CMSampleBufferGetNumSamples(sample) {
                var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .invalid, decodeTimeStamp: .invalid)
                let status = CMSampleBufferGetSampleTimingInfo(sample, at: index, timingInfoOut: &timing)
                guard status == noErr, timing.presentationTimeStamp.isNumeric else {
                    throw Failure(message: "Некорректная временная отметка исходного кадра")
                }
                let duration = timing.duration.isNumeric && CMTimeCompare(timing.duration, .zero) > 0 ? timing.duration : time(1 / fps)
                let finish = CMTimeAdd(timing.presentationTimeStamp, duration)
                if CMTimeCompare(timing.presentationTimeStamp, end) < 0, CMTimeCompare(finish, from) > 0 {
                    frames.append(Frame(start: timing.presentationTimeStamp, end: finish))
                }
            }
        }
        if reader.status == .failed { throw reader.error ?? Failure(message: "Временные отметки видео не прочитаны") }
        frames.sort { CMTimeCompare($0.start, $1.start) < 0 }
        for index in 0..<max(0, frames.count - 1) {
            guard CMTimeCompare(frames[index].start, frames[index + 1].start) < 0 else {
                throw Failure(message: "Исходное видео содержит повторные временные отметки")
            }
            if CMTimeCompare(frames[index].end, frames[index + 1].start) > 0 {
                frames[index] = Frame(start: frames[index].start, end: frames[index + 1].start)
            }
        }
        return frames
    }

    private func wait(_ input: AVAssetWriterInput, _ writer: AVAssetWriter) throws {
        let deadline = Date().addingTimeInterval(30)
        while !input.isReadyForMoreMediaData {
            try check()
            if writer.status == .failed || writer.status == .cancelled {
                throw writer.error ?? Failure(message: "Запись реверсии прервана")
            }
            if Date() > deadline { throw Failure(message: "Кодировщик реверсии не отвечает") }
            Thread.sleep(forTimeInterval: 0.002)
        }
        try check()
    }

    private func pcmSettings(_ format: AVAudioFormat) -> [String: Any] {
        [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: format.sampleRate,
         AVNumberOfChannelsKey: format.channelCount, AVLinearPCMBitDepthKey: 32,
         AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]
    }

    private func reverseAudio(asset: AVAsset, track: AVAssetTrack, from: Double, duration: Double,
                              to file: URL, progress: @escaping (Double) -> Void) throws -> AVAudioFormat {
        mark("audio-format")
        let desc = track.formatDescriptions.first.map { $0 as! CMAudioFormatDescription }
        let asbd = desc.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
        let rate = asbd?.mSampleRate ?? 48000, channels = asbd?.mChannelsPerFrame ?? 2
        guard rate > 0, channels > 0, let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
            sampleRate: rate, channels: channels, interleaved: true) else { throw Failure(message: "Формат звука не прочитан") }
        mark("audio-file", ["sampleRate": rate, "channels": channels, "sourceAudioCodec": asbd?.mFormatID ?? 0])
        let pcm = try AVAudioFile(forWriting: file, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: true)
        let total = Int((duration * rate).rounded()), block = max(1, Int(rate)), channelCount = Int(channels)
        var stop = total
        while stop > 0 {
            try check()
            let start = max(0, stop - block), n = stop - start
            let lo = from + Double(start) / rate, hi = from + Double(stop) / rate
            try autoreleasepool {
                mark("audio-decode", ["audioBlockFrom": lo, "audioBlockTo": hi])
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)),
                      let data = buffer.mutableAudioBufferList.pointee.mBuffers.mData else { throw Failure(message: "Не хватило памяти для звука") }
                buffer.frameLength = AVAudioFrameCount(n)
                memset(data, 0, n * channelCount * 4)
                let reader = try AVAssetReader(asset: asset)
                reader.timeRange = CMTimeRange(start: time(lo), duration: time(hi - lo))
                let out = AVAssetReaderTrackOutput(track: track, outputSettings: pcmSettings(format))
                reader.add(out)
                guard reader.startReading() else { throw reader.error ?? Failure(message: "Звук не читается") }
                defer { reader.cancelReading() }
                while let sample = out.copyNextSampleBuffer() {
                    try check()
                    let offset = Int(((CMSampleBufferGetPresentationTimeStamp(sample).seconds - lo) * rate).rounded())
                    let count = CMSampleBufferGetNumSamples(sample), a = max(0, -offset), b = min(count, n - offset)
                    if b <= a { continue }
                    guard let bytes = CMSampleBufferGetDataBuffer(sample) else { throw Failure(message: "Не удалось прочитать данные звука") }
                    let status = CMBlockBufferCopyDataBytes(bytes, atOffset: a * channelCount * 4,
                        dataLength: (b - a) * channelCount * 4, destination: data.advanced(by: (offset + a) * channelCount * 4))
                    guard status == kCMBlockBufferNoErr else { throw Failure(message: "Звуковой блок не прочитан") }
                }
                if reader.status == .failed { throw reader.error ?? Failure(message: "Чтение звука прервалось") }
                // Меняем порядок кадров PCM, сохраняя порядок каналов внутри
                // каждого кадра: левое и правое ухо не меняются местами.
                let floats = data.assumingMemoryBound(to: Float.self)
                for i in 0..<(n / 2) {
                    for c in 0..<channelCount {
                        let a = i * channelCount + c, b = (n - 1 - i) * channelCount + c
                        let value = floats[a]; floats[a] = floats[b]; floats[b] = value
                    }
                }
                mark("audio-pcm-write")
                try pcm.write(from: buffer)
            }
            stop = start; progress(0.24 * Double(total - stop) / Double(max(1, total)))
        }
        return format
    }
}
