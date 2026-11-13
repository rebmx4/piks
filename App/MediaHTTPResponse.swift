import Foundation

struct MediaHTTPResponse {
    let status: Int
    let headers: [String: String]
    let offset: Int64
    let length: Int64
    let sendBody: Bool

    static func make(method: String, range: String?, total: Int64) -> MediaHTTPResponse {
        // Baseline from the current scheme handler, exercised before replacing it.
        var start: Int64 = 0, end = total - 1, status = 200
        if let raw = range, raw.hasPrefix("bytes=") {
            let parts = raw.dropFirst(6).split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2 {
                if let value = Int64(parts[0]), value >= 0 { start = value }
                if let value = Int64(parts[1]), value >= start { end = min(value, total - 1) }
                status = 206
            }
        }
        if start >= total { return MediaHTTPResponse(status: 404, headers: [:], offset: 0, length: 0, sendBody: false) }
        end = min(end, start + 4 * 1024 * 1024 - 1)
        let length = max(0, end - start + 1)
        var headers = ["Content-Length": String(length), "Accept-Ranges": "bytes"]
        if status == 206 { headers["Content-Range"] = "bytes \(start)-\(end)/\(total)" }
        return MediaHTTPResponse(status: status, headers: headers, offset: start, length: length, sendBody: true)
    }
}
