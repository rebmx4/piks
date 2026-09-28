import Foundation
import AVFoundation

// Копии роликов проектов и кэш (сборка №22, владелец 28.09.2026: «проекты
// должны храниться в кэше телефона», «только копии 1080», «клавишу в
// настройках — очистить кэш»).
//
// Зачем. Проект открывает ролик прямо из галереи по номеру (ryndi-media://
// orig/<id>). Ролик удалили из галереи или он остался только в iCloud без
// сети — проект не открывался («ролик не сохранён — выберите заново»,
// журнал 26–28.09: 9 раз). Теперь у приложения своя копия каждого ролика
// проекта в Application Support/ryndi-keep (в резервную копию iCloud не
// идёт): ролик до 1080p — сам файл (на том же диске копия — клон, места
// почти не тратит, пока файл не меняется), больше — лёгкая копия 1080p
// (MediaPreview.swift, её же клоном; делается в фоновой очереди — уступает
// просьбам страницы). Фото и живые фото — их картинка и ролик. Оригинала
// нет — resolveFile отдаёт копию по тому же адресу: превью, волна, звук и
// экспорт телефоном ничего не замечают. Оригинала уже нет, а лёгкая копия
// или картинка ещё в кэше — она и становится копией проекта.
//
// Команды страницы (web/platform/native.js, web/platform/cache.js):
//   keep { id } → keep-ready { id, bytes, how, fresh } | keep-error { id, reason }
//   keep-drop { ids } — копии и кэш роликов удалённых проектов
//   cache { req, clear, keepIds } → cache { req, cache, kept, cleared, reason } —
//     кэш: лёгкие копии, копии фото и живых фото, временные файлы (звук
//     роликов, пересжатые копии, экспорты); kept — копии роликов проектов,
//     их очистка кэша не трогает. keepIds — ролики проектов: их лёгкую копию
//     или картинку, пока у ролика нет копии проекта, очистка не стирает
//     (оригинала может не быть — она последняя).
// Событие keep-used { id } — оригинала нет, отдана копия (раз за запуск).
extension MediaBridge {

    static let keepDir: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ryndi-keep", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var marked = dir
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? marked.setResourceValues(values)
        return dir
    }()

    // Кто ждёт лёгкую копию, чтобы сделать из неё копию проекта; о чьей
    // копии страница уже знает; чьи копии уже не нужны (проект удалён —
    // идущая копия не дописывается). С разных очередей — под замком.
    private static let keepLock = NSLock()
    private static var keepWaiting = Set<String>()
    private static var keepUsedSaid = Set<String>()
    private static var keepDropped = Set<String>()

    private static func locked<T>(_ body: () -> T) -> T {
        keepLock.lock()
        defer { keepLock.unlock() }
        return body()
    }

    // Номер ролика — только буквы, цифры, «-» и «_»: из него имя файла.
    static func keepSafe(_ id: String) -> String {
        return id.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    // Готовая копия ролика id (любое расширение) или nil.
    static func keptFile(_ id: String) -> URL? {
        let safe = keepSafe(id)
        guard !safe.isEmpty else { return nil }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: keepDir.path)) ?? []
        guard let name = names.first(where: { $0.hasPrefix(safe + ".") && !$0.hasSuffix(".part") }) else { return nil }
        return keepDir.appendingPathComponent(name)
    }

    // Картинка фото id в кэше (MediaFiles.swift: «<id>-<время правки>.jpg»),
    // самая свежая, или nil.
    static func cachedPhoto(_ id: String) -> URL? {
        let dir = cacheDir("ryndi-photos")
        let prefix = keepSafe(id) + "-"
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasPrefix(prefix) && $0.hasSuffix(".jpg") }
            .sorted()
        guard let name = names.last else { return nil }
        return dir.appendingPathComponent(name)
    }

    static func fileSize(_ url: URL) -> Int {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.intValue ?? 0
    }

    // Ролик уже не больше 1080p — копией идёт сам файл.
    static func fitsKeep(_ url: URL) -> Bool {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .video).first else { return true }
        let size = track.naturalSize.applying(track.preferredTransform)
        let w = abs(size.width), h = abs(size.height)
        return max(w, h) <= 1920.5 && min(w, h) <= 1080.5
    }

    // Оригинала нет — копия проекта (или nil). Страница узнаёт об этом раз
    // за запуск: в журнале видно, что проект держится на копии.
    func keptFallback(_ id: String) -> URL? {
        guard let file = MediaBridge.keptFile(id) else { return nil }
        let first = MediaBridge.locked { MediaBridge.keepUsedSaid.insert(id).inserted }
        if first {
            DispatchQueue.main.async { [weak self] in self?.send(["event": "keep-used", "id": id]) }
        }
        return file
    }

    // MARK: - Команды

    func keep(_ id: String?) {
        guard let id = id, !MediaBridge.keepSafe(id).isEmpty else { return }
        // Файл страницы («u…») и так живёт у приложения (MediaFiles.swift).
        if id.hasPrefix("u") {
            send(["event": "keep-ready", "id": id, "bytes": 0, "how": "файл приложения", "fresh": false])
            return
        }
        MediaBridge.locked { _ = MediaBridge.keepDropped.remove(id) }      // снова нужен
        // Есть ли уже копия — в очереди файлов, после уже поставленных удалений.
        MediaBridge.fileQueue.async { [weak self] in
            let kept = MediaBridge.keptFile(id)
            let bytes = kept.map { MediaBridge.fileSize($0) } ?? 0
            DispatchQueue.main.async {
                guard let self = self else { return }
                if kept != nil {
                    self.send(["event": "keep-ready", "id": id, "bytes": bytes, "how": "была", "fresh": false])
                } else {
                    self.keepMake(id)
                }
            }
        }
    }

    private func keepMake(_ id: String) {
        resolveFile(id) { [weak self] url in
            guard let self = self else { return }
            guard let url = url else {
                // Оригинала нет, но лёгкая копия или картинка ещё в кэше —
                // она и станет копией проекта, пока её не стёрли.
                if let copy = PreviewCopies.ready(id) {
                    self.keepClone(id, from: copy, how: "копия 1080p (оригинала нет)")
                } else if let photo = MediaBridge.cachedPhoto(id) {
                    self.keepClone(id, from: photo, how: "картинка (оригинала нет)")
                } else {
                    self.send(["event": "keep-error", "id": id, "reason": "ролика нет в галерее"])
                }
                return
            }
            let picture = ["jpg", "jpeg", "png", "heic", "heif"].contains(url.pathExtension.lowercased())
            if picture || id.hasPrefix("l") {
                self.keepClone(id, from: url, how: picture ? "картинка" : "ролик живого фото")
                return
            }
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let fits = MediaBridge.fitsKeep(url)
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    if fits {
                        self.keepClone(id, from: url, how: "сам ролик")
                    } else if let copy = PreviewCopies.ready(id) {
                        self.keepClone(id, from: copy, how: "копия 1080p")
                    } else {
                        // Больше 1080p и лёгкой копии ещё нет — просим её в
                        // фоновой очереди (MediaPreview.swift); готова —
                        // keepFromPreview.
                        MediaBridge.locked { _ = MediaBridge.keepWaiting.insert(id) }
                        self.previews.request(id, force: false, background: true)
                    }
                }
            }
        }
    }

    // Лёгкая копия готова (или не вышла) — если её ждала копия проекта.
    func keepFromPreview(_ id: String, file: URL?, reason: String) {
        let waited = MediaBridge.locked { MediaBridge.keepWaiting.remove(id) != nil }
        guard waited else { return }
        if let file = file {
            keepClone(id, from: file, how: "копия 1080p")
        } else {
            send(["event": "keep-error", "id": id, "reason": reason])
        }
    }

    // Копия файла к копиям проектов: сначала недописанной, потом на место.
    // Проект успели удалить — не дописываем.
    func keepClone(_ id: String, from src: URL, how: String) {
        MediaBridge.fileQueue.async { [weak self] in
            let fm = FileManager.default
            let safe = MediaBridge.keepSafe(id)
            let ext = src.pathExtension.isEmpty ? "mp4" : src.pathExtension.lowercased()
            let dest = MediaBridge.keepDir.appendingPathComponent(safe + "." + ext)
            let part = MediaBridge.keepDir.appendingPathComponent(safe + "." + ext + ".part")
            try? fm.removeItem(at: part)
            do {
                try fm.copyItem(at: src, to: part)
                if MediaBridge.locked({ MediaBridge.keepDropped.contains(id) }) {
                    try? fm.removeItem(at: part)
                    return
                }
                if let old = MediaBridge.keptFile(id) { try? fm.removeItem(at: old) }
                try fm.moveItem(at: part, to: dest)
                let bytes = MediaBridge.fileSize(dest)
                DispatchQueue.main.async {
                    self?.send(["event": "keep-ready", "id": id, "bytes": bytes, "how": how, "fresh": true])
                }
            } catch {
                try? fm.removeItem(at: part)
                let reason = error.localizedDescription
                DispatchQueue.main.async {
                    self?.send(["event": "keep-error", "id": id, "reason": reason])
                }
            }
        }
    }

    // Проект удалён — копии его роликов и их кэш (страница присылает только
    // те, что не нужны другим проектам обеих версий сайта).
    func keepDrop(_ ids: [String]) {
        let list = ids.filter { !MediaBridge.keepSafe($0).isEmpty && !$0.hasPrefix("u") }
        guard !list.isEmpty else { return }
        MediaBridge.locked { () -> Void in
            for id in list {
                MediaBridge.keepDropped.insert(id)
                MediaBridge.keepWaiting.remove(id)
            }
        }
        for id in list {
            previews.cancel(id)
            forgetFile(id)
            if let audio = audioFiles[id] { try? FileManager.default.removeItem(at: audio) }
            audioFiles[id] = nil
        }
        MediaBridge.fileQueue.async {
            let fm = FileManager.default
            let photos = MediaBridge.cacheDir("ryndi-photos"), live = MediaBridge.cacheDir("ryndi-live")
            let photoNames = (try? fm.contentsOfDirectory(atPath: photos.path)) ?? []
            for id in list {
                if let kept = MediaBridge.keptFile(id) { try? fm.removeItem(at: kept) }
                if let copy = PreviewCopies.ready(id) { try? fm.removeItem(at: copy) }
                for name in photoNames where name.hasPrefix(MediaBridge.keepSafe(id) + "-") {
                    try? fm.removeItem(at: photos.appendingPathComponent(name))
                }
                try? fm.removeItem(at: live.appendingPathComponent(MediaBridge.keepSafe(id) + ".mov"))
            }
        }
    }

    // Размер кэша и копий проектов; clear — очистить кэш. Идёт экспорт или
    // лёгкая копия по просьбе страницы — не чистим (их файлы в работе),
    // честно говорим почему. Копии в фоне для копий проектов — отменяются
    // (страница попросит снова при следующем запуске).
    func cacheCommand(_ body: [String: Any]) {
        let req = (body["req"] as? String) ?? ""
        let asked = (body["clear"] as? Bool) ?? false
        let spare = Set(((body["keepIds"] as? [String]) ?? []).map { MediaBridge.keepSafe($0) })
        var clear = asked
        var reason = ""
        if clear && (exportRunning || previews.busy) {
            clear = false
            reason = exportRunning ? "идёт экспорт — попробуйте после него" : "делается лёгкая копия ролика — попробуйте через минуту"
        }
        if clear {
            previews.stopBackground()
            for (_, url) in audioFiles { try? FileManager.default.removeItem(at: url) }
            audioFiles.removeAll()
        }
        let doClear = clear
        let why = reason
        MediaBridge.fileQueue.async { [weak self] in
            if doClear { MediaBridge.clearCacheFiles(sparing: spare) }
            let cache = MediaBridge.cacheFiles().reduce(0) { $0 + MediaBridge.fileSize($1.url) }
            let kept = MediaBridge.filesIn(MediaBridge.keepDir).reduce(0) { $0 + MediaBridge.fileSize($1) }
            DispatchQueue.main.async {
                var answer: [String: Any] = ["event": "cache", "req": req, "cache": cache, "kept": kept, "cleared": doClear]
                if asked && !doClear { answer["reason"] = why }
                self?.send(answer)
            }
        }
    }

    // Файлы папки (без вложенных папок).
    static func filesIn(_ dir: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.map { dir.appendingPathComponent($0) }
    }

    // Что считается кэшем: лёгкие копии «<id>.mp4», картинки фото
    // «<id>-<время>.jpg», ролики живых фото «<id>.mov», временные файлы
    // приложения («ryndi-…»: звук роликов, пересжатые копии, экспорты).
    // id — чей это файл (у временных — пусто).
    static func cacheFiles() -> [(url: URL, id: String)] {
        var out: [(url: URL, id: String)] = []
        for u in filesIn(PreviewCopies.folder) { out.append((u, u.deletingPathExtension().lastPathComponent)) }
        for u in filesIn(cacheDir("ryndi-photos")) {
            let name = u.deletingPathExtension().lastPathComponent
            let id = name.range(of: "-", options: .backwards).map { String(name[..<$0.lowerBound]) } ?? name
            out.append((u, id))
        }
        for u in filesIn(cacheDir("ryndi-live")) { out.append((u, u.deletingPathExtension().lastPathComponent)) }
        let tmp = FileManager.default.temporaryDirectory
        for u in filesIn(tmp) where u.lastPathComponent.hasPrefix("ryndi-") { out.append((u, "")) }
        return out
    }

    // Очистка кэша. sparing — ролики проектов: их файл кэша остаётся, пока у
    // ролика нет копии проекта (она может быть последней).
    static func clearCacheFiles(sparing: Set<String>) {
        for item in cacheFiles() {
            if !item.id.isEmpty && sparing.contains(item.id) && keptFile(item.id) == nil { continue }
            try? FileManager.default.removeItem(at: item.url)
        }
    }
}
