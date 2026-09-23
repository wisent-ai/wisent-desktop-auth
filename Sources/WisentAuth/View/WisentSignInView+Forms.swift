import AppKit
import SwiftUI
import WisentDesignSystem

extension WisentSignInView {
    var loginForm: some View {
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
                title: "Sign in with email",
                isDisabled: store.isBusy && store.loadingProvider != "email",
                isBusy: store.loadingProvider == "email"
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

    var verificationForm: some View {
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
                title: "Continue",
                isDisabled: false,
                isBusy: store.isBusy
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

    func verificationField(at index: Int) -> some View {
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

    func digitBinding(at index: Int) -> Binding<String> {
        Binding(
            get: { digits[index] },
            set: { value in
                if value.count == WisentVerificationCode.length,
                   value.unicodeScalars.allSatisfy({ (48...57).contains($0.value) }) {
                    digits = value.map(String.init)
                    store.code = digits.joined()
                    showsVerificationError = false
                    focusedDigit = WisentVerificationCode.length - 1
                    return
                }

                digits[index] = value.isEmpty ? "" : String(value.suffix(1))
                store.code = digits.joined()
                showsVerificationError = false
                if !digits[index].isEmpty, index < WisentVerificationCode.length - 1 {
                    focusedDigit = index + 1
                }
            }
        )
    }

    var verificationError: String? {
        guard showsVerificationError else { return nil }
        return store.errorMessage
    }

    func synchronizeDigits(with code: String) {
        var synchronized = Array(repeating: "", count: WisentVerificationCode.length)
        for (index, character) in code.prefix(WisentVerificationCode.length).enumerated() {
            synchronized[index] = String(character)
        }
        digits = synchronized
    }

    var loginTerms: AttributedString {
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

    var brandPanel: some View {
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
