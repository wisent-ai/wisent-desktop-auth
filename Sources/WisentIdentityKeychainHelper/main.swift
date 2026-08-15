import Foundation
import Security

@main
struct WisentIdentityKeychainHelper {
    private static let service = "ai.wisent.identity"
    private static let account = "primary-session"
    private enum Action: UInt8 {
        case load = 1
        case save = 2
        case clear = 3
    }

    static func main() {
        let request = FileHandle.standardInput.readDataToEndOfFile()
        guard let rawAction = request.first,
              let action = Action(rawValue: rawAction) else {
            write(status: errSecParam)
            return
        }

        switch action {
        case .load:
            var query = baseQuery
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            write(status: status, payload: result as? Data ?? Data())

        case .save:
            let value = request.dropFirst()
            let query = baseQuery
            let updateStatus = SecItemUpdate(
                query as CFDictionary,
                [kSecValueData as String: value] as CFDictionary
            )
            if updateStatus == errSecSuccess {
                write(status: errSecSuccess)
                return
            }
            guard updateStatus == errSecItemNotFound else {
                write(status: updateStatus)
                return
            }

            var item = query
            item[kSecValueData as String] = value
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            if addStatus == errSecDuplicateItem {
                let retryStatus = SecItemUpdate(
                    query as CFDictionary,
                    [kSecValueData as String: value] as CFDictionary
                )
                write(status: retryStatus)
            } else {
                write(status: addStatus)
            }

        case .clear:
            write(status: SecItemDelete(baseQuery as CFDictionary))
        }
    }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func write(status: OSStatus, payload: Data = Data()) {
        var statusBits = UInt32(bitPattern: status).bigEndian
        var response = Data(bytes: &statusBits, count: MemoryLayout.size(ofValue: statusBits))
        response.append(payload)
        FileHandle.standardOutput.write(response)
    }
}
