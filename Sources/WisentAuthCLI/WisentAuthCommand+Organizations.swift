import Darwin
import Foundation
import WisentAuth

extension WisentAuthCommand {
    @MainActor
    static func runInvitation(
        _ arguments: [String],
        selector: String?,
        store: WisentAuthStore
    ) async throws {
        guard let action = arguments.first else { throw CLIError.usage("invitation requires an action") }
        let values = Array(arguments.dropFirst())
        switch action {
        case "list":
            try noArguments(values)
            try requireSignedIn(store)
            if store.selectedOrganization != nil || selector != nil {
                try await prepareOrganization(selector: selector, management: true, store: store)
            }
            try output(
                InvitationListOutput(
                    received: store.pendingInvitations.map { ReceivedInvitationOutput($0) },
                    pending: store.organizationInvitations
                )
            )
        case "send":
            guard (1...2).contains(values.count) else {
                throw CLIError.usage("Usage: wisent-auth invitation send <email> [owner|admin|member] [--organization <id-or-slug>]")
            }
            try await prepareOrganization(selector: selector, management: true, store: store)
            store.inviteEmail = values[0]
            if values.count == 2 {
                store.inviteRole = try role(values[1])
            }
            await store.sendOrganizationInvitation()
            try succeeded(store, organization: true)
            guard let invitation = store.organizationInvitations.first(where: {
                $0.email.caseInsensitiveCompare(values[0]) == .orderedSame
            }) else {
                throw CLIError.failure("Invitation was sent but its saved record was not returned")
            }
            try output(invitation)
        case "resend":
            guard values.count == 1 else {
                throw CLIError.usage("Usage: wisent-auth invitation resend <invitation-id> [--organization <id-or-slug>]")
            }
            try await prepareOrganization(selector: selector, management: true, store: store)
            let invitation = try organizationInvitation(values[0], store: store)
            await store.resendOrganizationInvitation(invitation)
            try succeeded(store, organization: true)
            try output(try organizationInvitation(values[0], store: store))
        case "accept":
            guard values.count == 1 else { throw CLIError.usage("Usage: wisent-auth invitation accept <invitation-id>") }
            let invitation = try receivedInvitation(values[0], store: store)
            await store.acceptInvitation(invitation)
            try succeeded(store)
            guard let organization = store.selectedOrganization else {
                throw CLIError.failure("Invitation was accepted but the organization could not be selected")
            }
            try output(organization)
        case "decline":
            guard values.count == 1 else { throw CLIError.usage("Usage: wisent-auth invitation decline <invitation-id>") }
            let invitation = try receivedInvitation(values[0], store: store)
            await store.declineInvitation(invitation)
            try succeeded(store)
            try output(MessageOutput(ok: true, message: "Invitation declined"))
        case "cancel":
            guard values.count == 1 else {
                throw CLIError.usage("Usage: wisent-auth invitation cancel <invitation-id> [--organization <id-or-slug>]")
            }
            try await prepareOrganization(selector: selector, management: true, store: store)
            let invitation = try organizationInvitation(values[0], store: store)
            await store.cancelOrganizationInvitation(invitation)
            try succeeded(store, organization: true)
            try output(MessageOutput(ok: true, message: "Invitation cancelled"))
        default:
            throw CLIError.usage("Unknown invitation action '\(action)'")
        }
    }

    @MainActor
    static func runMember(
        _ arguments: [String],
        selector: String?,
        store: WisentAuthStore
    ) async throws {
        guard let action = arguments.first else { throw CLIError.usage("member requires an action") }
        let values = Array(arguments.dropFirst())
        try await prepareOrganization(selector: selector, management: true, store: store)
        switch action {
        case "list":
            try noArguments(values)
            try output(store.organizationMembers)
        case "role":
            guard values.count == 2 else {
                throw CLIError.usage("Usage: wisent-auth member role <user-id> <owner|admin|member> [--organization <id-or-slug>]")
            }
            let member = try organizationMember(values[0], store: store)
            await store.updateOrganizationMemberRole(member, role: try role(values[1]))
            try succeeded(store, organization: true)
            try output(try organizationMember(values[0], store: store))
        case "permissions":
            guard let userID = values.first else {
                throw CLIError.usage("Usage: wisent-auth member permissions <user-id> [permission ...] [--organization <id-or-slug>]")
            }
            let permissions = try values.dropFirst().map { try permission($0) }
            let member = try organizationMember(userID, store: store)
            await store.updateOrganizationMemberPermissions(member, permissions: permissions)
            try succeeded(store, organization: true)
            try output(try organizationMember(userID, store: store))
        case "remove":
            guard values.count == 1 else {
                throw CLIError.usage("Usage: wisent-auth member remove <user-id> [--organization <id-or-slug>]")
            }
            let member = try organizationMember(values[0], store: store)
            await store.removeOrganizationMember(member)
            try succeeded(store, organization: true)
            try output(MessageOutput(ok: true, message: "Member removed"))
        default:
            throw CLIError.usage("Unknown member action '\(action)'")
        }
    }

    @MainActor
    static func runOwnership(
        _ arguments: [String],
        selector: String?,
        store: WisentAuthStore
    ) async throws {
        guard arguments.first == "transfer", arguments.count == 2 else {
            throw CLIError.usage("Usage: wisent-auth ownership transfer <user-id> [--organization <id-or-slug>]")
        }
        try await prepareOrganization(selector: selector, management: true, store: store)
        let member = try organizationMember(arguments[1], store: store)
        await store.transferOrganizationOwnership(to: member)
        try succeeded(store, organization: true)
        try output(store.selectedOrganization!)
    }

    @MainActor
    static func prepareOrganization(
        selector: String?,
        management: Bool,
        store: WisentAuthStore
    ) async throws {
        try requireSignedIn(store)
        if let selector { try await selectOrganization(selector, store: store) }
        guard store.selectedOrganization != nil else {
            throw CLIError.failure("No organization is selected; pass --organization <id-or-slug>")
        }
        if management {
            await store.loadOrganizationManagement()
            try succeeded(store, organization: true)
        }
    }

}
