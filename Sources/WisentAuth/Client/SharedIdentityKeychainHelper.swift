import Foundation
import Security

/// The packaged macOS apps all invoke the same signed helper identity. The
/// login Keychain therefore sees one designated requirement instead of ten app
/// bundle identifiers, without requiring a restricted Keychain access-group
/// profile. iOS cannot start a helper process: there the type exists but is
/// never discovered, and an iOS app reaches the shared item through its
/// Keychain access group instead.
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
    #if os(macOS)
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
    #endif

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
        #if os(macOS)
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        let helper = executableURL.path
        process.executableURL = executableURL
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        do {
            try process.run()
        } catch {
            throw WisentAuthError.keychainHelper("\(helper) did not start: \(error)")
        }

        // A request the helper never received is named with its cause, not
        // left to read as whatever status the helper answers without it.
        var request = Data([action.rawValue])
        request.append(payload)
        do {
            try input.fileHandleForWriting.write(contentsOf: request)
            try input.fileHandleForWriting.close()
        } catch {
            process.terminate()
            process.waitUntilExit()
            throw WisentAuthError.keychainHelper(
                "\(helper) was not handed its request: \(error)")
        }
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let stderr = String(
                decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw WisentAuthError.keychainHelper(
                "\(helper) exited with status \(process.terminationStatus): \(stderr)")
        }
        return try Response(output.fileHandleForReading.readDataToEndOfFile(), helper: helper)
        #else
        throw WisentAuthError.keychain(errSecUnimplemented)
        #endif
    }

    private struct Response {
        /// The helper answers with a big-endian OSStatus (four bytes) followed by the payload.
        private static let statusByteCount = 4
        private static let bitsPerByte = 8

        let status: OSStatus
        let payload: Data

        init(_ data: Data, helper: String) throws {
            guard data.count >= Self.statusByteCount else {
                throw WisentAuthError.keychainHelper(
                    "\(helper) answered \(data.count) bytes, fewer than its \(Self.statusByteCount)-byte status")
            }
            let bytes = data.prefix(Self.statusByteCount)
            let bits = bytes.reduce(UInt32.zero) { ($0 << Self.bitsPerByte) | UInt32($1) }
            status = OSStatus(bitPattern: bits)
            payload = data.dropFirst(Self.statusByteCount)
        }
    }
}
