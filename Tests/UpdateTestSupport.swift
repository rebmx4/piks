import Foundation

// Test app/bundle only. The release app always calls Apple's public endpoint.
final class UpdateTestProtocol: URLProtocol {
    typealias Handler = (URLRequest) throws -> (Int, Data)
    private static let lock = NSLock()
    private static var handler: Handler?
    private static var recorded: [URLRequest] = []

    static var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    static func session(_ response: @escaping Handler) -> URLSession {
        lock.lock(); handler = response; recorded = []; lock.unlock()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [UpdateTestProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "itunes.apple.com"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.recorded.append(request)
        let response = Self.handler
        Self.lock.unlock()
        do {
            let (status, data) = try response!(request)
            let http = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

enum UpdateFixture {
    static func data(version: String = "1.0.2", bundle: String = "com.piks.app",
                     appID: Int64 = 6_794_464_999, minimumOS: String = "15.0") throws -> Data {
        let url = Bundle(for: UpdateTestProtocol.self).url(forResource: "app-store-lookup",
            withExtension: "json", subdirectory: "UpdateFixtures")!
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        var app = (json["results"] as! [[String: Any]])[0]
        app["version"] = version; app["bundleId"] = bundle
        app["trackId"] = appID; app["minimumOsVersion"] = minimumOS
        json["results"] = [app]
        return try JSONSerialization.data(withJSONObject: json)
    }
}
