import AppKit
import AuthenticationServices
import Combine
import Foundation
import os

public enum WisentAuthStatus: Equatable {
    case restoring
    case signedOut
    case waitingForCode
    case resolvingOrganization
    case reviewingInvitations
    case choosingOrganization
    case ready
}

/// The one-time code the identity provider mails is six digits long.
public enum WisentVerificationCode {
    public static let length = 6
}

@MainActor
public final class WisentAuthStore: ObservableObject {
    @Published public internal(set) var status: WisentAuthStatus = .restoring
    @Published public internal(set) var session: WisentSession?
    @Published public internal(set) var organizations: [WisentOrganization] = []
    @Published public internal(set) var restoredIdentity: WisentRestoredIdentity?
    @Published public internal(set) var selectedOrganization: WisentOrganization?
    @Published public var email = "" {
        didSet {
            guard email != oldValue else { return }
            resetResendCountdown()
        }
    }
    @Published public var code = ""
    @Published public internal(set) var isBusy = false
    @Published public internal(set) var isOAuthBusy = false
    @Published public internal(set) var loadingProvider: String?
    @Published public internal(set) var resendCountdown: Int = 0
    @Published public internal(set) var errorMessage: String?

    /// The classified form of ``errorMessage``. Lets a host app tell the user's
    /// own mistake apart from our outage instead of colouring everything red,
    /// and tells it whether retrying is worth a button.
    @Published public internal(set) var failure: WisentFailure?
    @Published public internal(set) var pendingInvitations: [WisentUserInvite] = []
    @Published public internal(set) var organizationMembers: [WisentOrganizationMember] = []
    @Published public internal(set) var organizationInvitations: [WisentOrganizationInvite] = []
    @Published public var inviteEmail = ""
    @Published public var inviteRole = WisentOrganizationRole.member
    @Published public internal(set) var isOrganizationBusy = false
    @Published public internal(set) var organizationError: String?
    @Published public internal(set) var organizationFailure: WisentFailure?

    public let productName: String
    /// Nonprompting host diagnostics captured before the first Keychain access.
    @Published public internal(set) var permissionReport: WisentPermissionReport?
    public var oauthEnabled: Bool { configuration.oauthEnabled }

    let configuration: WisentAuthConfiguration
    let client: SupabaseIdentityClient
    let persistence: any IdentityPersistence
    var started = false
    var restoredIdentityPending = false
    var refreshTask: Task<Void, Never>?
    var resendCountdownTask: Task<Void, Never>?
    var webSession: (any OAuthWebSession)?
    let webSessionFactory: @MainActor () -> any OAuthWebSession
    var sharedIdentityObserver: NSObjectProtocol?
    let sharedIdentityNotificationSource = UUID().uuidString
    static let sharedIdentityDidChange = Notification.Name(
        "ai.wisent.identity.didChange"
    )
    static let refreshLeadTime: TimeInterval = 5 * 60
    static let resendDuration = 60

    /// Why the app is on the sign-in screen has to survive the app.
    ///
    /// `errorMessage` is a `@Published` value read by one SwiftUI banner: it
    /// dies with the view state, it is invisible to the operator and to any
    /// tooling, and on the one path that ends at a silent `.signedOut` it is
    /// never set at all. On 2026-08-31 a Jeden Desktop instance was found
    /// sitting on a first-run welcome screen, having started on 2026-08-27 half
    /// an hour after the shared session expired, with that session still intact
    /// in the Keychain and nothing anywhere on the machine saying what the
    /// restore had decided. The reason was unrecoverable by then.
    ///
    /// These lines are `notice`, so they persist, and they name only the
    /// decision: no token, no access token, no refresh token, no email.
    static let restoreLog = Logger(
        subsystem: "ai.wisent.desktop.auth",
        category: "restore"
    )
    static let expiryFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    public convenience init(productName: String) {
        let bundleIdentifier = Bundle.main.bundleIdentifier
            ?? "ai.wisent.\(WisentAuthStore.identifierSlug(from: productName))"
        self.init(
            productName: productName,
            bundleIdentifier: bundleIdentifier,
            configuration: .production(bundleIdentifier: bundleIdentifier)
        )
    }

    /// A display name is not an identifier: unbundled hosts would otherwise
    /// derive a Keychain service containing spaces.
    static func identifierSlug(from productName: String) -> String {
        productName
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .joined(separator: "-")
    }

    init(
        productName: String,
        bundleIdentifier: String,
        configuration: WisentAuthConfiguration,
        persistence: (any IdentityPersistence)? = nil,
        webSessionFactory: (@MainActor () -> any OAuthWebSession)? = nil
    ) {
        self.productName = productName
        self.configuration = configuration
        client = SupabaseIdentityClient(configuration: configuration)
        self.persistence = persistence ?? KeychainIdentityStore(bundleIdentifier: bundleIdentifier)
        self.webSessionFactory = webSessionFactory ?? { DesktopWebAuthSession() }
        sharedIdentityObserver = DistributedNotificationCenter.default().addObserver(
            forName: Self.sharedIdentityDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  notification.object as? String != self.sharedIdentityNotificationSource else {
                return
            }
            Task { @MainActor [weak self] in
                await self?.synchronizeSharedIdentity()
            }
        }
    }

    deinit {
        refreshTask?.cancel()
        resendCountdownTask?.cancel()
        if let sharedIdentityObserver {
            DistributedNotificationCenter.default().removeObserver(sharedIdentityObserver)
        }
    }

    public var identity: WisentIdentity? {
        guard let session, let selectedOrganization else { return nil }
        return WisentIdentity(
            userID: session.userID,
            email: session.email,
            organization: selectedOrganization,
            accessToken: session.accessToken
        )
    }

}
