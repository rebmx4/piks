import Foundation
import UIKit
import AuthenticationServices
import CryptoKit
import Security
import PiksCore

/// Google's documented installed-app OAuth flow. No Firebase or Google cloud storage SDK.
@MainActor
final class GoogleOAuth: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var browser: ASWebAuthenticationSession?
    private var completion: ((Result<URL, Error>) -> Void)?
    private final class Redirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }
    private static let http = URLSession(configuration: .ephemeral, delegate: Redirects(), delegateQueue: nil)
    static func scheme(clientID: String) -> String { clientID.split(separator: ".").reversed().joined(separator: ".") }
    static func registered(clientID: String) -> Bool {
        let types = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] ?? []
        return types.contains { ($0["CFBundleURLSchemes"] as? [String] ?? []).contains(scheme(clientID: clientID)) }
    }
    static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw IdentityFailure(status: 503, message: "Не удалось подготовить защищённый вход.")
        }
        return base64URL(Data(bytes))
    }
    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func authorizationURL(clientID: String, nonce: String, state: String, verifier: String) throws -> URL {
        guard clientID.range(of: "^[A-Za-z0-9-]+\\.apps\\.googleusercontent\\.com$", options: .regularExpression) != nil else {
            throw IdentityFailure(status: 503, message: "Вход Google временно недоступен.")
        }
        var url = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        let values = ["client_id": clientID, "redirect_uri": scheme(clientID: clientID) + ":/oauth2redirect",
                      "response_type": "code", "scope": "openid email", "state": state, "nonce": nonce,
                      "code_challenge_method": "S256", "code_challenge": base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))]
        url.queryItems = values.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return url.url!
    }
    static func code(callback: URL, clientID: String, state: String) throws -> String {
        guard callback.scheme == scheme(clientID: clientID), callback.host == nil, callback.path == "/oauth2redirect",
              let components = URLComponents(url: callback, resolvingAgainstBaseURL: false) else {
            throw IdentityFailure(status: 401, message: "Ответ Google не относится к этому входу.")
        }
        let items = components.queryItems ?? []
        guard items.filter({ $0.name == "state" }).count == 1,
              items.first(where: { $0.name == "state" })?.value == state,
              !items.contains(where: { $0.name == "error" }),
              items.filter({ $0.name == "code" }).count == 1,
              let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty, code.count <= 4096 else {
            throw IdentityFailure(status: 401, message: "Вход Google не подтверждён. Повторите попытку.")
        }
        return code
    }
    func signIn(clientID: String, nonce: String) async throws -> String {
        guard browser == nil, Self.registered(clientID: clientID) else {
            throw IdentityFailure(status: 503, message: "Вход Google временно недоступен.")
        }
        let state = try Self.random(), verifier = try Self.random()
        let url = try Self.authorizationURL(clientID: clientID, nonce: nonce, state: state, verifier: verifier)
        let callback: URL = try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                completion = { continuation.resume(with: $0) }
                let flow = ASWebAuthenticationSession(url: url, callbackURLScheme: Self.scheme(clientID: clientID)) { [weak self] url, error in
                    Task { @MainActor in
                        if let url { self?.finish(.success(url)) }
                        else if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin { self?.finish(.failure(CancellationError())) }
                        else { self?.finish(.failure(IdentityFailure(status: 401, message: "Не удалось завершить вход Google."))) }
                    }
                }
                flow.presentationContextProvider = self
                browser = flow
                if !flow.start() { finish(.failure(IdentityFailure(status: 503, message: "Не удалось открыть окно входа."))) }
            }
        }, onCancel: { Task { @MainActor in self.browser?.cancel(); self.finish(.failure(CancellationError())) } })
        let code = try Self.code(callback: callback, clientID: clientID, state: state)
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"; request.timeoutInterval = 15
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = ["client_id": clientID, "code": code, "code_verifier": verifier,
                           "redirect_uri": Self.scheme(clientID: clientID) + ":/oauth2redirect", "grant_type": "authorization_code"]
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = form.percentEncodedQuery?.data(using: .utf8)
        let (data, response) = try await Self.http.data(for: request)
        struct Token: Decodable { let id_token: String }
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 65536,
              let token = try? JSONDecoder().decode(Token.self, from: data), token.id_token.count <= 8192 else {
            throw IdentityFailure(status: 401, message: "Google не подтвердил вход. Повторите попытку.")
        }
        return token.id_token
    }
    private func finish(_ result: Result<URL, Error>) {
        let callback = completion; completion = nil; browser = nil
        callback?(result)
    }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }
}
