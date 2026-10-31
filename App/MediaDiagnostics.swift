import Foundation

// Independent TEST journal: background queue + ephemeral URLSession, no JS
// evaluation and no file writes. Media/UI code only submits small observations.
final class MediaDiagnostics {
    private let queue = DispatchQueue(label: "com.piks.media-diagnostics", qos: .utility)
    private let state: MediaDiagnosticsState
    private let gate = NSLock()
    private var queued = 0
    private var lastPlaybackAt = -Double.infinity
    private var foreground = true
    private var timer: DispatchSourceTimer?
    private var task: URLSessionDataTask?
    private var uploadID: UUID?
    private var lastUploadAt = -Double.infinity
    private var session: URLSession?
    private func networkSession() -> URLSession {
        if let session = session { return session }
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 8; config.timeoutIntervalForResource = 8
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config)
        self.session = session
        return session
    }

    init(build: String) { state = MediaDiagnosticsState(build: build) }

    // Bound pending observation blocks as well as the collector's stored lines.
    private func observe(_ work: @escaping (MediaDiagnostics) -> Void) {
        gate.lock()
        guard queued < 128 else { gate.unlock(); return }
        queued += 1; gate.unlock()
        queue.async { [weak self] in
            guard let self = self else { return }
            self.gate.lock(); self.queued -= 1; self.gate.unlock()
            work(self)
        }
    }

    func handle(_ body: [String: Any], origin: URL?, mainFrame: Bool, allowed: Bool) {
        guard MediaDiagnosticsState.allows(origin: origin, mainFrame: mainFrame, allowed: allowed) else { return }
        switch body["cmd"] as? String {
        case "diag-configure":
            guard let meta = body["meta"] as? [String: Any] else { return }
            queue.async { [weak self] in
                guard let self = self, self.state.configure(meta, origin: origin, mainFrame: mainFrame, allowed: allowed) else { return }
                self.task?.cancel(); self.task = nil; self.uploadID = nil; self.lastUploadAt = -.infinity
                self.state.setForeground(self.foreground)
                self.startTimer()
            }
        case "diag-heartbeat":
            guard let session = body["session"] as? String, let hidden = body["hidden"] as? Bool else { return }
            observe { $0.state.heartbeat(session: session, hidden: hidden) }
        case "diag-point":
            guard let session = body["session"] as? String, let record = body["record"] as? [String: Any] else { return }
            observe { if $0.state.accepts(session: session) { $0.state.record(record) } }
        default: break
        }
    }

    func command(_ body: [String: Any]) {
        guard let cmd = body["cmd"] as? String,
              ["play-load", "play-start", "play-pause", "play-seek", "play-hide", "play-stop"].contains(cmd) else { return }
        var record: [String: Any] = ["op": "received." + cmd]
        record["t"] = body["t"]
        observe { $0.state.record(record) }
    }

    func playback(_ payload: [String: Any]) {
        guard let event = payload["event"] as? String,
              ["play-ready", "play-started", "play-paused", "play-ended", "play-error", "play-time"].contains(event) else { return }
        if event == "play-time" {
            let now = ProcessInfo.processInfo.systemUptime
            gate.lock()
            guard now - lastPlaybackAt >= 1 else { gate.unlock(); return }
            lastPlaybackAt = now; gate.unlock()
        }
        var record: [String: Any] = ["op": "native." + event]
        for key in ["t", "rate", "code", "kind", "phase", "domain"] { record[key] = payload[key] }
        observe { $0.state.record(record) }
    }

    func input(_ payload: [String: Any]) {
        guard let phase = payload["phase"] as? String, ["start", "end", "cancel"].contains(phase) else { return }
        var record: [String: Any] = ["op": "uikit." + phase]
        record["wall"] = payload["observedWall"]; record["queue"] = payload["queue"]
        observe { $0.state.record(record) }
    }

    func setForeground(_ active: Bool) {
        queue.async { [weak self] in
            self?.foreground = active; self?.state.setForeground(active)
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.state.stop(); self.timer?.cancel(); self.timer = nil
            self.task?.cancel(); self.task = nil; self.uploadID = nil
        }
    }

    private func startTimer() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(500), repeating: .seconds(2), leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            if let token = self.state.tick() {
                DispatchQueue.main.async { [weak self] in
                    self?.observe { $0.state.mainReplied(token) }
                }
            }
            self.upload()
        }
        self.timer = timer; timer.resume()
    }

    private func upload() {
        let now = ProcessInfo.processInfo.systemUptime
        guard task == nil, now - lastUploadAt >= 10, let batch = state.takeBatch() else { return }
        lastUploadAt = now
        let id = UUID(); uploadID = id
        var request = URLRequest(url: URL(string: "https://rynpro.ru/ryn-api/log")!)
        request.httpMethod = "POST"; request.httpBody = batch.data; request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        task = networkSession().dataTask(with: request) { [weak self] _, response, error in
            self?.queue.async { [weak self] in
                guard let self = self, self.uploadID == id else { return }
                self.task = nil; self.uploadID = nil
                if error == nil, (response as? HTTPURLResponse)?.statusCode == 204 { self.state.acknowledge(batch) }
            }
        }
        task?.resume()
    }

    deinit { timer?.cancel(); task?.cancel(); session?.invalidateAndCancel() }
}
