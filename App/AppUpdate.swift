import Foundation

struct AppUpdate: Equatable {
    let version: String
    static let appID: Int64 = 6_794_464_999
    static let storeURL = URL(string: "https://apps.apple.com/app/id6794464999")!

    private struct Lookup: Decodable {
        let resultCount: Int
        let results: [Item]
    }
    private struct Item: Decodable {
        let trackId: Int64?
        let bundleId: String?
        let version: String?
        let minimumOsVersion: String?
    }

    static func available(in data: Data, installedVersion: String, systemVersion: String) -> AppUpdate? {
        guard let installed = StoreVersion(installedVersion), let system = StoreVersion(systemVersion),
              let lookup = try? JSONDecoder().decode(Lookup.self, from: data), lookup.resultCount > 0,
              let item = lookup.results.first(where: { $0.trackId == appID && $0.bundleId == "com.piks.app" }),
              let version = item.version, let published = StoreVersion(version), published > installed,
              let minimum = item.minimumOsVersion.flatMap(StoreVersion.init), minimum <= system
        else { return nil }
        return AppUpdate(version: version)
    }

    static var systemVersion: String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
    }
}

private struct StoreVersion: Comparable {
    private let parts: [Int]
    init?(_ string: String) {
        let components = string.split(separator: ".", omittingEmptySubsequences: false)
        var numbers: [Int] = []
        for part in components {
            guard !part.isEmpty, part.utf8.allSatisfy({ (48...57).contains($0) }), let number = Int(part)
            else { return nil }
            numbers.append(number)
        }
        guard !numbers.isEmpty else { return nil }
        while numbers.count > 1 && numbers.last == 0 { numbers.removeLast() }
        parts = numbers
    }
    static func < (lhs: StoreVersion, rhs: StoreVersion) -> Bool {
        for index in 0..<max(lhs.parts.count, rhs.parts.count) {
            let a = index < lhs.parts.count ? lhs.parts[index] : 0
            let b = index < rhs.parts.count ? rhs.parts[index] : 0
            if a != b { return a < b }
        }
        return false
    }
}

@MainActor
final class AppUpdateChecker {
    private let installedVersion: String?
    private let systemVersion: String
    private let region: String
    private let session: URLSession
    private let defaults: UserDefaults
    private let now: () -> Date
    private var nextCheck = Date.distantPast
    private var candidate: AppUpdate?
    private let dismissalKey = "apiks.dismissedPublicUpdate"

    init(installedVersion: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
         systemVersion: String = AppUpdate.systemVersion, region: String = Locale.current.regionCode ?? "us",
         session: URLSession = .shared, defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.installedVersion = installedVersion
        self.systemVersion = systemVersion
        let country = region.lowercased()
        self.region = country.count == 2 && country.utf8.allSatisfy({ (97...122).contains($0) }) ? country : "us"
        self.session = session; self.defaults = defaults; self.now = now
    }

    private var visibleCandidate: AppUpdate? {
        guard let candidate = candidate else { return nil }
        if let dismissed = defaults.string(forKey: dismissalKey),
           StoreVersion(dismissed) == StoreVersion(candidate.version) { return nil }
        return candidate
    }

    func check() async -> AppUpdate? {
        guard let installedVersion = installedVersion, StoreVersion(installedVersion) != nil else { return nil }
        if now() < nextCheck { return visibleCandidate }
        var url = URLComponents(string: "https://itunes.apple.com/lookup")!
        url.queryItems = [URLQueryItem(name: "id", value: String(AppUpdate.appID)),
                          URLQueryItem(name: "country", value: region)]
        let request = URLRequest(url: url.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        do {
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            candidate = AppUpdate.available(in: data, installedVersion: installedVersion, systemVersion: systemVersion)
            nextCheck = now().addingTimeInterval(15 * 60)
        } catch {
            candidate = nil
            nextCheck = now().addingTimeInterval(60)
        }
        return visibleCandidate
    }

    func dismiss(_ update: AppUpdate) {
        defaults.set(update.version, forKey: dismissalKey)
    }
}
