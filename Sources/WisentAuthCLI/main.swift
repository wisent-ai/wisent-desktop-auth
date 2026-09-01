import Darwin
import Foundation
import WisentAuth

@main
struct WisentAuthCommand {
    @MainActor
    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            guard !arguments.isEmpty else { throw CLIError.usage(Self.usage) }
            let store = WisentAuthStore(productName: "Wisent Auth CLI")
            await store.start()
            try await run(arguments, store: store)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            FileHandle.standardError.write(Data("wisent-auth: \(message)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }

    @MainActor
    private static func run(_ rawArguments: [String], store: WisentAuthStore) async throws {
        var arguments = rawArguments
        let organizationSelector = try takeOption("--organization", from: &arguments)
        guard let command = arguments.first else { throw CLIError.usage(usage) }
        arguments.removeFirst()

        switch command {
        case "otp":
            try await runOTP(arguments, store: store)
        case "status":
            try noArguments(arguments)
            try output(StatusOutput(store: store))
        case "logout":
            try noArguments(arguments)
            await store.signOut()
            try output(MessageOutput(ok: true, message: "Signed out"))
        case "organization":
            try await runOrganization(arguments, selector: organizationSelector, store: store)
        case "invitation":
            try await runInvitation(arguments, selector: organizationSelector, store: store)
        case "member":
            try await runMember(arguments, selector: organizationSelector, store: store)
        case "ownership":
            try await runOwnership(arguments, selector: organizationSelector, store: store)
        case "help", "--help", "-h":
            try output(HelpOutput(usage: usage))
        default:
            throw CLIError.usage("Unknown command '\(command)'.\n\n\(usage)")
        }
    }

    @MainActor
    private static func runOTP(_ arguments: [String], store: WisentAuthStore) async throws {
        guard let action = arguments.first else { throw CLIError.usage("otp requires request or verify") }
        switch action {
        case "request":
            guard arguments.count == 2 else { throw CLIError.usage("Usage: wisent-auth otp request <email>") }
            store.email = arguments[1]
            await store.sendCode()
            try succeeded(store)
            try output(MessageOutput(ok: true, message: "Verification code requested"))
        case "verify":
            guard arguments.count == 3 else {
                throw CLIError.usage("Usage: wisent-auth otp verify <email> <six-digit-code>")
            }
            store.email = arguments[1]
            store.code = arguments[2]
            await store.verifyCode()
            try succeeded(store)
            guard let session = store.session else { throw CLIError.failure("Verification did not create a session") }
            try output(SessionOutput(session: session, organization: store.selectedOrganization))
        default:
            throw CLIError.usage("otp requires request or verify")
        }
    }

    @MainActor
    private static func runOrganization(
        _ arguments: [String],
        selector: String?,
        store: WisentAuthStore
    ) async throws {
        guard let action = arguments.first else { throw CLIError.usage("organization requires an action") }
        let values = Array(arguments.dropFirst())
        switch action {
        case "list":
            try noArguments(values)
            try requireSignedIn(store)
            try output(store.organizations)
        case "create":
            guard values.count == 2 else {
                throw CLIError.usage("Usage: wisent-auth organization create <name> <slug>")
            }
            try requireSignedIn(store)
            await store.createOrganization(name: values[0], slug: values[1])
            try succeeded(store, organization: true)
            guard let organization = store.selectedOrganization else {
                throw CLIError.failure("Organization was created but could not be selected")
            }
            try output(organization)
        case "select":
            guard values.count == 1 else {
                throw CLIError.usage("Usage: wisent-auth organization select <id-or-slug>")
            }
            try await selectOrganization(values[0], store: store)
            try output(store.selectedOrganization!)
        case "show":
            try noArguments(values)
            try await prepareOrganization(selector: selector, management: false, store: store)
            try output(store.selectedOrganization!)
        case "rename":
            guard values.count == 1 else {
                throw CLIError.usage("Usage: wisent-auth organization rename <name> [--organization <id-or-slug>]")
            }
            try await prepareOrganization(selector: selector, management: false, store: store)
            await store.renameOrganization(name: values[0])
            try succeeded(store, organization: true)
            try output(store.selectedOrganization!)
        case "slug":
            guard values.count == 1 else {
                throw CLIError.usage("Usage: wisent-auth organization slug <slug> [--organization <id-or-slug>]")
            }
            try await prepareOrganization(selector: selector, management: false, store: store)
            await store.updateOrganizationSlug(values[0])
            try succeeded(store, organization: true)
            try output(store.selectedOrganization!)
        case "leave":
            try noArguments(values)
            try await prepareOrganization(selector: selector, management: true, store: store)
            let previous = store.selectedOrganization?.id
            await store.leaveOrganization()
            try succeeded(store, organization: true)
            try output(LifecycleOutput(ok: true, previousOrganizationID: previous, selected: store.selectedOrganization))
        case "delete":
            try noArguments(values)
            try await prepareOrganization(selector: selector, management: false, store: store)
            let previous = store.selectedOrganization?.id
            await store.deleteOrganization()
            try succeeded(store, organization: true)
            try output(LifecycleOutput(ok: true, previousOrganizationID: previous, selected: store.selectedOrganization))
        default:
            throw CLIError.usage("Unknown organization action '\(action)'")
        }
    }

    @MainActor
    private static func runInvitation(
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
    private static func runMember(
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
    private static func runOwnership(
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
    private static func prepareOrganization(
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

    @MainActor
    private static func selectOrganization(_ selector: String, store: WisentAuthStore) async throws {
        try requireSignedIn(store)
        guard let organization = store.organizations.first(where: {
            $0.id == selector || $0.slug.caseInsensitiveCompare(selector) == .orderedSame
        }) else {
            throw CLIError.failure("No accessible organization matches '\(selector)'")
        }
        await store.selectOrganization(organization)
        try succeeded(store, organization: true)
        guard store.selectedOrganization?.id == organization.id else {
            throw CLIError.failure("Organization '\(selector)' could not be selected")
        }
    }

    @MainActor
    private static func requireSignedIn(_ store: WisentAuthStore) throws {
        guard store.session != nil else {
            throw CLIError.failure("No saved session; run 'wisent-auth otp request <email>' then 'wisent-auth otp verify <email> <code>'")
        }
        try succeeded(store)
    }

    @MainActor
    private static func succeeded(_ store: WisentAuthStore, organization: Bool = false) throws {
        if organization, let message = store.organizationError { throw CLIError.failure(message) }
        if let message = store.errorMessage { throw CLIError.failure(message) }
    }

    @MainActor
    private static func organizationMember(
        _ userID: String,
        store: WisentAuthStore
    ) throws -> WisentOrganizationMember {
        guard let member = store.organizationMembers.first(where: { $0.userID == userID }) else {
            throw CLIError.failure("No organization member has user id '\(userID)'")
        }
        return member
    }

    @MainActor
    private static func organizationInvitation(
        _ id: String,
        store: WisentAuthStore
    ) throws -> WisentOrganizationInvite {
        guard let invitation = store.organizationInvitations.first(where: { $0.id == id }) else {
            throw CLIError.failure("No pending organization invitation has id '\(id)'")
        }
        return invitation
    }

    @MainActor
    private static func receivedInvitation(
        _ id: String,
        store: WisentAuthStore
    ) throws -> WisentUserInvite {
        guard let invitation = store.pendingInvitations.first(where: { $0.id == id }) else {
            throw CLIError.failure("No invitation received by this account has id '\(id)'")
        }
        return invitation
    }

    private static func role(_ value: String) throws -> WisentOrganizationRole {
        guard let role = WisentOrganizationRole(rawValue: value.lowercased()) else {
            throw CLIError.usage("Role must be owner, admin, or member")
        }
        return role
    }

    private static func permission(_ value: String) throws -> WisentOrganizationManagementPermission {
        guard let permission = WisentOrganizationManagementPermission(rawValue: value.lowercased()) else {
            let accepted = WisentOrganizationManagementPermission.allCases.map(\.rawValue).joined(separator: ", ")
            throw CLIError.usage("Unknown permission '\(value)'; expected one of: \(accepted)")
        }
        return permission
    }

    private static func takeOption(_ name: String, from arguments: inout [String]) throws -> String? {
        guard let index = arguments.firstIndex(of: name) else { return nil }
        guard arguments.indices.contains(index + 1) else {
            throw CLIError.usage("\(name) requires a value")
        }
        let value = arguments[index + 1]
        arguments.removeSubrange(index...(index + 1))
        return value
    }

    private static func noArguments(_ arguments: [String]) throws {
        guard arguments.isEmpty else { throw CLIError.usage("Unexpected argument '\(arguments[0])'") }
    }

    private static func output<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    private static let usage = """
    Usage: wisent-auth <command>

      otp request <email>
      otp verify <email> <six-digit-code>
      status
      logout
      organization list
      organization create <name> <slug>
      organization select <id-or-slug>
      organization show|rename|slug|leave|delete [arguments] [--organization <id-or-slug>]
      invitation list|send|resend|accept|decline|cancel [arguments] [--organization <id-or-slug>]
      member list|role|permissions|remove [arguments] [--organization <id-or-slug>]
      ownership transfer <user-id> [--organization <id-or-slug>]
    """
}

private enum CLIError: LocalizedError {
    case usage(String)
    case failure(String)

    var errorDescription: String? {
        switch self {
        case let .usage(message), let .failure(message): message
        }
    }
}

private struct MessageOutput: Encodable {
    let ok: Bool
    let message: String
}

private struct HelpOutput: Encodable {
    let usage: String
}

private struct StatusOutput: Encodable {
    let status: String
    let signedIn: Bool
    let userID: String?
    let email: String?
    let selectedOrganization: WisentOrganization?
    let organizations: [WisentOrganization]
    let receivedInvitationCount: Int
    let failureCode: String?
    let failureMessage: String?

    @MainActor
    init(store: WisentAuthStore) {
        switch store.status {
        case .restoring: status = "restoring"
        case .signedOut: status = "signed_out"
        case .waitingForCode: status = "waiting_for_code"
        case .resolvingOrganization: status = "resolving_organization"
        case .reviewingInvitations: status = "reviewing_invitations"
        case .choosingOrganization: status = "choosing_organization"
        case .ready: status = "ready"
        }
        signedIn = store.session != nil
        userID = store.session?.userID
        email = store.session?.email
        selectedOrganization = store.selectedOrganization
        organizations = store.organizations
        receivedInvitationCount = store.pendingInvitations.count
        failureCode = store.failure?.code.rawValue
        failureMessage = store.errorMessage
    }
}

private struct SessionOutput: Encodable {
    let userID: String
    let email: String
    let expiresAt: Date
    let organization: WisentOrganization?

    init(session: WisentSession, organization: WisentOrganization?) {
        userID = session.userID
        email = session.email
        expiresAt = session.expiresAt
        self.organization = organization
    }
}

private struct LifecycleOutput: Encodable {
    let ok: Bool
    let previousOrganizationID: String?
    let selected: WisentOrganization?
}

private struct ReceivedInvitationOutput: Encodable {
    let id: String
    let organizationID: String
    let organizationName: String
    let role: String
    let expiresAt: Date?

    init(_ invitation: WisentUserInvite) {
        id = invitation.id
        organizationID = invitation.organizationID
        organizationName = invitation.organizationName
        role = invitation.role
        expiresAt = invitation.expiresAt
    }
}

private struct InvitationListOutput: Encodable {
    let received: [ReceivedInvitationOutput]
    let pending: [WisentOrganizationInvite]
}
