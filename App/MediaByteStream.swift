import Foundation

// One read is followed by one delivery. The next read is scheduled only after
// the consumer returns, so a busy main queue cannot accumulate the whole file.
// Cancel and delivery callbacks run on deliveryQueue (main for WebKit).
final class MediaByteStream {
    static let chunkLimit = 4 * 1024 * 1024
    private let file: URL
    private let response: MediaHTTPResponse
    private let deliveryQueue: DispatchQueue
    private let io = DispatchQueue(label: "apiks.media.stream", qos: .userInitiated)
    private let lock = NSLock()
    private var active = true
    private var started = false
    private var handle: FileHandle?
    private var remaining: Int64
    private let receive: (Data) -> Void
    private let finish: () -> Void
    private let fail: (Error) -> Void

    init(file: URL, response: MediaHTTPResponse, deliveryQueue: DispatchQueue = .main,
         receive: @escaping (Data) -> Void, finish: @escaping () -> Void,
         fail: @escaping (Error) -> Void) {
        self.file = file; self.response = response; self.deliveryQueue = deliveryQueue
        self.remaining = response.length; self.receive = receive; self.finish = finish; self.fail = fail
    }

    func start() {
        lock.lock()
        guard active, !started else { lock.unlock(); return }
        started = true; lock.unlock()
        io.async { [self] in
            guard isActive else { return }
            do {
                if response.sendBody {
                    handle = try FileHandle(forReadingFrom: file)
                    try handle?.seek(toOffset: UInt64(response.offset))
                } else { remaining = 0 }
                readNext()
            } catch { complete(error) }
        }
    }

    func cancel() {
        lock.lock(); active = false; lock.unlock()
        io.async { [self] in close() }
    }

    private var isActive: Bool {
        lock.lock(); defer { lock.unlock() }; return active
    }

    // Called only on io. No reads and no descriptors are held for HEAD/416.
    private func readNext() {
        guard isActive else { close(); return }
        guard remaining > 0 else { complete(nil); return }
        do {
            let count = Int(min(Int64(Self.chunkLimit), remaining))
            guard let data = try handle?.read(upToCount: count), !data.isEmpty else {
                throw NSError(domain: "apiks.media", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "медиафайл закончился раньше заявленного размера"])
            }
            remaining -= Int64(data.count)
            deliveryQueue.async { [self] in
                guard isActive else { return }
                receive(data)
                io.async { [self] in readNext() }
            }
        } catch { complete(error) }
    }

    private func close() {
        try? handle?.close(); handle = nil
    }

    private func complete(_ error: Error?) {
        close()
        deliveryQueue.async { [self] in
            lock.lock()
            guard active else { lock.unlock(); return }
            active = false; lock.unlock()
            if let error = error { fail(error) } else { finish() }
        }
    }
}
