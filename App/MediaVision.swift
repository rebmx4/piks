import Foundation
import AVFoundation
import CoreImage
import ImageIO
import Vision

// Разбор «человек/фон» средствами iOS (сборка №17, caps «vision»).
//
// Зачем. Страница разбирает кадры нейросетью MediaPipe в браузере: 20–30 мс
// на кадр, ролик в 43 с — 25–55 с, край у волос грубый, а на середине
// видеокарта может отнять у неё контекст (журнал владельца 25.09.2026).
// У айфона своя нейросеть (Vision, на нейропроцессоре) — быстрее и точнее.
//
// Команда: vision-person { req, media, fps, from, to, size, quality } —
// кадры ролика media с шагом 1/fps от from до to (секунды исходника).
// Ответ — события vision-person { req, frames: [{ i, t, w, h, rle }], done }:
// i — номер кадра (round(t·fps)), маска стоя, по байту на точку (255 —
// человек), size по длинной стороне (256 — как у страницы, core/retouch.js
// maskSize), сжатие повторов парами [значение, длина до 255] — ровно как
// rleEncode страницы, base64. Последнее событие — done: true, count, ms.
// Ошибка — vision-error { req, reason }. vision-cancel { req } — остановить.
final class VisionJobs {
    private static let lock = NSLock()
    private static var cancelled = Set<String>()
    static func cancel(_ req: String) { lock.lock(); cancelled.insert(req); lock.unlock() }
    static func reset(_ req: String) { lock.lock(); cancelled.remove(req); lock.unlock() }
    static func isCancelled(_ req: String) -> Bool { lock.lock(); defer { lock.unlock() }; return cancelled.contains(req) }
}

extension MediaBridge {

    static let visionQueue = DispatchQueue(label: "ryndi.vision", qos: .userInitiated)

    func visionPerson(_ body: [String: Any]) {
        let req = (body["req"] as? String) ?? ""
        guard let media = body["media"] as? String else {
            send(["event": "vision-error", "req": req, "reason": "нет ролика"])
            return
        }
        let fps = max(1, min(30, ExportPlan.num(body["fps"]) ?? 15))
        let from = max(0, ExportPlan.num(body["from"]) ?? 0)
        let to = ExportPlan.num(body["to"])
        let long = max(64, min(1024, ExportPlan.int(body["size"]) ?? 256))
        let accurate = (body["quality"] as? String) == "accurate"
        VisionJobs.reset(req)
        resolveFile(media) { [weak self] url in
            guard let self = self else { return }
            guard let url = url else {
                self.send(["event": "vision-error", "req": req, "reason": "ролик не найден"])
                return
            }
            let source = PreviewCopies.ready(media) ?? url
            MediaBridge.visionQueue.async {
                self.personMasks(req: req, url: source, fps: fps, from: from, to: to, long: long, accurate: accurate)
            }
        }
    }

    func visionCancel(_ body: [String: Any]) {
        if let req = body["req"] as? String { VisionJobs.cancel(req) }
    }

    private func personMasks(req: String, url: URL, fps: Double, from: Double, to: Double?, long: Int, accurate: Bool) {
        let started = Date()
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .video).first else {
            send(["event": "vision-error", "req": req, "reason": "в ролике нет видео"])
            return
        }
        let duration = CMTimeGetSeconds(asset.duration)
        let end = min(to ?? duration, duration)
        let nat = track.naturalSize
        let pref = track.preferredTransform
        let shown = CGRect(origin: .zero, size: nat).applying(pref)
        let upW = abs(shown.width), upH = abs(shown.height)
        guard upW >= 2, upH >= 2, end > from else {
            send(["event": "vision-person", "req": req, "frames": [[String: Any]](), "done": true, "count": 0, "ms": 0])
            return
        }
        // Кадр для нейросети — стоя, 512 по длинной стороне.
        let k = 512 / max(upW, upH)
        let inW = max(16, Int((upW * k).rounded())), inH = max(16, Int((upH * k).rounded()))
        // Маска — размером страницы: size по длинной стороне.
        let mk = CGFloat(long) / max(upW, upH)
        let mW = max(1, Int((upW * mk).rounded())), mH = max(1, Int((upH * mk).rounded()))
        // Кадр декодера (Core Image, y вверх) -> кадр стоя нужного размера (y
        // вверх). Высота — самого кадра (у роликов не с айфона буфер бывает
        // выше видимого: 1088 при 1080).
        let upright = pref.concatenating(CGAffineTransform(translationX: -shown.minX, y: -shown.minY))
        let flipUp = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: upH)
        let fit = CGAffineTransform(scaleX: CGFloat(inW) / upW, y: CGFloat(inH) / upH)
        func toInput(_ bufferHeight: CGFloat) -> CGAffineTransform {
            return CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: bufferHeight)
                .concatenating(upright).concatenating(flipUp).concatenating(fit)
        }
        // Кадр под меткой i — ближайший к i/fps (а не первый, округлившийся к i).
        let srcFps = track.nominalFrameRate > 0 ? Double(track.nominalFrameRate) : 30
        let half = 0.5 / srcFps

        do {
            let reader = try AVAssetReader(asset: asset)
            reader.timeRange = CMTimeRange(start: CMTime(seconds: max(0, from - 0.1), preferredTimescale: 600),
                                           end: CMTime(seconds: end + 0.1, preferredTimescale: 600))
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            ])
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { throw ExportError("кадры не читаются") }
            reader.add(output)
            guard reader.startReading() else { throw reader.error ?? ExportError("чтение не началось") }

            let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
            var made: CVPixelBuffer? = nil
            CVPixelBufferCreate(kCFAllocatorDefault, inW, inH, kCVPixelFormatType_32BGRA,
                                [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary, &made)
            guard let input = made else { throw ExportError("нет памяти под кадр") }
            let request = VNGeneratePersonSegmentationRequest()
            request.qualityLevel = accurate ? .accurate : .balanced
            request.outputPixelFormat = kCVPixelFormatType_OneComponent8

            let first = Int((from * fps).rounded(.up)), last = Int((end * fps).rounded(.down))
            var seen = Set<Int>()
            var batch: [[String: Any]] = []
            var lastSend = Date()
            var count = 0
            while reader.status == .reading {
                if VisionJobs.isCancelled(req) { reader.cancelReading(); break }
                guard let sample = output.copyNextSampleBuffer() else { break }
                autoreleasepool {
                    let t = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
                    guard t.isFinite else { return }                     // Int(NaN) уронил бы приложение
                    let i = Int(((t + half) * fps).rounded(.down))
                    guard Double(i) / fps >= t - half, i >= first, i <= last, !seen.contains(i),
                          let frame = CMSampleBufferGetImageBuffer(sample) else { return }
                    seen.insert(i)
                    let image = CIImage(cvPixelBuffer: frame)
                        .transformed(by: toInput(CGFloat(CVPixelBufferGetHeight(frame))))
                    context.render(image, to: input, bounds: CGRect(x: 0, y: 0, width: inW, height: inH), colorSpace: nil)
                    let handler = VNImageRequestHandler(cvPixelBuffer: input, orientation: .up, options: [:])
                    guard (try? handler.perform([request])) != nil,
                          let mask = request.results?.first?.pixelBuffer,
                          let bytes = MediaBridge.shrink(mask, to: mW, mH) else { return }
                    batch.append(["i": i, "t": t, "w": mW, "h": mH,
                                  "rle": Data(MediaBridge.rle(bytes)).base64EncodedString()])
                    count += 1
                    if batch.count >= 12 || Date().timeIntervalSince(lastSend) > 0.5 {
                        send(["event": "vision-person", "req": req, "frames": batch, "done": false])
                        batch = []
                        lastSend = Date()
                    }
                }
            }
            if reader.status == .failed { throw reader.error ?? ExportError("чтение кадров оборвалось") }
            send(["event": "vision-person", "req": req, "frames": batch, "done": true, "count": count,
                  "cancelled": VisionJobs.isCancelled(req),
                  "ms": Int(Date().timeIntervalSince(started) * 1000)])
        } catch {
            send(["event": "vision-error", "req": req, "reason": error.localizedDescription])
        }
    }

    // MARK: - «Выделить объект» на фото (сборка №21, caps «subject»)

    // Владелец, 28.09.2026: «удалил фон с картинки — не удаляется» (шахматы с
    // нарисованной «клеткой» прозрачности). Нейросеть «человек/фон» находит
    // только людей; у iOS 17 есть та же, что при долгом нажатии на предмет в
    // «Фото», — любые предметы, животные, люди.
    //
    // Команда: vision-subject { req, media, size } — фото media (JPEG стоя,
    // MediaFiles.swift resolvePhoto). Ответ — одно событие vision-subject
    // { req, frames: [{ i: 0, t: 0, w, h, rle }], done: true, count, instances,
    // ms }: маска всех найденных предметов, 255 — предмет, край мягкий, size по
    // длинной стороне (не больше самой картинки), сжатие — как у vision-person.
    // Ничего не нашлось — frames пуст. Ошибка — vision-error { req, reason }.
    func visionSubject(_ body: [String: Any]) {
        let req = (body["req"] as? String) ?? ""
        guard let media = body["media"] as? String else {
            send(["event": "vision-error", "req": req, "reason": "нет фото"])
            return
        }
        let long = max(64, min(2048, ExportPlan.int(body["size"]) ?? 1024))
        resolveFile(media) { [weak self] url in
            guard let self = self else { return }
            guard let url = url else {
                self.send(["event": "vision-error", "req": req, "reason": "фото не найдено"])
                return
            }
            MediaBridge.visionQueue.async {
                if #available(iOS 17.0, *) {
                    self.subjectMask(req: req, url: url, long: long)
                } else {
                    self.send(["event": "vision-error", "req": req, "reason": "нужна iOS 17"])
                }
            }
        }
    }

    @available(iOS 17.0, *)
    private func subjectMask(req: String, url: URL, long: Int) {
        let started = Date()
        let ms = { Int(Date().timeIntervalSince(started) * 1000) }
        // Картинка для нейросети — не больше 1536 по длинной стороне: маска
        // полного фото 4096² во float — 64 МБ. Меньшую не увеличивает.
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1536,
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary) else {
            send(["event": "vision-error", "req": req, "reason": "фото не читается"])
            return
        }
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        let request = VNGenerateForegroundInstanceMaskRequest()
        do {
            try handler.perform([request])
            guard let found = request.results?.first, !found.allInstances.isEmpty else {
                send(["event": "vision-subject", "req": req, "frames": [[String: Any]](), "done": true,
                      "count": 0, "instances": 0, "ms": ms()])
                return
            }
            // Маска всех предметов размером картинки, 0…1 с мягким краем.
            let mask = try found.generateScaledMaskForImage(forInstances: found.allInstances, from: handler)
            let iw = CVPixelBufferGetWidth(mask), ih = CVPixelBufferGetHeight(mask)
            guard iw > 0, ih > 0 else { throw ExportError("маска пустая") }
            let k = min(1.0, Double(long) / Double(max(iw, ih)))
            let w = max(1, Int((Double(iw) * k).rounded())), h = max(1, Int((Double(ih) * k).rounded()))
            // Маска — float 0…1 (так в документации); байтовую тоже примем.
            let format = CVPixelBufferGetPixelFormatType(mask)
            let shrunk = format == kCVPixelFormatType_OneComponent8
                ? MediaBridge.shrink(mask, to: w, h) : MediaBridge.shrinkFloat(mask, to: w, h)
            guard let bytes = shrunk else { throw ExportError("маска не читается (формат \(format))") }
            send(["event": "vision-subject", "req": req,
                  "frames": [["i": 0, "t": 0, "w": w, "h": h, "rle": Data(MediaBridge.rle(bytes)).base64EncodedString()] as [String: Any]],
                  "done": true, "count": 1, "instances": found.allInstances.count, "ms": ms()])
        } catch {
            send(["event": "vision-error", "req": req, "reason": error.localizedDescription])
        }
    }

    // Маска «Выделить объект» (float 0…1 на точку, строки сверху вниз) -> w×h
    // байтов 0…255 усреднением, как shrink ниже.
    static func shrinkFloat(_ mask: CVPixelBuffer, to w: Int, _ h: Int) -> [UInt8]? {
        guard CVPixelBufferGetPixelFormatType(mask) == kCVPixelFormatType_OneComponent32Float else { return nil }
        CVPixelBufferLockBaseAddress(mask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(mask) else { return nil }
        let sw = CVPixelBufferGetWidth(mask), sh = CVPixelBufferGetHeight(mask)
        let row = CVPixelBufferGetBytesPerRow(mask)
        guard sw > 0, sh > 0 else { return nil }
        var out = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            let y0 = y * sh / h, y1 = max(y0 + 1, (y + 1) * sh / h)
            for x in 0..<w {
                let x0 = x * sw / w, x1 = max(x0 + 1, (x + 1) * sw / w)
                var sum: Float = 0
                var n = 0
                for yy in y0..<min(y1, sh) {
                    let line = (base + yy * row).assumingMemoryBound(to: Float32.self)
                    for xx in x0..<min(x1, sw) { sum += min(1, max(0, line[xx])); n += 1 }
                }
                out[y * w + x] = UInt8(n > 0 ? min(255, max(0, (sum / Float(n) * 255).rounded())) : 0)
            }
        }
        return out
    }

    // Маска Vision (байт на точку, строки сверху вниз) -> w×h усреднением,
    // как core/retouch.js personMask: уменьшение даёт мягкий край.
    static func shrink(_ mask: CVPixelBuffer, to w: Int, _ h: Int) -> [UInt8]? {
        CVPixelBufferLockBaseAddress(mask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(mask) else { return nil }
        let sw = CVPixelBufferGetWidth(mask), sh = CVPixelBufferGetHeight(mask)
        let row = CVPixelBufferGetBytesPerRow(mask)
        guard sw > 0, sh > 0 else { return nil }
        let src = base.assumingMemoryBound(to: UInt8.self)
        var out = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            let y0 = y * sh / h, y1 = max(y0 + 1, (y + 1) * sh / h)
            for x in 0..<w {
                let x0 = x * sw / w, x1 = max(x0 + 1, (x + 1) * sw / w)
                var sum = 0, n = 0
                for yy in y0..<min(y1, sh) {
                    let line = src + yy * row
                    for xx in x0..<min(x1, sw) { sum += Int(line[xx]); n += 1 }
                }
                out[y * w + x] = UInt8(n > 0 ? (sum + n / 2) / n : 0)
            }
        }
        return out
    }

    // Сжатие повторов — как rleEncode страницы: [значение, длина до 255]…
    static func rle(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count / 8)
        var i = 0
        while i < bytes.count {
            let v = bytes[i]
            var n = 1
            while n < 255 && i + n < bytes.count && bytes[i + n] == v { n += 1 }
            out.append(v)
            out.append(UInt8(n))
            i += n
        }
        return out
    }
}
