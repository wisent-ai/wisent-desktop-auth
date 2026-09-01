import AppKit
import AuthenticationServices
import Combine
import Foundation
import os

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
    @Published public var inviteRole = WisentOrganizationRole.member
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
    private var sharedIdentityObserver: NSObjectProtocol?
    private let sharedIdentityNotificationSource = UUID().uuidString
    private static let sharedIdentityDidChange = Notification.Name(
        "ai.wisent.identity.didChange"
    )
    private static let refreshLeadTime: TimeInterval = 5 * 60
    private static let resendDuration = 60

    /// Why the app is on the sign-in screen has to survive the app.
    ///
    /// `errorMessage` is a `@Published` value read by one SwiftUI banner: it
    /// dies with the view state, it is invisible to the operator and to any
    /// tooling, and on the one path that ends at a silent `.signedOut` it is
    /// never set at all. On 2026-08-31 a Jeden Desktop instance was found
    /// sitting on a first-run welcome screen, having started on 2026-08-27 half
    /// an hour after the shared session expired, with that session still intact
    /// in the Keychain and nothing anywhere on the machine saying what the
    /// restore had decided. The reason was unrecoverable by then.
    ///
    /// These lines are `notice`, so they persist, and they name only the
    /// decision: no token, no access token, no refresh token, no email.
    private static let restoreLog = Logger(
        subsystem: "ai.wisent.desktop.auth",
        category: "restore"
    )
    private static let expiryFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    public convenience init(productName: String) {
        let bundleIdentifier = Bundle.main.bundleIdentifier
            ?? "ai.wisent.\(WisentAuthStore.identifierSlug(from: productName))"
        self.init(
            productName: productName,
            bundleIdentifier: bundleIdentifier,
            configuration: .production(bundleIdentifier: bundleIdentifier)
        )
    }

    /// A display name is not an identifier: unbundled hosts would otherwise
    /// derive a Keychain service containing spaces.
    static func identifierSlug(from productName: String) -> String {
        productName
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .joined(separator: "-")
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
        sharedIdentityObserver = DistributedNotificationCenter.default().addObserver(
            forName: Self.sharedIdentityDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  notification.object as? String != self.sharedIdentityNotificationSource else {
                return
            }
            Task { @MainActor [weak self] in
                await self?.synchronizeSharedIdentity()
            }
        }
    }

    deinit {
        refreshTask?.cancel()
        resendCountdownTask?.cancel()
        if let sharedIdentityObserver {
            DistributedNotificationCenter.default().removeObserver(sharedIdentityObserver)
        }
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
                // Absence, not failure - but it still has to be on the record,
                // because from the outside this is indistinguishable from a
                // stored identity we failed to read.
                Self.restoreLog.notice(
                    "\(self.productName, privacy: .public): no stored identity; showing sign-in"
                )
                status = .signedOut
                return
            }
            restoredIdentityPending = true
            let storedExpiry = Self.expiryFormatter.string(from: stored.session.expiresAt)
            if stored.session.expiresAt.timeIntervalSinceNow <= Self.refreshLeadTime {
                Self.restoreLog.notice(
                    """
                    \(self.productName, privacy: .public): stored session expired or inside the \
                    refresh lead time (expiry \(storedExpiry, privacy: .public)); refreshing
                    """
                )
                guard let refreshed = try await refreshedStoredIdentity() else {
                    transitionToSignedOut()
                    return
                }
                stored = refreshed
                Self.restoreLog.notice(
                    """
                    \(self.productName, privacy: .public): refresh accepted; new expiry \
                    \(Self.expiryFormatter.string(from: stored.session.expiresAt), privacy: .public)
                    """
                )
            } else {
                Self.restoreLog.notice(
                    """
                    \(self.productName, privacy: .public): restored a live session (expiry \
                    \(storedExpiry, privacy: .public)); no refresh needed
                    """
                )
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
            Self.restoreLog.error(
                """
                \(self.productName, privacy: .public): restore failed as \
                \(String(describing: restore.code), privacy: .public); stored identity \
                \(restore.code == .auth ? "cleared" : "kept", privacy: .public); showing sign-in
                """
            )
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

    public func selectOrganization(_ organization: WisentOrganization) async {
        guard organizations.contains(where: { $0.id == organization.id }),
              await ensureFreshSession(),
              let session else { return }
        do {
            let authorization = try await client.authorizeOrganization(
                organization.id,
                session: session
            )
            selectOrganizationLocally(
                WisentOrganization(
                    id: organization.id,
                    slug: organization.slug,
                    name: organization.name,
                    role: authorization.role
                )
            )
        } catch {
            reportOrganization(error, point: .organizations)
        }
    }

    public func reloadOrganizations() async {
        await resolveOrganizations(preferredID: selectedOrganization?.id)
    }

    public func createOrganization(name: String, slug: String) async {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let slug = slug.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !name.isEmpty, !slug.isEmpty else {
            organizationNote("Enter an organization name and slug.")
            return
        }
        guard !isOrganizationBusy,
              await ensureFreshUserSession(),
              let session else { return }
        isOrganizationBusy = true
        clearOrganizationFailure()
        defer { isOrganizationBusy = false }
        do {
            let organizationID = try await client.createOrganization(
                name: name,
                slug: slug,
                session: session
            )
            await resolveOrganizations(preferredID: organizationID)
        } catch {
            reportOrganization(error, point: .organizations)
        }
    }

    public func renameOrganization(name: String) async {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            organizationNote("Enter an organization name.")
            return
        }
        guard selectedOrganization?.organizationRole?.canManageMembers == true else {
            organizationNote("Only organization owners and admins can rename it.")
            return
        }
        await performOrganizationLifecycle { session, organization in
            try await client.renameOrganization(organization.id, name: name, session: session)
        }
    }

    public func updateOrganizationSlug(_ slug: String) async {
        let slug = slug.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !slug.isEmpty else {
            organizationNote("Enter an organization slug.")
            return
        }
        guard selectedOrganization?.organizationRole == .owner else {
            organizationNote("Only an organization owner can change its slug.")
            return
        }
        await performOrganizationLifecycle { session, organization in
            try await client.updateOrganizationSlug(organization.id, slug: slug, session: session)
        }
    }

    public func leaveOrganization() async {
        await performOrganizationLifecycle(preferCurrent: false) { session, organization in
            try await client.leaveOrganization(organization.id, session: session)
        }
    }

    public func deleteOrganization() async {
        guard selectedOrganization?.organizationRole == .owner else {
            organizationNote("Only an organization owner can delete it.")
            return
        }
        await performOrganizationLifecycle(preferCurrent: false) { session, organization in
            try await client.deleteOrganization(organization.id, session: session)
        }
    }

    public func transferOrganizationOwnership(to member: WisentOrganizationMember) async {
        guard selectedOrganization?.organizationRole == .owner,
              member.userID != session?.userID else {
            organizationNote("Choose another member to receive ownership.")
            return
        }
        await performOrganizationLifecycle { session, organization in
            try await client.transferOrganizationOwnership(
                organization.id,
                to: member.userID,
                session: session
            )
        }
    }

    public func acceptInvitation(_ invitation: WisentUserInvite) async {
        guard pendingInvitations.contains(where: { $0.id == invitation.id }),
              !isBusy,
              await ensureFreshUserSession(),
              let session else { return }
        isBusy = true
        clearFailure()
        defer { isBusy = false }
        do {
            let organizationID = try await client.acceptInvitation(invitation, session: session)
            pendingInvitations.removeAll { $0.id == invitation.id }
            await resolveOrganizations(preferredID: organizationID)
        } catch {
            report(error, point: .organizations)
        }
    }

    public func declineInvitation(_ invitation: WisentUserInvite) async {
        guard pendingInvitations.contains(where: { $0.id == invitation.id }),
              !isBusy,
              await ensureFreshUserSession(),
              let session else { return }
        isBusy = true
        clearFailure()
        defer { isBusy = false }
        do {
            try await client.declineInvitation(invitation, session: session)
            pendingInvitations.removeAll { $0.id == invitation.id }
            await resolveOrganizations(preferredID: selectedOrganization?.id)
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
        guard let callerRole = selectedOrganization?.organizationRole,
              callerRole.canManageMembers else {
            organizationNote("Choose a role allowed by your organization access.")
            return
        }
        let role = inviteRole
        let allowedRoles: [WisentOrganizationRole] = callerRole == .owner
            ? WisentOrganizationRole.allCases
            : [.member]
        guard allowedRoles.contains(role) else {
            organizationNote("Choose a role allowed by your organization access.")
            return
        }
        await performOrganizationOperation { session, organization in
            try await client.inviteMember(
                email: address,
                role: role,
                organizationID: organization.id,
                session: session
            )
            inviteEmail = ""
        }
    }

    public func cancelOrganizationInvitation(_ invitation: WisentOrganizationInvite) async {
        guard let callerRole = selectedOrganization?.organizationRole,
              callerRole == .owner
                || (callerRole == .admin && invitation.organizationRole == .member) else {
            organizationNote("Your organization role cannot cancel this invitation.")
            return
        }
        await performOrganizationOperation { session, organization in
            try await client.cancelInvitation(
                id: invitation.id,
                organizationID: organization.id,
                session: session
            )
        }
    }

    public func removeOrganizationMember(_ member: WisentOrganizationMember) async {
        guard member.userID != session?.userID,
              let callerRole = selectedOrganization?.organizationRole,
              callerRole == .owner || (callerRole == .admin && member.organizationRole == .member) else {
            organizationNote("Your organization role cannot remove this member.")
            return
        }
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
        role: WisentOrganizationRole
    ) async {
        guard selectedOrganization?.organizationRole == .owner,
              member.userID != session?.userID else {
            organizationNote("Only an owner can change another member's role.")
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
        transitionToSignedOut()
        broadcastSharedIdentityChange()
    }

    @discardableResult
    public func ensureFreshSession() async -> Bool {
        await refreshSessionIfNeeded(requiresOrganization: true)
    }

    private func ensureFreshUserSession() async -> Bool {
        await refreshSessionIfNeeded(requiresOrganization: false)
    }

    private func refreshSessionIfNeeded(requiresOrganization: Bool) async -> Bool {
        guard let current = session else { return false }
        guard current.expiresAt.timeIntervalSinceNow <= Self.refreshLeadTime else { return true }
        do {
            guard let stored = try await refreshedStoredIdentity() else {
                transitionToSignedOut()
                return false
            }
            session = stored.session
            email = stored.session.email
            scheduleRefresh(for: stored.session)
            await resolveOrganizations(preferredID: stored.selectedOrganizationID)
            let contextIsReady = status == .ready && selectedOrganization != nil
            return requiresOrganization ? contextIsReady : true
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
            guard callback.scheme == configuration.callbackScheme,
                  callback.host == "auth-callback" else {
                throw WisentAuthError.oauthRejected("\(label) returned an unexpected callback")
            }
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
        broadcastSharedIdentityChange()
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
            async let availableRequest = client.organizations(session: session)
            async let invitationsRequest = client.pendingInvitations(session: session)
            let available = try await availableRequest
            pendingInvitations = try await invitationsRequest
            organizations = available

            guard !available.isEmpty else {
                selectedOrganization = nil
                organizationMembers = []
                organizationInvitations = []
                try persistence.save(
                    StoredIdentity(session: session, selectedOrganizationID: nil)
                )
                broadcastSharedIdentityChange()
                status = pendingInvitations.isEmpty ? .choosingOrganization : .reviewingInvitations
                return
            }

            let candidate: WisentOrganization?
            if let preferredID {
                candidate = available.first(where: { $0.id == preferredID })
            } else if available.count == 1 {
                candidate = available.first
            } else {
                candidate = nil
            }

            guard let candidate else {
                selectedOrganization = nil
                organizationMembers = []
                organizationInvitations = []
                try persistence.save(
                    StoredIdentity(session: session, selectedOrganizationID: nil)
                )
                broadcastSharedIdentityChange()
                status = .choosingOrganization
                return
            }
            await selectOrganization(candidate)
            if selectedOrganization?.id != candidate.id {
                status = .choosingOrganization
            }
        } catch {
            report(error, point: .organizations)
            status = organizations.isEmpty ? .choosingOrganization : .signedOut
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
            organizationMembers = try await client.organizationMembers(
                organizationID: organization.id,
                session: session
            )
            if organization.canManageMembers {
                organizationInvitations = try await client.organizationInvitations(
                    organizationID: organization.id,
                    session: session
                )
            } else {
                organizationInvitations = []
            }
        } catch {
            reportOrganization(error, point: .organizations)
        }
    }

    private func performOrganizationLifecycle(
        preferCurrent: Bool = true,
        _ operation: (WisentSession, WisentOrganization) async throws -> Void
    ) async {
        guard !isOrganizationBusy,
              await ensureFreshSession(),
              let session,
              let organization = selectedOrganization else {
            organizationNote("Select an organization first.")
            return
        }
        isOrganizationBusy = true
        clearOrganizationFailure()
        defer { isOrganizationBusy = false }
        do {
            try await operation(session, organization)
            await resolveOrganizations(preferredID: preferCurrent ? organization.id : nil)
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

    private func selectOrganizationLocally(_ organization: WisentOrganization) {
        guard let session,
              let index = organizations.firstIndex(where: { $0.id == organization.id }) else {
            return
        }
        organizations[index] = organization
        selectedOrganization = organization
        organizationMembers = []
        organizationInvitations = []
        inviteEmail = ""
        inviteRole = .member
        clearOrganizationFailure()
        status = .ready
        publishRestoredIdentityIfReady()
        do {
            try persistence.save(
                StoredIdentity(session: session, selectedOrganizationID: organization.id)
            )
            broadcastSharedIdentityChange()
        } catch {
            report(error, point: .storage)
        }
    }

    /// Re-reads the shared item immediately before using its refresh token.
    /// Another Wisent process may already have rotated it since this store last
    /// published `session`; refreshing that stale token would revoke the shared
    /// login for every app.
    private func refreshedStoredIdentity() async throws -> StoredIdentity? {
        guard let latest = try persistence.load() else { return nil }
        guard latest.session.expiresAt.timeIntervalSinceNow <= Self.refreshLeadTime else {
            return latest
        }
        let refreshed = try await client.refresh(refreshToken: latest.session.refreshToken)
        let stored = StoredIdentity(
            session: refreshed,
            selectedOrganizationID: latest.selectedOrganizationID
        )
        try persistence.save(stored)
        broadcastSharedIdentityChange()
        return stored
    }

    private func synchronizeSharedIdentity() async {
        do {
            guard let stored = try persistence.load() else {
                transitionToSignedOut()
                return
            }
            let current = session.map {
                StoredIdentity(
                    session: $0,
                    selectedOrganizationID: selectedOrganization?.id
                )
            }
            guard stored != current else { return }
            session = stored.session
            email = stored.session.email
            code = ""
            clearFailure()
            scheduleRefresh(for: stored.session)
            await resolveOrganizations(preferredID: stored.selectedOrganizationID)
        } catch {
            report(error, point: .storage)
        }
    }

    private func transitionToSignedOut() {
        refreshTask?.cancel()
        refreshTask = nil
        resetResendCountdown()
        session = nil
        restoredIdentity = nil
        restoredIdentityPending = false
        organizations = []
        selectedOrganization = nil
        pendingInvitations = []
        organizationMembers = []
        organizationInvitations = []
        inviteEmail = ""
        inviteRole = .member
        clearOrganizationFailure()
        email = ""
        code = ""
        clearFailure()
        status = .signedOut
    }

    private func broadcastSharedIdentityChange() {
        DistributedNotificationCenter.default().postNotificationName(
            Self.sharedIdentityDidChange,
            object: sharedIdentityNotificationSource,
            userInfo: nil,
            deliverImmediately: true
        )
    }



    /// Publishes a dependency failure: the classified sentence for the screen,
    /// the raw material for the operator log. Nothing technical gets past here.
    @discardableResult
    private func report(_ error: Error, point: WisentFailurePoint) -> WisentFailure {
        let classified = WisentFailureClassifier.report(error, point: point)
        if let authError = error as? WisentAuthError,
           case .organizationRefusal = authError {
            organizationFailure = classified
            organizationError = classified.message
        }
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
