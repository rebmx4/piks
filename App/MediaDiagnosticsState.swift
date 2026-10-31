import Foundation
import CoreFoundation

// Bounded, Foundation-only observer. Its owner serializes access; it never
// calls a player, changes a media session, or waits for the web/main thread.
final class MediaDiagnosticsState {
    struct Batch { let data: Data; let to: Int; let generation: Int }
    private let build: String
    private let now: () -> Double
    private let wall: () -> Double
    private var meta: [String: Any]?
    private var webSession = ""
    private var generation = 0
    private var lines: [[String: Any]] = []
    private var serial = 0, dropped = 0, count = 0
    private var windowAt = -Double.infinity
    private var foreground = true, visible = true
    private var lastWeb = 0.0, lastHealth = -Double.infinity, mainLast = 0.0
    private var pingSerial = 0
    private var mainPing: (token: Int, at: Double)?

    init(build: String, now: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime * 1000 },
         wall: @escaping () -> Double = { Date().timeIntervalSince1970 * 1000 }) {
        self.build = Self.label(build, limit: 40); self.now = now; self.wall = wall
    }

    private static func label(_ value: Any?, limit: Int) -> String {
        guard let s = value as? String else { return "" }
        return String(s.prefix(limit).filter { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) })
    }

    static func allows(origin: URL?, mainFrame: Bool, allowed: Bool) -> Bool {
        guard allowed, mainFrame, let url = origin, url.scheme == "https", url.host == "rynpro.ru",
              url.port == nil || url.port == 443, url.path.hasPrefix("/ryn-next/") else { return false }
        return true
    }

    @discardableResult func configure(_ value: [String: Any], origin: URL?, mainFrame: Bool, allowed: Bool) -> Bool {
        guard Self.allows(origin: origin, mainFrame: mainFrame, allowed: allowed),
              value["site"] as? String == "ryn-next",
              let session = value["session"] as? String,
              session.range(of: "^[a-z0-9]{4,32}$", options: .regularExpression) != nil,
              let device = value["device"] as? String,
              device.range(of: "^[a-z0-9]{6}$", options: .regularExpression) != nil else { return false }
        stop()
        webSession = session
        meta = ["v": 1, "session": UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
                "device": device, "site": "ryn-next", "ver": Self.label(value["ver"], limit: 40),
                "commit": Self.label(value["commit"], limit: 20),
                "ua": "APIKS-native/\(build) web/\(session)", "scr": "", "touch": 0]
        lastWeb = now(); lastHealth = -.infinity; foreground = true; visible = true
        append(["op": "session", "build": build, "web": webSession])
        return true
    }

    func stop() {
        generation += 1; meta = nil; webSession = ""; lines.removeAll()
        serial = 0; dropped = 0; count = 0; windowAt = -.infinity
        mainPing = nil; mainLast = 0
    }

    private static let operations: Set<String> = [
        "audio.resume", "audio.suspend", "player.play", "player.pause", "seek.wait", "seek.ready",
        "bridge.play-load", "bridge.play-start", "bridge.play-pause", "bridge.play-seek", "bridge.play-hide", "bridge.play-stop",
        "received.play-load", "received.play-start", "received.play-pause", "received.play-seek", "received.play-hide", "received.play-stop",
        "native.play-ready", "native.play-started", "native.play-paused", "native.play-ended", "native.play-error", "native.play-time",
        "input.pointerdown", "input.pointerup", "input.touchend", "input.click", "uikit.start", "uikit.end", "uikit.cancel"
    ]
    private static let enums: [String: Set<String>] = [
        "phase": ["begin", "return", "throw", "resolved", "rejected", "pending", "prepare", "play", "start", "reset", "display"],
        "state": ["running", "suspended", "interrupted", "closed"], "target": ["play", "full-play", "timeline"],
        "kind": ["services-reset", "cancelled", "not-ready", "prepare", "decode", "display"],
        "domain": ["AVFoundationErrorDomain", "NSOSStatusErrorDomain", "NSCocoaErrorDomain", "NSURLErrorDomain", "AVKitErrorDomain"]
    ]

    func record(_ record: [String: Any]) {
        guard meta != nil, let op = record["op"] as? String, Self.operations.contains(op) else { return }
        var clean: [String: Any] = ["op": op]
        for key in ["wall", "epoch", "id", "attempt", "ms", "t", "code", "rate", "queue"] {
            if let number = record[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
                let value = number.doubleValue
                if value.isFinite && abs(value) < 1e15 { clean[key] = (value * 1000).rounded() / 1000 }
            }
        }
        for key in ["playing", "seeking", "held"] {
            if let value = record[key] as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() { clean[key] = value.boolValue }
        }
        for (key, allowed) in Self.enums {
            if let value = record[key] as? String, allowed.contains(value) { clean[key] = value }
        }
        append(clean)
    }

    private func append(_ fields: [String: Any]) {
        guard meta != nil else { return }
        let time = now()
        if time - windowAt >= 60000 { windowAt = time; count = 0 }
        guard count < 512 else { dropped += 1; return }
        count += 1
        guard let data = try? JSONSerialization.data(withJSONObject: fields, options: .sortedKeys),
              let json = String(data: data, encoding: .utf8), json.count <= 560 else { dropped += 1; return }
        serial += 1
        lines.append(["n": serial, "t": Int(wall()), "text": "медиа оболочка: " + json])
        if lines.count > 128 { dropped += lines.count - 128; lines.removeFirst(lines.count - 128) }
    }

    func accepts(session: String) -> Bool { meta != nil && session == webSession }

    func heartbeat(session: String, hidden: Bool) {
        guard accepts(session: session) else { return }
        lastWeb = now()
        if visible == hidden { mainPing = nil; lastHealth = -.infinity }
        visible = !hidden
    }

    func setForeground(_ active: Bool) {
        guard foreground != active else { return }
        foreground = active; mainPing = nil; mainLast = 0; lastWeb = now(); lastHealth = -.infinity
        append(["op": "lifecycle", "active": active])
    }

    // Called by a background timer. At most one pending dispatch to main.
    func tick() -> Int? {
        guard meta != nil, foreground, visible else { return nil }
        let time = now(), webGap = max(0, time - lastWeb), mainGap = mainPing.map { max(0, time - $0.at) } ?? 0
        let slow = max(max(webGap, mainGap), mainLast) >= 3000
        if time - lastHealth >= (slow ? 2000 : 10000) {
            lastHealth = time
            append(["op": "health", "webGapMs": Int(webGap), "mainGapMs": Int(mainGap), "mainLastMs": Int(mainLast)])
        }
        guard mainPing == nil else { return nil }
        pingSerial += 1; mainPing = (pingSerial, time)
        return pingSerial
    }

    func mainReplied(_ token: Int) {
        guard let ping = mainPing, ping.token == token else { return }
        mainLast = max(0, now() - ping.at); mainPing = nil
    }

    func takeBatch() -> Batch? {
        guard var body = meta, !lines.isEmpty else { return nil }
        let batch = Array(lines.prefix(48))
        body["lines"] = batch; body["dropped"] = dropped
        guard let data = try? JSONSerialization.data(withJSONObject: body), data.count < 64000,
              let to = batch.last?["n"] as? Int else { return nil }
        return Batch(data: data, to: to, generation: generation)
    }

    func acknowledge(_ batch: Batch) {
        guard batch.generation == generation else { return }
        lines.removeAll { ($0["n"] as? Int ?? 0) <= batch.to }
    }
}
