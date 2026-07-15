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

    public init(id: String, slug: String, name: String, role: String) {
        self.id = id
        self.slug = slug
        self.name = name
        self.role = role
    }
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

enum WisentAuthError: LocalizedError {
    case malformedURL(String)
    case invalidResponse
    case http(Int, String)
    case malformedSession
    case noOrganization
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case let .malformedURL(value): "Invalid authentication URL: \(value)"
        case .invalidResponse: "The identity service returned an invalid response."
        case let .http(status, body): "Identity request failed (\(status)): \(Self.safe(body))"
        case .malformedSession: "The identity service did not return a complete session."
        case .noOrganization: "No organization is available for this account."
        case let .keychain(status): "The session could not be stored securely (Keychain status \(status))."
        }
    }

    private static func safe(_ body: String) -> String {
        let singleLine = body.split(whereSeparator: \.isNewline).joined(separator: " ")
        return String(singleLine.prefix(240))
    }
}

struct StoredIdentity: Codable, Sendable, Equatable {
    let session: WisentSession
    var selectedOrganizationID: String?
}

struct MembershipRow: Decodable, Sendable {
    struct Organization: Decodable, Sendable {
        let id: String
        let slug: String
        let name: String
    }

    let organizationID: String
    let role: String
    let organization: Organization

    enum CodingKeys: String, CodingKey {
        case organizationID = "org_id"
        case role
        case organization = "organizations"
    }

    var value: WisentOrganization {
        WisentOrganization(
            id: organizationID,
            slug: organization.slug,
            name: organization.name,
            role: role
        )
    }
}
