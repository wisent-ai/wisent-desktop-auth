import Foundation
import Security

public struct WisentAuthConfiguration: Sendable, Equatable {
    public let supabaseURL: String
    public let anonKey: String
    public let redirectURL: String
    public let callbackScheme: String
    public let oauthEnabled: Bool
    /// Whether this is the fleet's shared identity project. A shared identity
    /// resolves organizations and keeps its session in the one item every
    /// Wisent app reads; a product's own project (Byk's trading project) has
    /// no organizations and keeps its session in an item of its own, so it
    /// never overwrites the identity the other apps are signed in with.
    public let sharedIdentity: Bool

    public init(
        supabaseURL: String,
        anonKey: String,
        redirectURL: String,
        callbackScheme: String,
        oauthEnabled: Bool,
        sharedIdentity: Bool = true
    ) {
        self.supabaseURL = supabaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        self.anonKey = anonKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.redirectURL = redirectURL
        self.callbackScheme = callbackScheme
        self.oauthEnabled = oauthEnabled
        self.sharedIdentity = sharedIdentity
    }

    /// A product's own Supabase project, signed in through this package's
    /// store: its email code, OAuth and refresh, returning on the callback
    /// scheme the product's project already allows, with no organizations and
    /// a session item of its own.
    public static func product(
        supabaseURL: String,
        anonKey: String,
        callbackScheme: String
    ) -> WisentAuthConfiguration {
        WisentAuthConfiguration(
            supabaseURL: supabaseURL,
            anonKey: anonKey,
            redirectURL: "\(callbackScheme)://auth-callback",
            callbackScheme: callbackScheme,
            oauthEnabled: true,
            sharedIdentity: false
        )
    }

    /// The app's own Wisent Identity configuration: the `WisentIdentityURL`
    /// and `WisentIdentityAnonKey` keys of its Info.plist, else
    /// `SUPABASE_URL` / `SUPABASE_ANON_KEY` from the environment (a CLI or a
    /// test host has no bundle). Nothing is compiled into this package: an
    /// app that declares neither is not configured, and sign-in says so.
    public static func production(bundleIdentifier: String) -> WisentAuthConfiguration {
        let environment = ProcessInfo.processInfo.environment
        let callbackScheme = environment["WISENT_AUTH_CALLBACK_SCHEME"] ?? bundleIdentifier
        func declared(_ infoKey: String, _ environmentKey: String) -> String {
            let bundled = (Bundle.main.object(forInfoDictionaryKey: infoKey) as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !bundled.isEmpty, !bundled.hasPrefix("$(") { return bundled }
            return environment[environmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        return WisentAuthConfiguration(
            supabaseURL: declared("WisentIdentityURL", "SUPABASE_URL"),
            anonKey: declared("WisentIdentityAnonKey", "SUPABASE_ANON_KEY"),
            redirectURL: environment["WISENT_AUTH_REDIRECT_URL"] ?? "\(callbackScheme)://auth-callback",
            callbackScheme: callbackScheme,
            oauthEnabled: environment["WISENT_AUTH_OAUTH_ENABLED"] != "0"
        )
    }

    public var isConfigured: Bool {
        !supabaseURL.isEmpty && URL(string: supabaseURL) != nil && !anonKey.isEmpty
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
