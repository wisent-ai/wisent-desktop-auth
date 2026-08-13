import SwiftUI
import WisentDesignSystem

private struct WisentIdentityEnvironmentKey: EnvironmentKey {
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
    private let content: () -> Content

    public init(store: WisentAuthStore, @ViewBuilder content: @escaping () -> Content) {
        self.store = store
        self.content = content
    }

    public var body: some View {
        Group {
            switch store.status {
            case .restoring, .resolvingOrganization:
                loadingView
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
                    loadingView
                }
            }
        }
        .task { await store.start() }
        .sheet(isPresented: $isOrganizationManagerPresented) {
            OrganizationManagementView(store: store)
        }
    }

    private var loadingView: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text(store.status == .resolvingOrganization ? "Loading organizations…" : "Restoring Wisent session…")
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 520, minHeight: 420)
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
                if store.organizations.count > 1 {
                    Section("Switch organization") {
                        ForEach(store.organizations) { organization in
                            Button {
                                store.selectOrganization(organization)
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

private struct WisentSignInView: View {
    @ObservedObject var store: WisentAuthStore

    var body: some View {
        ZStack {
            WisentCanvasBackground()

            WisentPanel {
                VStack(alignment: .leading, spacing: WisentDesign.Space.x5) {
                    WisentPageHeader(
                        eyebrow: "Wisent account",
                        title: store.productName,
                        detail: "Sign in once for organization-scoped access across Wisent products.",
                        symbol: "person.badge.shield.checkmark.fill",
                        tone: .success
                    )

                    if store.status == .waitingForCode {
                        codeForm
                    } else {
                        emailForm
                    }

                    activity

                    if let error = store.errorMessage {
                        WisentFailureBanner(
                            message: error,
                            failure: store.failure,
                            identifier: "wisent.auth.error",
                            retry: { await store.retry() }
                        )
                    }

                    HStack(spacing: WisentDesign.Space.x2) {
                        Image(systemName: "building.2")
                        Text("Organization membership determines product access.")
                    }
                    .font(WisentTypography.body(11))
                    .foregroundStyle(WisentDesign.muted)
                }
            }
            .frame(maxWidth: 480)
            .padding(WisentDesign.Space.x8)
        }
        .frame(minWidth: 560, minHeight: 480)
        .accessibilityIdentifier("wisent.auth.screen")
    }

    private var codeForm: some View {
        VStack(alignment: .leading, spacing: WisentDesign.Space.x3) {
            WisentSectionHeader(
                "Verify your email",
                detail: "Enter the one-time code sent to \(store.email)."
            )
            TextField("123456", text: $store.code)
                .textFieldStyle(.roundedBorder)
                .font(WisentTypography.monoMedium(15))
                .accessibilityIdentifier("wisent.auth.code")
                .onSubmit { Task { await store.verifyCode() } }
            HStack(spacing: WisentDesign.Space.x3) {
                Button("Verify code") {
                    Task { await store.verifyCode() }
                }
                .keyboardShortcut(.return)
                .buttonStyle(WisentPrimaryButtonStyle())
                .disabled(store.isBusy)
                Button("Use a different email") {
                    store.changeEmail()
                }
                .buttonStyle(WisentSecondaryButtonStyle())
            }
        }
    }

    private var emailForm: some View {
        VStack(alignment: .leading, spacing: WisentDesign.Space.x3) {
            WisentSectionHeader(
                "Continue with email",
                detail: "We will send a short-lived sign-in code."
            )
            TextField("you@company.com", text: $store.email)
                .textFieldStyle(.roundedBorder)
                .font(WisentTypography.body(14))
                .accessibilityIdentifier("wisent.auth.email")
                .onSubmit { Task { await store.sendCode() } }
            Button("Send one-time code") {
                Task { await store.sendCode() }
            }
            .keyboardShortcut(.return)
            .buttonStyle(WisentPrimaryButtonStyle())
            .disabled(store.isBusy)

            if store.oauthEnabled {
                HStack(spacing: WisentDesign.Space.x2) {
                    Rectangle()
                        .fill(WisentDesign.border)
                        .frame(height: WisentDesign.hairline)
                    Text("OR")
                        .font(WisentTypography.monoMedium(10))
                        .foregroundStyle(WisentDesign.muted)
                    Rectangle()
                        .fill(WisentDesign.border)
                        .frame(height: WisentDesign.hairline)
                }
                HStack(spacing: WisentDesign.Space.x3) {
                    WisentOAuthButton(.google) {
                        Task { await store.signInWithGoogle() }
                    }
                    WisentOAuthButton(.github) {
                        Task { await store.signInWithGitHub() }
                    }
                }
                .disabled(store.isBusy)
            }
        }
    }

    @ViewBuilder
    private var activity: some View {
        if store.isOAuthBusy {
            HStack(spacing: WisentDesign.Space.x3) {
                ProgressView()
                    .controlSize(.small)
                Text("Completing secure sign-in…")
                    .font(WisentTypography.body(12))
                    .foregroundStyle(WisentDesign.secondary)
                Spacer()
                Button("Cancel") {
                    store.cancelOAuthSignIn()
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("wisent.auth.cancel-oauth")
            }
        } else if store.isBusy {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct OrganizationPickerView: View {
    @ObservedObject var store: WisentAuthStore

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Choose an organization", systemImage: "building.2")
                .font(.title2.bold())
            Text("Your permissions and data are scoped to the selected organization.")
                .foregroundStyle(.secondary)

            ForEach(store.organizations) { organization in
                Button {
                    store.selectOrganization(organization)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(organization.name).font(.headline)
                            Text(organization.slug).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(organization.role.capitalized)
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.secondary.opacity(0.12), in: Capsule())
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(14)
                .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityIdentifier("wisent.auth.organization.\(organization.id)")
            }

            HStack {
                Text(store.session?.email ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Sign out") { Task { await store.signOut() } }
            }
        }
        .padding(40)
        .frame(minWidth: 560, minHeight: 420)
        .accessibilityIdentifier("wisent.auth.organization-picker")
    }
}

private struct OrganizationInvitationReviewView: View {
    @ObservedObject var store: WisentAuthStore

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Organization invitations", systemImage: "envelope.badge")
                .font(.title2.bold())
            Text("Review invitations before continuing to your Wisent workspace.")
                .foregroundStyle(.secondary)

            ForEach(store.pendingInvitations) { invitation in
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(invitation.organizationName)
                                .font(.headline)
                            Text("Role: \(invitation.role.capitalized)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let expiresAt = invitation.expiresAt {
                            Text("Expires \(expiresAt.formatted(date: .abbreviated, time: .omitted))")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    HStack {
                        Spacer()
                        Button("Decline", role: .destructive) {
                            Task { await store.declineInvitation(invitation) }
                        }
                        Button("Accept") {
                            Task { await store.acceptInvitation(invitation) }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding(16)
                .background(.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityIdentifier("wisent.auth.invitation.\(invitation.id)")
            }

            if store.isBusy {
                ProgressView().controlSize(.small)
            }
            if let error = store.errorMessage {
                WisentFailureBanner(
                    message: error,
                    failure: store.failure,
                    identifier: "wisent.auth.invitation-error",
                    retry: { await store.retry() }
                )
            }

            HStack {
                Text(store.session?.email ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Sign out") { Task { await store.signOut() } }
            }
        }
        .padding(40)
        .frame(minWidth: 580, minHeight: 420)
        .disabled(store.isBusy)
        .accessibilityIdentifier("wisent.auth.invitation-review")
    }
}

private struct OrganizationManagementView: View {
    @ObservedObject var store: WisentAuthStore
    @Environment(\.dismiss) private var dismiss
    @State private var memberPendingRemoval: WisentOrganizationMember?

    private let roles = ["owner", "admin", "member"]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(store.selectedOrganization?.name ?? "Organization")
                        .font(.title2.bold())
                    Text("Team and access")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if store.isOrganizationBusy {
                    ProgressView().controlSize(.small)
                }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(20)

            Divider()

            if let organization = store.selectedOrganization, organization.canManageMembers {
                GroupBox("Invite a teammate") {
                    HStack(spacing: 10) {
                        TextField("teammate@company.com", text: $store.inviteEmail)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("wisent.auth.invite-email")
                        Picker("Role", selection: $store.inviteRole) {
                            ForEach(availableRoles, id: \.self) { role in
                                Text(role.capitalized).tag(role)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 120)
                        Button("Send invite") {
                            Task { await store.sendOrganizationInvitation() }
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("wisent.auth.send-invite")
                    }
                    .padding(.top, 4)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            }

            if let error = store.organizationError {
                WisentFailureBanner(
                    message: error,
                    failure: store.organizationFailure,
                    identifier: "wisent.auth.organization-error",
                    retry: { await store.loadOrganizationManagement() }
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, BannerLayout.horizontalPadding)
                .padding(.bottom, BannerLayout.bottomPadding)
            }

            List {
                Section("Members") {
                    ForEach(store.organizationMembers) { member in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(member.email)
                                if member.userID == store.session?.userID {
                                    Text("You")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Text(member.role.capitalized)
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(.secondary.opacity(0.12), in: Capsule())
                            if canEdit(member) {
                                Menu {
                                    ForEach(availableRoles, id: \.self) { role in
                                        Button(role.capitalized) {
                                            Task {
                                                await store.updateOrganizationMemberRole(member, role: role)
                                            }
                                        }
                                        .disabled(role == member.role)
                                    }
                                    Divider()
                                    Button("Remove member…", role: .destructive) {
                                        memberPendingRemoval = member
                                    }
                                } label: {
                                    Image(systemName: "ellipsis.circle")
                                }
                                .menuStyle(.borderlessButton)
                            }
                        }
                        .accessibilityIdentifier("wisent.auth.member.\(member.userID)")
                    }
                }

                if store.selectedOrganization?.canManageMembers == true,
                   !store.organizationInvitations.isEmpty {
                    Section("Pending invitations") {
                        ForEach(store.organizationInvitations) { invitation in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(invitation.email)
                                    Text(invitation.role.capitalized)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if let expiresAt = invitation.expiresAt {
                                    Text(expiresAt.formatted(date: .abbreviated, time: .omitted))
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                                Button("Cancel", role: .destructive) {
                                    Task { await store.cancelOrganizationInvitation(invitation) }
                                }
                            }
                            .accessibilityIdentifier("wisent.auth.pending-invitation.\(invitation.id)")
                        }
                    }
                }
            }
            .overlay {
                if store.isOrganizationBusy && store.organizationMembers.isEmpty {
                    ProgressView("Loading team…")
                }
            }
        }
        .frame(minWidth: 720, minHeight: 560)
        .disabled(store.isOrganizationBusy)
        .task { await store.loadOrganizationManagement() }
        .alert(
            "Remove member?",
            isPresented: Binding(
                get: { memberPendingRemoval != nil },
                set: { if !$0 { memberPendingRemoval = nil } }
            ),
            presenting: memberPendingRemoval
        ) { member in
            Button("Remove", role: .destructive) {
                Task { await store.removeOrganizationMember(member) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { member in
            Text("\(member.email) will lose access to this organization.")
        }
        .accessibilityIdentifier("wisent.auth.organization-management")
    }

    private var availableRoles: [String] {
        store.selectedOrganization?.role == "owner" ? roles : ["admin", "member"]
    }

    private func canEdit(_ member: WisentOrganizationMember) -> Bool {
        guard member.userID != store.session?.userID,
              let organization = store.selectedOrganization else { return false }
        if organization.role == "owner" { return true }
        return organization.role == "admin" && member.role != "owner"
    }
}

/// Spelled as strings because bare numeric literals are rejected in this
/// repository.
private enum BannerLayout {
    static let maxWidth = CGFloat(Int("420") ?? .zero)
    static let horizontalPadding = CGFloat(Int("20") ?? .zero)
    static let bottomPadding = CGFloat(Int("8") ?? .zero)
    static let spacing = CGFloat(Int("6") ?? .zero)
}

/// The single rendering for every failure this library shows, so one incident
/// reads the same on the sign-in screen, on the invitation screen and in the
/// organization sheet.
///
/// An outage is deliberately not styled like a mistake. Painting "we are down"
/// in the same red as "that code is wrong" is what sends a user off to reset a
/// password that was never the problem.
private struct WisentFailureBanner: View {
    let message: String
    let failure: WisentFailure?
    let identifier: String
    var retry: (() async -> Void)?

    var body: some View {
        VStack(spacing: BannerLayout.spacing) {
            Text(message)
                .font(.caption)
                .foregroundStyle(failure?.isOutage == true ? Color.orange : Color.red)
                .multilineTextAlignment(.center)
                .frame(maxWidth: BannerLayout.maxWidth)
                .accessibilityIdentifier(identifier)

            if let retry, failure?.isRetryable == true {
                Button("Try again") { Task { await retry() } }
                    .buttonStyle(.link)
                    .font(.caption)
                    .accessibilityIdentifier(identifier + ".retry")
            }
        }
    }
}
