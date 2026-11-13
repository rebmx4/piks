import Foundation

// Kept in one owner so every privileged entry point can use the same decision.
enum EditorTrustPolicy {
    enum Site { case stable, test }

    static func allows(_ url: URL?, mainFrame: Bool) -> Bool {
        site(url, mainFrame: mainFrame) != nil
    }

    static func site(_ url: URL?, mainFrame: Bool) -> Site? {
        guard mainFrame, let url = url, url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "rynpro.ru", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let encoded = components.percentEncodedPath.lowercased()
        // Reject paths whose interpretation could differ between WebKit and the server.
        guard !encoded.contains("%2f"), !encoded.contains("%5c"), !url.path.contains("\\"),
              !url.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else { return nil }
        for (root, value) in [("/ryn", Site.stable), ("/ryn-next", Site.test)] {
            if url.path == root || url.path.hasPrefix(root + "/") { return value }
        }
        return nil
    }

    static func allowsCapture(_ url: URL?, mainFrame: Bool,
                              originScheme: String, originHost: String, originPort: Int) -> Bool {
        allows(url, mainFrame: mainFrame) && originScheme.lowercased() == "https" &&
            originHost.lowercased() == "rynpro.ru" && (originPort == 0 || originPort == 443)
    }
}
