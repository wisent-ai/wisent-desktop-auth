import AppKit
import AuthenticationServices
import Combine
import Foundation

public enum WisentAuthStatus: Equatable {
    case restoring
    case signedOut
    case waitingForCode
    case resolvingOrganization
    case reviewingInvitations
    case choosingOrganization
    case ready
}

@MainActor
public final class WisentAuthStore: ObservableObject {
    @Published public private(set) var status: WisentAuthStatus = .restoring
    @Published public private(set) var session: WisentSession?
    @Published public private(set) var organizations: [WisentOrganization] = []
    @Published public private(set) var restoredIdentity: WisentRestoredIdentity?
    @Published public private(set) var selectedOrganization: WisentOrganization?
    @Published public var email = "" {
        didSet {
            guard email != oldValue else { return }
            resetResendCountdown()
        }
    }
    @Published public var code = ""
    @Published public private(set) var isBusy = false
    @Published public private(set) var isOAuthBusy = false
    @Published public private(set) var loadingProvider: String?
    @Published public private(set) var resendCountdown: Int = 0
    @Published public private(set) var errorMessage: String?

    /// The classified form of ``errorMessage``. Lets a host app tell the user's
    /// own mistake apart from our outage instead of colouring everything red,
    /// and tells it whether retrying is worth a button.
    @Published public private(set) var failure: WisentFailure?
    @Published public private(set) var pendingInvitations: [WisentUserInvite] = []
    @Published public private(set) var organizationMembers: [WisentOrganizationMember] = []
    @Published public private(set) var organizationInvitations: [WisentOrganizationInvite] = []
    @Published public var inviteEmail = ""
    @Published public var inviteRole = "member"
    @Published public private(set) var isOrganizationBusy = false
    @Published public private(set) var organizationError: String?
    @Published public private(set) var organizationFailure: WisentFailure?

    public let productName: String
    /// Nonprompting host diagnostics captured before the first Keychain access.
    @Published public private(set) var permissionReport: WisentPermissionReport?
    public var oauthEnabled: Bool { configuration.oauthEnabled }

    private let configuration: WisentAuthConfiguration
    private let client: SupabaseIdentityClient
    private let persistence: any IdentityPersistence
    private var started = false
    private var restoredIdentityPending = false
    private var refreshTask: Task<Void, Never>?
    private var resendCountdownTask: Task<Void, Never>?
    private var webSession: (any OAuthWebSession)?
    private let webSessionFactory: @MainActor () -> any OAuthWebSession
    private static let refreshLeadTime: TimeInterval = 5 * 60
    private static let resendDuration = 60

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
        persistence: (any IdentityPersistence)? = nil,
        webSessionFactory: (@MainActor () -> any OAuthWebSession)? = nil
    ) {
        self.productName = productName
        self.configuration = configuration
        client = SupabaseIdentityClient(configuration: configuration)
        self.persistence = persistence ?? KeychainIdentityStore(bundleIdentifier: bundleIdentifier)
        self.webSessionFactory = webSessionFactory ?? { DesktopWebAuthSession() }
    }

    deinit {
        refreshTask?.cancel()
        resendCountdownTask?.cancel()
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
        permissionReport = await WisentPermissionCenter.report(
            required: [.sharedIdentityKeychain]
        )
        guard configuration.isConfigured else {
            report(WisentAuthError.notConfigured(configurationReason), point: .configuration)
            status = .signedOut
            return
        }

        do {
            guard var stored = try persistence.load() else {
                status = .signedOut
                return
            }
            restoredIdentityPending = true
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
            // Only a rejected refresh token means the user is really signed
            // out. Clearing the keychain because the network or the identity
            // service blinked would force a pointless re-login and make an
            // outage indistinguishable from an expired account.
            let restore = report(error, point: .session)
            if restore.code == .auth {
                try? persistence.clear()
                session = nil
                restoredIdentityPending = false
            }
            status = .signedOut
        }
    }

    public func sendCode() async {
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard address.contains("@") else {
            note("Enter a valid email address.")
            return
        }
        guard !isBusy else { return }
        loadingProvider = "email"
        defer { loadingProvider = nil }
        await perform(point: .otpRequest) {
            try await client.requestOTP(email: address)
            email = address
            code = ""
            status = .waitingForCode
            startResendCountdown()
        }
    }

    public func verifyCode() async {
        let token = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.count == 6 else {
            note("Please enter all 6 digits")
            return
        }
        guard !isBusy else { return }
        isBusy = true
        clearFailure()
        defer { isBusy = false }
        do {
            let newSession = try await client.verifyOTP(email: email, code: token)
            try await accept(newSession)
        } catch {
            _ = report(error, point: .otpVerify)
            errorMessage = "Verification code is incorrect. Please, try again"
        }
    }

    public func resendCode() async {
        guard resendCountdown == 0, !isBusy else { return }
        await perform(point: .otpRequest) {
            try await client.requestOTP(email: email)
            code = ""
            startResendCountdown()
        }
    }

    public func signInWithApple() async {
        await signInWithOAuth(provider: "apple", label: "Apple")
    }

    public func signInWithGoogle() async {
        await signInWithOAuth(provider: "google", label: "Google")
    }

    public func signInWithGitHub() async {
        await signInWithOAuth(provider: "github", label: "GitHub")
    }

    public func changeEmail() {
        resetResendCountdown()
        code = ""
        clearFailure()
        status = .signedOut
    }

    public func selectOrganization(_ organization: WisentOrganization) {
        guard organizations.contains(where: { $0.id == organization.id }), let session else { return }
        selectedOrganization = organization
        organizationMembers = []
        organizationInvitations = []
        inviteEmail = ""
        inviteRole = "member"
        organizationError = nil
        status = .ready
        publishRestoredIdentityIfReady()
        do {
            try persistence.save(
                StoredIdentity(session: session, selectedOrganizationID: organization.id)
            )
        } catch {
            report(error, point: .storage)
        }
    }

    public func acceptInvitation(_ invitation: WisentUserInvite) async {
        guard pendingInvitations.contains(where: { $0.id == invitation.id }),
              !isBusy,
              await ensureFreshSession(),
              let session else { return }
        isBusy = true
        clearFailure()
        defer { isBusy = false }
        do {
            let organizationID = try await client.acceptInvitation(invitation, session: session)
            pendingInvitations.removeAll { $0.id == invitation.id }
            if pendingInvitations.isEmpty {
                await resolveOrganizations(preferredID: organizationID)
            } else {
                status = .reviewingInvitations
            }
        } catch {
            report(error, point: .organizations)
        }
    }

    public func declineInvitation(_ invitation: WisentUserInvite) async {
        guard pendingInvitations.contains(where: { $0.id == invitation.id }),
              !isBusy,
              await ensureFreshSession(),
              let session else { return }
        isBusy = true
        clearFailure()
        defer { isBusy = false }
        do {
            try await client.declineInvitation(invitation, session: session)
            pendingInvitations.removeAll { $0.id == invitation.id }
            if pendingInvitations.isEmpty {
                await resolveOrganizations(preferredID: nil)
            } else {
                status = .reviewingInvitations
            }
        } catch {
            report(error, point: .organizations)
        }
    }

    public func loadOrganizationManagement() async {
        await performOrganizationOperation { _, _ in }
    }

    public func sendOrganizationInvitation() async {
        let address = inviteEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard address.contains("@"), address.contains(".") else {
            organizationNote("Enter a valid email address.")
            return
        }
        guard let organization = selectedOrganization, organization.canManageMembers else {
            organizationNote("Your organization role cannot send invitations.")
            return
        }
        let allowedRoles = organization.role == "owner"
            ? ["owner", "admin", "member"]
            : ["admin", "member"]
        guard allowedRoles.contains(inviteRole) else {
            organizationNote("Choose a role allowed by your organization access.")
            return
        }
        await performOrganizationOperation { session, organization in
            try await client.inviteMember(
                email: address,
                role: inviteRole,
                organizationID: organization.id,
                session: session
            )
            inviteEmail = ""
        }
    }

    public func cancelOrganizationInvitation(_ invitation: WisentOrganizationInvite) async {
        await performOrganizationOperation { session, organization in
            try await client.cancelInvitation(
                id: invitation.id,
                organizationID: organization.id,
                session: session
            )
        }
    }

    public func removeOrganizationMember(_ member: WisentOrganizationMember) async {
        await performOrganizationOperation { session, organization in
            try await client.removeMember(
                userID: member.userID,
                organizationID: organization.id,
                session: session
            )
        }
    }

    public func updateOrganizationMemberRole(
        _ member: WisentOrganizationMember,
        role: String
    ) async {
        guard ["owner", "admin", "member"].contains(role) else {
            organizationNote("Choose a valid organization role.")
            return
        }
        await performOrganizationOperation { session, organization in
            try await client.updateMemberRole(
                userID: member.userID,
                role: role,
                organizationID: organization.id,
                session: session
            )
        }
    }

    public func cancelOAuthSignIn() {
        webSession?.cancel()
    }

    /// Re-runs whatever a retryable failure interrupted. An outage should cost
    /// the user a click, not a password reset, so the stored session is kept
    /// and restored again instead of being thrown away.
    public func retry() async {
        guard failure?.isRetryable == true, !isBusy else { return }
        clearFailure()
        if session != nil {
            await resolveOrganizations(preferredID: selectedOrganization?.id)
            return
        }
        // Nothing on disk to restore: the sign-in form itself is the retry.
        guard hasStoredSession else { return }
        started = false
        status = .restoring
        await start()
    }

    public func signOut() async {
        refreshTask?.cancel()
        refreshTask = nil
        resetResendCountdown()
        if let token = session?.accessToken {
            try? await client.signOut(accessToken: token)
        }
        try? persistence.clear()
        session = nil
        restoredIdentity = nil
        restoredIdentityPending = false
        organizations = []
        selectedOrganization = nil
        pendingInvitations = []
        organizationMembers = []
        organizationInvitations = []
        inviteEmail = ""
        inviteRole = "member"
        clearOrganizationFailure()
        email = ""
        code = ""
        clearFailure()
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
            // signOut() clears the published failure, so the message is
            // published after it — otherwise the user lands on a bare sign-in
            // screen with no idea why. And only a rejected token justifies
            // signing out at all: an unreachable identity service must not
            // look like an expired session.
            let refreshFailure = WisentFailureClassifier.report(error, point: .session)
            if refreshFailure.code == .auth {
                await signOut()
            }
            publish(refreshFailure)
            return false
        }
    }

    private func signInWithOAuth(provider: String, label: String) async {
        guard !isBusy else { return }
        isBusy = true
        isOAuthBusy = true
        loadingProvider = provider
        clearFailure()
        defer {
            isBusy = false
            isOAuthBusy = false
            loadingProvider = nil
            webSession = nil
        }
        do {
            let pkce = PKCEPair()
            let url = try await client.oauthAuthorizeURL(provider: provider, challenge: pkce.challenge)
            let session = webSessionFactory()
            webSession = session
            let callback = try await session.start(url: url, callbackScheme: configuration.callbackScheme)
            let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems
            guard let authorizationCode = items?.first(where: { $0.name == "code" })?.value,
                  !authorizationCode.isEmpty else {
                let providerError = items?.first(where: { $0.name == "error_description" })?.value
                throw WisentAuthError.oauthRejected(providerError ?? "\(label) returned no authorization code")
            }
            let newSession = try await client.exchangeCode(authorizationCode, verifier: pkce.verifier)
            try await accept(newSession)
        } catch is CancellationError {
            return
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            return
        } catch {
            report(error, point: .oauthCallback)
        }
    }

    private func accept(_ newSession: WisentSession) async throws {
        restoredIdentity = nil
        restoredIdentityPending = false
        resetResendCountdown()
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
        clearFailure()
        do {
            let invitations = try await client.pendingInvitations(session: session)
            if !invitations.isEmpty {
                pendingInvitations = invitations
                status = .reviewingInvitations
                return
            }
            pendingInvitations = []

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
            report(error, point: .organizations)
            status = .signedOut
        }
    }

    private func performOrganizationOperation(
        _ operation: (WisentSession, WisentOrganization) async throws -> Void
    ) async {
        guard !isOrganizationBusy else { return }
        guard await ensureFreshSession(),
              let session,
              let organization = selectedOrganization else {
            organizationNote("Select an organization before managing its team.")
            return
        }

        isOrganizationBusy = true
        clearOrganizationFailure()
        defer { isOrganizationBusy = false }
        do {
            try await operation(session, organization)
            async let members = client.organizationMembers(
                organizationID: organization.id,
                session: session
            )
            async let invitations = client.organizationInvitations(
                organizationID: organization.id,
                session: session
            )
            organizationMembers = try await members
            organizationInvitations = try await invitations
        } catch {
            reportOrganization(error, point: .organizations)
        }
    }

    private func perform(point: WisentFailurePoint, _ operation: () async throws -> Void) async {
        guard !isBusy else { return }
        isBusy = true
        clearFailure()
        defer { isBusy = false }
        do {
            try await operation()
        } catch {
            report(error, point: point)
        }
    }

    private func startResendCountdown() {
        resendCountdownTask?.cancel()
        resendCountdown = Self.resendDuration
        resendCountdownTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
                guard let self, !Task.isCancelled else { return }
                guard self.resendCountdown > 0 else { return }
                self.resendCountdown -= 1
                if self.resendCountdown == 0 {
                    self.resendCountdownTask = nil
                    return
                }
            }
        }
    }

    private func resetResendCountdown() {
        resendCountdownTask?.cancel()
        resendCountdownTask = nil
        resendCountdown = 0
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



    /// Publishes a dependency failure: the classified sentence for the screen,
    /// the raw material for the operator log. Nothing technical gets past here.
    @discardableResult
    private func report(_ error: Error, point: WisentFailurePoint) -> WisentFailure {
        let classified = WisentFailureClassifier.report(error, point: point)
        publish(classified)
        return classified
    }

    private func publish(_ classified: WisentFailure) {
        failure = classified
        errorMessage = classified.message
    }

    /// A local input problem, not a dependency failure: nothing to classify,
    /// nothing worth an operator's attention.
    private func note(_ message: String) {
        failure = nil
        errorMessage = message
    }

    private func clearFailure() {
        failure = nil
        errorMessage = nil
    }

    @discardableResult
    private func reportOrganization(_ error: Error, point: WisentFailurePoint) -> WisentFailure {
        let classified = WisentFailureClassifier.report(error, point: point)
        organizationFailure = classified
        organizationError = classified.message
        return classified
    }

    private func organizationNote(_ message: String) {
        organizationFailure = nil
        organizationError = message
    }

    private func clearOrganizationFailure() {
        organizationFailure = nil
        organizationError = nil
    }

    /// Which half of the configuration is unusable. Names the field, never its
    /// value, and only ever reaches the log.
    private var configurationReason: String {
        URL(string: configuration.supabaseURL) == nil
            ? "identity url is missing or not a url"
            : "anon key is empty"
    }

    private func publishRestoredIdentityIfReady() {
        guard restoredIdentityPending,
              status == .ready,
              let session,
              let selectedOrganization else { return }
        restoredIdentityPending = false
        restoredIdentity = WisentRestoredIdentity(
            userID: session.userID,
            organizationID: selectedOrganization.id,
            sessionExpiresAt: session.expiresAt,
            observedAt: Date()
        )
    }

    /// True when there is a session on disk worth restoring again.
    private var hasStoredSession: Bool {
        ((try? persistence.load()) ?? nil) != nil
    }
}

@MainActor
protocol OAuthWebSession: AnyObject {
    func start(url: URL, callbackScheme: String) async throws -> URL
    func cancel()
}

@MainActor
private final class DesktopWebAuthSession: NSObject, OAuthWebSession,
    ASWebAuthenticationPresentationContextProviding
{
    private let timeout: Duration
    private var session: ASWebAuthenticationSession?
    private var continuation: CheckedContinuation<URL, Error>?
    private var timeoutTask: Task<Void, Never>?

    init(timeout: Duration = .seconds(300)) {
        self.timeout = timeout
    }

    func start(url: URL, callbackScheme: String) async throws -> URL {
        guard continuation == nil else { throw WisentAuthError.invalidResponse(.oauthAuthorize) }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let session = ASWebAuthenticationSession(
                    url: url,
                    callbackURLScheme: callbackScheme
                ) { [weak self] url, error in
                    Task { @MainActor in
                        if let error {
                            self?.finish(.failure(error))
                        } else if let url {
                            self?.finish(.success(url))
                        } else {
                            self?.finish(.failure(WisentAuthError.invalidResponse(.oauthAuthorize)))
                        }
                    }
                }
                session.presentationContextProvider = self
                session.prefersEphemeralWebBrowserSession = false
                self.session = session
                guard session.start() else {
                    finish(.failure(WisentAuthError.invalidResponse(.oauthAuthorize)))
                    return
                }
                timeoutTask = Task { @MainActor [weak self, timeout] in
                    do {
                        try await Task.sleep(for: timeout)
                    } catch {
                        return
                    }
                    self?.cancel(with: WisentAuthError.webAuthenticationTimedOut)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancel()
            }
        }
    }

    func cancel() {
        cancel(with: CancellationError())
    }

    private func cancel(with error: Error) {
        guard continuation != nil else { return }
        session?.cancel()
        finish(.failure(error))
    }

    private func finish(_ result: Result<URL, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        session = nil
        continuation.resume(with: result)
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApplication.shared.keyWindow
            ?? NSApplication.shared.windows.first(where: \.isVisible)
            ?? ASPresentationAnchor()
    }
}
