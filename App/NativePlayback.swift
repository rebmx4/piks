import UIKit
import AVFoundation

// Нативное превью Ryndi (сборка №23, caps «play»): при игре видео показывает
// сам телефон, как CapCut и LumaFusion.
//
// Зачем. Страница показывала каждый слой отдельным видео браузера и копировала
// каждый кадр в WebGL; на айфоне владельца (29.09.2026, журнал) превью шло по
// 6–15 кадров в секунду даже с одним видео, наложение — по 0–13, на каждой
// склейке картинка отставала на 0,3 с. Страница при этом почти не работала
// (0,3–0,9 мс на кадр) — упирался показ видео в браузере.
//
// Как. Страница присылает тот же ПЛАН, что для экспорта (web/core/nativeplan.js,
// в размере превью), — телефон собирает ту же композицию, что и экспорт
// (NativeExporter.assemble: слои, переходы, маски, фильтры, скорость, фото,
// надписи картинками, звук), и играет её AVPlayer'ом в слое ПОД прозрачной
// страницей, в прямоугольнике её превью. Страница остаётся управлением:
// лента, кнопки, ручки поверх; время ленты берёт у телефона (play-time).
// На паузе видео снова рисует страница (кадр точный, ручки, правки) — этот
// слой прячется по её просьбе (play-hide), когда её кадр уже на экране.
//
// Команды (MediaBridge): play-load { plan, key } — собрать заранее (ответ
// play-ready / play-error), play-start { t, key, requestId } (ответ play-started, дальше
// play-time { t } ~30 раз в секунду, в конце play-ended), play-pause (ответ
// play-paused { t }), play-seek { t }, play-hide, play-rect { x, y, w, h } —
// где превью на странице (точки), play-stop — выгрузить.
// При play-context start/pause/seek/stop адресуются key + requestId;
// события запуска несут тот же контекст. Без обоих полей — прежний протокол.
final class NativePlayback: NSObject {

    let view = UIView()                          // под webView: слой видео в прямоугольнике превью
    private var player = AVPlayer()
    private let playerLayer: AVPlayerLayer
    private var key: String?                     // план, который собран и стоит в проигрывателе
    private var loadingKey: String?
    private struct Run: Equatable {
        let key: String
        let requestId: String
    }
    private var run: Run?                        // nil — старый web без play-context
    private var gen = 0                           // номер загрузки: устаревшую сборку выбросить
    private var link: CADisplayLink?
    private var lastSent = 0.0
    private var wantPlay = false                 // пауза пришла, пока шла перемотка к началу, — не запускать
    private var startSeq = 0                      // номер запуска: прерванная перемотка не запускает
    private var seekSeq = 0
    private var seekTarget: Double?
    private var lastPosition = 0.0
    private var statusWatch: NSKeyValueObservation?
    private var playWatch: NSKeyValueObservation?
    private var failToken: NSObjectProtocol?
    private var endToken: NSObjectProtocol?
    private var temps = TempFiles()
    private let work = DispatchQueue(label: "ryndi.play.work")
    var send: (([String: Any]) -> Void)?
    var resolve: ((String, @escaping (URL?) -> Void) -> Void)?

    override init() {
        playerLayer = AVPlayerLayer(player: player)
        super.init()
        view.isUserInteractionEnabled = false     // касания — странице
        view.backgroundColor = .clear
        view.isHidden = true
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = UIColor.black.cgColor
        view.layer.addSublayer(playerLayer)
        player.actionAtItemEnd = .pause
        // Не ждать «запаса» перед запуском: ролики локальные, запуск — сразу.
        player.automaticallyWaitsToMinimizeStalling = false
        NotificationCenter.default.addObserver(self, selector: #selector(servicesReset),
            name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
    }

    @objc private func servicesReset() {
        DispatchQueue.main.async {
            // После сброса/удаления item AVPlayer уже может отдавать 0.
            // Последняя позиция сохраняется по его тикам и запросам перемотки.
            if self.key != nil || self.loadingKey != nil {
                self.failed("медиаслужба телефона перезапустилась", kind: "services-reset",
                            phase: "reset", at: self.seekTarget ?? self.lastPosition)
            }
            // Даже без текущего плана старый AVPlayer пережил глобальный reset.
            self.player.replaceCurrentItem(with: nil)
            self.player = AVPlayer()
            self.player.actionAtItemEnd = .pause
            self.player.automaticallyWaitsToMinimizeStalling = false
            self.playerLayer.player = self.player
        }
    }

    private static func time(_ seconds: Double) -> CMTime {
        return CMTime(seconds: max(0, seconds), preferredTimescale: 30000)
    }

    // MARK: - Сборка

    func load(_ text: String?, key newKey: String?) {
        guard let newKey = newKey else { return }
        if newKey == loadingKey { return }
        if newKey == key {
            gen += 1                              // собиравшийся другой план — отменён
            loadingKey = nil
            send?(["event": "play-ready", "key": newKey])
            return
        }
        // Новый запрос сразу отменяет старую сборку и запуск, даже при ошибке JSON.
        if player.rate != 0 || wantPlay { pause() }
        gen += 1
        startSeq += 1
        seekSeq += 1
        seekTarget = nil
        run = nil
        key = nil
        loadingKey = nil
        forget()
        guard let text = text, let data = text.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let plan = ExportPlan(json: json) else {
            send?(errorEvent("план превью не прочитался", kind: "prepare", phase: "prepare", key: newKey))
            return
        }
        let myGen = gen
        loadingKey = newKey
        let started = Date()
        resolveAll(plan) { [weak self] files in
            guard let self = self, myGen == self.gen else { return }
            self.work.async {
                let fresh = TempFiles()
                do {
                    let a = try NativeExporter.assemble(plan, files, temps: fresh)
                    DispatchQueue.main.async {
                        guard myGen == self.gen else { fresh.removeAll(); return }
                        self.install(a, key: newKey, temps: fresh)
                        self.send?(["event": "play-ready", "key": newKey,
                                    "took": Date().timeIntervalSince(started),
                                    "light": self.lightUsed, "total": plan.media.count])
                    }
                } catch {
                    fresh.removeAll()
                    DispatchQueue.main.async {
                        guard myGen == self.gen else { return }
                        self.loadingKey = nil
                        self.send?(self.errorEvent(error.localizedDescription, kind: "prepare", phase: "prepare",
                                                  key: newKey, error: error))
                    }
                }
            }
        }
    }

    // Ролики превью — ЛЁГКИЕ копии 1080p (MediaPreview.swift), как у превью
    // страницы: сборка №23 брала оригиналы 4K HEVC (журнал владельца 29.09:
    // через 1,4 с «Не удается выполнить действие», и следом у страницы «Media
    // failed to decode» — медиаслужба телефона не выдержала). Матрицы плана
    // от размера не зависят (кадр приводится к единице), копия — тот же кадр.
    private var lightUsed = 0
    private func resolveAll(_ plan: ExportPlan, _ done: @escaping ([String: URL]) -> Void) {
        let group = DispatchGroup()
        var found: [String: URL] = [:]
        let lock = NSLock()
        lightUsed = 0
        for (id, address) in plan.media {
            let name = URL(string: address)?.lastPathComponent ?? ""
            let fileId = (name as NSString).deletingPathExtension
            if let light = PreviewCopies.ready(fileId) {
                found[id] = light
                lightUsed += 1
                continue
            }
            group.enter()
            guard let resolve = resolve else { group.leave(); continue }
            resolve(fileId) { file in
                if let file = file {
                    lock.lock()
                    found[id] = file
                    lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) { done(found) }
    }

    private func install(_ a: PlanAssembly, key newKey: String, temps fresh: TempFiles) {
        startSeq += 1
        seekSeq += 1
        seekTarget = nil
        let item = AVPlayerItem(asset: a.comp)
        item.videoComposition = a.video
        item.audioMix = a.mix
        item.forwardPlaybackEndTime = a.total            // как экспорт: ровно до конца ролика
        item.audioTimePitchAlgorithm = .spectral         // звук кусков со скоростью — как в экспорте
        // Прошлое — в корзину: новый план заменил его целиком.
        forget()
        run = nil
        key = newKey
        loadingKey = nil
        player.replaceCurrentItem(with: item)
        watch(item, key: newKey, preparing: true)
        temps.removeAll()
        temps = fresh
    }

    // Перепривязываем наблюдателей на каждый Play: callback старого запуска
    // того же AVPlayerItem не получает идентификатор нового запуска.
    private func watch(_ item: AVPlayerItem, key itemKey: String, preparing: Bool = false) {
        forget()
        let context = run
        let sequence = startSeq
        endToken = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            guard let self = self, self.current(item, key: itemKey, run: context, sequence: sequence),
                  self.wantPlay else { return }
            self.wantPlay = false
            self.stopLink()
            self.send?(self.event("play-ended", fields: ["t": self.seconds()]))
        }
        failToken = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] note in
            guard let self = self, self.current(item, key: itemKey, run: context, sequence: sequence) else { return }
            let err = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            self.failed(err?.localizedDescription ?? "видео не доиграло", phase: "play", error: err)
        }
        statusWatch = item.observe(\.status, options: [.initial, .new]) { [weak self] it, _ in
            guard it.status == .failed else { return }
            let reason = it.error?.localizedDescription ?? "видео не открылось"
            DispatchQueue.main.async {
                guard let self = self, self.current(it, key: itemKey, run: context, sequence: sequence) else { return }
                self.failed(reason, kind: preparing ? "prepare" : "decode",
                            phase: preparing ? "prepare" : "play", error: it.error)
            }
        }
    }

    private func current(_ item: AVPlayerItem, key itemKey: String, run context: Run?, sequence: Int) -> Bool {
        return player.currentItem === item && key == itemKey && run == context && startSeq == sequence
    }

    private func forget() {
        if let t = endToken { NotificationCenter.default.removeObserver(t) }
        if let t = failToken { NotificationCenter.default.removeObserver(t) }
        endToken = nil
        failToken = nil
        statusWatch?.invalidate()
        statusWatch = nil
    }

    private func event(_ name: String, fields: [String: Any] = [:]) -> [String: Any] {
        var value = fields
        value["event"] = name
        if let key = key ?? loadingKey { value["key"] = key }
        if let run = run {
            value["key"] = run.key
            value["requestId"] = run.requestId
        }
        return value
    }

    // Не передаём userInfo целиком: там бывают адреса оригиналов и полные пути.
    private static func safe(_ text: String, limit: Int = 512) -> String {
        let pattern = #"(?:[A-Za-z][A-Za-z0-9+.-]*://|[A-Za-z]:[\\/]|/)[^\s\"'<>]+"#
        let clean = text.replacingOccurrences(of: pattern, with: "[redacted]", options: .regularExpression)
        return String(clean.prefix(limit))
    }

    private func errorEvent(_ reason: String, kind: String, phase: String, key errorKey: String? = nil,
                            error: Error? = nil, item: AVPlayerItem? = nil) -> [String: Any] {
        var value: [String: Any] = ["event": "play-error", "reason": Self.safe(reason), "kind": kind, "phase": phase]
        if let errorKey = errorKey { value["key"] = errorKey }
        if let error = error as NSError? {
            value["domain"] = Self.safe(error.domain, limit: 128)
            value["code"] = error.code
            var chain: [[String: Any]] = []
            var next: NSError? = error
            var visited = Set<ObjectIdentifier>()
            for _ in 0..<4 {
                guard let current = next, visited.insert(ObjectIdentifier(current)).inserted else { break }
                if current.domain == AVFoundationErrorDomain && current.code == AVError.Code.mediaServicesWereReset.rawValue {
                    value["kind"] = "services-reset"
                } else if (current.domain == NSCocoaErrorDomain && current.code == NSUserCancelledError) ||
                          (current.domain == NSURLErrorDomain && current.code == NSURLErrorCancelled) {
                    if value["kind"] as? String != "services-reset" { value["kind"] = "cancelled" }
                }
                if current !== error {
                    chain.append(["domain": Self.safe(current.domain, limit: 128), "code": current.code,
                                  "reason": Self.safe(current.localizedDescription)])
                }
                next = current.userInfo[NSUnderlyingErrorKey] as? NSError
            }
            if !chain.isEmpty { value["underlying"] = chain }
        }
        if let entries = item?.errorLog()?.events.suffix(3), !entries.isEmpty {
            value["errorLog"] = entries.map { entry -> [String: Any] in
                return ["domain": Self.safe(entry.errorDomain, limit: 128), "code": entry.errorStatusCode,
                        "reason": Self.safe(entry.errorComment ?? "")]
            }
        }
        return value
    }

    // Элемент не играет — странице ошибку (она сыграет сама), план — заново.
    private func failed(_ reason: String, kind: String = "decode", phase: String,
                        error: Error? = nil, at position: Double? = nil) {
        var failure = errorEvent(reason, kind: kind, phase: phase, key: key ?? loadingKey,
                                 error: error, item: player.currentItem)
        failure["t"] = position ?? seekTarget ?? seconds()
        if let run = run {
            failure["key"] = run.key
            failure["requestId"] = run.requestId
        }
        wantPlay = false
        player.pause()
        stopLink()
        // Последняя картинка остаётся до play-hide: страница сначала
        // декодирует и рисует нужный кадр резервного проигрывателя.
        key = nil
        loadingKey = nil
        run = nil
        gen += 1
        startSeq += 1
        seekSeq += 1
        seekTarget = nil
        forget()
        send?(failure)
    }

    private func seconds() -> Double {
        let t = CMTimeGetSeconds(player.currentTime())
        return t.isFinite ? t : 0
    }

    // MARK: - Игра

    func start(_ t: Double, key requestedKey: String? = nil, requestId: String? = nil) {
        // Старый web не передаёт ни одного поля; половинный контекст не принимаем.
        guard (requestedKey == nil) == (requestId == nil) else { return }
        if let requestedKey = requestedKey, let activeKey = loadingKey ?? key, requestedKey != activeKey { return }
        guard let item = player.currentItem, let itemKey = key, loadingKey == nil else {
            var failure = errorEvent("превью ещё не собрано", kind: "not-ready", phase: "start", key: requestedKey ?? loadingKey)
            if let requestId = requestId { failure["requestId"] = requestId }
            send?(failure)
            return
        }
        run = requestedKey.flatMap { key in requestId.map { Run(key: key, requestId: $0) } }
        player.pause()
        stopLink()
        MediaBridge.audioSession(nil)
        wantPlay = true
        startSeq += 1
        let mySeq = startSeq
        let context = run
        watch(item, key: itemKey)
        if item.status == .failed {
            failed(item.error?.localizedDescription ?? "видео не открылось", phase: "start", error: item.error)
            return
        }
        seekSeq += 1
        let mySeek = seekSeq
        seekTarget = max(0, t)
        lastPosition = max(0, t)
        player.seek(to: NativePlayback.time(t), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            DispatchQueue.main.async {
                guard let self = self, self.wantPlay, finished,
                      self.current(item, key: itemKey, run: context, sequence: mySeq) else { return }
                if mySeek == self.seekSeq { self.seekTarget = nil }
                self.playWatch = self.player.observe(\.timeControlStatus, options: [.new]) { [weak self] p, _ in
                    guard p.timeControlStatus == .playing else { return }
                    DispatchQueue.main.async {
                        guard let self = self, self.wantPlay, self.playWatch != nil,
                              self.current(item, key: itemKey, run: context, sequence: mySeq) else { return }
                        self.view.isHidden = false
                        self.startLink()
                        self.send?(self.event("play-started", fields: ["t": self.seconds()]))
                    }
                }
                self.player.play()
            }
        }
    }

    private func accepts(key requestedKey: String?, requestId: String?, preparing: Bool = false) -> Bool {
        if requestedKey == nil && requestId == nil { return true } // старый web
        if let run = run { return requestedKey == run.key && requestId == run.requestId }
        return preparing && requestId == nil && requestedKey != nil && requestedKey == (loadingKey ?? key)
    }

    func pause(key requestedKey: String? = nil, requestId: String? = nil) {
        guard accepts(key: requestedKey, requestId: requestId) else { return }
        wantPlay = false
        startSeq += 1
        seekSeq += 1
        lastPosition = seekTarget ?? seconds()
        seekTarget = nil
        player.pause()
        stopLink()
        if let item = player.currentItem, let key = key { watch(item, key: key) }
        send?(event("play-paused", fields: ["t": lastPosition]))
    }

    func seek(_ t: Double, key requestedKey: String? = nil, requestId: String? = nil) {
        guard accepts(key: requestedKey, requestId: requestId) else { return }
        if wantPlay && player.rate == 0 {
            start(t, key: requestedKey, requestId: requestId)
            return
        }
        guard let item = player.currentItem, let itemKey = key else { return }
        let context = run
        let sequence = startSeq
        let small = CMTime(value: 1, timescale: 30)
        seekSeq += 1
        let mySeek = seekSeq
        seekTarget = max(0, t)
        lastPosition = max(0, t)
        player.seek(to: NativePlayback.time(t), toleranceBefore: small, toleranceAfter: small) { [weak self] finished in
            DispatchQueue.main.async {
                guard let self = self, finished, mySeek == self.seekSeq,
                      self.current(item, key: itemKey, run: context, sequence: sequence) else { return }
                self.seekTarget = nil
            }
        }
    }

    func hide() {
        if player.rate == 0 { view.isHidden = true }
    }

    func stop(key requestedKey: String? = nil, requestId: String? = nil) {
        guard accepts(key: requestedKey, requestId: requestId, preparing: true) else { return }
        startSeq += 1
        seekSeq += 1
        seekTarget = nil
        wantPlay = false
        player.pause()
        stopLink()
        gen += 1
        forget()
        player.replaceCurrentItem(with: nil)
        key = nil
        loadingKey = nil
        run = nil
        temps.removeAll()
        view.isHidden = true
    }

    // Где превью на странице: x, y, w, h — точки от левого верхнего угла webView.
    func rect(_ r: CGRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = r
        CATransaction.commit()
    }

    // Время — странице ~30 раз в секунду, пока играет.
    private func startLink() {
        stopLink()
        let l = CADisplayLink(target: self, selector: #selector(tick))
        l.add(to: .main, forMode: .common)
        link = l
    }

    private func stopLink() {
        playWatch?.invalidate()
        playWatch = nil
        link?.invalidate()
        link = nil
    }

    @objc private func tick() {
        let now = CACurrentMediaTime()
        if now - lastSent < 0.03 { return }
        lastSent = now
        lastPosition = seconds()
        send?(event("play-time", fields: ["t": lastPosition, "rate": Double(player.rate)]))
    }
}
