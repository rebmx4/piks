import Foundation

extension MediaBridge {
    // Оригинал для веб-экспорта. Собственная схема WebKit недоступна fetch;
    // мост отдаёт ограниченные куски исходного файла без пересжатия.
    func readMediaBytes(_ body: [String: Any]) {
        let req = (body["req"] as? String) ?? ""
        guard let id = body["id"] as? String, !id.isEmpty else {
            send(["event": "media-read-error", "req": req, "reason": "нет номера исходника"])
            return
        }
        let offset = max(0, (body["offset"] as? Int) ?? 0)
        let length = max(0, min((body["length"] as? Int) ?? 0, 512 * 1024))
        let read: (URL?) -> Void = { [weak self] url in
            guard let self = self else { return }
            guard let url = url else {
                self.send(["event": "media-read-error", "req": req, "reason": "исходный файл недоступен — откройте ролик из Фото заново"])
                return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
                    let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
                    let handle = try FileHandle(forReadingFrom: url)
                    defer { try? handle.close() }
                    try handle.seek(toOffset: UInt64(min(offset, size)))
                    let data = try handle.read(upToCount: length) ?? Data()
                    self.send(["event": "media-read", "req": req, "size": size, "data": data.base64EncodedString()])
                } catch {
                    self.send(["event": "media-read-error", "req": req, "reason": "не удалось прочитать исходный файл",
                               "details": ExportDiagnostics.details(error, phase: "media-read")])
                }
            }
        }
        switch body["kind"] as? String {
        case "preview": read(PreviewCopies.ready(id))
        case "audio": read(audioFiles[id])
        default: resolveFile(id, done: read)
        }
    }
}
