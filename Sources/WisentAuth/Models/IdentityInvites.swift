import Foundation

public enum WisentInvitationDeliveryStatus: String, Codable, Sendable, Equatable, Hashable {
    case pending
    case sent
    case failed
}

public struct WisentOrganizationInvite: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let email: String
    public let role: String
    public let expiresAt: Date?
    public let createdAt: Date?
    public let deliveryID: String?
    public let deliveryStatus: WisentInvitationDeliveryStatus
    public let deliveryAttempts: Int
    public let deliveredAt: Date?
    public let providerMessageID: String?
    public let lastDeliveryError: String?

    enum CodingKeys: String, CodingKey {
        case id
        case email
        case role
        case expiresAt = "expires_at"
        case createdAt = "created_at"
        case deliveryID = "delivery_id"
        case deliveryStatus = "delivery_status"
        case deliveryAttempts = "delivery_attempts"
        case deliveredAt = "delivered_at"
        case providerMessageID = "provider_message_id"
        case lastDeliveryError = "last_delivery_error"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        email = try values.decode(String.self, forKey: .email)
        role = try values.decode(String.self, forKey: .role)
        expiresAt = try values.decodeIfPresent(Date.self, forKey: .expiresAt)
        createdAt = try values.decodeIfPresent(Date.self, forKey: .createdAt)
        deliveryID = try values.decodeIfPresent(String.self, forKey: .deliveryID)
        deliveryStatus = try values.decodeIfPresent(
            WisentInvitationDeliveryStatus.self,
            forKey: .deliveryStatus
        ) ?? .pending
        deliveryAttempts = try values.decodeIfPresent(Int.self, forKey: .deliveryAttempts) ?? 0
        deliveredAt = try values.decodeIfPresent(Date.self, forKey: .deliveredAt)
        providerMessageID = try values.decodeIfPresent(String.self, forKey: .providerMessageID)
        lastDeliveryError = try values.decodeIfPresent(String.self, forKey: .lastDeliveryError)
    }
}

public extension WisentOrganizationInvite {
    var organizationRole: WisentOrganizationRole? { WisentOrganizationRole(rawValue: role) }
}

public struct WisentUserInvite: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let organizationID: String
    public let organizationName: String
    public let role: String
    public let expiresAt: Date?
    let token: String

    enum CodingKeys: String, CodingKey {
        case id
        case organizationID = "org_id"
        case organizationName = "org_name"
        case role
        case expiresAt = "expires_at"
        case token
    }
}

public extension WisentUserInvite {
    var organizationRole: WisentOrganizationRole? { WisentOrganizationRole(rawValue: role) }
}

public struct WisentIdentity: Sendable, Equatable {
    public let userID: String
    public let email: String
    public let organization: WisentOrganization
    public let accessToken: String

    public init(userID: String, email: String, organization: WisentOrganization, accessToken: String) {
        self.userID = userID
        self.email = email
        self.organization = organization
        self.accessToken = accessToken
    }
}

public extension WisentIdentity {
    func authorize(_ request: inout URLRequest) {

        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: WisentAuthHeader.authorization)
        request.setValue(organization.id, forHTTPHeaderField: WisentAuthHeader.organizationID)
    }

    func authorized(_ request: URLRequest) -> URLRequest {
        var request = request
        authorize(&request)
        return request
    }
}
enum WisentOrganizationRefusal: String, Sendable {
    case notAuthenticated = "not authenticated"
    case noMembership = "no organization membership"
    case insufficientRole = "insufficient organization role"
    case transferBeforeLeaving = "transfer ownership before leaving the organization"
    case ownersOnlyTransfer = "only owners can transfer ownership"
    case targetNotMember = "target member does not belong to the organization"
    case wisentOrganizationImmutable = "the Wisent organization cannot be modified"
    case wisentOrganizationNotDeletable = "the Wisent organization cannot be deleted"
    case invalidName = "organization name is invalid"
    case invalidSlug = "organization slug is invalid"
    case slugInUse = "organization slug is already in use"
    case invalidEmail = "email is invalid"
    case emailAlreadyMember = "email is already a member of this organization"
    case invalidRole = "invalid organization role"
    case invalidInvite = "invalid or expired invite"

    var userMessage: String {
        switch self {
        case .notAuthenticated:
            "Your session has expired. Sign in again to continue."
        case .noMembership:
            "You no longer have access to this organization."
        case .insufficientRole, .ownersOnlyTransfer:
            "Your organization role does not allow this action."
        case .transferBeforeLeaving:
            "Transfer ownership before leaving this organization."
        case .targetNotMember:
            "That person is no longer a member of this organization."
        case .wisentOrganizationImmutable:
            "The Wisent organization cannot be modified."
        case .wisentOrganizationNotDeletable:
            "The Wisent organization cannot be deleted."
        case .invalidName:
            "Enter a valid organization name."
        case .invalidSlug:
            "Enter a valid organization slug."
        case .slugInUse:
            "That organization slug is already in use."
        case .invalidEmail:
            "Enter a valid email address."
        case .emailAlreadyMember:
            "That email is already a member of this organization."
        case .invalidRole:
            "Choose a valid organization role."
        case .invalidInvite:
            "That invitation is invalid or has expired."
        }
    }
}

/// Evidence that this process restored a previously persisted host identity.
///
/// The initializer is intentionally internal. Host applications can observe
/// this value, but cannot manufacture it from a sign-in button or callback.
/// ``WisentAuthStore`` publishes it only after a stored session has resolved a
/// real organization and reached the ready state.
public struct WisentRestoredIdentity: Sendable, Equatable {
    public let userID: String
    public let organizationID: String
    public let sessionExpiresAt: Date
    public let observedAt: Date

    package init(
        userID: String,
        organizationID: String,
        sessionExpiresAt: Date,
        observedAt: Date
    ) {
        self.userID = userID
        self.organizationID = organizationID
        self.sessionExpiresAt = sessionExpiresAt
        self.observedAt = observedAt
    }
}
