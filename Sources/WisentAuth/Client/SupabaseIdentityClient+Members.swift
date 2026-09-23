import Foundation

extension SupabaseIdentityClient {
    func organizationMembers(
        organizationID: String,
        session identity: WisentSession
    ) async throws -> [WisentOrganizationMember] {
        let data = try await rpc(
            "list_org_members_for_org",
            body: ["target_org_id": organizationID],
            session: identity,
            organizationID: organizationID
        )
        return try Self.decode([WisentOrganizationMember].self, from: data)
    }

    func organizationInvitations(
        organizationID: String,
        session identity: WisentSession
    ) async throws -> [WisentOrganizationInvite] {
        let data = try await rpc(
            "list_org_invites_for_org",
            body: ["target_org_id": organizationID],
            session: identity,
            organizationID: organizationID
        )
        return try Self.decode([WisentOrganizationInvite].self, from: data)
    }

    @discardableResult
    func inviteMember(
        email: String,
        role: WisentOrganizationRole,
        organizationID: String,
        session identity: WisentSession
    ) async throws -> WisentOrganizationInvite {
        try await deliverInvitation(
            body: [
                "action": "create",
                "organization_id": organizationID,
                "email": email,
                "role": role.rawValue,
            ],
            organizationID: organizationID,
            session: identity
        )
    }

    @discardableResult
    func resendInvitation(
        id: String,
        organizationID: String,
        session identity: WisentSession
    ) async throws -> WisentOrganizationInvite {
        try await deliverInvitation(
            body: [
                "action": "resend",
                "organization_id": organizationID,
                "invite_id": id,
            ],
            organizationID: organizationID,
            session: identity
        )
    }

    func cancelInvitation(
        id: String,
        organizationID: String,
        session identity: WisentSession
    ) async throws {
        _ = try await rpc(
            "cancel_org_invite_for_org",
            body: ["target_org_id": organizationID, "invite_id": id],
            session: identity,
            organizationID: organizationID
        )
    }

    func removeMember(
        userID: String,
        organizationID: String,
        session identity: WisentSession
    ) async throws {
        _ = try await rpc(
            "remove_org_member_from_org",
            body: ["target_org_id": organizationID, "member_user_id": userID],
            session: identity,
            organizationID: organizationID
        )
    }

    func updateMemberRole(
        userID: String,
        role: WisentOrganizationRole,
        organizationID: String,
        session identity: WisentSession
    ) async throws {
        _ = try await rpc(
            "update_org_member_role_for_org",
            body: [
                "target_org_id": organizationID,
                "member_user_id": userID,
                "new_role": role.rawValue,
            ],
            session: identity,
            organizationID: organizationID
        )
    }

    func updateMemberPermissions(
        userID: String,
        permissions: [WisentOrganizationManagementPermission],
        organizationID: String,
        session identity: WisentSession
    ) async throws {
        _ = try await rpc(
            "update_org_member_permissions_for_org",
            body: [
                "target_org_id": organizationID,
                "member_user_id": userID,
                "new_permissions": permissions.map(\.rawValue),
            ],
            session: identity,
            organizationID: organizationID
        )
    }

}
