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
    private let lock = NSLock()
    private var cancelled = false
    private var currentWriter: AVAssetWriter?
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

    func run(source: URL, destination: URL, from: Double, duration: Double,
             progress: @escaping (Double) -> Void) throws -> Info {
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
        guard writer.startWriting() else { throw writer.error ?? Failure(message: "Кодировщик реверсии не запустился") }
        writer.startSession(atSourceTime: .zero)
        // Две независимые подачи: writer может ждать звук, пока видеовход
        // не готов, и наоборот. Последовательная подача стопорила оба входа.
        let audioGroup = DispatchGroup(), feed = AudioFeed()
        if let sound = audio, let out = audioOutput, let reader = audioReader {
            audioGroup.enter()
            DispatchQueue(label: "ryndi.reverse.audio", qos: .userInitiated).async {
                defer { audioGroup.leave() }
                do {
                    while let sample = out.copyNextSampleBuffer() {
                        try autoreleasepool {
                            try self.wait(sound, writer)
                            guard sound.append(sample) else { throw writer.error ?? Failure(message: "Обратный звук не записался") }
                        }
                    }
                    if reader.status == .failed { throw reader.error ?? Failure(message: "Обратный звук не прочитан") }
                    sound.markAsFinished()
                } catch { feed.fail(error); writer.cancelWriting() }
            }
        }
        var audioDone = false
        defer {
            if !audioDone { writer.cancelWriting(); audioReader?.cancelReading() }
            audioGroup.wait()
        }
        let end = from + duration
        // Консервативный предел 64 МБ: не зависит от длины исходника.
        let blockFrames = max(1, (64 * 1024 * 1024) / max(1, width * height * 4))
        let blockSeconds = min(1, Double(blockFrames) / fps)
        var hi = end, lastSource = Double.infinity, count = 0
        while hi > from + 0.00000001 {
            try check()
            try feed.check()
            let lo = max(from, hi - blockSeconds)
            try autoreleasepool {
                let reader = try AVAssetReader(asset: asset)
                reader.timeRange = CMTimeRange(start: time(lo), duration: time(hi - lo))
                let out = AVAssetReaderTrackOutput(track: track,
                    outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: pixelFormat])
                out.alwaysCopiesSampleData = false
                reader.add(out)
                guard reader.startReading() else { throw reader.error ?? Failure(message: "Кадры видео не читаются") }
                defer { reader.cancelReading() }
                var samples: [CMSampleBuffer] = []
                while let sample = out.copyNextSampleBuffer() {
                    try check()
                    let t = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                    if t < hi - 0.00000001 && t < lastSource - 0.00000001 { samples.append(sample) }
                }
                if reader.status == .failed { throw reader.error ?? Failure(message: "Чтение кадров прервалось") }
                samples.sort { CMSampleBufferGetPresentationTimeStamp($0) < CMSampleBufferGetPresentationTimeStamp($1) }
                for sample in samples.reversed() {
                    try check()
                    let t = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                    let rawDuration = CMSampleBufferGetDuration(sample).seconds
                    let d = rawDuration.isFinite && rawDuration > 0 ? rawDuration : 1 / fps
                    let a = max(from, t), b = min(end, min(lastSource, t + d))
                    guard b > a + 0.00000001, let pixels = CMSampleBufferGetImageBuffer(sample) else { continue }
                    let at = max(0, end - b)
                    try wait(video, writer)
                    guard adaptor.append(pixels, withPresentationTime: time(at)) else {
                        throw writer.error ?? Failure(message: "Обратный кадр не записался")
                    }
                    lastSource = t; count += 1
                }
            }
            hi = lo
            progress(0.25 + 0.74 * (end - hi) / duration)
        }
        guard count > 0 else { throw Failure(message: "Выбранный участок не содержит читаемых кадров") }
        video.markAsFinished()
        while audioGroup.wait(timeout: .now() + 0.1) == .timedOut { try check(); try feed.check() }
        audioDone = true; try feed.check()
        writer.endSession(atSourceTime: time(duration))
        let finished = DispatchSemaphore(value: 0)
        writer.finishWriting { finished.signal() }
        while finished.wait(timeout: .now() + 0.1) == .timedOut { try check() }
        try check()
        guard writer.status == .completed else { throw writer.error ?? Failure(message: "Реверсия не сохранилась") }
        // destination — новый номер, случайный для каждого запроса. Чужой
        // файл не перезаписываем даже при ошибке клиента.
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw Failure(message: "Файл реверсии уже существует") }
        try FileManager.default.moveItem(at: part, to: destination); committed = true
        let size = track.naturalSize.applying(track.preferredTransform)
        progress(1)
        return Info(duration: duration, width: Int(abs(size.width)), height: Int(abs(size.height)), fps: fps,
                    transfer: hdr ? (transfer == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String) ? "hlg" : "pq") : "")
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
        let desc = track.formatDescriptions.first.map { $0 as! CMAudioFormatDescription }
        let asbd = desc.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
        let rate = asbd?.mSampleRate ?? 48000, channels = asbd?.mChannelsPerFrame ?? 2
        guard rate > 0, channels > 0, let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
            sampleRate: rate, channels: channels, interleaved: true) else { throw Failure(message: "Формат звука не прочитан") }
        let pcm = try AVAudioFile(forWriting: file, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: true)
        let total = Int((duration * rate).rounded()), block = max(1, Int(rate)), channelCount = Int(channels)
        var stop = total
        while stop > 0 {
            try check()
            let start = max(0, stop - block), n = stop - start
            let lo = from + Double(start) / rate, hi = from + Double(stop) / rate
            try autoreleasepool {
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
                try pcm.write(from: buffer)
            }
            stop = start; progress(0.24 * Double(total - stop) / Double(max(1, total)))
        }
        return format
    }
}
