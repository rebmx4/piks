import Foundation

// Foundation-only state for the optional TEST observer. Red test scaffold.
final class MediaDiagnosticsState {
    struct Batch { let data: Data; let to: Int; let generation: Int }
    init(build: String, now: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime * 1000 },
         wall: @escaping () -> Double = { Date().timeIntervalSince1970 * 1000 }) {}
    @discardableResult func configure(_ meta: [String: Any], origin: URL?, mainFrame: Bool, allowed: Bool) -> Bool { false }
    func stop() {}
    func record(_ record: [String: Any]) {}
    func heartbeat(session: String, hidden: Bool) {}
    func setForeground(_ active: Bool) {}
    func tick() -> Int? { nil }
    func mainReplied(_ token: Int) {}
    func takeBatch() -> Batch? { nil }
    func acknowledge(_ batch: Batch) {}
}
