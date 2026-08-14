import Foundation
import Security

protocol IdentityPersistence: Sendable {
    func load() throws -> StoredIdentity?
    func save(_ value: StoredIdentity) throws
    func clear() throws
}

struct KeychainIdentityStore: IdentityPersistence, @unchecked Sendable {
    static let sharedService = "ai.wisent.identity"
    static let sharedAccessGroupSuffix = ".ai.wisent.identity"

    private let service: String
    private let accessGroup: String?
    private let legacyService: String
    private let account = "primary-session"
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(bundleIdentifier: String) {
        legacyService = "\(bundleIdentifier).wisent-identity"
        accessGroup = Self.sharedAccessGroup()
        service = accessGroup == nil ? legacyService : Self.sharedService
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    func load() throws -> StoredIdentity? {
        if let shared = try load(service: service, accessGroup: accessGroup) {
            return shared
        }
        guard accessGroup != nil,
              let legacy = try load(service: legacyService, accessGroup: nil) else {
            return nil
        }

        try save(legacy)
        try delete(service: legacyService, accessGroup: nil)
        return legacy
    }

    func save(_ value: StoredIdentity) throws {
        let data = try encoder.encode(value)
        let query = query(service: service, accessGroup: accessGroup)
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw WisentAuthError.keychain(updateStatus)
        }

        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        if addStatus == errSecDuplicateItem {
            let retryStatus = SecItemUpdate(
                query as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
            guard retryStatus == errSecSuccess else {
                throw WisentAuthError.keychain(retryStatus)
            }
            return
        }
        guard addStatus == errSecSuccess else {
            throw WisentAuthError.keychain(addStatus)
        }
    }

    func clear() throws {
        try delete(service: service, accessGroup: accessGroup)
        if accessGroup != nil {
            try delete(service: legacyService, accessGroup: nil)
        }
    }

    private func load(service: String, accessGroup: String?) throws -> StoredIdentity? {
        var item = query(service: service, accessGroup: accessGroup)
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(item as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw WisentAuthError.keychain(status)
        }
        return try decoder.decode(StoredIdentity.self, from: data)
    }

    private func delete(service: String, accessGroup: String?) throws {
        let status = SecItemDelete(query(service: service, accessGroup: accessGroup) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw WisentAuthError.keychain(status)
        }
    }

    private func query(service: String, accessGroup: String?) -> [String: Any] {
        var item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let accessGroup {
            item[kSecAttrAccessGroup as String] = accessGroup
        }
        return item
    }

    private static func sharedAccessGroup() -> String? {
        guard let task = SecTaskCreateFromSelf(nil),
              let groups = SecTaskCopyValueForEntitlement(
                  task,
                  "keychain-access-groups" as CFString,
                  nil
              ) as? [String] else {
            return nil
        }
        return groups.first { $0.hasSuffix(sharedAccessGroupSuffix) }
    }
}
