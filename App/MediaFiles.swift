import UIKit
import Photos
import AVFoundation
import CoreImage
import ImageIO

// Сборка №17 (владелец, 26.09.2026: «чтобы меньше делать сборок»): общие
// кубики для страницы Ryndi.
//
// Файлы от страницы (caps «files»). Музыка, запись голоса, обработанный на
// сервере звук — всё, что страница держит байтами, она отдаёт сюда кусками:
//   file-put  { req, id: "u…", ext, offset, chunk (base64), last } →
//             file-ack { req, id, offset } или file-ready { req, id, url, bytes };
//   file-drop { id } — удалить.
// Файл лежит в Application Support (переживает перезапуск), страница играет
// его по ryndi-media://file/<id>.<ext>, а экспорт телефоном берёт как ролик
// или звук плана — по тому же номеру.
//
// Фото и живые фото из галереи (caps «photo», «live»): gallery-use отдаёт фото
// картинкой JPEG стоя (не больше 4096 точек, sRGB), живое фото — его роликом.
// Номер фото — тот же, что у ролика («p…»), номер ролика живого фото — «l…».
//
// Вибрация (caps «haptic»): haptic { style: selection | light | medium |
// heavy | success | warning } — отклик на защёлку ползунка и прилипание.
extension MediaBridge {

    static let fileQueue = DispatchQueue(label: "ryndi.files")   // куски одного файла — по порядку

    static let userDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ryndi-files", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    static func cacheDir(_ name: String) -> URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // Номер файла страницы: «u» + буквы, цифры, «-», «_» — не больше 80 знаков.
    static func userId(_ raw: String?) -> String? {
        guard let r = raw, r.hasPrefix("u"), r.count >= 2, r.count <= 80,
              r.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { return nil }
        return r
    }

    static func safeExt(_ raw: String?) -> String {
        let e = (raw ?? "").lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        return e.isEmpty || e.count > 5 ? "bin" : e
    }

    // Тип содержимого по расширению файла — для ответа схемы ryndi-media://.
    static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "heic", "heif": return "image/heic"
        case "m4a", "aac": return "audio/mp4"
        case "mp3": return "audio/mpeg"
        case "wav": return "audio/wav"
        case "caf": return "audio/x-caf"
        default: return "video/mp4"
        }
    }

    // MARK: - Файлы от страницы

    func filePut(_ body: [String: Any]) {
        let req = (body["req"] as? String) ?? ""
        guard let id = MediaBridge.userId(body["id"] as? String) else {
            send(["event": "file-error", "req": req, "reason": "неверный номер файла"])
            return
        }
        let ext = MediaBridge.safeExt(body["ext"] as? String)
        let offset = ExportPlan.int(body["offset"]) ?? 0
        let last = (body["last"] as? Bool) ?? false
        let chunk = (body["chunk"] as? String).flatMap { Data(base64Encoded: $0) } ?? Data()
        let url = MediaBridge.userDir.appendingPathComponent(id + "." + ext)
        MediaBridge.fileQueue.async { [weak self] in
            // Расширение — из первого куска; дальше файл ищется по номеру.
            let target = offset == 0 ? url : (MediaBridge.userFile(id) ?? url)
            do {
                if offset == 0 {
                    MediaBridge.removeUserFiles(id)
                    try chunk.write(to: target)
                } else {
                    let attrs = try FileManager.default.attributesOfItem(atPath: target.path)
                    let size = (attrs[.size] as? NSNumber)?.intValue ?? -1
                    guard size == offset else { throw ExportError("кусок не по порядку: файл \(size), кусок с \(offset)") }
                    // Бросающие методы (iOS 13.4): старые write/seekToEndOfFile
                    // при полной памяти роняли бы приложение исключением.
                    let handle = try FileHandle(forWritingTo: target)
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: chunk)
                }
                let total = offset + chunk.count
                if last {
                    DispatchQueue.main.async {
                        self?.rememberFile(id, target)
                        self?.send(["event": "file-ready", "req": req, "id": id,
                                    "url": "\(MediaBridge.scheme)://file/\(target.lastPathComponent)", "bytes": total])
                    }
                } else {
                    self?.send(["event": "file-ack", "req": req, "id": id, "offset": total])
                }
            } catch {
                self?.send(["event": "file-error", "req": req, "id": id, "reason": error.localizedDescription])
            }
        }
    }

    func fileDrop(_ body: [String: Any]) {
        guard let id = MediaBridge.userId(body["id"] as? String) else { return }
        forgetFile(id)
        MediaBridge.fileQueue.async { MediaBridge.removeUserFiles(id) }
    }

    static func removeUserFiles(_ id: String) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: userDir.path)) ?? []
        for name in names where name.hasPrefix(id + ".") {
            try? FileManager.default.removeItem(at: userDir.appendingPathComponent(name))
        }
    }

    static func userFile(_ id: String) -> URL? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: userDir.path)) ?? []
        guard let name = names.first(where: { $0.hasPrefix(id + ".") }) else { return nil }
        return userDir.appendingPathComponent(name)
    }

    // MARK: - Фото и живые фото

    // Фото — JPEG стоя (ориентация применена), sRGB, не больше 4096 точек:
    // и превью (текстура WebGL), и экспорт телефоном берут один файл.
    func resolvePhoto(_ id: String, _ asset: PHAsset, done: @escaping (URL?) -> Void) {
        // В имени — время правки: фото обрезали в «Фото» — картинка новая.
        let stamp = Int(asset.modificationDate?.timeIntervalSince1970 ?? 0)
        let url = MediaBridge.cacheDir("ryndi-photos").appendingPathComponent("\(id)-\(stamp).jpg")
        if FileManager.default.fileExists(atPath: url.path) {
            rememberFile(id, url)
            done(url)
            return
        }
        let opts = PHImageRequestOptions()
        opts.isNetworkAccessAllowed = true          // фото может лежать в iCloud
        opts.deliveryMode = .highQualityFormat
        opts.version = .current
        PHImageManager.default().requestImageDataAndOrientation(for: asset, options: opts) { [weak self] data, _, _, _ in
            DispatchQueue.global(qos: .userInitiated).async {
                var ok = false
                if let data = data, let jpeg = MediaBridge.uprightJPEG(data, maxSide: 4096) {
                    ok = (try? jpeg.write(to: url, options: .atomic)) != nil
                }
                DispatchQueue.main.async {
                    if ok { self?.rememberFile(id, url); done(url) } else { done(nil) }
                }
            }
        }
    }

    static func uprightJPEG(_ data: Data, maxSide: CGFloat) -> Data? {
        guard let raw = CIImage(data: data, options: [.applyOrientationProperty: true]) else { return nil }
        let e = raw.extent
        guard e.width >= 1, e.height >= 1 else { return nil }
        var img = raw.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
        let long = max(e.width, e.height)
        if long > maxSide {
            img = img.applyingFilter("CILanczosScaleTransform", parameters: [
                kCIInputScaleKey: NSNumber(value: Double(maxSide / long)),
                kCIInputAspectRatioKey: NSNumber(value: 1.0),
            ])
        }
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let quality = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
        return CIContext().jpegRepresentation(of: img, colorSpace: srgb, options: [quality: 0.9])
    }

    // Ролик живого фото — «l…»: пишется в кэш один раз.
    func resolveLive(_ id: String, done: @escaping (URL?) -> Void) {
        let url = MediaBridge.cacheDir("ryndi-live").appendingPathComponent(id + ".mov")
        if FileManager.default.fileExists(atPath: url.path) {
            rememberFile(id, url)
            done(url)
            return
        }
        guard let local = MediaBridge.localIdentifier(from: id),
              let asset = PHAsset.fetchAssets(withLocalIdentifiers: [local], options: nil).firstObject else {
            done(nil)
            return
        }
        let resources = PHAssetResource.assetResources(for: asset)
        guard let video = resources.first(where: { $0.type == .fullSizePairedVideo })
                ?? resources.first(where: { $0.type == .pairedVideo }) else {
            done(nil)
            return
        }
        let opts = PHAssetResourceRequestOptions()
        opts.isNetworkAccessAllowed = true
        // Во временный файл, потом на место: оборванная загрузка из iCloud не
        // оставит недописанный ролик, два запроса сразу не столкнутся.
        let tmp = url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".mov")
        PHAssetResourceManager.default().writeData(for: video, toFile: tmp, options: opts) { [weak self] error in
            let fm = FileManager.default
            if error == nil, !fm.fileExists(atPath: url.path) { try? fm.moveItem(at: tmp, to: url) }
            try? fm.removeItem(at: tmp)
            let ok = error == nil && fm.fileExists(atPath: url.path)
            DispatchQueue.main.async {
                if ok { self?.rememberFile(id, url); done(url) } else { done(nil) }
            }
        }
    }

    // MARK: - Звук при записи голоса

    // audio-session { mode: "record" | "play" } — страница зовёт перед записью
    // голоса и после: при записи WebKit может сам переключить звук на
    // разговорный динамик и оставить так.
    static func audioSession(_ mode: String?) {
        let session = AVAudioSession.sharedInstance()
        if mode == "record" {
            try? session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP])
        } else {
            try? session.setCategory(.playback, mode: .moviePlayback, options: [])
        }
        try? session.setActive(true)
    }

    // MARK: - Вибрация

    func haptic(_ style: String?) {
        DispatchQueue.main.async {
            switch style {
            case "selection":
                UISelectionFeedbackGenerator().selectionChanged()
            case "success":
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            case "warning":
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
            case "heavy":
                UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
            case "medium":
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            default:
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
        }
    }
}
