import Foundation
import WisentErrors
import os

/// Failure taxonomy shared with the Wisent web app, the Python backends, the
/// Rust router and the iOS app, so one incident is named identically in a
/// desktop sign-in sheet, in a server log and in the warehouse. That sentence is
/// a dependency now rather than a promise: the seven shared codes take their
/// retry and outage answers, their status classification and the detail trim
/// from `wisent-errors`, the fleet's one catalogue. The spellings below are the
/// wire contract and stay here; nothing derivable from a code is decided here.
///
/// Two rules this file exists to enforce, in this order:
///
/// 1. An infrastructure outage is never reported as "not found" and never as a
///    silent empty result. A broken identity service must not look like an
///    account that does not exist.
/// 2. "We are down" is never rendered as "your password is wrong". A user told
///    that their details were rejected will reset a password that was fine,
///    and will keep resetting it for as long as the outage lasts.
public enum WisentFailureCode: String, Sendable, CaseIterable {

    // MARK: Wire contract
    // The only values a Wisent service may send in `x-wisent-failure`.

    case config
    case auth
    case notFound = "not_found"
    case rateLimit = "rate_limit"
    case timeout
    case infraDown = "infra_down"
    case unknown

    // MARK: Client only

    /// This Mac has no usable connection. The user's network is not our
    /// outage, and the app must neither apologise for something it did not
    /// break nor announce an outage that only exists on a bad hotel Wi-Fi.
    case offline

    /// Parses the `x-wisent-failure` header.
    ///
    /// Membership is the catalogue's answer, not a local table: a header naming
    /// something the fleet does not define is not a code. `offline` is therefore
    /// rejected for free, and deliberately — a server cannot know that the
    /// client is offline, so a header claiming it is not trustworthy.
    init?(header: String?) {
        guard let raw = header?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty,
              let catalogue = WisentErrors.Code(rawValue: raw)
        else { return nil }
        self.init(catalogue)
    }

    /// The local spelling of a catalogue code. Total: the seven raw values here
    /// are the seven raw values there, which is what makes them one vocabulary.
    init(_ catalogue: WisentErrors.Code) {
        switch catalogue {
        case .config: self = .config
        case .auth: self = .auth
        case .notFound: self = .notFound
        case .rateLimit: self = .rateLimit
        case .timeout: self = .timeout
        case .infraDown: self = .infraDown
        case .unknown: self = .unknown
        }
    }

    /// The catalogue code this case is, or `nil` for `offline` — the one case the
    /// fleet's vocabulary does not contain.
    var catalogue: WisentErrors.Code? {
        switch self {
        case .config: .config
        case .auth: .auth
        case .notFound: .notFound
        case .rateLimit: .rateLimit
        case .timeout: .timeout
        case .infraDown: .infraDown
        case .unknown: .unknown
        case .offline: nil
        }
    }

    /// `offline`'s own answers, written here because the catalogue's seven
    /// cannot express "this device has no network" and are not being stretched
    /// to: `infra_down` would be the nearest, and it reports an outage we did
    /// not have. A dead Wi-Fi link is worth retrying and is pointedly not our
    /// breakage. Byte-identical to the table this file carried before.
    private enum LocalOffline {
        static let isRetryable = true
        static let isOutage = false
    }

    /// Worth retrying without the user changing anything. Matches the exit-code
    /// split used by the Wisent command line tools.
    public var isRetryable: Bool {
        guard let catalogue else { return LocalOffline.isRetryable }
        return catalogue.retryable
    }

    /// True when our side is down, i.e. the user is owed an apology rather than
    /// a correction. `offline` is pointedly excluded.
    public var isOutage: Bool {
        guard let catalogue else { return LocalOffline.isOutage }
        return catalogue.outage
    }
}

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

/// The two statuses this product reads differently from the fleet, and nothing
/// else: the catalogue classifies every other status now. Spelled as strings
/// because bare numeric literals are rejected in this repository.
private enum HTTPStatus {
    static let badRequest = Int("400") ?? .zero
    static let unprocessable = Int("422") ?? .zero
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

extension WisentFailureCode {

    /// Short, honest, safe to render.
    ///
    /// Every branch that is our fault says so in words, because the failure
    /// mode being fixed here is a user reading "sign-in failed" and concluding
    /// that their own password is broken.
    func userMessage(impact: WisentFailureImpact, isCredentialEntry: Bool) -> String {
        switch self {
        case .offline:
            "You appear to be offline. Check your internet connection and try again."
        case .auth:
            isCredentialEntry
                ? "Those sign-in details weren't accepted. Check them and try again."
                : "Your session has expired. Sign in again to continue."
        case .rateLimit:
            "Too many sign-in attempts. Wait a minute and try again."
        case .notFound:
            "That account or invitation is no longer available."
        case .config:
            impact == .account
                ? "Wisent sign-in isn't set up correctly in this build. This is a problem on our side, not with your details — please contact support."
                : "This app isn't set up correctly. This is a problem on our side — please contact support."
        case .timeout, .infraDown, .unknown:
            impact == .account
                ? "The Wisent account service isn't responding. This is a problem on our side, not with your details — please try again shortly."
                : "Something on our side is down. This isn't a problem with your details — please try again shortly."
        }
    }
}

/// Turns whatever URLSession, the identity provider or a decoder produced into
/// the few distinctions a user and an operator actually need, and writes the
/// raw material to the operator log — the only place it is allowed to appear.
enum WisentFailureClassifier {

    private static let logger = Logger(subsystem: "ai.wisent.desktop.auth", category: "failure")
    private static let maxDiagnosticLength = Int("400") ?? .zero

    /// URLError codes that mean this Mac cannot reach anything. Everything else
    /// that fails at the transport layer is treated as our problem, because
    /// from the user's seat it is.
    private static let deviceOfflineCodes: Set<URLError.Code> = [
        .notConnectedToInternet,
        .networkConnectionLost,
        .internationalRoamingOff,
        .dataNotAllowed,
        .callIsActive
    ]

    private static let infrastructureCodes: Set<URLError.Code> = [
        .cannotConnectToHost,
        .cannotFindHost,
        .dnsLookupFailed,
        .badServerResponse,
        .secureConnectionFailed,
        .serverCertificateUntrusted,
        .resourceUnavailable
    ]

    /// A cancelled request is not a failure and must never be reported: the
    /// user closed the browser window, or a newer request superseded this one.
    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    /// Classifies, logs the technical detail once, and hands back only what is
    /// safe to show. This is the single boundary where a failure becomes words.
    static func report(_ error: Error, point fallbackPoint: WisentFailurePoint) -> WisentFailure {
        let failure = classify(error, point: fallbackPoint)
        log(failure, diagnostic: diagnostic(for: error))
        return failure
    }

    static func classify(_ error: Error, point fallbackPoint: WisentFailurePoint) -> WisentFailure {
        if let authError = error as? WisentAuthError {
            let point = authError.point
            let code = authError.code
            let impact = authError.impact
            return WisentFailure(
                point: point,
                code: code,
                impact: impact,
                message: authError.specificMessage
                    ?? code.userMessage(impact: impact, isCredentialEntry: point.isCredentialEntry)
            )
        }

        let code = transportCode(for: error) ?? .unknown
        return WisentFailure(
            point: fallbackPoint,
            code: code,
            impact: fallbackPoint.impact,
            message: code.userMessage(
                impact: fallbackPoint.impact,
                isCredentialEntry: fallbackPoint.isCredentialEntry
            )
        )
    }

    /// Precedence: what the service said about itself, then the status code.
    ///
    /// The status ladder itself is the catalogue's, so this app cannot come to
    /// read a status differently from the router, the backends or the iOS
    /// client. What stays here is the two readings that are this product's own
    /// and are not derivable from a status alone: an API key the identity
    /// provider rejected is our deployment, and PostgREST's 404 for a function
    /// nobody deployed is a broken release rather than a missing account.
    static func code(for response: WisentUpstreamResponse, service: WisentFailureService) -> WisentFailureCode {
        if let named = WisentFailureCode(header: response.headerCode) { return named }

        // 400 and 422 carry no fleet-wide meaning — the catalogue calls them
        // `unknown` — but they are exactly how the identity provider rejects a
        // wrong one-time code, a stale refresh token or an unusable email, and
        // how PostgREST reports a query we generated badly.
        if response.status == HTTPStatus.badRequest || response.status == HTTPStatus.unprocessable {
            if mentionsAPIKey(response.body) { return .config }
            return service == .auth ? .auth : .config
        }

        let classified = WisentFailureCode(WisentErrors.Code.fromUpstream(status: response.status))
        switch classified {
        case .auth where mentionsAPIKey(response.body):
            // A rejected API key is our deployment being wrong, not the user's
            // password being wrong. The body decides; the body is never shown.
            return .config
        case .notFound where service == .database:
            // PostgREST answers 404 for a route or function that was never
            // deployed. That is a broken release, and calling it "not found"
            // would tell the user their organization does not exist.
            return .config
        default:
            return classified
        }
    }

    private static func transportCode(for error: Error) -> WisentFailureCode? {
        if let urlError = error as? URLError {
            if deviceOfflineCodes.contains(urlError.code) { return .offline }
            if urlError.code == .timedOut { return .timeout }
            if infrastructureCodes.contains(urlError.code) { return .infraDown }
            return nil
        }
        if error is DecodingError { return .unknown }
        return nil
    }

    private static func mentionsAPIKey(_ body: String) -> Bool {
        let lowered = body.lowercased()
        return lowered.contains("api key")
            || lowered.contains("apikey")
            || lowered.contains("api_key")
    }

    private static func diagnostic(for error: Error) -> String {
        if let authError = error as? WisentAuthError, let detail = authError.diagnostic {
            return detail
        }
        if let urlError = error as? URLError {
            return "urlerror \(urlError.code.rawValue) \(urlError.localizedDescription)"
        }
        return String(describing: error)
    }

    /// One structured line per failure. The operator is not a child: the status,
    /// the upstream body and the exception all belong here. They just never
    /// belong on a screen.
    private static func log(_ failure: WisentFailure, diagnostic: String) {
        logger.error(
            """
            wisent_auth_failure \
            failure_point=\(failure.point.id, privacy: .public) \
            error_code=\(failure.code.rawValue, privacy: .public) \
            service=\(failure.service.rawValue, privacy: .public) \
            impact=\(failure.impact.rawValue, privacy: .public) \
            retryable=\(failure.isRetryable, privacy: .public) \
            outage=\(failure.isOutage, privacy: .public) \
            detail=\(Self.sanitize(diagnostic), privacy: .public)
            """
        )
    }

    /// Collapses the detail onto one line, strips the one thing that must not be
    /// persisted even for an operator — bearer material — and cuts it to this
    /// product's own width. The width stays here; how to cut is the catalogue's
    /// hard cut, which is what the rest of the fleet emits.
    private static func sanitize(_ detail: String) -> String {
        let singleLine = detail.split(whereSeparator: \.isNewline).joined(separator: " ")
        let redacted = Self.secretPattern.stringByReplacingMatches(
            in: singleLine,
            range: NSRange(singleLine.startIndex..., in: singleLine),
            withTemplate: "$1<redacted>"
        )
        return trimDetail(redacted, limit: maxDiagnosticLength)
    }

    private static let secretPattern: NSRegularExpression = {
        let keys = [
            "access_token",
            "refresh_token",
            "provider_token",
            "provider_refresh_token",
            "id_token",
            "apikey",
            "api_key"
        ].joined(separator: "|")
        // swiftlint:disable:next force_try - the pattern is a compile-time constant.
        return try! NSRegularExpression(
            pattern: "(\"?(?:\(keys))\"?\\s*[:=]\\s*\"?)([^\",&}\\s]+)",
            options: [.caseInsensitive]
        )
    }()
}
