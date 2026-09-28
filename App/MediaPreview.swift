import Foundation
import UIKit
import AVFoundation

// Копия ролика для просмотра (сборка №18, владелец 27.09.2026).
//
// Зачем. Ролик 4K HDR с айфона (2160×3840, ~50 Мбит/с) страница Ryndi
// показывает элементами видео WebKit, и телефон тянет их на ~10 кадрах в
// секунду (1080p — на 24). На разрезе второй элемент открывает место в
// тяжёлом файле дольше секунды — картинка встаёт (журнал 27.09: «картинка
// разошлась со звуком на −1 с»). Как «оптимизированные медиа» в LumaFusion:
// для просмотра — лёгкая копия 1080p, экспорт — по-прежнему из оригинала
// (NativeExport.swift берёт ролик по его номеру «p…», копию не трогает).
//
// Как. Команда `preview {id, force}` — копия ролика id пресетом системы
// 1920x1080 (H.264, считает видеокарта; HDR пресет переводит в обычный цвет
// сам). Копия лежит в Library/Caches/ryndi-preview/<id>.mp4 и переживает
// перезапуск; есть — ответ сразу (force — сделать заново: ролик обрезали в
// «Фото», длина копии не та). События: preview-progress {id, value},
// preview-ready {id, url, bytes, took, seconds}, preview-error {id, reason}.
// Адрес — ryndi-media://preview/<id>.mp4 (MediaServer.swift).
//
// Порядок: по одной копии за раз (и пока телефон ищет файл ролика — тоже),
// не во время экспорта телефоном (один кодировщик на двоих) и не в фоне
// (там видеокарта недоступна — ждём возвращения). Копий в сумме — не больше
// 3 ГБ: уходят самые давние, кроме нужных в этом запуске.
final class PreviewCopies {

    weak var bridge: MediaBridge?

    private var queue: [String] = []
    // Фоновая очередь (сборка №22): копии для копий проектов (MediaKeep.swift)
    // — только когда очередь страницы пуста; страница попросила тот же
    // ролик — он переходит в её очередь.
    private var low: [String] = []
    private var lowIds = Set<String>()                 // что сейчас делается для фона
    private var forced = Set<String>()                 // сделать заново, даже если копия есть
    private var resolving: String?                     // ищем файл ролика (current ещё нет)
    private var current: (id: String, session: AVAssetExportSession, timer: Timer, part: URL)?
    private var cancelling = false                     // current отменяется
    private var used = Set<String>()                   // нужны в этом запуске — не удалять
    private var retries: [String: Int] = [:]           // сколько раз копию прерывала система

    private static let limit: Int64 = 3 * 1024 * 1024 * 1024

    // Идёт копия или ждёт очереди по просьбе страницы — кэш не чистим
    // (MediaKeep.swift). Фоновая работа не в счёт: её отменяет stopBackground.
    var busy: Bool {
        if !queue.isEmpty { return true }
        if let cur = current, !lowIds.contains(cur.id) { return true }
        if let r = resolving, !lowIds.contains(r) { return true }
        return false
    }

    // Очистка кэша: фоновые копии — отменить (копия проекта попросит снова).
    func stopBackground() {
        let pending = low
        low.removeAll()
        for id in pending { lowIds.remove(id); fail(id, "отменено очисткой кэша") }
        if let cur = current, lowIds.contains(cur.id), !cancelling {
            cancelling = true
            cur.session.cancelExport()
        }
    }

    init() {
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.next() }
    }

    static var folder: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("ryndi-preview", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // Номер ролика — только буквы, цифры, «-» и «_» (MediaBridge.stableId):
    // из него имя файла, ничего лишнего в путь не попадёт.
    private static func safe(_ id: String) -> String {
        return id.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    static func file(_ id: String) -> URL { folder.appendingPathComponent(safe(id) + ".mp4") }

    // Готовая копия ролика id или nil.
    static func ready(_ id: String) -> URL? {
        let f = file(id)
        return FileManager.default.fileExists(atPath: f.path) ? f : nil
    }

    func request(_ id: String?, force: Bool, background: Bool = false) {
        guard let id = id, !PreviewCopies.safe(id).isEmpty else { return }
        used.insert(id)
        if !force, let f = PreviewCopies.ready(id) {
            // Недавно нужная копия — последней в очереди на удаление.
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: f.path)
            sendReady(id, f, took: 0)
            return
        }
        if background {
            if resolving == id || queue.contains(id) || low.contains(id) { return }
            if let cur = current, cur.id == id, !cancelling { return }
            low.append(id)
            lowIds.insert(id)
            next()
            return
        }
        // Страница просит — из фона в её очередь (или уже делается — пусть).
        lowIds.remove(id)
        low.removeAll { $0 == id }
        if resolving == id || queue.contains(id) { return }
        if let cur = current, cur.id == id, !cancelling { return }
        if force { forced.insert(id) }
        retries[id] = nil
        queue.append(id)
        next()
    }

    func cancel(_ id: String?) {
        guard let id = id else { return }
        forced.remove(id)
        retries[id] = nil
        if low.contains(id) {
            low.removeAll { $0 == id }
            lowIds.remove(id)
            fail(id, "отменено")
        }
        if queue.contains(id) {
            queue.removeAll { $0 == id }
            fail(id, "отменено")
        }
        if resolving == id {
            resolving = nil
            fail(id, "отменено")
            next()
            return
        }
        if let cur = current, cur.id == id {
            cancelling = true
            cur.session.cancelExport()
        }
    }

    // Экспорт телефоном начинается — идущая копия уступает кодировщик и
    // встаёт в начало очереди; кончился — очередь идёт дальше (MediaBridge).
    func pause() {
        guard let cur = current, !cancelling else { return }
        requeue(cur.id)                      // ветка .cancelled увидит id в очереди — без «отменено»
        cancelling = true
        cur.session.cancelExport()
    }
    func resume() { next() }

    // Снова в начало своей очереди: фоновая работа — в фоновую.
    private func requeue(_ id: String) {
        if lowIds.contains(id) { low.insert(id, at: 0) } else { queue.insert(id, at: 0) }
    }
    private func waiting(_ id: String) -> Bool { queue.contains(id) || low.contains(id) }

    private func next() {
        guard current == nil, resolving == nil, !queue.isEmpty || !low.isEmpty, let bridge = bridge,
              !bridge.exportRunning, UIApplication.shared.applicationState == .active else { return }
        let id = !queue.isEmpty ? queue.removeFirst() : low.removeFirst()
        resolving = id
        if forced.contains(id) { bridge.forgetFile(id) }    // обрезали в «Фото» — файл мог смениться
        bridge.resolveFile(id) { [weak self] url in
            guard let self = self, self.resolving == id else { return }     // отменили, пока искали
            self.resolving = nil
            guard let url = url else {
                self.fail(id, "ролик не найден")
                self.next()
                return
            }
            if !self.forced.contains(id), let f = PreviewCopies.ready(id) {  // успела появиться
                self.sendReady(id, f, took: 0)
                self.next()
                return
            }
            if self.bridge?.exportRunning ?? true || UIApplication.shared.applicationState != .active {
                self.requeue(id)                              // resume() / didBecomeActive запустят снова
                return
            }
            self.forced.remove(id)
            self.start(id, AVURLAsset(url: url))
        }
    }

    private func start(_ id: String, _ asset: AVURLAsset) {
        let preset = AVAssetExportPreset1920x1080
        guard AVAssetExportSession.exportPresets(compatibleWith: asset).contains(preset),
              let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            fail(id, "телефон не берётся сделать копию этого ролика")
            next()
            return
        }
        // Своё имя недописанному файлу: прежний (приложение закрыли посреди
        // копии) не мешает, его уберёт prune.
        let part = PreviewCopies.folder.appendingPathComponent(PreviewCopies.safe(id) + "-" + UUID().uuidString + ".part.mp4")
        session.outputURL = part
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true      // заголовок в начале — открывается сразу
        let started = Date()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self, weak session] _ in
            guard let session = session else { return }
            self?.bridge?.send(["event": "preview-progress", "id": id, "value": Double(session.progress)])
        }
        RunLoop.main.add(timer, forMode: .common)       // и пока листают — ход не встаёт
        current = (id, session, timer, part)

        session.exportAsynchronously { [weak self] in
            DispatchQueue.main.async {
                timer.invalidate()
                guard let self = self else { return }
                self.current = nil
                let wasCancelled = self.cancelling
                self.cancelling = false
                switch session.status {
                case .completed:
                    self.queue.removeAll { $0 == id }
                    self.low.removeAll { $0 == id }
                    self.forced.remove(id)
                    self.retries[id] = nil
                    let dest = PreviewCopies.file(id)
                    try? FileManager.default.removeItem(at: dest)
                    do {
                        try FileManager.default.moveItem(at: part, to: dest)
                        self.prune(keep: dest)
                        self.sendReady(id, dest, took: Date().timeIntervalSince(started))
                    } catch {
                        try? FileManager.default.removeItem(at: part)
                        self.fail(id, "копия не сохранилась")
                    }
                case .cancelled where !wasCancelled && UIApplication.shared.applicationState != .active,
                     .failed where !wasCancelled && (UIApplication.shared.applicationState != .active
                        || (session.error as NSError?)?.code == -11847):
                    // Ушли в фон или систему заняли — видеокарта недоступна:
                    // копию начнём заново, когда приложение вернётся
                    // (didBecomeActive → next); прервали при открытом — через
                    // 2 с, не больше трёх раз.
                    try? FileManager.default.removeItem(at: part)
                    if UIApplication.shared.applicationState == .active {
                        // В фоне попытка не считается: там видеокарта недоступна всегда.
                        let n = (self.retries[id] ?? 0) + 1
                        self.retries[id] = n
                        guard n <= 3 else {
                            self.retries[id] = nil
                            self.fail(id, session.error?.localizedDescription ?? "копию прерывает система")
                            self.next()
                            return
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.next() }
                    }
                    self.requeue(id)
                    return
                case .cancelled:
                    try? FileManager.default.removeItem(at: part)
                    // Отменили и тут же попросили снова — просьба уже в очереди.
                    if !self.waiting(id) { self.fail(id, "отменено") }
                default:
                    try? FileManager.default.removeItem(at: part)
                    // Уступила экспорту (pause) — id уже в очереди, это не ошибка.
                    if !(wasCancelled && self.waiting(id)) {
                        self.fail(id, session.error?.localizedDescription ?? "копия не вышла")
                    }
                }
                self.next()
            }
        }
    }

    private func sendReady(_ id: String, _ file: URL, took: Double) {
        lowIds.remove(id)
        // Копию ждала копия проекта (сборка №22, MediaKeep.swift).
        bridge?.keepFromPreview(id, file: file, reason: "")
        let attrs = try? FileManager.default.attributesOfItem(atPath: file.path)
        let bytes = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        let seconds = CMTimeGetSeconds(AVURLAsset(url: file).duration)
        let version = Int(((attrs?[.creationDate] as? Date) ?? Date()).timeIntervalSince1970)   // новая копия — новый адрес
        bridge?.send([
            "event": "preview-ready", "id": id,
            "url": "\(MediaBridge.scheme)://preview/\(id).mp4?v=\(version)",
            "bytes": bytes, "took": took, "seconds": seconds.isFinite ? seconds : 0,
        ])
    }

    private func fail(_ id: String, _ reason: String) {
        lowIds.remove(id)
        bridge?.keepFromPreview(id, file: nil, reason: reason)
        bridge?.send(["event": "preview-error", "id": id, "reason": reason])
    }

    // Недописанные файлы (приложение закрыли посреди копии) — вон; копий
    // больше 3 ГБ — удаляем самые давние (по дате последней нужды), кроме
    // только что сделанной и нужных в этом запуске. Кэш iOS и сама может
    // почистить при нехватке места — тогда страница попросит копию заново.
    private func prune(keep: URL) {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let list = try? fm.contentsOfDirectory(at: PreviewCopies.folder, includingPropertiesForKeys: keys) else { return }
        for u in list where u.lastPathComponent.hasSuffix(".part.mp4") { try? fm.removeItem(at: u) }
        let keepNames = Set(used.map { PreviewCopies.file($0).lastPathComponent })
        var items: [(url: URL, size: Int64, date: Date)] = list.compactMap { u in
            guard u.pathExtension == "mp4", !u.lastPathComponent.hasSuffix(".part.mp4"),
                  let v = try? u.resourceValues(forKeys: Set(keys)) else { return nil }
            return (u, Int64(v.fileSize ?? 0), v.contentModificationDate ?? .distantPast)
        }
        var total = items.reduce(Int64(0)) { $0 + $1.size }
        items.sort { $0.date < $1.date }
        for it in items where total > PreviewCopies.limit && it.url != keep && !keepNames.contains(it.url.lastPathComponent) {
            try? fm.removeItem(at: it.url)
            total -= it.size
        }
    }
}
