import Foundation

struct MediaHTTPResponse {
    let status: Int
    let headers: [String: String]
    let offset: Int64
    let length: Int64
    let sendBody: Bool

    static func make(method: String, range: String?, total: Int64) -> MediaHTTPResponse {
        let method = method.uppercased()
        guard total >= 0 else { return empty(500) }
        if method == "OPTIONS" { return empty(204) }
        guard method == "GET" || method == "HEAD" else {
            return empty(405, headers: ["Allow": "GET, HEAD, OPTIONS"])
        }
        let full = MediaHTTPResponse(status: 200,
            headers: ["Content-Length": String(total), "Accept-Ranges": "bytes"],
            offset: 0, length: total, sendBody: method == "GET" && total > 0)
        guard method == "GET", let raw = range?.trimmingCharacters(in: .whitespaces),
              raw.lowercased().hasPrefix("bytes="), !raw.contains(",") else { return full }
        let invalid = empty(416, headers: ["Content-Range": "bytes */\(total)", "Accept-Ranges": "bytes"])
        let parts = raw.dropFirst(6).split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard total > 0, parts.count == 2 else { return invalid }
        func number(_ text: Substring) -> Int64? {
            guard !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            return Int64(text)
        }
        let start: Int64, end: Int64
        if parts[0].isEmpty {
            guard let suffix = number(parts[1]), suffix > 0 else { return invalid }
            start = total - min(total, suffix); end = total - 1
        } else {
            guard let first = number(parts[0]), first < total else { return invalid }
            start = first
            if parts[1].isEmpty { end = total - 1 }
            else {
                guard let last = number(parts[1]), last >= start else { return invalid }
                end = min(last, total - 1)
            }
        }
        let length = end - start + 1
        var headers = ["Content-Length": String(length), "Accept-Ranges": "bytes"]
        headers["Content-Range"] = "bytes \(start)-\(end)/\(total)"
        return MediaHTTPResponse(status: 206, headers: headers, offset: start, length: length, sendBody: true)
    }

    private static func empty(_ status: Int, headers: [String: String] = [:]) -> MediaHTTPResponse {
        var headers = headers; headers["Content-Length"] = "0"
        return MediaHTTPResponse(status: status, headers: headers, offset: 0, length: 0, sendBody: false)
    }
}
