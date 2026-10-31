import Foundation

// Один запрос исходника на файл. У каждого потребителя своя отмена;
// PhotoKit останавливается, когда больше никто не ждёт. Поздний callback
// старого запроса не может завершить новую попытку того же файла.
final class MediaRequests<Value> {
    typealias Start = (@escaping (Double) -> Void, @escaping (Value?) -> Void) -> (() -> Void)
    private struct Consumer {
        let progress: ((Double) -> Void)?
        let done: (Value?) -> Void
    }
    private final class Entry {
        var consumers: [UUID: Consumer] = [:]
        var deadline: DispatchWorkItem?
        var cancel: (() -> Void)?
    }
    private var entries: [String: Entry] = [:]

    private static func onMain(_ action: @escaping () -> Void) {
        if Thread.isMainThread { action() } else { DispatchQueue.main.async(execute: action) }
    }

    @discardableResult
    func request(_ key: String, timeout: TimeInterval, progress: ((Double) -> Void)? = nil,
                 start: Start, done: @escaping (Value?) -> Void) -> (() -> Void) {
        precondition(Thread.isMainThread)
        let consumerID = UUID()
        let entry = entries[key] ?? Entry()
        let isNew = entries[key] == nil
        entry.consumers[consumerID] = Consumer(progress: progress, done: done)
        entries[key] = entry
        if isNew {
            let deadline = DispatchWorkItem { [weak self, weak entry] in
                guard let self = self, let entry = entry else { return }
                self.finish(key, entry, nil, cancel: true)
            }
            entry.deadline = deadline
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: deadline)
            let cancel = start({ [weak self, weak entry] value in
                Self.onMain {
                    guard let self = self, let entry = entry, self.entries[key] === entry else { return }
                    for consumer in Array(entry.consumers.values) { consumer.progress?(value) }
                }
            }, { [weak self, weak entry] value in
                Self.onMain {
                    guard let self = self, let entry = entry else { return }
                    self.finish(key, entry, value, cancel: false)
                }
            })
            // start может завершиться синхронно (локальный кэш).
            if entries[key] === entry { entry.cancel = cancel }
        }
        return { [weak self, weak entry] in
            Self.onMain {
                guard let self = self, let entry = entry, self.entries[key] === entry,
                      let consumer = entry.consumers.removeValue(forKey: consumerID) else { return }
                if entry.consumers.isEmpty { self.finish(key, entry, nil, cancel: true) }
                consumer.done(nil)
            }
        }
    }

    private func finish(_ key: String, _ entry: Entry, _ value: Value?, cancel: Bool) {
        guard entries[key] === entry else { return }
        entries[key] = nil
        entry.deadline?.cancel()
        let consumers = Array(entry.consumers.values)
        entry.consumers.removeAll()
        if cancel { entry.cancel?() }
        entry.cancel = nil
        for consumer in consumers { consumer.done(value) }
    }
}
