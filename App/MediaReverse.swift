import UIKit
import AVFoundation

extension MediaBridge {
    func reverseCommand(_ body: [String: Any]) {
        let req = (body["req"] as? String) ?? ""
        guard reverser == nil, !exportRunning, let media = body["media"] as? String,
              let id = MediaBridge.userId(body["id"] as? String), id.hasPrefix("u-reverse-"),
              let from = ExportPlan.num(body["from"]), let duration = ExportPlan.num(body["duration"]) else {
            send(["event": "reverse-error", "req": req, "reason": "Реверсия недоступна или уже выполняется"]); return
        }
        let engine = ReverseMedia()
        reverser = (req, engine)
        UIApplication.shared.isIdleTimerDisabled = true
        let start: (URL?) -> Void = { [weak self] url in
            guard let self = self, self.reverser?.req == req else { return }
            guard let url = url, !engine.isCancelled else {
                self.finishReverse(req, error: (body["preview"] as? Bool == true ? "Лёгкая копия ещё не готова — повторите реверсию после подготовки" : "Исходный ролик не найден"), cancelled: engine.isCancelled); return
            }
            let destination = MediaBridge.userDir.appendingPathComponent(id + ".mp4")
            var value = 0.0
            let progressLock = NSLock()
            let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
                progressLock.lock(); let p = value; progressLock.unlock()
                self?.send(["event": "reverse-progress", "req": req, "value": p])
            }
            RunLoop.main.add(timer, forMode: .common)
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let info = try engine.run(source: url, destination: destination, from: from, duration: duration) { p in
                        progressLock.lock(); value = p; progressLock.unlock()
                    }
                    let attrs = try FileManager.default.attributesOfItem(atPath: destination.path)
                    DispatchQueue.main.async {
                        timer.invalidate()
                        if engine.isCancelled {
                            try? FileManager.default.removeItem(at: destination)
                            self.finishReverse(req, error: "Реверсия отменена", cancelled: true); return
                        }
                        self.rememberFile(id, destination)
                        self.send(["event": "reverse-ready", "req": req, "id": id,
                            "url": "\(MediaBridge.scheme)://file/\(id).mp4", "bytes": (attrs[.size] as? NSNumber)?.intValue ?? 0,
                            "duration": info.duration, "width": info.width, "height": info.height, "fps": info.fps, "transfer": info.transfer])
                        self.finishReverse(req)
                    }
                } catch {
                    var details = engine.failureDetails(error)
                    details["source"] = body["preview"] as? Bool == true ? "preview" : "original"
                    DispatchQueue.main.async {
                        timer.invalidate()
                        self.finishReverse(req, error: error.localizedDescription, cancelled: engine.isCancelled, details: details)
                    }
                }
            }
        }
        // Номер preview-URL тот же, что у оригинала; resolveFile(media)
        // всегда находил 4К. Источник теперь выбирается явно по назначению.
        previews.pause { [weak self] in
            guard let self = self else { return }
            if body["preview"] as? Bool == true { start(PreviewCopies.ready(media)) }
            else { self.resolveFile(media, done: start) }
        }
    }

    func cancelReverse(_ req: String?) {
        if let job = reverser, job.req == req { job.engine.cancel() }
    }

    private func finishReverse(_ req: String, error: String? = nil, cancelled: Bool = false, details: [String: Any]? = nil) {
        guard reverser?.req == req else { return }
        if let error = error {
            var event: [String: Any] = ["event": cancelled ? "reverse-cancelled" : "reverse-error", "req": req, "reason": error]
            if let details = details { event["details"] = details }
            send(event)
        }
        reverser = nil; UIApplication.shared.isIdleTimerDisabled = false; previews.resume()
    }
}
