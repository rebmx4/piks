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
// play-ready / play-error), play-start { t } (ответ play-started, дальше
// play-time { t } ~30 раз в секунду, в конце play-ended), play-pause (ответ
// play-paused { t }), play-seek { t }, play-hide, play-rect { x, y, w, h } —
// где превью на странице (точки), play-stop — выгрузить.
final class NativePlayback: NSObject {

    let view = UIView()                          // под webView: слой видео в прямоугольнике превью
    private let player = AVPlayer()
    private let playerLayer: AVPlayerLayer
    private var key: String?                     // план, который собран и стоит в проигрывателе
    private var loadingKey: String?
    private var gen = 0                           // номер загрузки: устаревшую сборку выбросить
    private var link: CADisplayLink?
    private var lastSent = 0.0
    private var wantPlay = false                 // пауза пришла, пока шла перемотка к началу, — не запускать
    private var startSeq = 0                      // номер запуска: прерванная перемотка не запускает
    private var statusWatch: NSKeyValueObservation?
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
        guard let text = text, let data = text.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let plan = ExportPlan(json: json) else {
            send?(["event": "play-error", "key": newKey, "reason": "план превью не прочитался"])
            return
        }
        gen += 1
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
                                    "took": Date().timeIntervalSince(started)])
                    }
                } catch {
                    fresh.removeAll()
                    DispatchQueue.main.async {
                        guard myGen == self.gen else { return }
                        self.loadingKey = nil
                        self.send?(["event": "play-error", "key": newKey, "reason": error.localizedDescription])
                    }
                }
            }
        }
    }

    private func resolveAll(_ plan: ExportPlan, _ done: @escaping ([String: URL]) -> Void) {
        let group = DispatchGroup()
        var found: [String: URL] = [:]
        let lock = NSLock()
        for (id, address) in plan.media {
            let name = URL(string: address)?.lastPathComponent ?? ""
            let fileId = (name as NSString).deletingPathExtension
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
        // Шла игра — сначала пауза: странице — где встали (она тоже встанет).
        if player.rate != 0 || wantPlay {
            wantPlay = false
            player.pause()
            stopLink()
            send?(["event": "play-paused", "t": seconds()])
        }
        let item = AVPlayerItem(asset: a.comp)
        item.videoComposition = a.video
        item.audioMix = a.mix
        item.forwardPlaybackEndTime = a.total            // как экспорт: ровно до конца ролика
        item.audioTimePitchAlgorithm = .spectral         // звук кусков со скоростью — как в экспорте
        // Прошлое — в корзину: новый план заменил его целиком.
        forget()
        player.replaceCurrentItem(with: item)
        endToken = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            self.wantPlay = false
            self.stopLink()
            self.send?(["event": "play-ended", "t": self.seconds()])
        }
        failToken = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] note in
            let err = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            self?.failed(err?.localizedDescription ?? "видео не доиграло")
        }
        statusWatch = item.observe(\.status, options: [.new]) { [weak self] it, _ in
            guard it.status == .failed else { return }
            let reason = it.error?.localizedDescription ?? "видео не открылось"
            DispatchQueue.main.async { self?.failed(reason) }
        }
        temps.removeAll()
        temps = fresh
        key = newKey
        loadingKey = nil
    }

    private func forget() {
        if let t = endToken { NotificationCenter.default.removeObserver(t) }
        if let t = failToken { NotificationCenter.default.removeObserver(t) }
        endToken = nil
        failToken = nil
        statusWatch?.invalidate()
        statusWatch = nil
    }

    // Элемент не играет — странице ошибку (она сыграет сама), план — заново.
    private func failed(_ reason: String) {
        wantPlay = false
        player.pause()
        stopLink()
        view.isHidden = true
        key = nil
        send?(["event": "play-error", "reason": reason])
    }

    private func seconds() -> Double {
        let t = CMTimeGetSeconds(player.currentTime())
        return t.isFinite ? t : 0
    }

    // MARK: - Игра

    func start(_ t: Double) {
        guard player.currentItem != nil, key != nil else {
            send?(["event": "play-error", "reason": "превью ещё не собрано"])
            return
        }
        MediaBridge.audioSession(nil)
        wantPlay = true
        startSeq += 1
        let mySeq = startSeq
        player.seek(to: NativePlayback.time(t), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            DispatchQueue.main.async {
                guard let self = self, self.wantPlay, finished, mySeq == self.startSeq else { return }
                self.view.isHidden = false
                self.player.play()
                self.startLink()
                self.send?(["event": "play-started", "t": self.seconds()])
            }
        }
    }

    func pause() {
        wantPlay = false
        player.pause()
        stopLink()
        send?(["event": "play-paused", "t": seconds()])
    }

    func seek(_ t: Double) {
        let small = CMTime(value: 1, timescale: 30)
        player.seek(to: NativePlayback.time(t), toleranceBefore: small, toleranceAfter: small)
    }

    func hide() {
        if player.rate == 0 { view.isHidden = true }
    }

    func stop() {
        wantPlay = false
        player.pause()
        stopLink()
        gen += 1
        forget()
        player.replaceCurrentItem(with: nil)
        key = nil
        loadingKey = nil
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
        link?.invalidate()
        link = nil
    }

    @objc private func tick() {
        let now = CACurrentMediaTime()
        if now - lastSent < 0.03 { return }
        lastSent = now
        send?(["event": "play-time", "t": seconds(), "rate": Double(player.rate)])
    }
}
