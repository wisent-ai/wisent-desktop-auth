import Foundation
import Security

/// The packaged apps all invoke the same signed helper identity. The login
/// Keychain therefore sees one designated requirement instead of ten app bundle
/// identifiers, without requiring a restricted Keychain access-group profile.
struct SharedIdentityKeychainHelper: Sendable {
    static let bundleRelativePath = "Contents/Helpers/WisentIdentityKeychainHelper"
    static let siblingExecutableName = "wisent-identity-keychain-helper"
    static let environmentKey = "WISENT_IDENTITY_KEYCHAIN_HELPER"
    static let userLibexecRelativePath = ".local/libexec/wisent/WisentIdentityKeychainHelper"

    private enum Action: UInt8 {
        case load = 1
        case save = 2
        case clear = 3
    }

    private let executableURL: URL
    static func installed(
        in bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        executableURL: URL? = Bundle.main.executableURL,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Self? {
        var candidates = [
            bundle.bundleURL.appending(path: bundleRelativePath),
        ]
        if let explicit = environment[environmentKey], !explicit.isEmpty {
            candidates.append(URL(fileURLWithPath: explicit))
        }
        if let executableURL {
            candidates.append(
                executableURL
                    .deletingLastPathComponent()
                    .appending(path: siblingExecutableName)
            )
        }
        candidates.append(homeDirectory.appending(path: userLibexecRelativePath))

        guard let candidate = candidates.first(where: isRunnableExecutable) else {
            return nil
        }
        return Self(executableURL: candidate)
    }

    private static func isRunnableExecutable(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return false
        }
        return FileManager.default.isExecutableFile(atPath: url.path)
    }

    func load() throws -> Data? {
        let response = try exchange(action: .load)
        if response.status == errSecItemNotFound { return nil }
        guard response.status == errSecSuccess else {
            throw WisentAuthError.keychain(response.status)
        }
        return response.payload
    }

    func save(_ data: Data) throws {
        let response = try exchange(action: .save, payload: data)
        guard response.status == errSecSuccess else {
            throw WisentAuthError.keychain(response.status)
        }
    }

    func clear() throws {
        let response = try exchange(action: .clear)
        guard response.status == errSecSuccess || response.status == errSecItemNotFound else {
            throw WisentAuthError.keychain(response.status)
        }
    }

    private func exchange(action: Action, payload: Data = Data()) throws -> Response {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = executableURL
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw WisentAuthError.keychain(errSecInternalError)
        }

        var request = Data([action.rawValue])
        request.append(payload)
        input.fileHandleForWriting.write(request)
        try? input.fileHandleForWriting.close()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw WisentAuthError.keychain(errSecInternalError)
        }
        return try Response(output.fileHandleForReading.readDataToEndOfFile())
    }

    private struct Response {
        let status: OSStatus
        let payload: Data

        init(_ data: Data) throws {
            guard data.count >= 4 else {
                throw WisentAuthError.keychain(errSecInternalError)
            }
            let bytes = data.prefix(4)
            let bits = bytes.reduce(UInt32.zero) { ($0 << 8) | UInt32($1) }
            status = OSStatus(bitPattern: bits)
            payload = data.dropFirst(4)
        }
    }
}
