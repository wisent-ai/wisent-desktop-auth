import Foundation
import WisentErrors

/// Failure taxonomy shared with the Wisent web app, the Python backends, the
/// Rust router and the iOS app, so one incident is named identically in a
/// desktop sign-in sheet, in a server log and in the warehouse. That sentence is
/// a dependency now rather than a promise: the shared codes take their
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
    case refused
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

    /// The local spelling of every catalogue code, without changing its meaning.
    init(_ catalogue: WisentErrors.Code) {
        switch catalogue {
        case .config: self = .config
        case .auth: self = .auth
        case .notFound: self = .notFound
        case .rateLimit: self = .rateLimit
        case .timeout: self = .timeout
        case .infraDown: self = .infraDown
        case .refused: self = .refused
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
        case .refused: .refused
        case .unknown: .unknown
        case .offline: nil
        }
    }

    /// `offline`'s own answers, written here because the catalogue's codes
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
        case .refused:
            "A policy refused this operation. Review the access requirements before trying again."
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

