import AuthenticationServices
import Combine
import Foundation
import os

extension WisentAuthStore {
    func synchronizeSharedIdentity() async {
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

    func transitionToSignedOut() {
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

    /// Local sign-out always happens: the user asked to leave, and a server
    /// that cannot be reached must not keep them signed in. What did not
    /// happen is shown afterwards, so a session the server still holds, or a
    /// stored identity the keychain refused to erase (it would come back on the
    /// next launch), is never presented as a clean sign-out.
    public func signOut() async {
        refreshTask?.cancel()
        refreshTask = nil
        resetResendCountdown()
        var remoteFailure: Error?
        if let token = session?.accessToken {
            do {
                try await client.signOut(accessToken: token)
            } catch {
                remoteFailure = error
            }
        }
        var storageFailure: Error?
        do {
            try persistence.clear()
        } catch {
            storageFailure = error
        }
        transitionToSignedOut()
        broadcastSharedIdentityChange()
        if let storageFailure {
            report(storageFailure, point: .storage)
        } else if let remoteFailure {
            report(remoteFailure, point: .session)
        }
    }

    func broadcastSharedIdentityChange() {
        guard configuration.sharedIdentity else { return }
        #if os(macOS)
        DistributedNotificationCenter.default().postNotificationName(
            Self.sharedIdentityDidChange,
            object: sharedIdentityNotificationSource,
            userInfo: nil,
            deliverImmediately: true
        )
        #endif
    }



    /// Publishes a dependency failure: the classified sentence for the screen,
    /// the raw material for the operator log. Nothing technical gets past here.
    @discardableResult
    func report(_ error: Error, point: WisentFailurePoint) -> WisentFailure {
        let classified = WisentFailureClassifier.report(error, point: point)
        if let authError = error as? WisentAuthError,
           case .organizationRefusal = authError {
            organizationFailure = classified
            organizationError = classified.message
        }
        publish(classified)
        return classified
    }

    func publish(_ classified: WisentFailure) {
        failure = classified
        errorMessage = classified.message
    }

    /// A local input problem, not a dependency failure: nothing to classify,
    /// nothing worth an operator's attention.
    func note(_ message: String) {
        failure = nil
        errorMessage = message
    }

    func clearFailure() {
        failure = nil
        errorMessage = nil
    }

    @discardableResult
    func reportOrganization(_ error: Error, point: WisentFailurePoint) -> WisentFailure {
        let classified = WisentFailureClassifier.report(error, point: point)
        organizationFailure = classified
        organizationError = classified.message
        return classified
    }

    func organizationNote(_ message: String) {
        organizationFailure = nil
        organizationError = message
    }

    func clearOrganizationFailure() {
        organizationFailure = nil
        organizationError = nil
    }

    /// Which half of the configuration is unusable. Names the field, never its
    /// value, and only ever reaches the log.
    var configurationReason: String {
        URL(string: configuration.supabaseURL) == nil
            ? "identity url is missing or not a url"
            : "anon key is empty"
    }

    func publishRestoredIdentityIfReady() {
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
    var hasStoredSession: Bool {
        ((try? persistence.load()) ?? nil) != nil
    }
}
