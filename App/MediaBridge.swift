import UIKit
import WebKit
import Photos
import PhotosUI
import AVFoundation

// Мост к галерее для видеоредактора Ryndi.
//
// Зачем он нужен. Веб-страница получает ролик из галереи только полным
// копированием файла в свою песочницу. На материале владельца (4K, 4 ГБ,
// 147 Мбит/с) это занимает минуты, а Safari потом всё равно не успевает читать
// файл и воспроизведение встаёт: измерено на iPhone 13 Pro Max — прочитано
// 6 секунд из 236.
//
// Как решаем. Главный путь — отдать ОРИГИНАЛ там, где он лежит, вообще ничего
// не готовя. Так работает CapCut, поэтому у него ролик открывается мгновенно.
// Пересжатие в 1080p остаётся запасным вариантом на случай, когда файл
// напрямую недоступен: оно занимает время, пропорциональное длине ролика.
//
// Что отдаём вебу: адрес вида ryndi-media://orig/<id>.mp4 (или .../proxy/...,
// если пришлось пересжимать). Свою схему обслуживает этот же класс, с
// поддержкой докачки по частям — без неё перемотка не работает — и с
// заголовком доступа, без которого кадр нельзя положить в текстуру WebGL.
final class MediaBridge: NSObject {

    static let scheme = "ryndi-media"
    static let handlerName = "ryndi"

    private weak var webView: WKWebView?
    private weak var host: UIViewController?

    private var files: [String: URL] = [:]          // id -> файл ролика (оригинал или копия)
    var audioFiles: [String: URL] = [:]             // id -> звук ролика отдельным m4a (MediaAudio.swift)
    private var stopped = Set<ObjectIdentifier>()   // задачи, которые WebKit отменил
    private var export: AVAssetExportSession?
    private var progressTimer: Timer?
    private var exporter: NativeExporter?           // идущий нативный экспорт
    private var lastExport: URL?                    // последний готовый файл — для «Поделиться»

    // Что умеет эта сборка. Страница читает это до загрузки своих модулей
    // и решает, звать ли нативный экспорт. Старая сборка этого не пишет —
    // страница тогда работает как раньше.
    // build — номер сборки: по нему в журнале видно, какая сборка стоит у
    // владельца. wave — волна телефоном, audio — звук отдельным файлом,
    // ramps — плавная громкость по точкам в экспорте телефоном (сборка №13),
    // read — байты звукового файла ролика кусками: звук превью одним потоком,
    // как в экспорте (сборка №14, MediaAudio.swift). gallery — своя галерея
    // с альбомами и меткой цвета HDR (сборка №16, MediaGallery.swift).
    // Сборка №17 — общие кубики (NativeExport.swift, MediaFiles.swift,
    // MediaVision.swift): speed — скорость куска, crop — обрезка, mask — маска
    // картинкой, overlap — нахлёст кусков (переходы), cifilter — фильтры Core
    // Image по имени, stills — фото в экспорте, files — файлы от страницы,
    // photo и live — фото и живые фото из галереи, haptic — вибрация, mic —
    // микрофон (запись голоса; audio-session — режим звука), vision — разбор
    // «человек/фон» средствами iOS.
    static var capsScript: String {
        let build = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? ""
        return "window.__ryndiApp = { version: 3, build: '\(build)', caps: ['pick', 'export', 'photos', 'share', 'site', 'wave', 'audio', 'ramps', 'read', 'adjust', 'gallery', 'speed', 'crop', 'mask', 'overlap', 'cifilter', 'stills', 'files', 'photo', 'live', 'haptic', 'mic', 'vision'] };"
    }

    init(host: UIViewController) {
        self.host = host
        super.init()
    }

    func attach(_ webView: WKWebView) { self.webView = webView }

    // Доступ для обработчика схемы, который лежит в соседнем файле.
    // В Swift private ограничен файлом, поэтому поля отдаём через методы.
    func proxyFile(_ id: String) -> URL? { files[id] }
    func rememberFile(_ id: String, _ url: URL) { files[id] = url }
    func forgetFile(_ id: String) { files[id] = nil }
    func markStopped(_ key: ObjectIdentifier) { stopped.insert(key) }
    func unmarkStopped(_ key: ObjectIdentifier) { stopped.remove(key) }
    func isStopped(_ key: ObjectIdentifier) -> Bool { stopped.contains(key) }

    // MARK: - Команды со страницы

    func handle(_ message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        switch body["cmd"] as? String {
        case "ping":          send(["event": "ready"])
        case "pick":          pickVideo()
        case "proxy":         makeProxyOnDemand(body["id"] as? String)
        case "export":        startExport(body["plan"] as? String, job: body["job"] as? String)
        case "export-cancel": exporter?.cancel()
        case "export-share":  shareExport()
        case "site":          setSite(body["value"] as? String)
        case "wave":          makeWave(body["id"] as? String, buckets: (body["buckets"] as? Int) ?? 2000)
        case "audio":         makeAudioFile(body["id"] as? String)
        case "read":          readAudioBytes(body)
        case "gallery-albums", "gallery-assets", "gallery-use":
            galleryCommand(body["cmd"] as? String ?? "", body)
        case "file-put":      filePut(body)
        case "file-drop":     fileDrop(body)
        case "haptic":        haptic(body["style"] as? String)
        case "audio-session": MediaBridge.audioSession(body["mode"] as? String)
        case "vision-person": visionPerson(body)
        case "vision-cancel": visionCancel(body)
        default:              break
        }
    }

    // MARK: - Нативный экспорт

    private func startExport(_ text: String?, job: String?) {
        let job = job ?? "job"
        if exporter != nil {
            send(["event": "export-error", "job": job, "reason": "экспорт уже идёт"])
            return
        }
        guard let text = text, let data = text.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let plan = ExportPlan(json: json) else {
            send(["event": "export-error", "job": job, "reason": "план экспорта не прочитался"])
            return
        }
        let ex = NativeExporter(job: job, plan: plan,
            send: { [weak self] event in self?.send(event) },
            resolve: { [weak self] id, done in
                guard let self = self else { done(nil); return }
                self.resolveFile(id, done: done)
            })
        ex.onFinish = { [weak self] file in
            guard let self = self else { return }
            if let file = file {
                if let old = self.lastExport, old != file { try? FileManager.default.removeItem(at: old) }
                self.lastExport = file
            }
            self.exporter = nil
            UIApplication.shared.isIdleTimerDisabled = false
        }
        exporter = ex
        // Пока идёт экспорт, экран не гаснет: в фоне телефон не даёт считать
        // на видеокарте, и сборка оборвалась бы.
        UIApplication.shared.isIdleTimerDisabled = true
        ex.start()
    }

    // Готовый файл — в системное окно «Поделиться»: Instagram, Telegram, Файлы.
    private func shareExport() {
        guard let file = lastExport, FileManager.default.fileExists(atPath: file.path),
              let host = host else {
            send(["event": "share-error", "reason": "файла экспорта уже нет — экспортируйте заново"])
            return
        }
        let sheet = UIActivityViewController(activityItems: [file], applicationActivities: nil)
        if let pop = sheet.popoverPresentationController {
            pop.sourceView = host.view
            pop.sourceRect = CGRect(x: host.view.bounds.midX, y: host.view.bounds.midY, width: 0, height: 0)
            pop.permittedArrowDirections = []
        }
        host.present(sheet, animated: true)
    }

    // «Тестовая версия» в профиле: приложение открывает /ryn-next/ или /ryn/.
    private func setSite(_ value: String?) {
        (host as? ViewController)?.switchSite(value == "next" ? "next" : "stable")
    }

    // MARK: - Постоянные адреса роликов
    //
    // Раньше адрес ролика был случайным номером и жил, пока открыто
    // приложение: после перезапуска проект терял ролик. Теперь в адресе —
    // номер ролика в галерее (localIdentifier), и по нему файл находится
    // снова в любой момент.

    static func stableId(_ localIdentifier: String) -> String {
        let b64 = Data(localIdentifier.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "p" + b64
    }

    // «p…» — ролик или фото галереи, «l…» — ролик живого фото (сборка №17).
    static func localIdentifier(from id: String) -> String? {
        guard id.hasPrefix("p") || id.hasPrefix("l"), id.count > 1 else { return nil }
        var b64 = String(id.dropFirst())
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // Файл ролика по номеру из адреса. Ответ всегда на главной очереди.
    // Сборка №17: «u…» — файл страницы, «l…» — ролик живого фото, «p…» у фото —
    // картинка JPEG (MediaFiles.swift).
    func resolveFile(_ id: String, done: @escaping (URL?) -> Void) {
        if let file = files[id], FileManager.default.fileExists(atPath: file.path) {
            done(file)
            return
        }
        if id.hasPrefix("u") {
            let file = MediaBridge.userId(id).flatMap { MediaBridge.userFile($0) }
            if let file = file { files[id] = file }
            done(file)
            return
        }
        if id.hasPrefix("l") {
            resolveLive(id, done: done)
            return
        }
        guard let local = MediaBridge.localIdentifier(from: id),
              let asset = PHAsset.fetchAssets(withLocalIdentifiers: [local], options: nil).firstObject else {
            done(nil)
            return
        }
        if asset.mediaType == .image {
            resolvePhoto(id, asset, done: done)
            return
        }
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        options.version = .current
        PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { [weak self] avAsset, _, _ in
            let url = (avAsset as? AVURLAsset)?.url
            DispatchQueue.main.async {
                guard let url = url, FileManager.default.isReadableFile(atPath: url.path) else {
                    done(nil)
                    return
                }
                self?.files[id] = url
                done(url)
            }
        }
    }

    // Владелец попросил облегчить уже открытый ролик.
    private func makeProxyOnDemand(_ assetId: String?) {
        guard let assetId = assetId else { fail("нечего облегчать"); return }
        makeProxy(for: assetId)
    }

    func send(_ payload: [String: Any]) {
        guard let webView = webView,
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        let js = "window.__ryndiNative && window.__ryndiNative(\(json));"
        DispatchQueue.main.async { webView.evaluateJavaScript(js, completionHandler: nil) }
    }

    private func fail(_ reason: String) {
        stopProgress()
        send(["event": "error", "reason": reason])
    }

    // MARK: - Выбор ролика

    private func pickVideo() {
        // Нужен доступ к библиотеке: без него нельзя получить сам ролик,
        // можно только его копию, а копирование мы и обходим.
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] status in
            DispatchQueue.main.async {
                guard status == .authorized || status == .limited else {
                    self?.fail("нет доступа к галерее")
                    return
                }
                self?.presentPicker()
            }
        }
    }

    private func presentPicker() {
        var cfg = PHPickerConfiguration(photoLibrary: .shared())
        cfg.filter = .videos
        cfg.selectionLimit = 1
        cfg.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: cfg)
        picker.delegate = self
        host?.present(picker, animated: true)
    }

    // MARK: - Облегчённая копия

    private func makeProxy(for assetId: String) {
        let found = PHAsset.fetchAssets(withLocalIdentifiers: [assetId], options: nil)
        guard let asset = found.firstObject else { fail("ролик не найден в галерее"); return }

        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true          // ролик может лежать в iCloud
        options.deliveryMode = .highQualityFormat
        options.version = .current

        send(["event": "opening"])

        PHImageManager.default().requestAVAsset(forVideo: asset, options: options) {
            [weak self] avAsset, _, info in
            guard let self = self else { return }
            guard let avAsset = avAsset else {
                let cancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
                self.fail(cancelled ? "отменено" : "не удалось открыть ролик")
                return
            }
            let seconds = CMTimeGetSeconds(avAsset.duration)

            // Быстрый путь: отдаём ОРИГИНАЛ там, где он лежит, без пересжатия.
            // Так работает CapCut — он ничего не готовит заранее, поэтому ролик
            // открывается мгновенно. Пересжатие в 1080p оставляем запасным
            // вариантом: оно занимает время, пропорциональное длине ролика.
            if let urlAsset = avAsset as? AVURLAsset,
               FileManager.default.isReadableFile(atPath: urlAsset.url.path) {
                // Номер ролика в галерее, а не случайный: адрес переживёт
                // перезапуск приложения (см. «Постоянные адреса роликов»).
                let id = MediaBridge.stableId(assetId)
                self.files[id] = urlAsset.url
                let attrs = try? FileManager.default.attributesOfItem(atPath: urlAsset.url.path)
                let size = (attrs?[.size] as? Int) ?? 0
                self.send([
                    "event": "ready-file",
                    "url": "\(MediaBridge.scheme)://orig/\(id).mp4",
                    "bytes": size,
                    "seconds": seconds,
                    "original": true,
                ])
                return
            }

            // Оригинал недоступен напрямую — готовим облегчённую копию.
            DispatchQueue.main.async { self.exportProxy(from: avAsset, seconds: seconds) }
        }
    }

    private func exportProxy(from avAsset: AVAsset, seconds: Double) {
        // 1920x1080 — пресет системы: сам сохраняет пропорции, значит
        // вертикальный 2160x3840 становится 1080x1920. Считает видеокарта.
        let preset = AVAssetExportPreset1920x1080
        guard AVAssetExportSession.exportPresets(compatibleWith: avAsset).contains(preset),
              let session = AVAssetExportSession(asset: avAsset, presetName: preset) else {
            fail("телефон не берётся пересжать этот ролик")
            return
        }

        let id = UUID().uuidString
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("ryndi-\(id).mp4")
        try? FileManager.default.removeItem(at: out)

        session.outputURL = out
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true
        export = session

        startProgress(session)

        session.exportAsynchronously { [weak self] in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.stopProgress()
                switch session.status {
                case .completed:
                    self.files[id] = out
                    let attrs = try? FileManager.default.attributesOfItem(atPath: out.path)
                    let size = (attrs?[.size] as? Int) ?? 0
                    self.send([
                        "event": "ready-file",
                        "url": "\(MediaBridge.scheme)://proxy/\(id).mp4",
                        "bytes": size,
                        "seconds": seconds,
                    ])
                case .cancelled:
                    self.fail("отменено")
                default:
                    self.fail(session.error?.localizedDescription ?? "пересжатие не удалось")
                }
                self.export = nil
            }
        }
    }

    private func startProgress(_ session: AVAssetExportSession) {
        stopProgress()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) {
            [weak self, weak session] _ in
            guard let session = session else { return }
            self?.send(["event": "progress", "value": Double(session.progress)])
        }
    }

    private func stopProgress() {
        progressTimer?.invalidate()
        progressTimer = nil
    }
}

// MARK: - Выбор из галереи

extension MediaBridge: PHPickerViewControllerDelegate {
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let id = results.first?.assetIdentifier else {
            send(["event": "cancel"])
            return
        }
        makeProxy(for: id)
    }
}
