import Foundation
import WisentAuth
import WisentAuthOnboarding
import WisentOnboarding

private struct EstablishedHostIdentity: Codable {
    let userId: String
    let organizationId: String
    let sessionExpiresAt: Date
    let establishedAt: Date
    let processId: Int32
}

private struct HostState: Codable {
    let defaultsSuite: String
    var establishedIdentity: EstablishedHostIdentity?
}

private struct ScreenOutput: Encodable {
    let screenId: String
    let screenKind: String
    let actions: [String]
}

private struct HostOutput: Encodable {
    let productId: String
    let journeyId: String
    let journeyVersion: String
    let journeyVersionId: UUID
    let sourceRevision: String
    let firstSuccessFact: String
    let attemptId: UUID?
    let status: String
    let screen: ScreenOutput?
    let operation: String
    let identityState: String
    let result: WisentAuthFirstUseResult?
    let error: String?
}

private enum HostError: LocalizedError {
    case usage
    case missingEnvironment(String)
    case invalidState
    case identityNotEstablished
    case restoreMustCrossProcessBoundary

    var errorDescription: String? {
        switch self {
        case .usage:
            "usage: wisent-auth-onboarding-host <status|navigate|sign-in|restore>"
        case let .missingEnvironment(name):
            "\(name) is required"
        case .invalidState:
            "the onboarding host state is invalid"
        case .identityNotEstablished:
            "no established host identity is available to restore"
        case .restoreMustCrossProcessBoundary:
            "identity restoration must occur in a process after establishment"
        }
    }
}

@main
@MainActor
private struct WisentAuthOnboardingHost {
    static func main() async throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 2 else { throw HostError.usage }
        let operation = arguments[1]
        guard ["status", "navigate", "sign-in", "restore"].contains(operation) else {
            throw HostError.usage
        }

        let environment = ProcessInfo.processInfo.environment
        let statePath = try required(environment, "WISENT_DESKTOP_AUTH_ONBOARDING_STATE")
        let subject = try required(environment, "WISENT_DESKTOP_AUTH_ONBOARDING_SUBJECT")
        let stateURL = URL(fileURLWithPath: statePath)
        var hostState = try loadState(at: stateURL)
        let defaults = UserDefaults(suiteName: hostState.defaultsSuite)!
        let storage = UserDefaultsJourneyStorage(
            namespace: "ai.wisent.desktop-auth.onboarding.host",
            defaults: defaults
        )
        let store = WisentAuthStore(productName: "Wisent Auth Onboarding Host")
        let adapter = try WisentAuthFirstUseAdapter(
            store: store,
            subjectId: subject,
            transport: OfflineJourneyTransport(),
            storage: storage,
            defaults: defaults
        )
        await adapter.start()

        var identityState = hostState.establishedIdentity == nil ? "none" : "established"
        switch operation {
        case "navigate":
            await adapter.advance()
        case "sign-in":
            let userId = try required(environment, "WISENT_AUTH_HOST_USER_ID")
            let organizationId = try required(environment, "WISENT_AUTH_HOST_ORGANIZATION_ID")
            hostState.establishedIdentity = EstablishedHostIdentity(
                userId: userId,
                organizationId: organizationId,
                sessionExpiresAt: Date().addingTimeInterval(24 * 60 * 60),
                establishedAt: Date(),
                processId: ProcessInfo.processInfo.processIdentifier
            )
            try saveState(hostState, at: stateURL)
            identityState = "established"
        case "restore":
            guard let identity = hostState.establishedIdentity else {
                throw HostError.identityNotEstablished
            }
            guard identity.processId != ProcessInfo.processInfo.processIdentifier else {
                throw HostError.restoreMustCrossProcessBoundary
            }
            let receipt = WisentRestoredIdentity(
                userID: identity.userId,
                organizationID: identity.organizationId,
                sessionExpiresAt: identity.sessionExpiresAt,
                observedAt: Date()
            )
            await adapter.observe(restoredIdentity: receipt)
            identityState = "restored"
        default:
            break
        }

        let screen = adapter.currentScreen.map {
            ScreenOutput(screenId: $0.screenId, screenKind: $0.screenKind, actions: $0.actions)
        }
        let output = HostOutput(
            productId: WisentAuthFirstUseAdapter.productId,
            journeyId: WisentAuthFirstUseAdapter.journeyId,
            journeyVersion: WisentAuthFirstUseAdapter.journeyVersion,
            journeyVersionId: WisentAuthFirstUseAdapter.journeyVersionId,
            sourceRevision: WisentAuthFirstUseAdapter.sourceRevision,
            firstSuccessFact: WisentAuthFirstUseAdapter.firstSuccessFact,
            attemptId: adapter.attemptId,
            status: adapter.status.rawValue,
            screen: screen,
            operation: operation,
            identityState: identityState,
            result: adapter.result,
            error: adapter.errorMessage
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        encoder.keyEncodingStrategy = .convertToSnakeCase
        FileHandle.standardOutput.write(try encoder.encode(output))
        FileHandle.standardOutput.write(Data([0x0a]))
    }

    private static func required(_ environment: [String: String], _ name: String) throws -> String {
        guard let value = environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            throw HostError.missingEnvironment(name)
        }
        return value
    }

    private static func loadState(at url: URL) throws -> HostState {
        guard FileManager.default.fileExists(atPath: url.path) else {
            let state = HostState(
                defaultsSuite: "ai.wisent.desktop-auth.onboarding.host.\(UUID().uuidString.lowercased())",
                establishedIdentity: nil
            )
            try saveState(state, at: url)
            return state
        }
        guard let state = try? JSONDecoder().decode(HostState.self, from: Data(contentsOf: url)) else {
            throw HostError.invalidState
        }
        return state
    }

    private static func saveState(_ state: HostState, at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(state).write(to: url, options: .atomic)
    }
}
