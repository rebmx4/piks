import SwiftUI
import AuthenticationServices
import CryptoKit
import PiksCore

@MainActor
final class AccountStore: ObservableObject {
    @Published private(set) var session: IdentitySession?
    @Published private(set) var capabilities: IdentityCapabilities?
    @Published private(set) var busy = false
    @Published private(set) var appleReady = false
    @Published var error: String?
    @Published var notice: String?
    private(set) var client: IdentityClient?
    private let google = GoogleOAuth()
    private var appleChallenge: IdentityChallenge?
    init(client: IdentityClient? = nil) {
        do {
            if let client { self.client = client }
            else {
                let vault = KeychainVault()
                let endpoint = Bundle.main.object(forInfoDictionaryKey: "PiksIdentityURL") as? String ?? ""
                guard let url = URL(string: endpoint) else { throw IdentityFailure(status: 503, message: "Вход временно недоступен.") }
                let built = try IdentityClient(baseURL: url, vault: vault)
                self.client = built
                if let saved = try vault.read() { session = try JSONDecoder().decode(IdentitySession.self, from: saved) }
            }
        } catch { self.client = nil; self.error = error.localizedDescription }
    }
    var googleReady: Bool {
        guard capabilities?.google == true, let id = capabilities?.googleClientId else { return false }
        return GoogleOAuth.registered(clientID: id)
    }
    func loadCapabilities() async {
        guard let client else { return }
        do { capabilities = try await client.capabilities(); error = nil }
        catch { self.error = "Вход временно недоступен. Монтаж без регистрации работает." }
        await prepareApple()
    }
    func prepareApple() async {
        guard !busy, capabilities?.apple == true, let client else { appleReady = false; return }
        do {
            appleChallenge = try await client.challenge(provider: "apple"); appleReady = true
        } catch { appleReady = false }
    }
    func beginApple(_ request: ASAuthorizationAppleIDRequest) {
        guard let nonce = appleChallenge?.nonce else { return }
        request.requestedScopes = [.email]
        request.nonce = SHA256.hash(data: Data(nonce.utf8)).map { String(format: "%02x", $0) }.joined()
        busy = true; appleReady = false; error = nil
    }
    func receiveApple(_ result: Result<ASAuthorization, Error>) async {
        defer { busy = false }
        switch result {
        case .failure(let failure):
            if (failure as? ASAuthorizationError)?.code != .canceled { error = "Не удалось завершить вход Apple." }
        case .success(let authorization):
            do {
                guard let client, let challenge = appleChallenge,
                      let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                      let idData = credential.identityToken, let token = String(data: idData, encoding: .utf8),
                      let codeData = credential.authorizationCode, let code = String(data: codeData, encoding: .utf8) else {
                    throw IdentityFailure(status: 401, message: "Повторите вход через Apple.")
                }
                session = try await client.providerLogin(provider: "apple", idToken: token, challengeID: challenge.id, authorizationCode: code)
            } catch { self.error = error.localizedDescription }
        }
        appleChallenge = nil
    }
    func signInGoogle() async {
        guard !busy, googleReady, let client, let id = capabilities?.googleClientId else { return }
        busy = true; error = nil; defer { busy = false }
        do {
            let challenge = try await client.challenge(provider: "google")
            let token = try await google.signIn(clientID: id, nonce: challenge.nonce)
            session = try await client.providerLogin(provider: "google", idToken: token, challengeID: challenge.id)
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
    func logout() async {
        guard !busy, let client else { return }
        busy = true; error = nil; defer { busy = false }
        do {
            let revoked = try await client.logout(); session = nil
            if !revoked { notice = "Вы вышли на этом устройстве. Сервер временно недоступен." }
        } catch { self.error = error.localizedDescription }
    }
    func deleteAccount(localCleanup: @escaping (UUID) async throws -> Void) async {
        guard !busy, let client, let owner = session?.user.id else { return }
        busy = true; error = nil; defer { busy = false }
        do {
            try await client.deleteAccount()
            do { try await localCleanup(owner) }
            catch { self.error = "Аккаунт удалён. Не удалось полностью удалить его локальные проекты: " + error.localizedDescription }
            session = nil; notice = "Аккаунт удалён."
        } catch {
            session = await client.currentSession(); self.error = error.localizedDescription
        }
    }
    func perform<T>(_ operation: (IdentityClient) async throws -> T) async -> T? {
        guard !busy, let client else { return nil }
        busy = true; error = nil; defer { busy = false }
        do {
            let result = try await operation(client); session = await client.currentSession(); return result
        } catch { self.error = error.localizedDescription; return nil }
    }
}
