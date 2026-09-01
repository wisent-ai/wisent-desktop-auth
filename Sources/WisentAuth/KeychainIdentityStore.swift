import Foundation
import Security
import os

protocol IdentityPersistence: Sendable {
    func load() throws -> StoredIdentity?
    func save(_ value: StoredIdentity) throws
    func clear() throws
}

struct KeychainIdentityStore: IdentityPersistence, @unchecked Sendable {
    static let sharedService = "ai.wisent.identity"
    static let sharedAccessGroupSuffix = ".ai.wisent.identity"

    private let helper: SharedIdentityKeychainHelper?
    private let service: String
    private let accessGroup: String?
    private let legacyService: String
    private let account = "primary-session"
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(bundleIdentifier: String) {
        helper = SharedIdentityKeychainHelper.installed()
        legacyService = "\(bundleIdentifier).wisent-identity"
        accessGroup = Self.sharedAccessGroup()
        service = accessGroup == nil ? legacyService : Self.sharedService
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    /// Three sources can answer, and until this log existed the caller could
    /// not tell which one did - or tell "nothing is stored" apart from "the
    /// selected helper said not-found while a shared item was sitting right
    /// there". Both arrive as `nil`.
    private static let log = Logger(
        subsystem: "ai.wisent.desktop.auth",
        category: "keychain"
    )

    func load() throws -> StoredIdentity? {
        if let helper {
            if let data = try helper.load() {
                Self.log.notice("identity read from the selected helper's shared item")
                return try decoder.decode(StoredIdentity.self, from: data)
            }
            guard let fallback = try loadKeychainValue() else {
                Self.log.notice(
                    "no identity: the helper reported not-found and no legacy item exists"
                )
                return nil
            }

            Self.log.notice("identity found in the legacy per-app item; migrating to the helper")
            try helper.save(encoder.encode(fallback))
            try deleteKeychainStores()
            return fallback
        }
        Self.log.notice("no executable shared helper discovered; reading the per-app item directly")
        return try loadKeychainWithAccessGroupMigration()
    }

    func save(_ value: StoredIdentity) throws {
        let data = try encoder.encode(value)
        if let helper {
            try helper.save(data)
        } else {
            try saveToKeychain(data)
        }
    }

    func clear() throws {
        try helper?.clear()
        try deleteKeychainStores()
    }

    private func loadKeychainWithAccessGroupMigration() throws -> StoredIdentity? {
        if let shared = try load(service: service, accessGroup: accessGroup) {
            return shared
        }
        guard accessGroup != nil,
              let legacy = try load(service: legacyService, accessGroup: nil) else {
            return nil
        }

        try saveToKeychain(encoder.encode(legacy))
        try delete(service: legacyService, accessGroup: nil)
        return legacy
    }

    private func loadKeychainValue() throws -> StoredIdentity? {
        if accessGroup != nil,
           let shared = try load(service: Self.sharedService, accessGroup: accessGroup) {
            return shared
        }
        return try load(service: legacyService, accessGroup: nil)
    }

    private func saveToKeychain(_ data: Data) throws {
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

    private func deleteKeychainStores() throws {
        if let accessGroup {
            try delete(service: Self.sharedService, accessGroup: accessGroup)
        }
        try delete(service: legacyService, accessGroup: nil)
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
