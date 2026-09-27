import AVFoundation
import ImageIO

// Файлы из «Поделиться → APIKS» (сборка №19, ShareExtension). Расширение
// кладёт их в общую папку группы приложений (Inbox: файл и описание .json).
// Страница забирает их сама (caps «inbox»), при запуске и когда приложение
// снова на экране: inbox { req } → inbox { req, items: [{ id, url, kind,
// name, bytes, seconds, w, h }] }. Файл переезжает к файлам страницы
// (MediaFiles.swift, номер «u-share-…») и дальше живёт как ролик из
// галереи: превью, лёгкая копия, волна, звук и экспорт — по адресу
// ryndi-media://file/<номер>.<расширение>.
extension MediaBridge {

    static let appGroup = "group.com.piks.app"

    func takeInbox(_ body: [String: Any]) {
        let req = (body["req"] as? String) ?? ""
        MediaBridge.fileQueue.async { [weak self] in
            let items = MediaBridge.moveInbox()
            DispatchQueue.main.async {
                for it in items {
                    if let id = it["id"] as? String, let file = MediaBridge.userFile(id) { self?.rememberFile(id, file) }
                }
                self?.send(["event": "inbox", "req": req, "items": items])
            }
        }
    }

    // Всё, что лежит в Inbox, — к файлам страницы, по порядку отправки.
    static func moveInbox() -> [[String: Any]] {
        let fm = FileManager.default
        guard let base = fm.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else { return [] }
        let inbox = base.appendingPathComponent("Inbox", isDirectory: true)
        let metas = ((try? fm.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
        var list: [(order: Double, meta: [String: Any], file: URL, json: URL)] = []
        for m in metas {
            guard let data = try? Data(contentsOf: m),
                  let meta = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let name = meta["file"] as? String else {
                try? fm.removeItem(at: m)
                continue
            }
            let at = (meta["at"] as? Double) ?? 0
            let n = Double((meta["n"] as? Int) ?? 0)
            list.append((at * 1000 + n, meta, inbox.appendingPathComponent(name), m))
        }
        list.sort { $0.order < $1.order }
        var out: [[String: Any]] = []
        for entry in list {
            defer { try? fm.removeItem(at: entry.json) }
            let stem = entry.file.deletingPathExtension().lastPathComponent.filter { $0.isLetter || $0.isNumber }
            let id = "u-share-" + String(stem.prefix(40))
            let ext = safeExt(entry.file.pathExtension)
            removeUserFiles(id)
            let dst = userDir.appendingPathComponent(id + "." + ext)
            do { try fm.moveItem(at: entry.file, to: dst) } catch { continue }
            let size = ((try? fm.attributesOfItem(atPath: dst.path))?[.size] as? NSNumber)?.intValue ?? 0
            // Фото (сборка №20): размер стоя, с учётом поворота снимка.
            if (entry.meta["kind"] as? String) == "photo" {
                var w = 0, h = 0
                if let src = CGImageSourceCreateWithURL(dst as CFURL, nil),
                   let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
                    w = (p[kCGImagePropertyPixelWidth] as? Int) ?? 0
                    h = (p[kCGImagePropertyPixelHeight] as? Int) ?? 0
                    if let o = p[kCGImagePropertyOrientation] as? Int, o >= 5 { swap(&w, &h) }
                }
                out.append(["id": id, "url": "\(scheme)://file/\(dst.lastPathComponent)", "kind": "photo",
                            "name": (entry.meta["name"] as? String) ?? "", "bytes": size, "seconds": 0, "w": w, "h": h])
                continue
            }
            let asset = AVURLAsset(url: dst, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            var item: [String: Any] = [
                "id": id, "url": "\(scheme)://file/\(dst.lastPathComponent)",
                "kind": (entry.meta["kind"] as? String) ?? "video", "name": (entry.meta["name"] as? String) ?? "",
                "bytes": size, "seconds": max(0, CMTimeGetSeconds(asset.duration)),
            ]
            if let v = asset.tracks(withMediaType: .video).first {
                let s = v.naturalSize.applying(v.preferredTransform)
                item["w"] = Int(abs(s.width).rounded())
                item["h"] = Int(abs(s.height).rounded())
            } else {
                item["kind"] = "audio"             // «видео» без картинки — это звук
            }
            out.append(item)
        }
        return out
    }
}
