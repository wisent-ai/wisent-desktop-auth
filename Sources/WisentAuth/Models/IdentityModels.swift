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

    public var canManageMembers: Bool { self == .owner || self == .admin }

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
