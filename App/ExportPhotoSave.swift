import Foundation

struct ExportPhotoRequest {
    let token: String
    let id: String

    init?(_ body: [String: Any]) {
        guard let token=body["token"] as? String, !token.isEmpty, token.count<=48,
              token.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }),
              let id=body["id"] as? String, id == "uexport_"+token else { return nil }
        self.token=token; self.id=id
    }

    static func allows(_ origin: URL?, mainFrame: Bool) -> Bool {
        EditorTrustPolicy.allows(origin, mainFrame: mainFrame)
    }
}

// PhotoKit can finish after the page retries. Coalesce pending requests and
// remember successful tokens, including after the temporary file is removed.
final class ExportPhotoSave {
    typealias Completion = (Bool, String?) -> Void
    typealias Writer = (URL, @escaping Completion) -> Void
    private final class Entry {
        var waiters: [Completion]
        var finished=false
        init(_ done: @escaping Completion) { waiters=[done] }
    }
    private let lock=NSLock()
    private var entries: [String: Entry]=[:]
    private var saved: [String]=[]

    func save(_ request: ExportPhotoRequest, resolve: (String) -> URL?,
              write: Writer, done: @escaping Completion) {
        lock.lock()
        if let existing=entries[request.token] {
            if existing.finished { lock.unlock();done(true,nil) }
            else { existing.waiters.append(done);lock.unlock() }
            return
        }
        guard entries.values.filter({ !$0.finished }).count<4 else {
            lock.unlock();done(false,"дождитесь завершения сохранения");return
        }
        let entry=Entry(done);entries[request.token]=entry;lock.unlock()
        guard let file=resolve(request.id), file.isFileURL, file.pathExtension.lowercased()=="mp4" else {
            finish(request.token,entry,false,"готовый файл экспорта не найден");return
        }
        write(file) { [self] ok,error in finish(request.token,entry,ok,error) }
    }

    private func finish(_ token: String, _ entry: Entry, _ ok: Bool, _ error: String?) {
        lock.lock()
        guard entries[token] === entry, !entry.finished else { lock.unlock();return }
        entry.finished=true
        let waiters=entry.waiters;entry.waiters.removeAll()
        if ok {
            saved.append(token)
            if saved.count>64 { entries.removeValue(forKey:saved.removeFirst()) }
        } else { entries.removeValue(forKey:token) }
        lock.unlock()
        for done in waiters { done(ok,error) }
    }
}
