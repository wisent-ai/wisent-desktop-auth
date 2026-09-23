import AppKit
import SwiftUI
import WisentDesignSystem

struct WisentSignInView: View {
    @ObservedObject var store: WisentAuthStore
    @FocusState var emailIsFocused: Bool
    @FocusState var focusedDigit: Int?
    @State var digits = Array(repeating: "", count: WisentVerificationCode.length)
    @State var showsVerificationError = true

    init(store: WisentAuthStore) {
        self.store = store
    }

    var body: some View {
        GeometryReader { proxy in
            let showsHero = proxy.size.width >= SignInLayout.heroBreakpoint
            HStack(spacing: 0) {
                signInColumn
                    .frame(minWidth: SignInLayout.minimumWidth, maxWidth: .infinity, maxHeight: .infinity)

                if showsHero {
                    brandPanel
                        .frame(minWidth: 640, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(
                width: max(proxy.size.width, showsHero ? SignInLayout.widthWithHero : SignInLayout.minimumWidth),
                height: proxy.size.height,
                alignment: .leading
            )
        }
        .background(LoginPalette.page)
        .clipped()
        .frame(minWidth: SignInLayout.minimumWidth)
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

    var signInColumn: some View {
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

    var loginLogo: some View {
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

}
