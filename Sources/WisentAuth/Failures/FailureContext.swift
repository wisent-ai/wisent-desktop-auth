import Foundation

/// What the user actually loses. Only the two areas a sign-in library can take
/// down are modelled; an `x-wisent-failure-impact` naming some other product
/// area is not meaningful on a sign-in surface and falls back to the call site.
public enum WisentFailureImpact: String, Sendable {
    case account
    case app

    init?(header: String?) {
        guard let raw = header?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty,
              let parsed = WisentFailureImpact(rawValue: raw)
        else { return nil }
        self = parsed
    }
}

/// Stable dependency axis, named the way the same dependency is named
/// operationally in the other Wisent repositories.
public enum WisentFailureService: String, Sendable {
    case auth
    case database
    case app
}

/// A dependency call site whose failure reaches a person.
public struct WisentFailurePoint: Sendable, Equatable {
    public let id: String
    public let service: WisentFailureService
    public let impact: WisentFailureImpact

    /// True when the user has just typed the credential this call verifies.
    ///
    /// This is the distinction the sign-in screen lives or dies on: the same
    /// `auth` code means "the code you typed is wrong" while entering it, and
    /// "your stored session expired" everywhere else.
    public let isCredentialEntry: Bool

    init(
        id: String,
        service: WisentFailureService,
        impact: WisentFailureImpact,
        isCredentialEntry: Bool = false
    ) {
        self.id = id
        self.service = service
        self.impact = impact
        self.isCredentialEntry = isCredentialEntry
    }

    static let configuration = WisentFailurePoint(id: "identity.configuration", service: .app, impact: .account)
    static let storage = WisentFailurePoint(id: "identity.keychain", service: .app, impact: .app)
    static let session = WisentFailurePoint(id: "identity.session", service: .auth, impact: .account)
    static let organizations = WisentFailurePoint(id: "identity.organizations", service: .database, impact: .account)
    static let oauthAuthorize = WisentFailurePoint(id: "identity.oauth.authorize", service: .auth, impact: .account)
    static let oauthCallback = WisentFailurePoint(
        id: "identity.oauth.callback",
        service: .auth,
        impact: .account,
        isCredentialEntry: true
    )
    static let otpRequest = WisentFailurePoint(
        id: "identity.otp.request",
        service: .auth,
        impact: .account,
        isCredentialEntry: true
    )
    static let otpVerify = WisentFailurePoint(
        id: "identity.otp.verify",
        service: .auth,
        impact: .account,
        isCredentialEntry: true
    )
    static let oauthExchange = WisentFailurePoint(
        id: "identity.oauth.exchange",
        service: .auth,
        impact: .account,
        isCredentialEntry: true
    )
    static let sessionRefresh = WisentFailurePoint(
        id: "identity.session.refresh",
        service: .auth,
        impact: .account
    )

    /// The endpoint is the identity of the call site, so the point is derived
    /// from the path instead of threaded through every request helper.
    static func forRequest(path: String) -> WisentFailurePoint {
        let route = path.split(separator: "?").first.map(String.init) ?? path

        if route.hasPrefix("/auth/v1/") {
            switch route {
            case "/auth/v1/otp":
                return .otpRequest
            case "/auth/v1/verify":
                return .otpVerify
            case "/auth/v1/logout":
                return WisentFailurePoint(id: "identity.session.signout", service: .auth, impact: .account)
            case "/auth/v1/token":
                // A PKCE exchange is the user's fresh sign-in; a refresh is a
                // stored session being renewed behind their back.
                return path.contains("grant_type=pkce") ? .oauthExchange : .sessionRefresh
            default:
                return WisentFailurePoint(id: "identity.auth", service: .auth, impact: .account)
            }
        }

        if route.hasPrefix("/rest/v1/rpc/") {
            let name = String(route.dropFirst("/rest/v1/rpc/".count))
            return WisentFailurePoint(
                id: "identity.rpc." + (name.isEmpty ? "unknown" : name),
                service: .database,
                impact: .account
            )
        }
        if route.hasPrefix("/rest/v1/organization_members") { return .organizations }
        return WisentFailurePoint(id: "identity.rest", service: .database, impact: .account)
    }
}

/// Header names a Wisent service answers with. Read-only here: this library
/// never produces them, but an identity call routed through `brama` may carry
/// them, and a service that names its own failure is always believed.
enum WisentFailureHeader {
    static let code = "x-wisent-failure"
    static let impact = "x-wisent-failure-impact"
}

/// A non-2xx answer from the identity provider, kept whole so the operator log
/// can be honest. Nothing in here is ever rendered.
struct WisentUpstreamResponse: Sendable, Equatable {
    let status: Int
    let body: String
    let headerCode: String?
    let headerImpact: String?
}

/// The classified failure. Deliberately carries no diagnostic: everything a
/// consumer app can reach from here is safe to put on screen, and the raw
/// material never leaves ``WisentFailureClassifier/report(_:point:)``.
public struct WisentFailure: Sendable, Equatable {
    public let point: WisentFailurePoint
    public let code: WisentFailureCode

    /// The call site's own impact, unless a Wisent service named a different
    /// one in `x-wisent-failure-impact`.
    public let impact: WisentFailureImpact

    /// The one sentence a user is allowed to see. Never contains an exception
    /// message, an upstream body, an environment variable name or a path.
    public let message: String

    public var service: WisentFailureService { point.service }
    public var isRetryable: Bool { code.isRetryable }
    public var isOutage: Bool { code.isOutage }
}

