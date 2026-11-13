import Foundation

// Kept in one owner so every privileged entry point can use the same decision.
enum EditorTrustPolicy {
    static func allows(_ url: URL?, mainFrame: Bool) -> Bool {
        guard mainFrame, let url = url, url.scheme == "https", url.host == "rynpro.ru",
              url.port == nil || url.port == 443 else { return false }
        return ["/ryn", "/ryn-next"].contains { root in
            url.path == root || url.path.hasPrefix(root + "/")
        }
    }
}
