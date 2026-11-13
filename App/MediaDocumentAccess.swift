import Foundation

// A bearer grant belongs to one top-level document, not to the WebView forever.
// Same-origin hostile JS is outside this boundary: paths do not isolate origins.
final class MediaDocumentAccess {
    static let queryName = "__apiks_doc"
    static let hosts: Set<String> = ["orig", "proxy", "file", "photo", "live", "preview", "audio", "thumb"]
    private let lock = NSLock()
    private var counter = 0
    var generation: Int { lock.lock(); defer { lock.unlock() }; return counter }
    private var token: String?
    private var site: EditorTrustPolicy.Site?

    func revoke() {
        lock.lock(); defer { lock.unlock() }
        counter += 1; token = nil; site = nil
    }

    @discardableResult func bind(_ token: String, document: URL?, mainFrame: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let site = EditorTrustPolicy.site(document, mainFrame: mainFrame),
              token.count == 32, token.allSatisfy({ $0.isASCII && $0.isHexDigit }),
              self.token == nil || self.token == token else { return false }
        self.token = token; self.site = site
        return true
    }

    func allows(_ url: URL?, method: String, origin: String?, document: URL?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let token = token, let site = site,
              EditorTrustPolicy.site(document, mainFrame: true) == site,
              let url = url, url.scheme == "ryndi-media", let host = url.host, Self.hosts.contains(host),
              url.user == nil, url.password == nil, url.port == nil,
              ["GET", "HEAD", "OPTIONS"].contains(method.uppercased()),
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.queryItems?.filter({ $0.name == Self.queryName }).map({ $0.value }) == [token],
              url.path.split(separator: "/").count == 1,
              !url.lastPathComponent.isEmpty, !url.path.contains("\\"),
              url.lastPathComponent != ".", url.lastPathComponent != "..",
              !parts.percentEncodedPath.lowercased().contains("%2f"),
              !parts.percentEncodedPath.lowercased().contains("%5c") else { return false }
        if let origin = origin, origin != "https://rynpro.ru" && origin != "https://rynpro.ru:443" { return false }
        return true
    }
}
