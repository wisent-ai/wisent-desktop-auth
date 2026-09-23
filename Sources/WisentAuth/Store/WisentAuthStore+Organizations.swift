import AppKit
import AuthenticationServices
import Combine
import Foundation
import os

extension WisentAuthStore {
    public func selectOrganization(_ organization: WisentOrganization) async {
        guard organizations.contains(where: { $0.id == organization.id }),
              await ensureFreshUserSession(),
              let session else { return }
        do {
            _ = try await client.authorizeOrganization(
                organization.id,
                session: session
            )
            selectOrganizationLocally(organization)
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
        guard let organization = selectedOrganization else {
            organizationNote("Select an organization first.")
            return
        }
        guard !organization.isFixedWisentOrganization else {
            organizationNote("The Wisent organization cannot be modified.")
            return
        }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            organizationNote("Enter an organization name.")
            return
        }
        await performOrganizationLifecycle { session, organization in
            try await client.renameOrganization(organization.id, name: name, session: session)
        }
    }

    public func updateOrganizationSlug(_ slug: String) async {
        guard let organization = selectedOrganization else {
            organizationNote("Select an organization first.")
            return
        }
        guard !organization.isFixedWisentOrganization else {
            organizationNote("The Wisent organization cannot be modified.")
            return
        }
        let slug = slug.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !slug.isEmpty else {
            organizationNote("Enter an organization slug.")
            return
        }
        await performOrganizationLifecycle { session, organization in
            try await client.updateOrganizationSlug(organization.id, slug: slug, session: session)
        }
    }

    public func leaveOrganization() async {
        guard selectedOrganization != nil else {
            organizationNote("Select an organization first.")
            return
        }
        await performOrganizationLifecycle(preferCurrent: false) { session, organization in
            try await client.leaveOrganization(organization.id, session: session)
        }
    }

    public func deleteOrganization() async {
        guard let organization = selectedOrganization else {
            organizationNote("Select an organization first.")
            return
        }
        guard !organization.isFixedWisentOrganization else {
            organizationNote("The Wisent organization cannot be deleted.")
            return
        }
        await performOrganizationLifecycle(preferCurrent: false) { session, organization in
            try await client.deleteOrganization(organization.id, session: session)
        }
    }

    public func transferOrganizationOwnership(to member: WisentOrganizationMember) async {
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
        let role = inviteRole
        await performOrganizationOperation { session, organization in
            _ = try await client.inviteMember(
                email: address,
                role: role,
                organizationID: organization.id,
                session: session
            )
            inviteEmail = ""
        }
    }

    public func resendOrganizationInvitation(_ invitation: WisentOrganizationInvite) async {
        await performOrganizationOperation { session, organization in
            _ = try await client.resendInvitation(
                id: invitation.id,
                organizationID: organization.id,
                session: session
            )
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
        role: WisentOrganizationRole
    ) async {
        await performOrganizationOperation { session, organization in
            try await client.updateMemberRole(
                userID: member.userID,
                role: role,
                organizationID: organization.id,
                session: session
            )
        }
    }

    public func updateOrganizationMemberPermissions(
        _ member: WisentOrganizationMember,
        permissions: [WisentOrganizationManagementPermission]
    ) async {
        let requested = Set(permissions)
        let exactPermissions = WisentOrganizationManagementPermission.allCases.filter(
            requested.contains
        )
        await performOrganizationOperation { session, organization in
            try await client.updateMemberPermissions(
                userID: member.userID,
                permissions: exactPermissions,
                organizationID: organization.id,
                session: session
            )
        }
    }

}
