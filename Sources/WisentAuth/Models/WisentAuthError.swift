import Foundation
import Security

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
