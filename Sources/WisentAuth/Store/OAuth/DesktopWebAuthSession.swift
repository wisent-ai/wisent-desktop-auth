#if os(macOS)
import AppKit
#else
import UIKit
#endif
import AuthenticationServices
import Foundation

@MainActor
protocol OAuthWebSession: AnyObject {
    func start(url: URL, callbackScheme: String) async throws -> URL
    func cancel()
}

@MainActor
final class DesktopWebAuthSession: NSObject, OAuthWebSession,
    ASWebAuthenticationPresentationContextProviding
{
    private var session: ASWebAuthenticationSession?
    private var continuation: CheckedContinuation<URL, Error>?

    func start(url: URL, callbackScheme: String) async throws -> URL {
        guard continuation == nil else { throw WisentAuthError.invalidResponse(.oauthAuthorize) }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let session = ASWebAuthenticationSession(
                    url: url,
                    callbackURLScheme: callbackScheme
                ) { [weak self] url, error in
                    Task { @MainActor in
                        if let error {
                            self?.finish(.failure(error))
                        } else if let url {
                            self?.finish(.success(url))
                        } else {
                            self?.finish(.failure(WisentAuthError.invalidResponse(.oauthAuthorize)))
                        }
                    }
                }
                session.presentationContextProvider = self
                session.prefersEphemeralWebBrowserSession = false
                self.session = session
                guard session.start() else {
                    finish(.failure(WisentAuthError.invalidResponse(.oauthAuthorize)))
                    return
                }
                // The sign-in ends when the person completes it, cancels the
                // browser sheet, or the caller's task is cancelled; nothing
                // decides on their behalf how long reading a login page may take.
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancel()
            }
        }
    }

    func cancel() {
        guard continuation != nil else { return }
        session?.cancel()
        finish(.failure(CancellationError()))
    }

    private func finish(_ result: Result<URL, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        session = nil
        continuation.resume(with: result)
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        #if os(macOS)
        NSApplication.shared.keyWindow
            ?? NSApplication.shared.windows.first(where: \.isVisible)
            ?? ASPresentationAnchor()
        #else
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
            ?? ASPresentationAnchor()
        #endif
    }
}
