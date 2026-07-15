import Foundation
import Security

protocol IdentityPersistence: Sendable {
    func load() throws -> StoredIdentity?
    func save(_ value: StoredIdentity) throws
    func clear() throws
}

struct KeychainIdentityStore: IdentityPersistence, @unchecked Sendable {
    private let service: String
    private let account = "primary-session"
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(bundleIdentifier: String) {
        service = "\(bundleIdentifier).wisent-identity"
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    func load() throws -> StoredIdentity? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw WisentAuthError.keychain(status)
        }
        return try decoder.decode(StoredIdentity.self, from: data)
    }

    func save(_ value: StoredIdentity) throws {
        let data = try encoder.encode(value)
        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw WisentAuthError.keychain(updateStatus)
        }

        var query = baseQuery
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw WisentAuthError.keychain(addStatus)
        }
    }

    func clear() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw WisentAuthError.keychain(status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
