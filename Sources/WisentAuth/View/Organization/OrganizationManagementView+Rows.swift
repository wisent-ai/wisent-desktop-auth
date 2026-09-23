import AppKit
import SwiftUI
import WisentDesignSystem

extension OrganizationManagementView {
    func memberRow(_ member: WisentOrganizationMember) -> some View {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(member.email)
                                if member.userID == store.session?.userID {
                                    Text("You")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 3) {
                                Text(member.role.capitalized)
                                    .font(.caption.weight(.medium))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(.secondary.opacity(0.12), in: Capsule())
                                if member.organizationRole != .owner,
                                   !member.managementPermissions.isEmpty {
                                    Text("\(member.managementPermissions.count) management permissions")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            if canManage(member) {
                                Menu {
                                    if store.selectedOrganization?.organizationRole == .owner {
                                        ForEach(WisentOrganizationRole.allCases, id: \.self) { role in
                                            Button("Make \(role.rawValue)") {
                                                Task {
                                                    await store.updateOrganizationMemberRole(
                                                        member,
                                                        role: role
                                                    )
                                                }
                                            }
                                            .disabled(role == member.organizationRole)
                                        }
                                        if member.organizationRole != .owner {
                                            Divider()
                                            Button("Transfer ownership…") {
                                                memberPendingOwnershipTransfer = member
                                            }
                                        }
                                    }
                                    if store.selectedOrganization?.organizationRole == .owner,
                                       member.organizationRole != .owner {
                                        Menu("Management permissions") {
                                            ForEach(
                                                WisentOrganizationManagementPermission.allCases,
                                                id: \.self
                                            ) { permission in
                                                Button {
                                                    Task {
                                                        await store.updateOrganizationMemberPermissions(
                                                            member,
                                                            permissions: toggledPermissions(
                                                                permission,
                                                                for: member
                                                            )
                                                        )
                                                    }
                                                } label: {
                                                    Label(
                                                        permission.label,
                                                        systemImage: member.managementPermissions.contains(
                                                            permission
                                                        ) ? "checkmark.circle.fill" : "circle"
                                                    )
                                                }
                                            }
                                        }
                                    }
                                    Divider()
                                    Button("Remove member…", role: .destructive) {
                                        memberPendingRemoval = member
                                    }
                                } label: {
                                    Image(systemName: "ellipsis.circle")
                                }
                                .menuStyle(.borderlessButton)
                            }
                        }
                        .accessibilityIdentifier("wisent.auth.member.\(member.userID)")
    }

    func invitationRow(_ invitation: WisentOrganizationInvite) -> some View {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(invitation.email)
                                    Text(invitation.role.capitalized)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Label(
                                        deliveryLabel(invitation.deliveryStatus),
                                        systemImage: deliveryIcon(invitation.deliveryStatus)
                                    )
                                    .font(.caption2)
                                    .foregroundStyle(
                                        invitation.deliveryStatus == .failed
                                            ? Color.red
                                            : Color.secondary
                                    )
                                }
                                Spacer()
                                if let expiresAt = invitation.expiresAt {
                                    Text(expiresAt.formatted(date: .abbreviated, time: .omitted))
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                                if canResend(invitation) {
                                    Button(
                                        invitation.deliveryStatus == .failed ? "Retry delivery" : "Resend"
                                    ) {
                                        Task {
                                            await store.resendOrganizationInvitation(invitation)
                                        }
                                    }
                                }
                                if canCancel(invitation) {
                                    Button("Cancel", role: .destructive) {
                                        Task {
                                            await store.cancelOrganizationInvitation(invitation)
                                        }
                                    }
                                }
                            }
                            .accessibilityIdentifier("wisent.auth.pending-invitation.\(invitation.id)")
    }

    var availableInviteRoles: [WisentOrganizationRole] {
        store.selectedOrganization?.organizationRole == .owner
            ? WisentOrganizationRole.allCases
            : [.member]
    }

    func canManage(_ member: WisentOrganizationMember) -> Bool {
        guard member.userID != store.session?.userID else { return false }
        if store.selectedOrganization?.organizationRole == .owner { return true }
        return member.organizationRole == .member
            && store.selectedOrganization?.hasManagementPermission(.membersRemove) == true
    }

    func canCancel(_ invitation: WisentOrganizationInvite) -> Bool {
        guard store.selectedOrganization?.hasManagementPermission(.invitationsCancel) == true else {
            return false
        }
        return store.selectedOrganization?.organizationRole == .owner
            || invitation.organizationRole == .member
    }

    func canResend(_ invitation: WisentOrganizationInvite) -> Bool {
        guard store.selectedOrganization?.hasManagementPermission(.membersInvite) == true else {
            return false
        }
        return store.selectedOrganization?.organizationRole == .owner
            || invitation.organizationRole == .member
    }

    func toggledPermissions(
        _ permission: WisentOrganizationManagementPermission,
        for member: WisentOrganizationMember
    ) -> [WisentOrganizationManagementPermission] {
        let existing = Set(member.managementPermissions)
        return WisentOrganizationManagementPermission.allCases.filter {
            $0 == permission ? !existing.contains($0) : existing.contains($0)
        }
    }

    func deliveryLabel(_ status: WisentInvitationDeliveryStatus) -> String {
        switch status {
        case .pending: "Delivery pending"
        case .sent: "Email sent"
        case .failed: "Saved — email not delivered"
        }
    }

    func deliveryIcon(_ status: WisentInvitationDeliveryStatus) -> String {
        switch status {
        case .pending: "clock"
        case .sent: "checkmark.circle"
        case .failed: "exclamationmark.triangle"
        }
    }

    var canLeaveSelectedOrganization: Bool {
        guard let organization = store.selectedOrganization else { return false }
        guard organization.organizationRole == .owner else { return true }
        return store.organizationMembers.contains {
            $0.userID != store.session?.userID && $0.organizationRole == .owner
        }
    }

    var canDeleteSelectedOrganization: Bool {
        guard let organization = store.selectedOrganization else { return false }
        return organization.organizationRole == .owner && !organization.isFixedWisentOrganization
    }
}
