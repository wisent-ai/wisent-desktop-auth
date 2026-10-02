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
    /// View-state errors do not survive process exit, and a restore decision
    /// can end at `.signedOut` without setting a banner. Keep that decision in
    /// the persistent diagnostic log as well.
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

    /// A store for a product's own Supabase project
    /// (`WisentAuthConfiguration.product`): the same sign-in, refresh and
    /// session Keychain as the shared identity, kept apart from it.
    public convenience init(productName: String, configuration: WisentAuthConfiguration) {
        let bundleIdentifier = Bundle.main.bundleIdentifier
            ?? "ai.wisent.\(WisentAuthStore.identifierSlug(from: productName))"
        self.init(productName: productName, bundleIdentifier: bundleIdentifier, configuration: configuration)
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
        self.persistence = persistence ?? (configuration.sharedIdentity
            ? KeychainIdentityStore(bundleIdentifier: bundleIdentifier)
            : KeychainIdentityStore(productService: "\(bundleIdentifier).session"))
        self.webSessionFactory = webSessionFactory ?? { DesktopWebAuthSession() }
        // Another Wisent app on this Mac that signs in or out posts this, so
        // every app follows the shared identity. iOS has no cross-app
        // notification centre; an iOS app and its widget read the same
        // access-group item on their next restore instead. A product's own
        // project is not that identity and neither follows nor announces it.
        #if os(macOS)
        guard configuration.sharedIdentity else { return }
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
        #endif
    }

    deinit {
        refreshTask?.cancel()
        resendCountdownTask?.cancel()
        #if os(macOS)
        if let sharedIdentityObserver {
            DistributedNotificationCenter.default().removeObserver(sharedIdentityObserver)
        }
        #endif
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
