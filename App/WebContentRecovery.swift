import Foundation

struct WebContentRecovery {
    enum Action: Equatable { case reload(URL), showError }
    private var lastAutomatic = -Double.infinity
    private(set) var recovering = false
    private let window: Double

    init(window: Double = 60) { self.window = window }

    mutating func terminated(at url: URL?, now: Double = ProcessInfo.processInfo.systemUptime) -> Action {
        guard EditorTrustPolicy.allows(url, mainFrame: true), let url = url,
              now - lastAutomatic >= window else { recovering = false; return .showError }
        lastAutomatic = now; recovering = true; return .reload(url)
    }

    mutating func loaded() { recovering = false }

    mutating func retry(at url: URL?) -> Action {
        guard EditorTrustPolicy.allows(url, mainFrame: true), let url = url else { return .showError }
        lastAutomatic = -.infinity; recovering = true; return .reload(url)
    }
}
