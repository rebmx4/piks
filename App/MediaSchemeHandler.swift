import Foundation
import WebKit

enum MediaSchemeResource {
    case file(URL, String)
    case data(Data, String)
}

// WebKit callbacks and request ownership stay on main. A late resolver cannot
// address a replacement request; only eight requests can hold a byte stream.
final class MediaSchemeHandler: NSObject, WKURLSchemeHandler {
    typealias Resolve = (URL, @escaping (MediaSchemeResource?) -> Void) -> (() -> Void)
    private final class Request {
        let task: WKURLSchemeTask
        let generation: Int
        var started = false
        var cancel: (() -> Void)?
        var stream: MediaByteStream?
        init(_ task: WKURLSchemeTask, generation: Int) { self.task = task; self.generation = generation }
    }
    private let access: MediaDocumentAccess
    private let document: () -> URL?
    private let resolve: Resolve
    private var requests: [ObjectIdentifier: Request] = [:]
    private var waiting: [ObjectIdentifier] = []
    private static let activeLimit = 8
    private static let pendingLimit = 128
    private static let cors = [
        "Access-Control-Allow-Origin": "https://rynpro.ru",
        "Access-Control-Allow-Methods": "GET, HEAD, OPTIONS",
        "Access-Control-Allow-Headers": "Range, Content-Type",
        "Access-Control-Expose-Headers": "Content-Range, Content-Length, Accept-Ranges",
        "Cache-Control": "no-store", "Vary": "Origin"
    ]

    init(access: MediaDocumentAccess, document: @escaping () -> URL?, resolve: @escaping Resolve) {
        self.access = access; self.document = document; self.resolve = resolve
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        let method = task.request.httpMethod ?? "GET"
        guard access.allows(task.request.url, method: method,
            origin: task.request.value(forHTTPHeaderField: "Origin"), document: document()) else {
            immediate(task, status: 403); return
        }
        if method == "OPTIONS" { immediate(task, status: 204); return }
        guard requests.count < Self.pendingLimit else { immediate(task, status: 503); return }
        let key = ObjectIdentifier(task)
        requests[key] = Request(task, generation: access.generation); waiting.append(key)
        pump()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) { remove(ObjectIdentifier(task)) }

    func cancelAll() {
        let active = Array(requests.values)
        requests.removeAll(); waiting.removeAll()
        for request in active { request.cancel?(); request.stream?.cancel() }
    }

    private func live(_ key: ObjectIdentifier, _ request: Request) -> Bool {
        requests[key] === request && request.generation == access.generation
    }

    private func pump() {
        var slots = Self.activeLimit - requests.values.filter({ $0.started }).count
        while slots > 0, !waiting.isEmpty {
            let key = waiting.removeFirst()
            guard let request = requests[key], let url = request.task.request.url else { continue }
            request.started = true; slots -= 1
            let cancel = resolve(url) { [weak self, weak request] resource in
                DispatchQueue.main.async {
                    guard let self = self, let request = request, self.live(key, request) else { return }
                    request.cancel = nil
                    switch resource {
                    case .file(let file, let type): self.serveFile(file, type: type, key: key, request: request)
                    case .data(let data, let type): self.serveData(data, type: type, key: key, request: request)
                    case nil: self.respond(request, key: key, status: 404)
                    }
                }
            }
            request.cancel = cancel
        }
    }

    private func serveFile(_ file: URL, type: String, key: ObjectIdentifier, request: Request) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self, weak request] in
            do {
                let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
                guard let size = attrs[.size] as? NSNumber else { throw CocoaError(.fileReadUnknown) }
                DispatchQueue.main.async {
                    guard let self = self, let request = request, self.live(key, request) else { return }
                    let response = self.response(request, total: size.int64Value)
                    guard self.headers(request, status: response.status, headers: response.headers, type: type) else {
                        self.remove(key); return
                    }
                    let stream = MediaByteStream(file: file, response: response, receive: { [weak self, weak request] data in
                        guard let self = self, let request = request, self.live(key, request) else { return }
                        request.task.didReceive(data)
                    }, finish: { [weak self, weak request] in
                        guard let self = self, let request = request, self.live(key, request) else { return }
                        request.task.didFinish(); self.remove(key)
                    }, fail: { [weak self, weak request] error in
                        guard let self = self, let request = request, self.live(key, request) else { return }
                        request.task.didFailWithError(error); self.remove(key)
                    })
                    request.stream = stream; stream.start()
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self = self, let request = request, self.live(key, request) else { return }
                    self.respond(request, key: key, status: 404)
                }
            }
        }
    }

    private func response(_ request: Request, total: Int64) -> MediaHTTPResponse {
        .make(method: request.task.request.httpMethod ?? "GET",
              range: request.task.request.value(forHTTPHeaderField: "Range"), total: total)
    }

    private func serveData(_ data: Data, type: String, key: ObjectIdentifier, request: Request) {
        guard data.count <= MediaByteStream.chunkLimit else { respond(request, key: key, status: 413); return }
        let response = response(request, total: Int64(data.count))
        guard headers(request, status: response.status, headers: response.headers, type: type) else { remove(key); return }
        if response.sendBody, live(key, request) {
            request.task.didReceive(data.subdata(in: Int(response.offset)..<Int(response.offset + response.length)))
        }
        if live(key, request) { request.task.didFinish(); remove(key) }
    }

    @discardableResult private func headers(_ request: Request, status: Int,
                                            headers: [String: String], type: String? = nil) -> Bool {
        var result = Self.cors.merging(headers) { _, specific in specific }
        if let type = type { result["Content-Type"] = type }
        guard let url = request.task.request.url,
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: result) else {
            request.task.didFailWithError(CocoaError(.fileReadUnknown)); return false
        }
        request.task.didReceive(response); return true
    }

    private func respond(_ request: Request, key: ObjectIdentifier, status: Int) {
        if headers(request, status: status, headers: ["Content-Length": "0"]), live(key, request) {
            request.task.didFinish()
        }
        remove(key)
    }

    private func immediate(_ task: WKURLSchemeTask, status: Int) {
        let request = Request(task, generation: access.generation)
        if headers(request, status: status, headers: ["Content-Length": "0"]) { task.didFinish() }
    }

    private func remove(_ key: ObjectIdentifier) {
        guard let request = requests.removeValue(forKey: key) else { return }
        request.cancel?(); request.stream?.cancel()
        DispatchQueue.main.async { [weak self] in self?.pump() }
    }
}
