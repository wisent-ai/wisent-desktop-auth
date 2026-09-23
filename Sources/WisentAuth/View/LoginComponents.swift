import AppKit
import SwiftUI
import WisentDesignSystem

struct WisentAuthLoadingView: View {

    var body: some View {
        GeometryReader { proxy in
            let showsRightSkeleton = proxy.size.width >= SignInLayout.heroBreakpoint
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
                .frame(minWidth: SignInLayout.minimumWidth, maxWidth: .infinity, maxHeight: .infinity)

                if showsRightSkeleton {
                    WisentSkeleton(.block, width: 320, height: 320)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(
                width: max(proxy.size.width, SignInLayout.minimumWidth),
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
        .frame(minWidth: SignInLayout.minimumWidth)
        .accessibilityLabel("Loading sign-in")
        .accessibilityIdentifier("wisent.auth.loading")
    }
}

struct LoginMessageBanner: View {
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

/// The sign-in verb, which does not change while the sign-in runs.
///
/// It used to read `store.isBusy ? "Verifying..." : "Continue"`, and every
/// application in the fleet embeds this view: at the one moment a screen reader
/// needs the control's name, the name became a status line, and the button
/// resized as the word changed length. `isBusy` keeps the word, hides it behind
/// a shimmering bar of its own width, and refuses a second press — the same
/// bargain `WisentAction(isBusy:)` makes in the shell.
struct LoginPrimaryButton: View {
    let title: String
    let isDisabled: Bool
    var isBusy: Bool = false
    let action: () -> Void
    @State var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(WisentTypography.monoMedium(16))
                .foregroundStyle(LoginPalette.buttonText)
                .opacity(isBusy ? 0 : 1)
                .overlay {
                    if isBusy {
                        WisentSkeleton(.line, height: 10)
                            .wisentSkeletonTone(.onDark)
                    }
                }
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
        .opacity(isDisabled && !isBusy ? 0.5 : 1)
        .disabled(isDisabled || isBusy)
        .onHover { isHovering = $0 }
        .accessibilityLabel(title)
    }
}

struct LoginOAuthButton: View {
    let image: NSImage
    let label: String
    let isLoading: Bool
    let isDisabled: Bool
    let action: () -> Void
    @State var isHovering = false

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

enum LoginPalette {
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

func hubotSemibold(_ size: CGFloat) -> Font {
    _ = WisentTypography.body(size)
    return .custom("HubotSans-SemiBold", size: size)
}
