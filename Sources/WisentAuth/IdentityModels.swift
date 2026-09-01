import Foundation
import Security

public struct WisentAuthConfiguration: Sendable, Equatable {
    public let supabaseURL: String
    public let anonKey: String
    public let redirectURL: String
    public let callbackScheme: String
    public let oauthEnabled: Bool

    public init(
        supabaseURL: String,
        anonKey: String,
        redirectURL: String,
        callbackScheme: String,
        oauthEnabled: Bool
    ) {
        self.supabaseURL = supabaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        self.anonKey = anonKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.redirectURL = redirectURL
        self.callbackScheme = callbackScheme
        self.oauthEnabled = oauthEnabled
    }

    public static func production(bundleIdentifier: String) -> WisentAuthConfiguration {
        let environment = ProcessInfo.processInfo.environment
        let callbackScheme = environment["WISENT_AUTH_CALLBACK_SCHEME"] ?? bundleIdentifier
        return WisentAuthConfiguration(
            supabaseURL: environment["SUPABASE_URL"] ?? "https://alvaewvbyxpgwdpugnxy.supabase.co",
            anonKey: environment["SUPABASE_ANON_KEY"] ?? "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImFsdmFld3ZieXhwZ3dkcHVnbnh5Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODEzOTc5NDcsImV4cCI6MjA5Njk3Mzk0N30.xkkJ36ZTwtqyVZLFju0vc9S25grTuKbj9ILKlsXdUPA",
            redirectURL: environment["WISENT_AUTH_REDIRECT_URL"] ?? "\(callbackScheme)://auth-callback",
            callbackScheme: callbackScheme,
            oauthEnabled: environment["WISENT_AUTH_OAUTH_ENABLED"] != "0"
        )
    }

    public var isConfigured: Bool {
        URL(string: supabaseURL) != nil && !anonKey.isEmpty
    }
}

public enum WisentOrganizationRole: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    case owner
    case admin
    case member


    public var defaultManagementPermissions: [WisentOrganizationManagementPermission] {
        self == .member ? [] : WisentOrganizationManagementPermission.allCases
    }
}

public enum WisentOrganizationManagementPermission: String, Codable, Sendable, Equatable,
    Hashable, CaseIterable
{
    case organizationRename = "organization.rename"
    case membersInvite = "members.invite"
    case membersRemove = "members.remove"
    case invitationsCancel = "invitations.cancel"

    public var label: String {
        switch self {
        case .organizationRename: "Rename organization"
        case .membersInvite: "Invite members"
        case .membersRemove: "Remove members"
        case .invitationsCancel: "Cancel invitations"
        }
    }
}

public enum WisentAuthHeader {
    public static let authorization = "Authorization"
    public static let organizationID = "X-Wisent-Organization-ID"
}

public struct WisentSession: Codable, Sendable, Equatable {
    public let accessToken: String
    public let refreshToken: String
    public let expiresAt: Date
    public let userID: String
    public let email: String

    public var isExpired: Bool { Date() >= expiresAt }
}

public struct WisentOrganization: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let slug: String
    public let name: String
    public let role: String
    public let managementPermissions: [WisentOrganizationManagementPermission]

    public init(
        id: String,
        slug: String,
        name: String,
        role: String,
        managementPermissions: [WisentOrganizationManagementPermission]? = nil
    ) {
        self.id = id
        self.slug = slug
        self.name = name
        self.role = role
        let organizationRole = WisentOrganizationRole(rawValue: role)
        self.managementPermissions = organizationRole == .owner
            ? WisentOrganizationManagementPermission.allCases
            : managementPermissions ?? organizationRole?.defaultManagementPermissions ?? []
    }

    enum CodingKeys: String, CodingKey {
        case id
        case slug
        case name
        case role
        case managementPermissions = "management_permissions"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        slug = try values.decode(String.self, forKey: .slug)
        name = try values.decode(String.self, forKey: .name)
        role = try values.decode(String.self, forKey: .role)
        let decodedPermissions = try values.decodeIfPresent(
            [WisentOrganizationManagementPermission].self,
            forKey: .managementPermissions
        )
        managementPermissions = WisentOrganizationRole(rawValue: role) == .owner
            ? WisentOrganizationManagementPermission.allCases
            : decodedPermissions ?? []
    }
}

public extension WisentOrganization {
    var organizationRole: WisentOrganizationRole? { WisentOrganizationRole(rawValue: role) }
    var effectiveManagementPermissions: [WisentOrganizationManagementPermission] {
        organizationRole == .owner
            ? WisentOrganizationManagementPermission.allCases
            : managementPermissions
    }
    var canManageMembers: Bool {
        hasManagementPermission(.membersInvite)
            || hasManagementPermission(.membersRemove)
            || hasManagementPermission(.invitationsCancel)
    }

    func hasManagementPermission(_ permission: WisentOrganizationManagementPermission) -> Bool {
        organizationRole == .owner || managementPermissions.contains(permission)
    }

    init(
        id: String,
        slug: String,
        name: String,
        role: WisentOrganizationRole,
        managementPermissions: [WisentOrganizationManagementPermission]? = nil
    ) {
        self.init(
            id: id,
            slug: slug,
            name: name,
            role: role.rawValue,
            managementPermissions: managementPermissions ?? role.defaultManagementPermissions
        )
    }
}

extension WisentOrganization {
    static let fixedWisentOrganizationID = "00000000-0000-4000-8000-000000000001"

    var isFixedWisentOrganization: Bool { id == Self.fixedWisentOrganizationID }
}

public struct WisentOrganizationMember: Codable, Sendable, Equatable, Identifiable {
    public let userID: String
    public let email: String
    public let role: String
    public let managementPermissions: [WisentOrganizationManagementPermission]
    public let createdAt: Date?

    public var id: String { userID }

    public init(
        userID: String,
        email: String,
        role: String,
        managementPermissions: [WisentOrganizationManagementPermission]? = nil,
        createdAt: Date? = nil
    ) {
        self.userID = userID
        self.email = email
        self.role = role
        let organizationRole = WisentOrganizationRole(rawValue: role)
        self.managementPermissions = organizationRole == .owner
            ? WisentOrganizationManagementPermission.allCases
            : managementPermissions ?? organizationRole?.defaultManagementPermissions ?? []
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case email
        case role
        case managementPermissions = "management_permissions"
        case createdAt = "created_at"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        userID = try values.decode(String.self, forKey: .userID)
        email = try values.decode(String.self, forKey: .email)
        role = try values.decode(String.self, forKey: .role)
        let decodedPermissions = try values.decodeIfPresent(
            [WisentOrganizationManagementPermission].self,
            forKey: .managementPermissions
        )
        managementPermissions = WisentOrganizationRole(rawValue: role) == .owner
            ? WisentOrganizationManagementPermission.allCases
            : decodedPermissions ?? []
        createdAt = try values.decodeIfPresent(Date.self, forKey: .createdAt)
    }
}

public extension WisentOrganizationMember {
    var organizationRole: WisentOrganizationRole? { WisentOrganizationRole(rawValue: role) }
    var effectiveManagementPermissions: [WisentOrganizationManagementPermission] {
        organizationRole == .owner
            ? WisentOrganizationManagementPermission.allCases
            : managementPermissions
    }

    func hasManagementPermission(_ permission: WisentOrganizationManagementPermission) -> Bool {
        organizationRole == .owner || managementPermissions.contains(permission)
    }
}

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

/// Every failure this library can produce, each one already knowing which
/// dependency it belongs to and how it should be named to a person.
///
/// The payloads are raw on purpose — an upstream body, a URL, an `OSStatus`.
/// None of them reach ``errorDescription``; they are reachable only through
/// ``diagnostic``, which only ``WisentFailureClassifier`` reads, and only to
/// write it to the operator log.
enum WisentAuthError: LocalizedError {
    case notConfigured(String)
    case malformedURL(String)
    case invalidResponse(WisentFailurePoint)
    case http(WisentUpstreamResponse, WisentFailurePoint)
    case malformedSession
    case noOrganization
    case keychain(OSStatus)
    case webAuthenticationTimedOut
    case oauthRejected(String)
    case organizationRefusal(WisentOrganizationRefusal)
    case invitationSavedButUndelivered(WisentOrganizationInvite)

    var point: WisentFailurePoint {
        switch self {
        case .notConfigured, .malformedURL: .configuration
        case let .invalidResponse(point): point
        case let .http(_, point): point
        case .malformedSession: .session
        case .noOrganization, .organizationRefusal, .invitationSavedButUndelivered: .organizations
        case .keychain: .storage
        case .webAuthenticationTimedOut: .oauthAuthorize
        case .oauthRejected: .oauthCallback
        }
    }

    /// A Wisent service fronting the identity provider may name the impact
    /// itself; otherwise the call site's own impact stands.
    var impact: WisentFailureImpact {
        guard case let .http(response, point) = self else { return self.point.impact }
        return WisentFailureImpact(header: response.headerImpact) ?? point.impact
    }

    var code: WisentFailureCode {
        switch self {
        case .notConfigured, .malformedURL, .noOrganization:
            .config
        case .organizationRefusal:
            .notFound
        case .invitationSavedButUndelivered:
            .infraDown
        case let .http(response, point):
            WisentFailureClassifier.code(for: response, service: point.service)
        case .invalidResponse, .malformedSession:
            // The transport or the identity provider handed us something that
            // is not a session. That is our side being broken, and it must
            // never surface as "no such account".
            .infraDown
        case .keychain:
            .unknown
        case .webAuthenticationTimedOut:
            .timeout
        case .oauthRejected:
            .auth
        }
    }

    /// A safe sentence that beats the generic taxonomy copy for this one case.
    /// Still free of exception text, upstream bodies, paths and env var names.
    var specificMessage: String? {
        switch self {
        case .noOrganization:
            "This account isn't attached to any organization yet. Create one or contact support."
        case let .organizationRefusal(refusal):
            refusal.userMessage
        case .invitationSavedButUndelivered:
            "Invitation was saved, but its email was not delivered. Retry it below."
        case .keychain:
            "Your sign-in couldn't be stored securely on this Mac. Try again, and check your keychain if it keeps failing."
        case .webAuthenticationTimedOut:
            "Browser sign-in did not respond. Cancel it or try again."
        default:
            nil
        }
    }

    /// Operator-only. Never rendered, never returned over a network.
    var diagnostic: String? {
        switch self {
        case let .notConfigured(reason):
            "identity configuration incomplete: \(reason)"
        case let .malformedURL(value):
            "malformed identity url: \(value)"
        case let .invalidResponse(point):
            "non-http response at \(point.id)"
        case let .http(response, _):
            "http \(response.status) header=\(response.headerCode ?? "-") body=\(response.body)"
        case .malformedSession:
            "session payload missing access_token, refresh_token or user id"
        case .noOrganization:
            "no organization rows visible during organization resolution"
        case let .organizationRefusal(refusal):
            "organization rpc refusal: \(refusal.rawValue)"
        case let .invitationSavedButUndelivered(invitation):
            "invitation \(invitation.id) persisted with delivery status \(invitation.deliveryStatus.rawValue)"
        case let .keychain(status):
            "keychain osstatus \(status)"
        case .webAuthenticationTimedOut:
            "asWebAuthenticationSession produced no callback before its deadline"
        case let .oauthRejected(detail):
            "oauth callback carried no authorization code: \(detail)"
        }
    }

    var errorDescription: String? {
        WisentFailureClassifier.classify(self, point: point).message
    }
}

struct StoredIdentity: Codable, Sendable, Equatable {
    let session: WisentSession
    var selectedOrganizationID: String?
}


struct OrganizationAuthorizationRow: Decodable, Sendable {
    let userID: String
    let organizationID: String
    let role: WisentOrganizationRole

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case organizationID = "organization_id"
        case role
    }
}

struct MembershipRow: Decodable, Sendable {
    struct Organization: Decodable, Sendable {
        let id: String
        let slug: String
        let name: String
    }

    let organizationID: String
    let role: WisentOrganizationRole
    let managementPermissions: [WisentOrganizationManagementPermission]
    let organization: Organization

    enum CodingKeys: String, CodingKey {
        case organizationID = "org_id"
        case role
        case managementPermissions = "management_permissions"
        case organization = "organizations"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        organizationID = try values.decode(String.self, forKey: .organizationID)
        role = try values.decode(WisentOrganizationRole.self, forKey: .role)
        let decodedPermissions = try values.decodeIfPresent(
            [WisentOrganizationManagementPermission].self,
            forKey: .managementPermissions
        )
        managementPermissions = role == .owner
            ? WisentOrganizationManagementPermission.allCases
            : decodedPermissions ?? []
        organization = try values.decode(Organization.self, forKey: .organization)
    }

    var value: WisentOrganization {
        WisentOrganization(
            id: organizationID,
            slug: organization.slug,
            name: organization.name,
            role: role,
            managementPermissions: managementPermissions
        )
    }
}
