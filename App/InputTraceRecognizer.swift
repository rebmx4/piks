import UIKit
import UIKit.UIGestureRecognizerSubclass

// Пассивный замер границы UIKit → WebView. Не меняет состояние проекта и
// никогда не переходит в .began/.recognized: остальные жесты идут как раньше.
final class InputTraceRecognizer: UIGestureRecognizer {
    var tracingAllowed: () -> Bool = { false }
    var report: (([String: Any]) -> Void)?

    private struct Entry {
        let id: String
        let at: TimeInterval
        let start: CGPoint
        let wall: Double
        let target: String
        var moves = 0
    }
    private var entries: [ObjectIdentifier: Entry] = [:]
    private var active: Set<ObjectIdentifier> = []
    private var serial = 0
    private var windowAt: TimeInterval = 0
    private var starts = 0
    private var limitReported = false

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        let now = ProcessInfo.processInfo.systemUptime
        if now - windowAt >= 60 { windowAt = now; starts = 0; limitReported = false }
        for touch in touches {
            let key = ObjectIdentifier(touch)
            active.insert(key)
            guard tracingAllowed() else { continue }
            guard starts < 60 else {
                if !limitReported {
                    limitReported = true
                    report?(["id": "ios-limit", "stream": "native", "phase": "limit",
                             "wall": Date().timeIntervalSince1970 * 1000, "starts": starts])
                }
                continue
            }
            starts += 1
            serial += 1
            let p = touch.location(in: view)
            let wall = Date().timeIntervalSince1970 * 1000 - max(0, now - touch.timestamp) * 1000
            let target = touch.view.map { String(describing: type(of: $0)) } ?? ""
            let entry = Entry(id: "ios-\(serial)", at: touch.timestamp, start: p,
                              wall: wall, target: String(target.prefix(80)))
            entries[key] = entry
            var record = base(entry, phase: "start", stamp: touch.timestamp)
            record["route"] = route(from: touch.view)
            report?(record)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        // Никаких сообщений/JavaScript на каждом движении.
        for touch in touches {
            let key = ObjectIdentifier(touch)
            if var entry = entries[key] { entry.moves += 1; entries[key] = entry }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        finish(touches, phase: "end")
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        finish(touches, phase: "cancel")
    }

    private func base(_ entry: Entry, phase: String, stamp: TimeInterval) -> [String: Any] {
        ["id": entry.id, "stream": "native", "phase": phase, "wall": entry.wall,
         "x": Int(entry.start.x.rounded()), "y": Int(entry.start.y.rounded()),
         "nativeTarget": entry.target,
         "traceVersion": 2, "observedWall": Date().timeIntervalSince1970 * 1000,
         "queue": Int((max(0, ProcessInfo.processInfo.systemUptime - stamp) * 1000).rounded())]
    }

    // Только публичные UIKit API. Цепочка включает дочерние прокрутчики,
    // которые не видны в состоянии основного webView.scrollView.
    private func route(from target: UIView?) -> [String: Any] {
        var nodes: [[String: Any]] = []
        var current = target
        var gestureCount = 0
        var gesturesTruncated = false
        while let node = current, nodes.count < 10 {
            let box = node.convert(node.bounds, to: view)
            var item: [String: Any] = [
                "id": String(describing: ObjectIdentifier(node)),
                "type": String(describing: type(of: node)),
                "rect": [Double(box.minX), Double(box.minY), Double(box.width), Double(box.height)],
                "hidden": node.isHidden, "interaction": node.isUserInteractionEnabled,
                "alpha": Double(node.alpha),
            ]
            var gestures: [[String: Any]] = []
            for gesture in node.gestureRecognizers ?? [] where gesture !== self {
                guard gestureCount < 24 else { gesturesTruncated = true; break }
                gestureCount += 1
                gestures.append([
                    "id": String(describing: ObjectIdentifier(gesture)),
                    "type": String(describing: type(of: gesture)),
                    "state": gesture.state.rawValue, "enabled": gesture.isEnabled,
                    "cancel": gesture.cancelsTouchesInView,
                    "delayBegin": gesture.delaysTouchesBegan, "delayEnd": gesture.delaysTouchesEnded,
                    "touches": gesture.numberOfTouches,
                ])
            }
            item["gestures"] = gestures
            if let scroll = node as? UIScrollView {
                item["scroll"] = [
                    "enabled": scroll.isScrollEnabled, "delay": scroll.delaysContentTouches,
                    "cancel": scroll.canCancelContentTouches,
                    "panState": scroll.panGestureRecognizer.state.rawValue,
                    "offset": [Double(scroll.contentOffset.x), Double(scroll.contentOffset.y)],
                    "size": [Double(scroll.contentSize.width), Double(scroll.contentSize.height)],
                ] as [String: Any]
            }
            nodes.append(item)
            current = node.superview
        }
        return ["views": nodes, "viewsTruncated": current != nil,
                "gesturesTruncated": gesturesTruncated, "missing": target == nil]
    }

    private func finish(_ touches: Set<UITouch>, phase: String) {
        for touch in touches {
            let key = ObjectIdentifier(touch)
            active.remove(key)
            guard let entry = entries.removeValue(forKey: key) else { continue }
            guard tracingAllowed() else { continue }
            let p = touch.location(in: view)
            var record = base(entry, phase: phase, stamp: touch.timestamp)
            record["moves"] = entry.moves
            record["dx"] = Int((p.x - entry.start.x).rounded())
            record["dy"] = Int((p.y - entry.start.y).rounded())
            record["ms"] = Int((max(0, touch.timestamp - entry.at) * 1000).rounded())
            record["route"] = route(from: touch.view)
            report?(record)
            // Отмена может прийти до перехода распознавателя в .began.
            // Один снимок после текущей обработки сохраняет этот переход.
            if phase == "cancel" {
                let cancelled = record
                DispatchQueue.main.async { [weak self, weak target = touch.view] in
                    guard let self = self, self.tracingAllowed() else { return }
                    var followup = cancelled
                    followup["phase"] = "afterCancel"
                    followup["observedWall"] = Date().timeIntervalSince1970 * 1000
                    followup["route"] = self.route(from: target)
                    self.report?(followup)
                }
            }
        }
        if active.isEmpty { state = .failed }
    }

    override func reset() {
        super.reset()
        entries.removeAll()
        active.removeAll()
    }
}
