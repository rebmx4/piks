import Foundation
import Security
import PiksCore

final class KeychainVault: SessionVault, @unchecked Sendable {
    private let lock = NSLock()
    private let service: String
    init(service: String = "com.piks.app.native.identity") { self.service = service }
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "session", kSecAttrSynchronizable as String: false]
    }
    private func failure(_ status: OSStatus) -> IdentityFailure {
        IdentityFailure(status: Int(status), message: status == errSecInteractionNotAllowed
            ? "Разблокируйте iPhone, чтобы открыть аккаунт." : "Не удалось сохранить вход в защищённом хранилище.")
    }
    func read() throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        var search = query
        search[kSecReturnData as String] = true; search[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(search as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw failure(status) }
        return data
    }
    func write(_ data: Data?) throws {
        lock.lock(); defer { lock.unlock() }
        guard let data else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw failure(status) }
            return
        }
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes, uniquingKeysWith: { _, new in new }) as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw failure(status) }
    }
}
