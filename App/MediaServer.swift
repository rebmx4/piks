import Foundation
import WebKit

// Отдаёт облегчённую копию ролика странице по схеме ryndi-media://
//
// Две вещи здесь обязательны, и обе неочевидны:
//
// 1. Докачка по частям (заголовок Range). Без неё элемент video не умеет
//    перематывать и на длинном ролике просто не стартует.
// 2. Заголовок Access-Control-Allow-Origin. Страница живёт на https, а файл
//    приходит по своей схеме — это разные источники. Без разрешения кадр
//    нельзя положить в текстуру WebGL: холст считается «запачканным» и
//    загрузка кадра падает с ошибкой безопасности.
extension MediaBridge: WKURLSchemeHandler {

    private static let chunkLimit = 4 * 1024 * 1024   // не читаем в память больше 4 МБ за раз

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        let key = ObjectIdentifier(task)
        unmarkStopped(key)

        guard let url = task.request.url else {
            respond(task, key: key, status: 404, headers: [:], body: Data())
            return
        }
        // ryndi-media://orig/<id>.mp4 — файл находим по номеру; после
        // перезапуска приложения — заново через галерею.
        let id = (url.lastPathComponent as NSString).deletingPathExtension
        let rangeHeader = task.request.value(forHTTPHeaderField: "Range")

        resolveFile(id) { [weak self] fileURL in
            guard let self = self else { return }
            guard let fileURL = fileURL else {
                self.respond(task, key: key, status: 404, headers: [:], body: Data())
                return
            }
            self.serve(task, key: key, fileURL: fileURL, rangeHeader: rangeHeader)
        }
    }

    private func serve(_ task: WKURLSchemeTask, key: ObjectIdentifier, fileURL: URL, rangeHeader: String?) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
                let total = (attrs[.size] as? Int) ?? 0
                guard total > 0 else { throw NSError(domain: "ryndi", code: 1) }

                var start = 0
                var end = total - 1
                var status = 200

                if let raw = rangeHeader, raw.hasPrefix("bytes=") {
                    let spec = String(raw.dropFirst("bytes=".count))
                    let parts = spec.split(separator: "-", maxSplits: 1,
                                           omittingEmptySubsequences: false)
                    if parts.count == 2 {
                        if let s = Int(parts[0]), s >= 0 { start = s }
                        if let e = Int(parts[1]), e >= start { end = min(e, total - 1) }
                    }
                    guard start < total else { throw NSError(domain: "ryndi", code: 2) }
                    status = 206
                }

                // Ограничиваем кусок: отдать меньше запрошенного законно,
                // лишь бы Content-Range говорил правду.
                if end - start + 1 > MediaBridge.chunkLimit {
                    end = start + MediaBridge.chunkLimit - 1
                }

                let handle = try FileHandle(forReadingFrom: fileURL)
                defer { try? handle.close() }
                try handle.seek(toOffset: UInt64(start))
                let body = handle.readData(ofLength: end - start + 1)

                var headers: [String: String] = [
                    "Content-Type": "video/mp4",
                    "Accept-Ranges": "bytes",
                    "Content-Length": String(body.count),
                    "Access-Control-Allow-Origin": "*",
                    "Cache-Control": "no-store",
                ]
                if status == 206 {
                    headers["Content-Range"] = "bytes \(start)-\(end)/\(total)"
                }

                self.respond(task, key: key, status: status, headers: headers, body: body)
            } catch {
                self.respond(task, key: key, status: 404, headers: [:], body: Data())
            }
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        markStopped(ObjectIdentifier(task))
    }

    // MARK: - Внутреннее

    // Ответ отдаём с главной очереди и только если WebKit не отменил задачу:
    // обращение к отменённой задаче роняет приложение.
    private func respond(_ task: WKURLSchemeTask, key: ObjectIdentifier,
                         status: Int, headers: [String: String], body: Data) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, !self.isStopped(key) else { return }
            guard let url = task.request.url,
                  let response = HTTPURLResponse(url: url, statusCode: status,
                                                 httpVersion: "HTTP/1.1",
                                                 headerFields: headers) else {
                task.didFailWithError(NSError(domain: "ryndi", code: 3))
                return
            }
            task.didReceive(response)
            if !body.isEmpty { task.didReceive(body) }
            task.didFinish()
        }
    }
}
