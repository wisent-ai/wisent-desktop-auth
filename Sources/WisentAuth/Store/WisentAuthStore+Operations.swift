import AppKit
import AuthenticationServices
import Combine
import Foundation
import os

extension WisentAuthStore {
    func resolveOrganizations(preferredID: String?) async {
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
            // Superseded, not failed: the newer read of the identity decides
            // the status, and a cancelled request must never sign anyone out.
            if WisentFailureClassifier.isCancellation(error) {
                return
            }
            report(error, point: .organizations)
            status = organizations.isEmpty ? .choosingOrganization : .signedOut
        }
    }

    func performOrganizationOperation(
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
            if organization.hasManagementPermission(.membersInvite)
                || organization.hasManagementPermission(.invitationsCancel)
            {
                organizationInvitations = try await client.organizationInvitations(
                    organizationID: organization.id,
                    session: session
                )
            } else {
                organizationInvitations = []
            }
        } catch {
            if case let WisentAuthError.invitationSavedButUndelivered(invitation) = error {
                upsertOrganizationInvitation(invitation)
            }
            reportOrganization(error, point: .organizations)
        }
    }

    func upsertOrganizationInvitation(_ invitation: WisentOrganizationInvite) {
        if let index = organizationInvitations.firstIndex(where: { $0.id == invitation.id }) {
            organizationInvitations[index] = invitation
        } else {
            organizationInvitations.append(invitation)
        }
    }

    func performOrganizationLifecycle(
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

    func perform(point: WisentFailurePoint, _ operation: () async throws -> Void) async {
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

    func startResendCountdown() {
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

    func resetResendCountdown() {
        resendCountdownTask?.cancel()
        resendCountdownTask = nil
        resendCountdown = 0
    }

    func scheduleRefresh(for session: WisentSession) {
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

    func selectOrganizationLocally(_ organization: WisentOrganization) {
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
    func refreshedStoredIdentity() async throws -> StoredIdentity? {
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

}
