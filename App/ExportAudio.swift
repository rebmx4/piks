import AVFoundation

// Звук экспорта телефоном (сборка №19, владелец 27.09.2026: «звук сохраняется
// только под левое ухо и тихий»):
//  • ролик со звуком в один канал (моно; петличка, радиомикрофон) — в оба
//    уха. Сведение AVFoundation кладёт один канал в стерео только в левое
//    ухо; поэтому такой звук сперва переписывается в стерео (оба канала
//    одинаковые) — файлом CAF во временной папке, и в сборку идёт уже он;
//  • галочка «Стерео — в оба уха» на странице (core/ears.js): у ролика, где
//    звук только в одном канале, этот канал — в оба уха (ear "L" / "R");
//  • громкость выше 100 %: громкость AVAudioMix больше единицы не берёт и
//    молча режет до 100 %. Все громкости делятся на наибольшую, сведённый
//    звук умножается на неё и не выходит за полную шкалу — как на странице.
enum ExportAudio {

    // Каналов у дорожки звука (0 — не узнать).
    static func channels(_ track: AVAssetTrack) -> Int {
        for d in track.formatDescriptions {
            let desc = d as! CMAudioFormatDescription
            if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee {
                return Int(asbd.mChannelsPerFrame)
            }
        }
        return 0
    }

    // Настройки чтения: Float32, кадры подряд (каналы вперемешку).
    static func floatPCM(channels: Int, rate: Double = 48000) -> [String: Any] {
        return [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
    }

    // Отсчёты куска (Float32 вперемешку, как в floatPCM), каналов и частота.
    static func floats(_ sample: CMSampleBuffer) -> (data: [Float], channels: Int, rate: Double)? {
        guard let fmt = CMSampleBufferGetFormatDescription(sample),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt)?.pointee,
              asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0, asbd.mBitsPerChannel == 32 else { return nil }
        let ch = Int(asbd.mChannelsPerFrame)
        let frames = CMSampleBufferGetNumSamples(sample)
        guard ch > 0, frames > 0 else { return nil }
        var data = [Float](repeating: 0, count: frames * ch)
        let ok = data.withUnsafeMutableBytes { raw -> Bool in
            var list = AudioBufferList(mNumberBuffers: 1,
                                       mBuffers: AudioBuffer(mNumberChannels: UInt32(ch),
                                                             mDataByteSize: UInt32(raw.count),
                                                             mData: raw.baseAddress))
            return CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames),
                                                                into: &list) == noErr
        }
        return ok ? (data, ch, asbd.mSampleRate) : nil
    }

    // Кусок звука из отсчётов (Float32 вперемешку) с тем же временем.
    static func sample(_ data: [Float], channels: Int, rate: Double, pts: CMTime) -> CMSampleBuffer? {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(4 * channels), mFramesPerPacket: 1, mBytesPerFrame: UInt32(4 * channels),
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = channels == 2 ? kAudioChannelLayoutTag_Stereo : kAudioChannelLayoutTag_Mono
        var fmt: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd,
                                             layoutSize: MemoryLayout<AudioChannelLayout>.size, layout: &layout,
                                             magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                             formatDescriptionOut: &fmt) == noErr, let format = fmt else { return nil }
        let frames = data.count / max(1, channels)
        var out: CMSampleBuffer?
        guard frames > 0,
              CMAudioSampleBufferCreateWithPacketDescriptions(
                allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
                makeDataReadyCallback: nil, refcon: nil, formatDescription: format,
                sampleCount: frames, presentationTimeStamp: pts, packetDescriptions: nil,
                sampleBufferOut: &out) == noErr, let sb = out else { return nil }
        var copy = data
        // Данные копируются в новый блок — массив живёт только здесь.
        let status = copy.withUnsafeMutableBytes { raw -> OSStatus in
            var list = AudioBufferList(mNumberBuffers: 1,
                                       mBuffers: AudioBuffer(mNumberChannels: UInt32(channels),
                                                             mDataByteSize: UInt32(raw.count),
                                                             mData: raw.baseAddress))
            return CMSampleBufferSetDataBufferFromAudioBufferList(
                sb, blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault,
                flags: 0, bufferList: &list)
        }
        return status == noErr ? sb : nil
    }

    // Звук ролика — в стереофайл CAF. mode "M" — один канал в оба уха; "L" /
    // "R" — этот канал стерео в оба уха. Время — как у ролика: с нуля, пустоты
    // тишиной (сведение дорожки), поэтому кусок берётся по тем же секундам.
    static func stereoCopy(_ asset: AVAsset, _ track: AVAssetTrack, mode: String, to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        let rate = 48000.0
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: .zero, duration: asset.duration)
        let output = AVAssetReaderAudioMixOutput(audioTracks: [track],
                                                 audioSettings: floatPCM(channels: mode == "M" ? 1 : 2, rate: rate))
        guard reader.canAdd(output) else { throw ExportError("звук ролика не читается") }
        reader.add(output)

        let writer = try AVAssetWriter(outputURL: url, fileType: .caf)
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
        var settings = floatPCM(channels: 2, rate: rate)
        settings[AVChannelLayoutKey] = Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw ExportError("стереофайл звука не пишется") }
        writer.add(input)

        guard reader.startReading() else { throw reader.error ?? (ExportError("звук ролика не читается") as Error) }
        guard writer.startWriting() else {
            reader.cancelReading()
            throw writer.error ?? (ExportError("стереофайл звука не пишется") as Error)
        }
        writer.startSession(atSourceTime: .zero)
        var failed = false
        while !failed, let s = output.copyNextSampleBuffer() {
            guard let got = floats(s) else { continue }
            let n = got.data.count / got.channels
            let pick = mode == "R" ? min(1, got.channels - 1) : 0
            var st = [Float](repeating: 0, count: n * 2)
            for i in 0..<n {
                let v = got.data[i * got.channels + pick]
                st[2 * i] = v
                st[2 * i + 1] = v
            }
            guard let out = sample(st, channels: 2, rate: got.rate, pts: CMSampleBufferGetPresentationTimeStamp(s)) else { continue }
            while !input.isReadyForMoreMediaData && writer.status == .writing { usleep(2000) }
            if writer.status != .writing || !input.append(out) { failed = true }
        }
        input.markAsFinished()
        if failed || reader.status == .failed {
            reader.cancelReading()
            writer.cancelWriting()
            throw writer.error ?? reader.error ?? (ExportError("звук в стерео не переписался") as Error)
        }
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else {
            throw writer.error ?? (ExportError("звук в стерео не записался") as Error)
        }
    }

    // Сведённый кусок, громче в gain раз, не за полной шкалой.
    static func amplified(_ s: CMSampleBuffer, by gain: Float) -> CMSampleBuffer? {
        guard var got = floats(s) else { return nil }
        for i in 0..<got.data.count { got.data[i] = max(-1, min(1, got.data[i] * gain)) }
        return sample(got.data, channels: got.channels, rate: got.rate, pts: CMSampleBufferGetPresentationTimeStamp(s))
    }
}
