import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct IdentityUser: Codable, Equatable, Sendable {
    public let id: UUID
    public let email: String?
}
public struct IdentitySession: Codable, Equatable, Sendable {
    public let user: IdentityUser
    public let accessToken: String
    public let refreshToken: String
    public let expiresAt: Double
}
public struct IdentityCapabilities: Decodable, Sendable {
    public let apple: Bool
    public let google: Bool
    public let email: Bool
    public let googleClientId: String?
    public let googleServerClientId: String?
}
public struct IdentityChallenge: Decodable, Sendable {
    public let id: String
    public let nonce: String
}
public struct IdentityRegistration: Decodable, Sendable { public let registrationId: String }
public struct IdentityFailure: Error, LocalizedError, Sendable {
    public let status: Int
    public let message: String
    public var errorDescription: String? { message }
}
public protocol SessionVault: Sendable {
    func read() throws -> Data?
    func write(_ data: Data?) throws
}

private final class IdentityRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // Credentials never follow redirects to another service.
        completionHandler(nil)
    }
}

/// Identity-only API. No project/media serialization or upload methods exist here.
public actor IdentityClient {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    private let baseURL: URL
    private let vault: any SessionVault
    private let transport: Transport
    private var session: IdentitySession?
    private var refreshing: Task<IdentitySession, Error>?
    private static let http: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false; config.httpCookieAcceptPolicy = .never
        config.urlCache = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 30
        return URLSession(configuration: config, delegate: IdentityRedirects(), delegateQueue: nil)
    }()
    public init(baseURL: URL, vault: any SessionVault, transport: Transport? = nil) throws {
        guard baseURL.scheme == "https", baseURL.host?.isEmpty == false, baseURL.user == nil,
              baseURL.password == nil, baseURL.query == nil, baseURL.fragment == nil else {
            throw IdentityFailure(status: 400, message: "Адрес сервиса входа настроен неверно.")
        }
        self.baseURL = baseURL; self.vault = vault
        self.transport = transport ?? { request in
            let (data, response) = try await Self.http.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw IdentityFailure(status: 503, message: "Сервис входа временно недоступен.")
            }
            return (data, http)
        }
        if let data = try vault.read() {
            let saved = try JSONDecoder().decode(IdentitySession.self, from: data)
            try Self.validate(saved); session = saved
        }
    }
    public func currentSession() -> IdentitySession? { session }
    private static func validate(_ session: IdentitySession) throws {
        guard (16...256).contains(session.accessToken.count), (16...256).contains(session.refreshToken.count),
              session.expiresAt.isFinite else {
            throw IdentityFailure(status: 503, message: "Не удалось сохранить сессию. Повторите вход.")
        }
    }
    private func persist(_ value: IdentitySession) throws -> IdentitySession {
        try Self.validate(value); try vault.write(JSONEncoder().encode(value)); session = value
        return value
    }
    private struct Success: Decodable { let ok: Bool }
    private struct Sent: Decodable { let sent: Bool }
    private struct ServerError: Decodable { let error: String }
    private func call<T: Decodable>(_ path: String, body: [String: String]? = nil, access: String? = nil) async throws -> T {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = body == nil ? "GET" : "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("APIKS Native/1.0", forHTTPHeaderField: "User-Agent")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        if let access { request.setValue("Bearer " + access, forHTTPHeaderField: "Authorization") }
        let (data, response) = try await transport(request)
        guard response.url?.host == baseURL.host, response.url?.scheme == "https", data.count <= 65536 else {
            throw IdentityFailure(status: 503, message: "Сервис входа ответил неверно. Попробуйте позже.")
        }
        guard (200...299).contains(response.statusCode) else {
            let text = (try? JSONDecoder().decode(ServerError.self, from: data))?.error
            throw IdentityFailure(status: response.statusCode, message: String((text ?? "Не удалось выполнить вход. Попробуйте позже.").prefix(500)))
        }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw IdentityFailure(status: 503, message: "Не удалось прочитать ответ сервиса входа.") }
    }
    public func capabilities() async throws -> IdentityCapabilities { try await call("v1/capabilities") }
    public func challenge(provider: String) async throws -> IdentityChallenge {
        try await call("v1/auth/challenge", body: ["provider": provider])
    }
    public func providerLogin(provider: String, idToken: String, challengeID: String, authorizationCode: String? = nil) async throws -> IdentitySession {
        var body = ["provider": provider, "idToken": idToken, "challengeId": challengeID]
        if let authorizationCode { body["authorizationCode"] = authorizationCode }
        let value: IdentitySession = try await call("v1/auth/provider", body: body)
        return try persist(value)
    }
    public func register(email: String, password: String) async throws -> IdentityRegistration {
        try await call("v1/auth/register", body: ["email": email, "password": password])
    }
    public func verifyEmail(email: String, code: String, registrationID: String) async throws -> IdentitySession {
        let value: IdentitySession = try await call("v1/auth/verify-email", body: ["email": email, "code": code, "registrationId": registrationID])
        return try persist(value)
    }
    public func login(email: String, password: String) async throws -> IdentitySession {
        let value: IdentitySession = try await call("v1/auth/login", body: ["email": email, "password": password])
        return try persist(value)
    }
    public func requestReset(email: String) async throws {
        let _: Sent = try await call("v1/auth/reset-request", body: ["email": email])
    }
    public func resetPassword(email: String, code: String, password: String) async throws {
        let _: Success = try await call("v1/auth/reset-confirm", body: ["email": email, "code": code, "password": password])
    }
    public func accessToken() async throws -> String {
        guard let value = session else { throw IdentityFailure(status: 401, message: "Войдите в аккаунт.") }
        if value.expiresAt > Date().timeIntervalSince1970 + 30 { return value.accessToken }
        if let refreshing { return try await refreshing.value.accessToken }
        let task = Task { () throws -> IdentitySession in
            do {
                let next: IdentitySession = try await self.call("v1/auth/refresh", body: ["refreshToken": value.refreshToken])
                return try self.persist(next)
            } catch {
                if (error as? IdentityFailure)?.status == 401 {
                    try self.vault.write(nil); self.session = nil
                }
                throw error
            }
        }
        refreshing = task
        defer { refreshing = nil }
        return try await task.value.accessToken
    }
    @discardableResult public func logout() async throws -> Bool {
        var revoked = false
        if let access = try? await accessToken() {
            let result: Success? = try? await call("v1/auth/logout", body: [:], access: access)
            revoked = result?.ok == true
        }
        try vault.write(nil); session = nil
        return revoked
    }
    public func deleteAccount() async throws {
        let access = try await accessToken()
        let result: Success = try await call("v1/account/delete", body: [:], access: access)
        guard result.ok else { throw IdentityFailure(status: 503, message: "Аккаунт не удалён. Попробуйте позже.") }
        try vault.write(nil); session = nil
    }
}
