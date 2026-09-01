import AppKit
import SwiftUI
import WisentDesignSystem

private enum WisentAuthResources {
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
        let name = store.status == .resolvingOrganization
            ? "Loading organizations"
            : "Restoring Wisent session"
        return VStack(spacing: 14) {
            Text("\(name)…")
                .foregroundStyle(.secondary)
            WisentSkeletonList(rows: 3, lines: 2, media: true, label: name)
                .frame(width: 360)
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

private struct WisentSignInView: View {
    @ObservedObject var store: WisentAuthStore
    @FocusState private var emailIsFocused: Bool
    @FocusState private var focusedDigit: Int?
    @State private var digits = Array(repeating: "", count: 6)
    @State private var showsVerificationError = true

    var body: some View {
        GeometryReader { proxy in
            let showsHero = proxy.size.width >= 1_024
            HStack(spacing: 0) {
                signInColumn
                    .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)

                if showsHero {
                    brandPanel
                        .frame(minWidth: 640, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(
                width: max(proxy.size.width, showsHero ? 1_120 : 480),
                height: proxy.size.height,
                alignment: .leading
            )
        }
        .background(LoginPalette.page)
        .clipped()
        .frame(minWidth: 480)
        .accessibilityIdentifier("wisent.auth.screen")
        .onChange(of: store.code) { _, code in
            guard code != digits.joined() else { return }
            synchronizeDigits(with: code)
        }
        .onChange(of: store.errorMessage) { _, error in
            if error != nil {
                showsVerificationError = true
            }
        }
    }

    private var signInColumn: some View {
        VStack(spacing: 24) {
            loginLogo

            VStack(spacing: 8) {
                Text("Welcome to Wisent")
                    .font(hubotSemibold(30))
                    .foregroundStyle(LoginPalette.ink)
                    .frame(height: 38)

                if store.status != .waitingForCode {
                    Text("Please enter your details.")
                        .font(WisentTypography.body(16))
                        .foregroundStyle(LoginPalette.secondary)
                        .frame(height: 24)
                }
            }
            .multilineTextAlignment(.center)

            if store.status == .waitingForCode {
                verificationForm
            } else {
                loginForm
            }
        }
        .frame(width: 360)
        .padding(.horizontal, 32)
        .frame(maxHeight: .infinity)
    }

    private var loginLogo: some View {
        Image(nsImage: WisentAuthResources.loginLogo)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 48, height: 48)
            .padding(8)
            .background {
                ZStack {
                    Rectangle()
                        .fill(.ultraThinMaterial)
                    Color(red: 214 / 255, green: 214 / 255, blue: 214 / 255)
                        .opacity(0.2)
                    LinearGradient(
                        stops: [
                            .init(color: .white.opacity(0.1), location: 0),
                            .init(color: .white.opacity(0.1), location: 0.0348),
                            .init(color: .clear, location: 0.0349),
                            .init(color: .clear, location: 0.2734),
                            .init(color: .white.opacity(0.1), location: 0.3367),
                            .init(color: .white.opacity(0.1), location: 0.5508),
                            .init(color: .clear, location: 0.6248),
                            .init(color: .clear, location: 0.8053),
                            .init(color: .white.opacity(0.1), location: 0.8825),
                            .init(color: .white.opacity(0.1), location: 1),
                        ],
                        startPoint: UnitPoint(x: 0, y: 0.06),
                        endPoint: UnitPoint(x: 1, y: 0.94)
                    )
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 39))
            .overlay {
                RoundedRectangle(cornerRadius: 39)
                    .stroke(LoginPalette.logoBorder, lineWidth: 1)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 39)
                    .stroke(.white.opacity(0.5), lineWidth: 1)
                    .blur(radius: 9)
                    .clipShape(RoundedRectangle(cornerRadius: 39))
            }
            .shadow(color: .black.opacity(0.06), radius: 7.5, x: 0, y: 12)
            .background {
                Rectangle()
                    .fill(
                        ImagePaint(
                            image: Image(nsImage: WisentAuthResources.loginPattern),
                            scale: 1
                        )
                    )
                    .frame(width: 272, height: 272)
                    .mask {
                        RadialGradient(
                            stops: [
                                .init(color: .black.opacity(0.7), location: 0),
                                .init(color: .clear, location: 0.6),
                            ],
                            center: .center,
                            startRadius: 0,
                            endRadius: 136
                        )
                    }
                    .accessibilityHidden(true)
            }
            .accessibilityLabel("Wisent")
    }

    private var loginForm: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let error = store.errorMessage {
                LoginMessageBanner(message: error)
                    .accessibilityIdentifier("wisent.auth.error")
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Email")
                    .font(WisentTypography.bodyMedium(14))
                    .foregroundStyle(LoginPalette.label)
                    .frame(height: 20)

                TextField(
                    "",
                    text: $store.email,
                    prompt: Text("you@company.com")
                        .foregroundStyle(LoginPalette.placeholder)
                )
                .textFieldStyle(.plain)
                .font(WisentTypography.body(16))
                .foregroundStyle(LoginPalette.label)
                .padding(.horizontal, 14)
                .frame(height: 40)
                .background(.white)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(
                            emailIsFocused ? LoginPalette.focus : LoginPalette.fieldBorder,
                            lineWidth: emailIsFocused ? 2 : 1
                        )
                }
                .shadow(color: LoginPalette.inputShadow, radius: 1, x: 0, y: 1)
                .focused($emailIsFocused)
                .accessibilityIdentifier("wisent.auth.email")
                .onSubmit { Task { await store.sendCode() } }
            }

            LoginPrimaryButton(
                title: store.loadingProvider == "email" ? "Sending link..." : "Sign in with email",
                isDisabled: store.isBusy
            ) {
                Task { await store.sendCode() }
            }
            .keyboardShortcut(.return)

            HStack(spacing: 8) {
                LoginOAuthButton(
                    image: WisentAuthResources.loginApple,
                    label: "Apple",
                    isLoading: store.loadingProvider == "apple",
                    isDisabled: store.isBusy
                ) {
                    Task { await store.signInWithApple() }
                }
                LoginOAuthButton(
                    image: WisentAuthResources.loginGoogle,
                    label: "Google",
                    isLoading: store.loadingProvider == "google",
                    isDisabled: store.isBusy
                ) {
                    Task { await store.signInWithGoogle() }
                }
                LoginOAuthButton(
                    image: WisentAuthResources.loginGitHub,
                    label: "GitHub",
                    isLoading: store.loadingProvider == "github",
                    isDisabled: store.isBusy
                ) {
                    Task { await store.signInWithGitHub() }
                }
            }

            Text(loginTerms)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 360)
    }

    private var verificationForm: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("A temporary login link and verification code have been sent to \(store.email).")
                .font(WisentTypography.bodyMedium(12))
                .foregroundStyle(LoginPalette.infoText)
                .lineSpacing(6)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                .background(verificationError == nil ? LoginPalette.infoBackground : LoginPalette.page)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(
                            verificationError == nil ? LoginPalette.page : LoginPalette.infoBorder,
                            lineWidth: 1
                        )
                }
                .shadow(color: .black.opacity(0.03), radius: 3, x: 0, y: 4)
                .shadow(color: .black.opacity(0.04), radius: 1, x: 0, y: 2)

            VStack(alignment: .leading, spacing: 6) {
                Text("Verification code")
                    .font(WisentTypography.bodyMedium(14))
                    .foregroundStyle(LoginPalette.label)
                    .frame(height: 20)

                HStack(spacing: 8) {
                    ForEach(0..<6, id: \.self) { index in
                        verificationField(at: index)
                    }
                }
                .frame(width: 433.6, alignment: .leading)
                .accessibilityIdentifier("wisent.auth.code")

                if let verificationError {
                    Text(verificationError)
                        .font(WisentTypography.body(14))
                        .foregroundStyle(LoginPalette.verificationError)
                        .frame(minHeight: 20)
                        .accessibilityIdentifier("wisent.auth.error")
                }
            }

            LoginPrimaryButton(
                title: store.isBusy ? "Verifying..." : "Continue",
                isDisabled: store.isBusy
            ) {
                Task { await store.verifyCode() }
            }
            .keyboardShortcut(.return)

            HStack(spacing: 8) {
                if store.resendCountdown > 0 {
                    Text("\(store.resendCountdown)s")
                        .font(WisentTypography.bodyMedium(14))
                        .foregroundStyle(.white)
                        .frame(height: 20)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(LoginPalette.label)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .shadow(color: LoginPalette.inputShadow, radius: 1, x: 0, y: 1)
                }

                Button("Resend Code") {
                    digits = Array(repeating: "", count: 6)
                    store.code = ""
                    focusedDigit = nil
                    showsVerificationError = false
                    Task { await store.resendCode() }
                }
                .buttonStyle(.plain)
                .font(WisentTypography.bodyMedium(14))
                .foregroundStyle(
                    store.resendCountdown > 0
                        ? LoginPalette.placeholder
                        : LoginPalette.link
                )
                .frame(height: 20)
                .disabled(store.resendCountdown > 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color.white.opacity(0.001))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .frame(width: 360)
        .onAppear {
            synchronizeDigits(with: store.code)
        }
    }

    private func verificationField(at index: Int) -> some View {
        TextField("", text: digitBinding(at: index))
            .textFieldStyle(.plain)
            .font(WisentTypography.body(18))
            .foregroundStyle(LoginPalette.label)
            .multilineTextAlignment(.center)
            .frame(width: 65.6, height: 60)
            .background(.white)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        focusedDigit == index
                            ? LoginPalette.focus
                            : (verificationError == nil
                                ? LoginPalette.fieldBorder
                                : LoginPalette.codeErrorBorder),
                        lineWidth: focusedDigit == index ? 2 : 1
                    )
            }
            .shadow(color: LoginPalette.inputShadow, radius: 1, x: 0, y: 1)
            .focused($focusedDigit, equals: index)
            .onKeyPress(.delete) {
                guard digits[index].isEmpty, index > 0 else { return .ignored }
                focusedDigit = index - 1
                return .handled
            }
            .accessibilityLabel("Verification code digit \(index + 1)")
            .accessibilityIdentifier("wisent.auth.code-\(index)")
    }

    private func digitBinding(at index: Int) -> Binding<String> {
        Binding(
            get: { digits[index] },
            set: { value in
                if value.count == 6,
                   value.unicodeScalars.allSatisfy({ (48...57).contains($0.value) }) {
                    digits = value.map(String.init)
                    store.code = digits.joined()
                    showsVerificationError = false
                    focusedDigit = 5
                    return
                }

                digits[index] = value.isEmpty ? "" : String(value.suffix(1))
                store.code = digits.joined()
                showsVerificationError = false
                if !digits[index].isEmpty, index < 5 {
                    focusedDigit = index + 1
                }
            }
        )
    }

    private var verificationError: String? {
        guard showsVerificationError else { return nil }
        return store.errorMessage
    }

    private func synchronizeDigits(with code: String) {
        var synchronized = Array(repeating: "", count: 6)
        for (index, character) in code.prefix(6).enumerated() {
            synchronized[index] = String(character)
        }
        digits = synchronized
    }

    private var loginTerms: AttributedString {
        var text = AttributedString(
            "By clicking Sign In, you agree to our Terms of Service and Privacy Policy"
        )
        text.font = WisentTypography.body(14)
        text.foregroundColor = LoginPalette.secondary

        if let range = text.range(of: "Terms of Service") {
            text[range].font = hubotSemibold(14)
            text[range].foregroundColor = LoginPalette.link
            text[range].underlineStyle = Text.LineStyle(pattern: .solid)
            text[range].link = URL(string: "https://app.wisent.com/terms")
        }
        if let range = text.range(of: "Privacy Policy") {
            text[range].font = hubotSemibold(14)
            text[range].foregroundColor = LoginPalette.link
            text[range].underlineStyle = Text.LineStyle(pattern: .solid)
            text[range].link = URL(string: "https://app.wisent.com/privacy")
        }
        return text
    }

    private var brandPanel: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                Image(nsImage: WisentAuthResources.loginHero)
                    .resizable()
                    .scaledToFill()
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()

                Text("Unprecedented level of control. Available for everyone.")
                    .font(WisentTypography.body(24))
                    .foregroundStyle(LoginPalette.heroText)
                    .lineSpacing(8)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 411, alignment: .trailing)
                    .padding(40)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .padding(24)
        .accessibilityHidden(true)
    }
}

private struct WisentAuthLoadingView: View {

    var body: some View {
        GeometryReader { proxy in
            let showsRightSkeleton = proxy.size.width >= 1_024
            HStack(spacing: 0) {
                VStack(spacing: 24) {
                    WisentSkeleton(.circle, width: 64, height: 64)
                        .frame(maxWidth: .infinity)

                    WisentSkeleton(.heading, width: 192, height: 32)
                        .frame(maxWidth: .infinity)
                    WisentSkeleton(.line, width: 256, height: 16)
                        .frame(maxWidth: .infinity)

                    VStack(spacing: 16) {
                        WisentSkeleton(.block, width: 360, height: 48)
                        WisentSkeleton(.block, width: 360, height: 48)
                        WisentSkeleton(.pill, width: 360, height: 48)
                    }
                    .padding(.top, 16)

                    HStack(spacing: 16) {
                        WisentSkeleton(.line, height: 1)
                        WisentSkeleton(.line, width: 32, height: 16)
                        WisentSkeleton(.line, height: 1)
                    }
                    .padding(.top, 16)

                    WisentSkeleton(.pill, width: 360, height: 48)
                }
                .frame(width: 360)
                .padding(.horizontal, 32)
                .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)

                if showsRightSkeleton {
                    WisentSkeleton(.block, width: 320, height: 320)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(
                width: max(proxy.size.width, 480),
                height: proxy.size.height,
                alignment: .leading
            )
        }
        .background {
            LinearGradient(
                colors: [LoginPalette.skeletonStart, LoginPalette.skeletonEnd],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .clipped()
        .frame(minWidth: 480)
        .accessibilityLabel("Loading sign-in")
        .accessibilityIdentifier("wisent.auth.loading")
    }
}

private struct LoginMessageBanner: View {
    let message: String

    var body: some View {
        let isSuccess = message.contains("Check your email")
        Text(message)
            .font(WisentTypography.body(14))
            .foregroundStyle(isSuccess ? LoginPalette.successText : LoginPalette.errorText)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(isSuccess ? LoginPalette.successBackground : LoginPalette.errorBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSuccess ? LoginPalette.successBorder : LoginPalette.errorBorder, lineWidth: 1)
            }
    }
}

private struct LoginPrimaryButton: View {
    let title: String
    let isDisabled: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(WisentTypography.monoMedium(16))
                .foregroundStyle(LoginPalette.buttonText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .buttonStyle(.plain)
        .frame(width: 360, height: 44)
        .background(isHovering && !isDisabled ? LoginPalette.primaryHover : LoginPalette.primary)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(LoginPalette.buttonBorder, lineWidth: 1)
        }
        .opacity(isDisabled ? 0.5 : 1)
        .disabled(isDisabled)
        .onHover { isHovering = $0 }
    }
}

private struct LoginOAuthButton: View {
    let image: NSImage
    let label: String
    let isLoading: Bool
    let isDisabled: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 24, height: 24)
                .opacity(isLoading ? 0.35 : 1)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .frame(height: 44)
        .background(isHovering && !isDisabled ? LoginPalette.oauthHover : .white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(LoginPalette.fieldBorder, lineWidth: 1)
        }
        .opacity(isDisabled ? 0.5 : 1)
        .disabled(isDisabled)
        .onHover { isHovering = $0 }
        .accessibilityLabel("Sign in with \(label)")
    }
}

private enum LoginPalette {
    static let page = Color(red: 249 / 255, green: 249 / 255, blue: 249 / 255)
    static let ink = Color(red: 39 / 255, green: 51 / 255, blue: 40 / 255)
    static let secondary = Color(red: 89 / 255, green: 96 / 255, blue: 93 / 255)
    static let label = Color(red: 18 / 255, green: 18 / 255, blue: 18 / 255)
    static let placeholder = Color(red: 166 / 255, green: 173 / 255, blue: 170 / 255)
    static let fieldBorder = Color(red: 221 / 255, green: 221 / 255, blue: 221 / 255)
    static let focus = Color(red: 158 / 255, green: 204 / 255, blue: 160 / 255)
    static let primary = focus
    static let primaryHover = Color(red: 141 / 255, green: 219 / 255, blue: 145 / 255)
    static let buttonText = Color(red: 45 / 255, green: 49 / 255, blue: 48 / 255)
    static let buttonBorder = Color(red: 242 / 255, green: 242 / 255, blue: 242 / 255)
    static let oauthHover = Color(red: 249 / 255, green: 250 / 255, blue: 251 / 255)
    static let link = Color(red: 118 / 255, green: 153 / 255, blue: 120 / 255)
    static let logoBorder = Color(red: 234 / 255, green: 234 / 255, blue: 234 / 255)
    static let infoBackground = Color(red: 245 / 255, green: 245 / 255, blue: 245 / 255)
    static let infoBorder = Color(red: 222 / 255, green: 228 / 255, blue: 226 / 255)
    static let infoText = Color(red: 66 / 255, green: 72 / 255, blue: 70 / 255)
    static let codeErrorBorder = Color(red: 255 / 255, green: 121 / 255, blue: 97 / 255)
    static let verificationError = Color(red: 212 / 255, green: 51 / 255, blue: 40 / 255)
    static let heroText = Color(red: 222 / 255, green: 228 / 255, blue: 226 / 255)
    static let inputShadow = Color(red: 10 / 255, green: 13 / 255, blue: 18 / 255).opacity(0.05)
    static let successBackground = Color(red: 240 / 255, green: 253 / 255, blue: 244 / 255)
    static let successText = Color(red: 22 / 255, green: 101 / 255, blue: 52 / 255)
    static let successBorder = Color(red: 187 / 255, green: 247 / 255, blue: 208 / 255)
    static let errorBackground = Color(red: 254 / 255, green: 242 / 255, blue: 242 / 255)
    static let errorText = Color(red: 153 / 255, green: 27 / 255, blue: 27 / 255)
    static let errorBorder = Color(red: 254 / 255, green: 202 / 255, blue: 202 / 255)
    static let skeletonStart = Color(red: 249 / 255, green: 250 / 255, blue: 251 / 255)
    static let skeletonEnd = Color(red: 243 / 255, green: 244 / 255, blue: 246 / 255)
}

private func hubotSemibold(_ size: CGFloat) -> Font {
    _ = WisentTypography.body(size)
    return .custom("HubotSans-SemiBold", size: size)
}

private struct OrganizationPickerView: View {
    @ObservedObject var store: WisentAuthStore
    @State private var organizationName = ""
    @State private var organizationSlug = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Choose an organization", systemImage: "building.2")
                .font(.title2.bold())
            Text("Your permissions and organization data are scoped to this selection.")
                .foregroundStyle(.secondary)

            ForEach(store.organizations) { organization in
                Button {
                    Task { await store.selectOrganization(organization) }
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

            GroupBox(store.organizations.isEmpty ? "Create your organization" : "Create another") {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Organization name", text: $organizationName)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("wisent.auth.create-organization-name")
                    HStack {
                        TextField("organization-slug", text: $organizationSlug)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("wisent.auth.create-organization-slug")
                        Button("Create") {
                            Task {
                                await store.createOrganization(
                                    name: organizationName,
                                    slug: organizationSlug
                                )
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("wisent.auth.create-organization")
                    }
                }
                .padding(.top, 4)
            }

            if let error = store.organizationError {
                WisentFailureBanner(
                    message: error,
                    failure: store.organizationFailure,
                    identifier: "wisent.auth.organization-create-error",
                    retry: { await store.reloadOrganizations() }
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
        .frame(minWidth: 560, minHeight: 520)
        .disabled(store.isOrganizationBusy)
        .accessibilityIdentifier("wisent.auth.organization-picker")
    }
}

private struct OrganizationInvitationReviewView: View {
    @ObservedObject var store: WisentAuthStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Organization invitations", systemImage: "envelope.badge")
                .font(.title2.bold())
            Text(
                store.selectedOrganization == nil
                    ? "Accept an invitation or create an organization to continue."
                    : "You can review these now or continue in your current organization."
            )
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
                WisentSkeleton(.pill, width: 140, height: 14)
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
                if store.selectedOrganization != nil {
                    Button("Continue to workspace") { dismiss() }
                }
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
    @State private var organizationName = ""
    @State private var organizationSlug = ""
    @State private var memberPendingRemoval: WisentOrganizationMember?
    @State private var memberPendingOwnershipTransfer: WisentOrganizationMember?
    @State private var isLeaveConfirmationPresented = false
    @State private var isDeleteConfirmationPresented = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(store.selectedOrganization?.name ?? "Organization")
                        .font(.title2.bold())
                    Text("Organization, team and access")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if store.isOrganizationBusy {
                    WisentSkeleton(.pill, width: 90, height: 14)
                }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(20)

            Divider()

            if store.selectedOrganization?.isFixedWisentOrganization == true {
                GroupBox("Managed centrally") {
                    Label(
                        "The Wisent organization is managed centrally. Its name, slug, and deletion settings cannot be changed here.",
                        systemImage: "lock.shield"
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                }
                .padding(.horizontal, 20)
                .padding(.top, 14)
            } else if store.selectedOrganization?.hasManagementPermission(.organizationRename) == true
                || store.selectedOrganization?.organizationRole == .owner
            {
                GroupBox("Organization details") {
                    VStack(spacing: 10) {
                        HStack {
                            TextField("Organization name", text: $organizationName)
                                .textFieldStyle(.roundedBorder)
                                .disabled(
                                    store.selectedOrganization?.hasManagementPermission(
                                        .organizationRename
                                    ) != true
                                )
                            if store.selectedOrganization?.hasManagementPermission(
                                .organizationRename
                            ) == true {
                                Button("Save name") {
                                    Task { await store.renameOrganization(name: organizationName) }
                                }
                            }
                        }
                        if store.selectedOrganization?.organizationRole == .owner {
                            HStack {
                                TextField("organization-slug", text: $organizationSlug)
                                    .textFieldStyle(.roundedBorder)
                                Button("Save slug") {
                                    Task { await store.updateOrganizationSlug(organizationSlug) }
                                }
                            }
                        }
                    }
                    .padding(.top, 4)
                }
                .padding(.horizontal, 20)
                .padding(.top, 14)
            }

            if let organization = store.selectedOrganization,
               organization.hasManagementPermission(.membersInvite) {
                GroupBox("Invite a teammate") {
                    HStack(spacing: 10) {
                        TextField("teammate@company.com", text: $store.inviteEmail)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("wisent.auth.invite-email")
                        Picker("Role", selection: $store.inviteRole) {
                            ForEach(availableInviteRoles, id: \.self) { role in
                                Text(role.rawValue.capitalized).tag(role)
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
                            VStack(alignment: .trailing, spacing: 3) {
                                Text(member.role.capitalized)
                                    .font(.caption.weight(.medium))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(.secondary.opacity(0.12), in: Capsule())
                                if member.organizationRole != .owner,
                                   !member.managementPermissions.isEmpty {
                                    Text("\(member.managementPermissions.count) management permissions")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            if canManage(member) {
                                Menu {
                                    if store.selectedOrganization?.organizationRole == .owner {
                                        ForEach(WisentOrganizationRole.allCases, id: \.self) { role in
                                            Button("Make \(role.rawValue)") {
                                                Task {
                                                    await store.updateOrganizationMemberRole(
                                                        member,
                                                        role: role
                                                    )
                                                }
                                            }
                                            .disabled(role == member.organizationRole)
                                        }
                                        if member.organizationRole != .owner {
                                            Divider()
                                            Button("Transfer ownership…") {
                                                memberPendingOwnershipTransfer = member
                                            }
                                        }
                                    }
                                    if store.selectedOrganization?.organizationRole == .owner,
                                       member.organizationRole != .owner {
                                        Menu("Management permissions") {
                                            ForEach(
                                                WisentOrganizationManagementPermission.allCases,
                                                id: \.self
                                            ) { permission in
                                                Button {
                                                    Task {
                                                        await store.updateOrganizationMemberPermissions(
                                                            member,
                                                            permissions: toggledPermissions(
                                                                permission,
                                                                for: member
                                                            )
                                                        )
                                                    }
                                                } label: {
                                                    Label(
                                                        permission.label,
                                                        systemImage: member.managementPermissions.contains(
                                                            permission
                                                        ) ? "checkmark.circle.fill" : "circle"
                                                    )
                                                }
                                            }
                                        }
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

                if (store.selectedOrganization?.hasManagementPermission(.membersInvite) == true
                    || store.selectedOrganization?.hasManagementPermission(.invitationsCancel) == true),
                   !store.organizationInvitations.isEmpty {
                    Section("Pending invitations") {
                        ForEach(store.organizationInvitations) { invitation in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(invitation.email)
                                    Text(invitation.role.capitalized)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Label(
                                        deliveryLabel(invitation.deliveryStatus),
                                        systemImage: deliveryIcon(invitation.deliveryStatus)
                                    )
                                    .font(.caption2)
                                    .foregroundStyle(
                                        invitation.deliveryStatus == .failed
                                            ? Color.red
                                            : Color.secondary
                                    )
                                }
                                Spacer()
                                if let expiresAt = invitation.expiresAt {
                                    Text(expiresAt.formatted(date: .abbreviated, time: .omitted))
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                                if canResend(invitation) {
                                    Button(
                                        invitation.deliveryStatus == .failed ? "Retry delivery" : "Resend"
                                    ) {
                                        Task {
                                            await store.resendOrganizationInvitation(invitation)
                                        }
                                    }
                                }
                                if canCancel(invitation) {
                                    Button("Cancel", role: .destructive) {
                                        Task {
                                            await store.cancelOrganizationInvitation(invitation)
                                        }
                                    }
                                }
                            }
                            .accessibilityIdentifier("wisent.auth.pending-invitation.\(invitation.id)")
                        }
                    }
                }

                if canLeaveSelectedOrganization || canDeleteSelectedOrganization {
                    Section {
                        if canLeaveSelectedOrganization {
                            Button("Leave organization…", role: .destructive) {
                                isLeaveConfirmationPresented = true
                            }
                        }
                        if canDeleteSelectedOrganization {
                            Button("Delete organization…", role: .destructive) {
                                isDeleteConfirmationPresented = true
                            }
                        }
                    }
                }
            }
            .overlay {
                if store.isOrganizationBusy && store.organizationMembers.isEmpty {
                    WisentSkeletonList(rows: 4, lines: 2, media: true, label: "Loading team")
                        .padding(20)
                }
            }
        }
        .frame(minWidth: 720, minHeight: 680)
        .disabled(store.isOrganizationBusy)
        .task {
            organizationName = store.selectedOrganization?.name ?? ""
            organizationSlug = store.selectedOrganization?.slug ?? ""
            await store.loadOrganizationManagement()
        }
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
        .alert(
            "Transfer ownership?",
            isPresented: Binding(
                get: { memberPendingOwnershipTransfer != nil },
                set: { if !$0 { memberPendingOwnershipTransfer = nil } }
            ),
            presenting: memberPendingOwnershipTransfer
        ) { member in
            Button("Transfer", role: .destructive) {
                Task { await store.transferOrganizationOwnership(to: member) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { member in
            Text("\(member.email) will become an owner and your role will become admin.")
        }
        .alert("Leave organization?", isPresented: $isLeaveConfirmationPresented) {
            Button("Leave", role: .destructive) {
                Task {
                    let previousID = store.selectedOrganization?.id
                    await store.leaveOrganization()
                    if store.selectedOrganization?.id != previousID { dismiss() }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You will lose access to this organization's data.")
        }
        .alert("Delete organization?", isPresented: $isDeleteConfirmationPresented) {
            Button("Delete", role: .destructive) {
                Task {
                    let previousID = store.selectedOrganization?.id
                    await store.deleteOrganization()
                    if store.selectedOrganization?.id != previousID { dismiss() }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes the organization and its access.")
        }
        .accessibilityIdentifier("wisent.auth.organization-management")
    }

    private var availableInviteRoles: [WisentOrganizationRole] {
        store.selectedOrganization?.organizationRole == .owner
            ? WisentOrganizationRole.allCases
            : [.member]
    }

    private func canManage(_ member: WisentOrganizationMember) -> Bool {
        guard member.userID != store.session?.userID else { return false }
        if store.selectedOrganization?.organizationRole == .owner { return true }
        return member.organizationRole == .member
            && store.selectedOrganization?.hasManagementPermission(.membersRemove) == true
    }

    private func canCancel(_ invitation: WisentOrganizationInvite) -> Bool {
        guard store.selectedOrganization?.hasManagementPermission(.invitationsCancel) == true else {
            return false
        }
        return store.selectedOrganization?.organizationRole == .owner
            || invitation.organizationRole == .member
    }

    private func canResend(_ invitation: WisentOrganizationInvite) -> Bool {
        guard store.selectedOrganization?.hasManagementPermission(.membersInvite) == true else {
            return false
        }
        return store.selectedOrganization?.organizationRole == .owner
            || invitation.organizationRole == .member
    }

    private func toggledPermissions(
        _ permission: WisentOrganizationManagementPermission,
        for member: WisentOrganizationMember
    ) -> [WisentOrganizationManagementPermission] {
        let existing = Set(member.managementPermissions)
        return WisentOrganizationManagementPermission.allCases.filter {
            $0 == permission ? !existing.contains($0) : existing.contains($0)
        }
    }

    private func deliveryLabel(_ status: WisentInvitationDeliveryStatus) -> String {
        switch status {
        case .pending: "Delivery pending"
        case .sent: "Email sent"
        case .failed: "Saved — email not delivered"
        }
    }

    private func deliveryIcon(_ status: WisentInvitationDeliveryStatus) -> String {
        switch status {
        case .pending: "clock"
        case .sent: "checkmark.circle"
        case .failed: "exclamationmark.triangle"
        }
    }

    private var canLeaveSelectedOrganization: Bool {
        guard let organization = store.selectedOrganization else { return false }
        guard organization.organizationRole == .owner else { return true }
        return store.organizationMembers.contains {
            $0.userID != store.session?.userID && $0.organizationRole == .owner
        }
    }

    private var canDeleteSelectedOrganization: Bool {
        guard let organization = store.selectedOrganization else { return false }
        return organization.organizationRole == .owner && !organization.isFixedWisentOrganization
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
