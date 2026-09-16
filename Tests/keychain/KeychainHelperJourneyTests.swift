import CryptoKit
import Darwin
import Foundation
import Security
import XCTest

final class KeychainHelperJourneyTests: XCTestCase {
    private let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private let service = "ai.wisent.identity"
    private let account = "primary-session"

    func testAuthorizedReadsAndUnauthorizedRefusalsPreserveIdentityWithoutConsent() throws {
        let interaction = SecKeychainSetUserInteractionAllowed(false)
        guard interaction == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(interaction))
        }
        let before = try searchList()
        let evidence = repository.appendingPathComponent(".build/evidence/keychain/\(UUID())")
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let helper = products.appendingPathComponent("wisent-identity-keychain-helper")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: helper.path))
        let revision = try run("/usr/bin/git", ["rev-parse", "HEAD"], evidence: evidence, name: "revision")
        _ = try run("/usr/bin/git", ["diff", "--binary", "--", "Sources", "Package.swift"],
                    evidence: evidence, name: "source-diff")
        var hashes: [String: String] = [:]
        for path in ["Sources/WisentIdentityKeychainHelper/main.swift",
                     "Sources/WisentAuth/KeychainIdentityStore.swift", "Package.swift",
                     "Tests/keychain/KeychainHelperJourneyTests.swift"] {
            hashes[path] = SHA256.hash(data: try Data(contentsOf: repository.appendingPathComponent(path)))
                .map { String(format: "%02x", $0) }.joined()
        }
        hashes[helper.path] = SHA256.hash(data: try Data(contentsOf: helper))
            .map { String(format: "%02x", $0) }.joined()
        try JSONSerialization.data(withJSONObject: ["revision": String(decoding: revision, as: UTF8.self),
            "arguments": ProcessInfo.processInfo.arguments, "sha256": hashes], options: [.prettyPrinted, .sortedKeys])
            .write(to: evidence.appendingPathComponent("source.json"))

        let value = Data("isolated-identity-\(UUID())".utf8)
        for authorized in [true, false] {
            let name = authorized ? "authorized" : "unauthorized"
            let path = evidence.appendingPathComponent("\(name).keychain-db")
            let keychain = try createKeychain(path: path)
            XCTAssertEqual(try searchList(), before)
            defer { XCTAssertEqual(SecKeychainDelete(keychain), errSecSuccess) }
            var ownApplication: SecTrustedApplication?
            XCTAssertEqual(SecTrustedApplicationCreateFromPath(nil, &ownApplication), errSecSuccess)
            var trusted = [try XCTUnwrap(ownApplication)]
            if authorized {
                var helperApplication: SecTrustedApplication?
                XCTAssertEqual(SecTrustedApplicationCreateFromPath(helper.path, &helperApplication), errSecSuccess)
                trusted.append(try XCTUnwrap(helperApplication))
            }
            var access: SecAccess?
            XCTAssertEqual(SecAccessCreate("Isolated Wisent auth journey" as CFString,
                                          trusted as CFArray, &access), errSecSuccess)
            let item: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecUseKeychain as String: keychain,
                kSecAttrAccess as String: try XCTUnwrap(access),
                kSecValueData as String: value,
                kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
            ]
            XCTAssertEqual(SecItemAdd(item as CFDictionary, nil), errSecSuccess)

            let result = try run(helper.path, [], input: Data([1]), environment: [
                "WISENT_IDENTITY_KEYCHAIN_PATH": path.path,
            ], evidence: evidence, name: name)
            XCTAssertGreaterThanOrEqual(result.count, 4)
            let status = OSStatus(bitPattern: result.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
            if authorized {
                XCTAssertEqual(status, errSecSuccess)
            } else {
                XCTAssertTrue(
                    status == errSecAuthFailed || status == errSecInteractionNotAllowed,
                    "An unauthorized read must report a native authorization refusal, got \(status)"
                )
            }
            XCTAssertEqual(Data(result.dropFirst(4)), authorized ? value : Data())
            if !authorized {
                let output = try run(products.appendingPathComponent("wisent-auth").path, ["status"],
                    environment: [
                        "WISENT_IDENTITY_KEYCHAIN_HELPER": helper.path,
                        "WISENT_IDENTITY_KEYCHAIN_PATH": path.path,
                    ], evidence: evidence, name: "cli-refusal")
                let state = try XCTUnwrap(JSONSerialization.jsonObject(with: output) as? [String: Any])
                XCTAssertEqual(state["signedIn"] as? Bool, false)
                XCTAssertEqual(state["status"] as? String, "signed_out")
                XCTAssertEqual(state["failureCode"] as? String, "unknown")
            }

            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecMatchSearchList as String: [keychain],
                kSecReturnData as String: true,
                kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
            ]
            var stored: CFTypeRef?
            XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &stored), errSecSuccess)
            let persisted = try XCTUnwrap(stored as? Data)
            XCTAssertEqual(persisted, value)
            try JSONSerialization.data(withJSONObject: ["status": status,
                "identityPreserved": persisted == value, "authorized": authorized], options: [.prettyPrinted])
                .write(to: evidence.appendingPathComponent("\(name)-result.json"))
        }
        XCTAssertEqual(try searchList(), before)
        print("Keychain journey evidence: \(evidence.path)")
    }

    private func createKeychain(path: URL) throws -> SecKeychain {
        let password = UUID().uuidString
        var keychain: SecKeychain?
        let status = password.withCString { bytes in
            SecKeychainCreate(path.path, UInt32(password.utf8.count), bytes, false, nil, &keychain)
        }
        XCTAssertEqual(status, errSecSuccess)
        return try XCTUnwrap(keychain)
    }

    private func searchList() throws -> [String] {
        var list: CFArray?
        XCTAssertEqual(SecKeychainCopyDomainSearchList(.user, &list), errSecSuccess)
        return try XCTUnwrap(list as? [SecKeychain]).map { keychain in
            var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            var size = UInt32(buffer.count)
            XCTAssertEqual(SecKeychainGetPath(keychain, &size, &buffer), errSecSuccess)
            return String(cString: buffer)
        }
    }

    private func run(_ executable: String, _ arguments: [String], input: Data = Data(),
                     environment: [String: String] = [:], evidence: URL, name: String) throws -> Data {
        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        let stderrURL = evidence.appendingPathComponent("\(name)-stderr.txt")
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        let stderr = try FileHandle(forWritingTo: stderrURL)
        defer { try? stderr.close() }
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = repository
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        try stdin.fileHandleForWriting.write(contentsOf: input)
        try stdin.fileHandleForWriting.close()
        let result = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try result.write(to: evidence.appendingPathComponent("\(name)-stdout.bin"))
        try JSONSerialization.data(withJSONObject: ["executable": executable, "arguments": arguments,
            "environment": environment, "exitStatus": process.terminationStatus], options: [.prettyPrinted, .sortedKeys])
            .write(to: evidence.appendingPathComponent("\(name)-command.json"))
        XCTAssertEqual(process.terminationStatus, 0)
        return result
    }
}
