import Foundation
import WisentAuth

enum CLIError: LocalizedError {
    case usage(String)
    case failure(String)

    var errorDescription: String? {
        switch self {
        case let .usage(message), let .failure(message): message
        }
    }
}

struct MessageOutput: Encodable {
    let ok: Bool
    let message: String
}

struct HelpOutput: Encodable {
    let usage: String
}

struct StatusOutput: Encodable {
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

struct SessionOutput: Encodable {
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

struct LifecycleOutput: Encodable {
    let ok: Bool
    let previousOrganizationID: String?
    let selected: WisentOrganization?
}

struct ReceivedInvitationOutput: Encodable {
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

struct InvitationListOutput: Encodable {
    let received: [ReceivedInvitationOutput]
    let pending: [WisentOrganizationInvite]
}
