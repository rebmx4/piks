import Foundation
import AVFoundation

// Звук ролика для страницы: волна и отдельный звуковой файл (сборка №13).
//
// Зачем. Страница загружена с https, а ролик приходит по своей схеме
// ryndi-media:// — WebKit считает её незащищённой и не пускает к ней fetch
// (смешанное содержимое; <video> пускает). Поэтому страница не может сама
// прочитать звук ролика: волна в приложении не строилась, а отдельный звук
// играл весь ролик 4K элементом <audio> — приложение не успевало кормить и
// видео, и звук, и звук шёл рывками (журнал владельца, 23.09.2026).
//
// Как решаем. Волну считает телефон (AVAssetReader) и отдаёт странице только
// точки. Звуковую дорожку телефон копирует в маленький m4a без пересжатия —
// её и играет отдельный звук (ryndi-media://audio/<id>.m4a, MediaServer.swift).
extension MediaBridge {

    // MARK: - Волна

    func makeWave(_ id: String?, buckets: Int) {
        guard let id = id else { return }
        resolveFile(id) { [weak self] url in
            guard let self = self else { return }
            guard let url = url else {
                self.send(["event": "wave-error", "id": id, "reason": "ролик не найден"])
                return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                let t0 = Date()
                do {
                    let (peaks, seconds) = try Waveform.peaks(url: url, buckets: max(100, min(buckets, 8000)))
                    self.send(["event": "wave", "id": id, "peaks": peaks, "seconds": seconds,
                               "ms": Int(Date().timeIntervalSince(t0) * 1000)])
                } catch {
                    self.send(["event": "wave-error", "id": id, "reason": error.localizedDescription])
                }
            }
        }
    }

    // MARK: - Звук отдельным файлом

    func makeAudioFile(_ id: String?) {
        guard let id = id else { return }
        let address = "\(MediaBridge.scheme)://audio/\(id).m4a"
        if let ready = audioFiles[id], FileManager.default.fileExists(atPath: ready.path) {
            send(["event": "audio-file", "id": id, "url": address])
            return
        }
        resolveFile(id) { [weak self] url in
            guard let self = self else { return }
            guard let url = url else {
                self.send(["event": "audio-error", "id": id, "reason": "ролик не найден"])
                return
            }
            let asset = AVURLAsset(url: url)
            guard let track = asset.tracks(withMediaType: .audio).first else {
                self.send(["event": "audio-error", "id": id, "reason": "в ролике нет звука"])
                return
            }
            // Дорожка звука отдельно, на той же шкале времени, что ролик:
            // момент t в файле — это момент t исходника.
            let comp = AVMutableComposition()
            guard let dst = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                self.send(["event": "audio-error", "id": id, "reason": "не вышло собрать звук"])
                return
            }
            do {
                try dst.insertTimeRange(CMTimeRange(start: .zero, duration: asset.duration), of: track, at: .zero)
            } catch {
                self.send(["event": "audio-error", "id": id, "reason": error.localizedDescription])
                return
            }
            let out = FileManager.default.temporaryDirectory.appendingPathComponent("ryndi-audio-\(id).m4a")
            // Сначала без пересжатия (быстро); если звук не AAC — пересжимаем.
            self.exportAudio(comp, to: out, presets: [AVAssetExportPresetPassthrough, AVAssetExportPresetAppleM4A]) { error in
                if let error = error {
                    self.send(["event": "audio-error", "id": id, "reason": error])
                } else {
                    self.audioFiles[id] = out
                    self.send(["event": "audio-file", "id": id, "url": address])
                }
            }
        }
    }

    // MARK: - Байты звукового файла для страницы (сборка №14)

    // Звук превью одним потоком, как в экспорте (engine/audioengine.js на
    // странице): страница сама раскладывает звук ролика по ленте, и ей нужен
    // весь звук ролика. Прочитать ryndi-media:// она не может (смешанное
    // содержимое), поэтому берёт звуковой файл — тот, что делает
    // makeAudioFile, — кусками через мост. Кусок не больше 4 МБ; ответ —
    // событие read с тем же номером просьбы, байты в base64, size — весь файл.
    func readAudioBytes(_ body: [String: Any]) {
        let req = (body["req"] as? String) ?? ""
        guard let id = body["id"] as? String, let url = audioFiles[id] else {
            send(["event": "read-error", "req": req, "reason": "звуковой файл ролика не готов"])
            return
        }
        let offset = max(0, (body["offset"] as? Int) ?? 0)
        let length = max(0, min((body["length"] as? Int) ?? 0, 4 * 1024 * 1024))
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
                let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                try handle.seek(toOffset: UInt64(min(offset, size)))
                // read(upToCount:) бросает ошибку Swift; readData(ofLength:)
                // при сбое чтения бросил бы исключение Objective-C мимо catch.
                let data = try handle.read(upToCount: length) ?? Data()
                self.send(["event": "read", "req": req, "size": size, "data": data.base64EncodedString()])
            } catch {
                self.send(["event": "read-error", "req": req, "reason": error.localizedDescription])
            }
        }
    }

    private func exportAudio(_ asset: AVAsset, to out: URL, presets: [String], done: @escaping (String?) -> Void) {
        guard let preset = presets.first else { done("телефон не берётся вынуть звук"); return }
        let rest = Array(presets.dropFirst())
        try? FileManager.default.removeItem(at: out)
        guard let session = AVAssetExportSession(asset: asset, presetName: preset),
              session.supportedFileTypes.contains(.m4a) else {
            exportAudio(asset, to: out, presets: rest, done: done)
            return
        }
        session.outputURL = out
        session.outputFileType = .m4a
        session.exportAsynchronously { [weak self] in
            DispatchQueue.main.async {
                if session.status == .completed { done(nil); return }
                if rest.isEmpty { done(session.error?.localizedDescription ?? "звук не вынулся"); return }
                self?.exportAudio(asset, to: out, presets: rest, done: done)
            }
        }
    }
}

// Точки волны: наибольший уровень на каждом из buckets отрезков, 0…1,
// нормированы по самому громкому месту (тихая запись читается так же, как
// громкая — как на странице, platform/waveform.js).
enum Waveform {
    static func peaks(url: URL, buckets: Int) throws -> ([Double], Double) {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .audio).first else {
            throw NSError(domain: "ryndi", code: 10, userInfo: [NSLocalizedDescriptionKey: "в ролике нет звука"])
        }
        let seconds = CMTimeGetSeconds(asset.duration)
        let rate = 8000.0                           // для картинки волны хватает 8 кГц моно
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? NSError(domain: "ryndi", code: 11, userInfo: [NSLocalizedDescriptionKey: "звук не читается"])
        }
        let total = max(1, Int(seconds * rate))
        var peaks = [Double](repeating: 0, count: buckets)
        var index = 0
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            if length == 0 { continue }
            var data = Data(count: length)
            data.withUnsafeMutableBytes { dst in
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: dst.baseAddress!)
            }
            data.withUnsafeBytes { raw in
                for s in raw.bindMemory(to: Int16.self) {
                    let b = min(buckets - 1, index * buckets / total)
                    let v = Double(abs(Int32(s))) / 32768.0
                    if v > peaks[b] { peaks[b] = v }
                    index += 1
                }
            }
        }
        if reader.status == .failed {
            throw reader.error ?? NSError(domain: "ryndi", code: 12, userInfo: [NSLocalizedDescriptionKey: "звук не дочитался"])
        }
        let top = peaks.max() ?? 0
        if top > 0.001 { peaks = peaks.map { min(1, $0 / top) } }
        return (peaks.map { ($0 * 1000).rounded() / 1000 }, seconds)
    }
}
