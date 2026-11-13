import Foundation

// One owner for both native render results and web-uploaded export results.
// It survives WebContent termination while the application process stays alive.
final class ExportOperationStore {
    typealias Completion = (Bool, String?) -> Void
    typealias Writer = (URL, @escaping Completion) -> Void
    enum Phase: String { case exporting, fileReady = "file-ready", saving, saved, failed, cancelled }
    struct Snapshot {
        let token: String
        let phase: Phase
        let file: URL?
        let reason: String?
        var payload: [String: Any] {
            ["token": token, "state": phase.rawValue, "hasFile": file.map { FileManager.default.isReadableFile(atPath: $0.path) } ?? false,
             "reason": reason ?? ""]
        }
    }
    private final class Entry {
        var phase: Phase
        var file: URL?
        var reason: String?
        var attempt = 0
        var waiters: [Completion] = []
        init(_ phase: Phase) { self.phase = phase }
    }
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    // Called outside the lock. UI owners must dispatch to main themselves.
    var onChange: ((Snapshot) -> Void)?

    @discardableResult func beginExport(_ token: String) -> Bool {
        guard Self.valid(token) else { return false }
        lock.lock()
        guard entries[token] == nil, entries.values.filter({ $0.phase == .exporting }).count < 4 else { lock.unlock(); return false }
        let entry = Entry(.exporting); insert(token, entry); let value = snapshot(token, entry)
        lock.unlock(); onChange?(value); return true
    }

    func fileReady(_ token: String, file: URL) {
        lock.lock()
        guard let entry = entries[token], entry.phase == .exporting else { lock.unlock(); return }
        entry.file = file; entry.phase = .fileReady
        let value = snapshot(token, entry); lock.unlock(); onChange?(value)
    }

    func failed(_ token: String, reason: String, cancelled: Bool = false) {
        lock.lock()
        guard let entry = entries[token], entry.phase == .exporting || entry.phase == .fileReady else { lock.unlock(); return }
        entry.phase = cancelled ? .cancelled : .failed; entry.reason = reason
        let value = snapshot(token, entry); lock.unlock(); onChange?(value)
    }

    func status(_ token: String? = nil) -> Snapshot? {
        lock.lock(); defer { lock.unlock() }
        guard let token = token ?? order.last, let entry = entries[token] else { return nil }
        return snapshot(token, entry)
    }

    func save(_ token: String, file: URL, write: Writer, done: @escaping Completion) {
        guard let request = ExportPhotoRequest(["token": token, "id": "uexport_" + token]) else {
            done(false, "неверный номер сохранения"); return
        }
        save(request, resolve: { _ in file }, write: write, done: done)
    }

    func save(_ request: ExportPhotoRequest, resolve: (String) -> URL?, write: Writer, done: @escaping Completion) {
        lock.lock()
        if let existing = entries[request.token] {
            if existing.phase == .saved { lock.unlock(); done(true, nil); return }
            if existing.phase == .saving { existing.waiters.append(done); lock.unlock(); return }
            if existing.phase == .exporting { lock.unlock(); done(false, "экспорт ещё идёт"); return }
        }
        guard entries.values.filter({ $0.phase == .saving }).count < 4 else {
            lock.unlock(); done(false, "дождитесь завершения сохранения"); return
        }
        let entry = entries[request.token] ?? Entry(.fileReady)
        entry.phase = .saving; entry.reason = nil; entry.waiters = [done]
        entry.attempt += 1
        let attempt = entry.attempt
        insert(request.token, entry); lock.unlock()
        guard let file = resolve(request.id), file.isFileURL, file.pathExtension.lowercased() == "mp4" else {
            finish(request.token, entry, attempt, false, "готовый файл экспорта не найден"); return
        }
        lock.lock(); entry.file = file; let value = snapshot(request.token, entry); lock.unlock()
        onChange?(value)
        write(file) { [self] ok, error in finish(request.token, entry, attempt, ok, error) }
    }

    private func finish(_ token: String, _ entry: Entry, _ attempt: Int, _ ok: Bool, _ error: String?) {
        lock.lock()
        guard entries[token] === entry, entry.phase == .saving, entry.attempt == attempt else { lock.unlock(); return }
        entry.phase = ok ? .saved : .failed; entry.reason = ok ? nil : error
        let waiters = entry.waiters; entry.waiters.removeAll()
        let value = snapshot(token, entry); trim(); lock.unlock()
        onChange?(value)
        for done in waiters { done(ok, error) }
    }

    private func insert(_ token: String, _ entry: Entry) {
        if entries[token] == nil { order.append(token) }
        entries[token] = entry; trim()
    }

    private func trim() {
        while order.count > 64 {
            guard let index = order.firstIndex(where: { token in
                guard let phase = entries[token]?.phase else { return true }
                return phase != .exporting && phase != .saving
            }) else { return }
            entries.removeValue(forKey: order.remove(at: index))
        }
    }

    private func snapshot(_ token: String, _ entry: Entry) -> Snapshot {
        Snapshot(token: token, phase: entry.phase, file: entry.file, reason: entry.reason)
    }

    private static func valid(_ token: String) -> Bool {
        ExportPhotoRequest(["token": token, "id": "uexport_" + token]) != nil
    }
}
