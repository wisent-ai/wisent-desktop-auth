import AppKit
import SwiftUI
import WisentDesignSystem

/// The sign-in window: the width from which the brand hero fits beside the form, the form's own
/// narrowest width, and the width the two columns take together.
enum SignInLayout {
    static let heroBreakpoint: CGFloat = 1_024
    static let minimumWidth: CGFloat = 480
    static let widthWithHero: CGFloat = 1_120
}

enum WisentAuthResources {
    static let bundle: Bundle = {
        let bundleName = "WisentDesktopAuth_WisentAuth.bundle"
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent(bundleName, isDirectory: true),
            Bundle.main.bundleURL.appendingPathComponent(bundleName, isDirectory: true),
        ]
        for case let url? in candidates {
            if let bundle = Bundle(url: url) {
                return bundle
            }
        }
        #if SWIFT_PACKAGE
        return Bundle.module
        #else
        preconditionFailure("Missing WisentAuth resource bundle")
        #endif
    }()

    static let loginLogo = image(named: "login-logo", fileExtension: "svg")
    static let loginPattern = image(named: "login-pattern", fileExtension: "svg")
    static let loginHero = image(named: "login-hero", fileExtension: "png")
    static let loginApple = image(named: "login-apple", fileExtension: "svg")
    static let loginGoogle = image(named: "login-google", fileExtension: "svg")
    static let loginGitHub = image(named: "login-github", fileExtension: "svg")

    private static func image(named name: String, fileExtension: String) -> NSImage {
        guard let url = bundle.url(forResource: name, withExtension: fileExtension),
              let image = NSImage(contentsOf: url) else {
            preconditionFailure("Missing WisentAuth resource: \(name).\(fileExtension)")
        }
        return image
    }
}

struct WisentIdentityEnvironmentKey: EnvironmentKey {
    static let defaultValue: WisentIdentity? = nil
}

public extension EnvironmentValues {
    var wisentIdentity: WisentIdentity? {
        get { self[WisentIdentityEnvironmentKey.self] }
        set { self[WisentIdentityEnvironmentKey.self] = newValue }
    }
}

public struct WisentAuthGate<Content: View>: View {
    @ObservedObject private var store: WisentAuthStore
    @State private var isOrganizationManagerPresented = false
    @State private var isInvitationReviewPresented = false
    private let content: () -> Content

    public init(store: WisentAuthStore, @ViewBuilder content: @escaping () -> Content) {
        self.store = store
        self.content = content
    }

    public var body: some View {
        Group {
            switch store.status {
            case .restoring:
                WisentAuthLoadingView()
            case .resolvingOrganization:
                organizationLoadingView
            case .signedOut, .waitingForCode:
                WisentSignInView(store: store)
            case .reviewingInvitations:
                OrganizationInvitationReviewView(store: store)
            case .choosingOrganization:
                OrganizationPickerView(store: store)
            case .ready:
                if let identity = store.identity {
                    content()
                        .environment(\.wisentIdentity, identity)
                        .toolbar { accountToolbar }
                } else {
                    organizationLoadingView
                }
            }
        }
        .task { await store.start() }
        .sheet(isPresented: $isOrganizationManagerPresented) {
            OrganizationManagementView(store: store)
        }
        .sheet(isPresented: $isInvitationReviewPresented) {
            OrganizationInvitationReviewView(store: store)
        }
    }

    private var organizationLoadingView: some View {
        WisentOrganizationLoadingView()
    }

    @ToolbarContentBuilder
    private var accountToolbar: some ToolbarContent {
        ToolbarItem(placement: .automatic) {
            Menu {
                if let organization = store.selectedOrganization {
                    Section("Organization") {
                        Label(organization.name, systemImage: "building.2.fill")
                        Text(organization.role.capitalized)
                        Button {
                            isOrganizationManagerPresented = true
                        } label: {
                            Label("Manage organization…", systemImage: "person.3")
                        }
                        .accessibilityIdentifier("wisent.auth.manage-organization")
                    }
                }
                if !store.pendingInvitations.isEmpty {
                    Section("Invitations") {
                        Button {
                            isInvitationReviewPresented = true
                        } label: {
                            Label(
                                "Review \(store.pendingInvitations.count) invitation\(store.pendingInvitations.count == 1 ? "" : "s")…",
                                systemImage: "envelope.badge"
                            )
                        }
                    }
                }
                if store.organizations.count > 1 {
                    Section("Switch organization") {
                        ForEach(store.organizations) { organization in
                            Button {
                                Task { await store.selectOrganization(organization) }
                            } label: {
                                if organization.id == store.selectedOrganization?.id {
                                    Label(organization.name, systemImage: "checkmark")
                                } else {
                                    Text(organization.name)
                                }
                            }
                        }
                    }
                }
                Section {
                    Button("Sign out", role: .destructive) {
                        Task { await store.signOut() }
                    }
                }
            } label: {
                Label(
                    store.selectedOrganization?.name ?? "Account",
                    systemImage: "person.crop.circle"
                )
            }
            .help(store.session?.email ?? "Wisent account")
            .accessibilityIdentifier("wisent.auth.account-menu")
        }
    }
}

struct WisentOrganizationLoadingView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                WisentSkeleton(.circle, width: 28, height: 28)
                WisentSkeleton(.heading, width: 240, height: 24)
            }

            WisentSkeleton(.line, width: 360, height: 14)

            VStack(spacing: 12) {
                ForEach(0 ..< 3, id: \.self) { _ in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 7) {
                            WisentSkeleton(.heading, width: 190, height: 16)
                            WisentSkeleton(.line, width: 120, height: 10)
                        }
                        Spacer()
                        WisentSkeleton(.pill, width: 72, height: 22)
                        WisentSkeleton(.line, width: 8, height: 12)
                    }
                    .padding(14)
                    .background(
                        Color.secondary.opacity(0.10),
                        in: RoundedRectangle(cornerRadius: 12)
                    )
                }
            }

            HStack {
                WisentSkeleton(.line, width: 200, height: 10)
                Spacer()
                WisentSkeleton(.pill, width: 64, height: 28)
            }
        }
        .frame(width: 480, alignment: .leading)
        .padding(40)
        .frame(minWidth: 560, minHeight: 420)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading organizations")
        .accessibilityIdentifier("wisent.auth.organization-loading")
    }
}
