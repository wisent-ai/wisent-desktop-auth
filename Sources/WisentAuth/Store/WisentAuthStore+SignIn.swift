import AppKit
import AuthenticationServices
import Combine
import Foundation
import os

extension WisentAuthStore {
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
        guard token.count == WisentVerificationCode.length else {
            note("Please enter all \(WisentVerificationCode.length) digits")
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

    func ensureFreshUserSession() async -> Bool {
        await refreshSessionIfNeeded(requiresOrganization: false)
    }

    func refreshSessionIfNeeded(requiresOrganization: Bool) async -> Bool {
        guard let current = session else { return false }
        guard current.expiresAt.timeIntervalSinceNow <= Self.refreshLeadTime else {
            return requiresOrganization ? (status == .ready && selectedOrganization != nil) : true
        }
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
            // A cancelled refresh was superseded - by a newer identity read
            // after another Wisent app broadcast a change, or by the app going
            // away - and the request that superseded it decides the state. On
            // 2026-09-18 Jeden reported every such cancellation as "the account
            // service isn't responding" and showed the sign-in screen once an
            // hour, with the identity service answering the whole time.
            if WisentFailureClassifier.isCancellation(error) {
                return false
            }
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

    func signInWithOAuth(provider: String, label: String) async {
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

    func accept(_ newSession: WisentSession) async throws {
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

}
