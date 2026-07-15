import AppKit
import AuthenticationServices
import Combine
import Foundation

public enum WisentAuthStatus: Equatable {
    case restoring
    case signedOut
    case waitingForCode
    case resolvingOrganization
    case choosingOrganization
    case ready
}

@MainActor
public final class WisentAuthStore: ObservableObject {
    @Published public private(set) var status: WisentAuthStatus = .restoring
    @Published public private(set) var session: WisentSession?
    @Published public private(set) var organizations: [WisentOrganization] = []
    @Published public private(set) var selectedOrganization: WisentOrganization?
    @Published public var email = ""
    @Published public var code = ""
    @Published public private(set) var isBusy = false
    @Published public private(set) var errorMessage: String?

    public let productName: String
    public var oauthEnabled: Bool { configuration.oauthEnabled }

    private let configuration: WisentAuthConfiguration
    private let client: SupabaseIdentityClient
    private let persistence: any IdentityPersistence
    private var started = false
    private var refreshTask: Task<Void, Never>?
    private var webSession: DesktopWebAuthSession?
    private static let refreshLeadTime: TimeInterval = 5 * 60

    public convenience init(productName: String) {
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "ai.wisent.\(productName.lowercased())"
        self.init(
            productName: productName,
            bundleIdentifier: bundleIdentifier,
            configuration: .production(bundleIdentifier: bundleIdentifier)
        )
    }

    init(
        productName: String,
        bundleIdentifier: String,
        configuration: WisentAuthConfiguration,
        persistence: (any IdentityPersistence)? = nil
    ) {
        self.productName = productName
        self.configuration = configuration
        client = SupabaseIdentityClient(configuration: configuration)
        self.persistence = persistence ?? KeychainIdentityStore(bundleIdentifier: bundleIdentifier)
    }

    deinit {
        refreshTask?.cancel()
    }

    public var identity: WisentIdentity? {
        guard let session, let selectedOrganization else { return nil }
        return WisentIdentity(
            userID: session.userID,
            email: session.email,
            organization: selectedOrganization,
            accessToken: session.accessToken
        )
    }

    public func start() async {
        guard !started else { return }
        started = true
        guard configuration.isConfigured else {
            errorMessage = "Wisent Identity is not configured."
            status = .signedOut
            return
        }

        do {
            guard var stored = try persistence.load() else {
                status = .signedOut
                return
            }
            if stored.session.expiresAt.timeIntervalSinceNow <= Self.refreshLeadTime {
                stored = StoredIdentity(
                    session: try await client.refresh(refreshToken: stored.session.refreshToken),
                    selectedOrganizationID: stored.selectedOrganizationID
                )
                try persistence.save(stored)
            }
            session = stored.session
            email = stored.session.email
            scheduleRefresh(for: stored.session)
            await resolveOrganizations(preferredID: stored.selectedOrganizationID)
        } catch {
            try? persistence.clear()
            session = nil
            status = .signedOut
            errorMessage = Self.describe(error)
        }
    }

    public func sendCode() async {
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard address.contains("@") else {
            errorMessage = "Enter a valid email address."
            return
        }
        await perform {
            try await client.requestOTP(email: address)
            email = address
            code = ""
            status = .waitingForCode
        }
    }

    public func verifyCode() async {
        let token = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            errorMessage = "Enter the code from your email."
            return
        }
        await perform {
            let newSession = try await client.verifyOTP(email: email, code: token)
            try await accept(newSession)
        }
    }

    public func signInWithGoogle() async {
        await signInWithOAuth(provider: "google", label: "Google")
    }

    public func signInWithGitHub() async {
        await signInWithOAuth(provider: "github", label: "GitHub")
    }

    public func changeEmail() {
        code = ""
        errorMessage = nil
        status = .signedOut
    }

    public func selectOrganization(_ organization: WisentOrganization) {
        guard organizations.contains(where: { $0.id == organization.id }), let session else { return }
        selectedOrganization = organization
        status = .ready
        do {
            try persistence.save(
                StoredIdentity(session: session, selectedOrganizationID: organization.id)
            )
        } catch {
            errorMessage = Self.describe(error)
        }
    }

    public func signOut() async {
        refreshTask?.cancel()
        refreshTask = nil
        if let token = session?.accessToken {
            try? await client.signOut(accessToken: token)
        }
        try? persistence.clear()
        session = nil
        organizations = []
        selectedOrganization = nil
        email = ""
        code = ""
        errorMessage = nil
        status = .signedOut
    }

    @discardableResult
    public func ensureFreshSession() async -> Bool {
        guard let current = session else { return false }
        guard current.expiresAt.timeIntervalSinceNow <= Self.refreshLeadTime else { return true }
        do {
            let refreshed = try await client.refresh(refreshToken: current.refreshToken)
            session = refreshed
            try persistence.save(
                StoredIdentity(session: refreshed, selectedOrganizationID: selectedOrganization?.id)
            )
            scheduleRefresh(for: refreshed)
            return true
        } catch {
            errorMessage = "Session expired. Sign in again."
            await signOut()
            return false
        }
    }

    private func signInWithOAuth(provider: String, label: String) async {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        defer {
            isBusy = false
            webSession = nil
        }
        do {
            let pkce = PKCEPair()
            let url = try await client.oauthAuthorizeURL(provider: provider, challenge: pkce.challenge)
            let session = DesktopWebAuthSession()
            webSession = session
            let callback = try await session.start(url: url, callbackScheme: configuration.callbackScheme)
            let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems
            guard let authorizationCode = items?.first(where: { $0.name == "code" })?.value,
                  !authorizationCode.isEmpty else {
                let providerError = items?.first(where: { $0.name == "error_description" })?.value
                throw WisentAuthError.http(-1, providerError ?? "\(label) did not return an authorization code.")
            }
            let newSession = try await client.exchangeCode(authorizationCode, verifier: pkce.verifier)
            try await accept(newSession)
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            return
        } catch {
            errorMessage = Self.describe(error)
        }
    }

    private func accept(_ newSession: WisentSession) async throws {
        session = newSession
        email = newSession.email
        code = ""
        try persistence.save(StoredIdentity(session: newSession, selectedOrganizationID: nil))
        scheduleRefresh(for: newSession)
        await resolveOrganizations(preferredID: nil)
    }

    private func resolveOrganizations(preferredID: String?) async {
        guard let session else {
            status = .signedOut
            return
        }
        status = .resolvingOrganization
        errorMessage = nil
        do {
            var available = try await client.organizations(session: session)
            if available.isEmpty {
                let bootstrappedID = try await client.bootstrapOrganization(session: session)
                available = try await client.organizations(session: session)
                if available.isEmpty {
                    throw WisentAuthError.noOrganization
                }
                organizations = available
                if let organization = available.first(where: { $0.id == bootstrappedID }) ?? available.first {
                    selectOrganization(organization)
                }
                return
            }

            organizations = available
            if let preferredID, let preferred = available.first(where: { $0.id == preferredID }) {
                selectOrganization(preferred)
            } else if available.count == 1, let only = available.first {
                selectOrganization(only)
            } else {
                selectedOrganization = nil
                status = .choosingOrganization
            }
        } catch {
            errorMessage = "Organization setup failed: \(Self.describe(error))"
            status = .signedOut
        }
    }

    private func perform(_ operation: () async throws -> Void) async {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            try await operation()
        } catch {
            errorMessage = Self.describe(error)
        }
    }

    private func scheduleRefresh(for session: WisentSession) {
        refreshTask?.cancel()
        let delayMilliseconds = max(
            0,
            Int((session.expiresAt.timeIntervalSinceNow - Self.refreshLeadTime) * 1_000)
        )
        refreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(delayMilliseconds))
            guard !Task.isCancelled else { return }
            _ = await self?.ensureFreshSession()
        }
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

@MainActor
private final class DesktopWebAuthSession: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    func start(url: URL, callbackScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { url, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let url {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(throwing: WisentAuthError.invalidResponse)
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            guard session.start() else {
                continuation.resume(throwing: WisentAuthError.invalidResponse)
                return
            }
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApplication.shared.keyWindow
            ?? NSApplication.shared.windows.first(where: \.isVisible)
            ?? ASPresentationAnchor()
    }
}
