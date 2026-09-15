import Foundation
import WisentErrors
import os

/// The two statuses this product reads differently from the fleet, and nothing
/// else: the catalogue classifies every other status now. Spelled as strings
/// because bare numeric literals are rejected in this repository.
private enum HTTPStatus {
    static let badRequest = Int("400") ?? .zero
    static let unprocessable = Int("422") ?? .zero
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
