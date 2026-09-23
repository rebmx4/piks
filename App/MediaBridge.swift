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
// 6 секунд из 236. Оболочка решает это штатно: берёт ролик из галереи без
// копирования и пересжимает его в 1080p средствами телефона, на видеокарте.
//
// Что отдаём вебу: адрес вида ryndi-media://proxy/<id>.mp4 на уже облегчённую
// копию. Свою схему обслуживает этот же класс, с поддержкой докачки по частям
// (без неё перемотка видео не работает) и с заголовком доступа, без которого
// кадр нельзя положить в текстуру WebGL.
final class MediaBridge: NSObject {

    static let scheme = "ryndi-media"
    static let handlerName = "ryndi"

    private weak var webView: WKWebView?
    private weak var host: UIViewController?

    private var files: [String: URL] = [:]          // id -> файл облегчённой копии
    private var stopped = Set<ObjectIdentifier>()   // задачи, которые WebKit отменил
    private var export: AVAssetExportSession?
    private var progressTimer: Timer?

    init(host: UIViewController) {
        self.host = host
        super.init()
    }

    func attach(_ webView: WKWebView) { self.webView = webView }

    // Доступ для обработчика схемы, который лежит в соседнем файле.
    // В Swift private ограничен файлом, поэтому поля отдаём через методы.
    func proxyFile(_ id: String) -> URL? { files[id] }
    func markStopped(_ key: ObjectIdentifier) { stopped.insert(key) }
    func unmarkStopped(_ key: ObjectIdentifier) { stopped.remove(key) }
    func isStopped(_ key: ObjectIdentifier) -> Bool { stopped.contains(key) }

    // MARK: - Команды со страницы

    func handle(_ message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        switch body["cmd"] as? String {
        case "ping":  send(["event": "ready"])
        case "pick":  pickVideo()
        default:      break
        }
    }

    private func send(_ payload: [String: Any]) {
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
