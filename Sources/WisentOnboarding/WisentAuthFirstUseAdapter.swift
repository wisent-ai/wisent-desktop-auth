import Combine
import Foundation
import WisentAuth
import WisentOnboarding

public struct WisentAuthFirstUseResult: Codable, Equatable, Sendable {
    public let productId: String
    public let journeyId: String
    public let journeyVersion: String
    public let journeyVersionId: UUID
    public let sourceRevision: String
    public let firstSuccessFact: String
    public let subjectHash: String
    public let userId: String
    public let organizationId: String
    public let sessionExpiresAt: Date
    public let restoredAt: Date

    public init(
        productId: String,
        journeyId: String,
        journeyVersion: String,
        journeyVersionId: UUID,
        sourceRevision: String,
        firstSuccessFact: String,
        subjectHash: String,
        userId: String,
        organizationId: String,
        sessionExpiresAt: Date,
        restoredAt: Date
    ) {
        self.productId = productId
        self.journeyId = journeyId
        self.journeyVersion = journeyVersion
        self.journeyVersionId = journeyVersionId
        self.sourceRevision = sourceRevision
        self.firstSuccessFact = firstSuccessFact
        self.subjectHash = subjectHash
        self.userId = userId
        self.organizationId = organizationId
        self.sessionExpiresAt = sessionExpiresAt
        self.restoredAt = restoredAt
    }
}

/// Connects the shared Echo journey runtime to a host's real
/// ``WisentAuthStore`` lifecycle.
///
/// Authentication remains entirely owned by `WisentAuthStore`. This adapter
/// observes its non-forgeable restoration receipt; it never signs in, refreshes
/// credentials, navigates OAuth, or provisions an organization. Calling
/// ``advance()`` can navigate to the result screen, but only a receipt emitted
/// after the store loaded and verified a persisted identity can complete the
/// journey.
@MainActor
public final class WisentAuthFirstUseAdapter: ObservableObject {
    public static let productId = "wisent-desktop-auth"
    public static let journeyId = "first-use"
    public static let journeyVersion = "2026-08-04.1"
    public static let journeyVersionId = UUID(uuidString: "12000000-0000-4000-8000-000000000011")!
    public static let sourceRevision = "wisent-desktop-auth-first-use-2026-08-04"
    public static let firstSuccessFact = "authenticated_identity_restored"

    @Published public private(set) var currentScreen: JourneyScreen?
    @Published public private(set) var attemptId: UUID?
    @Published public private(set) var status: JourneyProgressStatus = .inProgress
    @Published public private(set) var result: WisentAuthFirstUseResult?
    @Published public private(set) var errorMessage: String?

    private let client: JourneyClient
    private let subjectHash: String
    private let defaults: UserDefaults
    private let resultKey: String
    private let evidenceRevision = WisentAuthFirstUseAdapter.sourceRevision
    private var restoredIdentity: WisentRestoredIdentity?
    private var observation: AnyCancellable?
    private var started = false

    public init(
        store: WisentAuthStore,
        subjectId: String,
        transport: (any JourneyTransport)? = nil,
        storage: (any JourneyStorage)? = nil,
        defaults: UserDefaults = .standard
    ) throws {
        let normalizedSubject = subjectId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSubject.isEmpty else {
            throw JourneyClientError.invalid("host subject")
        }

        let subjectHash = JourneySubject.scoped([Self.productId, normalizedSubject])
        let fallback = try Self.loadFallback()
        let selectedTransport = transport ?? EnvironmentJourneyTransport(
            tokenEnvironmentKey: "WISENT_DESKTOP_AUTH_STADO_INTEGRATION_TOKEN"
        )
        let validatingTransport = WisentAuthJourneyTransport(base: selectedTransport)
        let selectedStorage = storage ?? UserDefaultsJourneyStorage(
            namespace: "ai.wisent.desktop-auth.onboarding"
        )

        self.subjectHash = subjectHash
        self.defaults = defaults
        resultKey = "ai.wisent.desktop-auth.onboarding.result.\(subjectHash)"
        client = try JourneyClient(
            productId: Self.productId,
            journeyId: Self.journeyId,
            subjectHash: subjectHash,
            scope: .device,
            transport: validatingTransport,
            storage: selectedStorage,
            fallback: fallback
        )

        if let data = defaults.data(forKey: resultKey),
           let stored = try? JSONDecoder().decode(WisentAuthFirstUseResult.self, from: data),
           stored.subjectHash == subjectHash {
            result = stored
        }

        observation = store.$restoredIdentity
            .compactMap { $0 }
            .sink { [weak self] receipt in
                Task { @MainActor [weak self] in
                    await self?.observe(restoredIdentity: receipt)
                }
            }
    }

    public func start() async {
        guard !started else { return }
        started = true
        errorMessage = nil
        do {
            let (_, progress) = try await client.start(evidenceRevision: evidenceRevision)
            attemptId = progress.attemptId
            status = progress.status
            currentScreen = await client.currentScreen
            if status == .inProgress {
                try await client.expose(evidenceRevision: evidenceRevision)
                await completeIfEligible()
            }
        } catch {
            started = false
            errorMessage = "The authenticated-identity restoration guide could not be opened."
        }
    }

    /// Advances explanatory and action screens only. On the terminal screen,
    /// this method remains a no-op until `WisentAuthStore` publishes a verified
    /// restoration receipt.
    public func advance() async {
        guard started, status == .inProgress else { return }
        errorMessage = nil
        do {
            if currentScreen?.transitions.isEmpty != true {
                _ = try await client.advance(evidence: [:], evidenceRevision: evidenceRevision)
                currentScreen = await client.currentScreen
                try await client.expose(evidenceRevision: evidenceRevision)
            }
            await completeIfEligible()
        } catch {
            errorMessage = "The authenticated-identity restoration step could not be saved."
        }
    }

    public func dismissError() {
        errorMessage = nil
    }

    package func observe(restoredIdentity receipt: WisentRestoredIdentity) async {
        restoredIdentity = receipt
        guard started, status == .inProgress else { return }
        await completeIfEligible()
    }

    private func completeIfEligible() async {
        guard status == .inProgress,
              currentScreen?.transitions.isEmpty == true,
              let restoredIdentity else { return }
        do {
            let completed = try await client.complete(
                evidence: [Self.firstSuccessFact: .boolean(true)],
                evidenceRevision: evidenceRevision
            )
            guard completed else { return }
            let completedResult = WisentAuthFirstUseResult(
                productId: Self.productId,
                journeyId: Self.journeyId,
                journeyVersion: Self.journeyVersion,
                journeyVersionId: Self.journeyVersionId,
                sourceRevision: Self.sourceRevision,
                firstSuccessFact: Self.firstSuccessFact,
                subjectHash: subjectHash,
                userId: restoredIdentity.userID,
                organizationId: restoredIdentity.organizationID,
                sessionExpiresAt: restoredIdentity.sessionExpiresAt,
                restoredAt: restoredIdentity.observedAt
            )
            result = completedResult
            status = .completed
            currentScreen = await client.currentScreen
            if let data = try? JSONEncoder().encode(completedResult) {
                defaults.set(data, forKey: resultKey)
            }
        } catch {
            errorMessage = "The identity was restored, but onboarding completion could not be saved."
        }
    }

    private static func loadFallback() throws -> JourneyBundle {
        guard let url = Bundle.module.url(
            forResource: "wisent-desktop-auth-first-use",
            withExtension: "json"
        ) else {
            throw JourneyClientError.invalid("missing bundled journey")
        }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let resource = try decoder.decode(FallbackResource.self, from: data)
        guard resource.journeyVersionId == journeyVersionId else {
            throw JourneyClientError.invalid("bundled journey identity")
        }
        return try JourneyRouter.makeBundle(
            canonicalDefinition: resource.canonicalDefinition,
            journeyVersionId: resource.journeyVersionId
        )
    }
}

private struct FallbackResource: Decodable {
    let journeyVersionId: UUID
    let canonicalDefinition: String
}

private struct WisentAuthJourneyTransport: JourneyTransport {
    let base: any JourneyTransport

    func readBundle(productId: String, journeyId: String) async throws -> JourneyBundle {
        let bundle = try await base.readBundle(productId: productId, journeyId: journeyId)
        guard bundle.journeyVersionId == WisentAuthFirstUseAdapter.journeyVersionId,
              bundle.definition.journeyVersion == WisentAuthFirstUseAdapter.journeyVersion,
              bundle.definition.sourceRevision == WisentAuthFirstUseAdapter.sourceRevision,
              bundle.definition.firstSuccessFact == WisentAuthFirstUseAdapter.firstSuccessFact
        else {
            throw JourneyClientError.invalid("central journey identity")
        }
        return bundle
    }

    func readState(productId: String, attemptId: UUID, subjectHash: String) async throws -> JSONValue? {
        try await base.readState(productId: productId, attemptId: attemptId, subjectHash: subjectHash)
    }

    func assignExperiment(request: JourneyAssignmentRequest) async throws -> JourneyAssignmentResponse {
        try await base.assignExperiment(request: request)
    }

    func collect(event: JourneyRuntimeEvent) async throws {
        try await base.collect(event: event)
    }
}
