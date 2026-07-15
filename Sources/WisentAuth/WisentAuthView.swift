import AuthenticationServices
import SwiftUI

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
        VStack(spacing: 18) {
            Image(systemName: "person.badge.shield.checkmark.fill")
                .font(.system(size: 46, weight: .medium))
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            Text(store.productName)
                .font(.system(size: 32, weight: .bold, design: .rounded))
            Text("Sign in with your Wisent account")
                .foregroundStyle(.secondary)

            if store.status == .waitingForCode {
                Text("Enter the code sent to \(store.email)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                TextField("123456", text: $store.code)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 280)
                    .accessibilityIdentifier("wisent.auth.code")
                    .onSubmit { Task { await store.verifyCode() } }
                Button("Verify code") {
                    Task { await store.verifyCode() }
                }
                .keyboardShortcut(.return)
                .buttonStyle(.borderedProminent)
                .disabled(store.isBusy)
                Button("Use a different email") { store.changeEmail() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            } else {
                TextField("you@company.com", text: $store.email)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 280)
                    .accessibilityIdentifier("wisent.auth.email")
                    .onSubmit { Task { await store.sendCode() } }
                Button("Send one-time code") {
                    Task { await store.sendCode() }
                }
                .keyboardShortcut(.return)
                .buttonStyle(.borderedProminent)
                .disabled(store.isBusy)

                if store.oauthEnabled {
                    HStack(spacing: 8) {
                        Rectangle().fill(.secondary.opacity(0.25)).frame(height: 1)
                        Text("or").font(.caption).foregroundStyle(.secondary)
                        Rectangle().fill(.secondary.opacity(0.25)).frame(height: 1)
                    }
                    .frame(width: 280)

                    HStack(spacing: 10) {
                        Button("Continue with Google") {
                            Task { await store.signInWithGoogle() }
                        }
                        Button("Continue with GitHub") {
                            Task { await store.signInWithGitHub() }
                        }
                        SignInWithAppleButton(.signIn) { request in
                            store.configureAppleRequest(request)
                        } onCompletion: { result in
                            Task { @MainActor in
                                await store.completeAppleAuthorization(result)
                            }
                        }
                        .signInWithAppleButtonStyle(.black)
                        .frame(width: 145, height: 28)
                        .accessibilityIdentifier("wisent.auth.apple")
                    }
                    .disabled(store.isBusy)
                }
            }

            if store.isBusy {
                ProgressView().controlSize(.small)
            }
            if let error = store.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                    .accessibilityIdentifier("wisent.auth.error")
            }

            Text("One account. Organization-scoped access across Wisent products.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(48)
        .frame(minWidth: 560, minHeight: 480)
        .accessibilityIdentifier("wisent.auth.screen")
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
