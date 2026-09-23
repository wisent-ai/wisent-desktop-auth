import AppKit
import SwiftUI
import WisentDesignSystem

/// The failure banner's width and spacing, in points.
enum BannerLayout {
    static let maxWidth: CGFloat = 420
    static let horizontalPadding: CGFloat = 20
    static let bottomPadding: CGFloat = 8
    static let spacing: CGFloat = 6
}

/// The single rendering for every failure this library shows, so one incident
/// reads the same on the sign-in screen, on the invitation screen and in the
/// organization sheet.
///
/// An outage is deliberately not styled like a mistake. Painting "we are down"
/// in the same red as "that code is wrong" is what sends a user off to reset a
/// password that was never the problem.
struct WisentFailureBanner: View {
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
