import AppKit
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
    private let timeout: Duration
    private var session: ASWebAuthenticationSession?
    private var continuation: CheckedContinuation<URL, Error>?
    private var timeoutTask: Task<Void, Never>?

    init(timeout: Duration = .seconds(300)) {
        self.timeout = timeout
    }

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
                timeoutTask = Task { @MainActor [weak self, timeout] in
                    do {
                        try await Task.sleep(for: timeout)
                    } catch {
                        return
                    }
                    self?.cancel(with: WisentAuthError.webAuthenticationTimedOut)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancel()
            }
        }
    }

    func cancel() {
        cancel(with: CancellationError())
    }

    private func cancel(with error: Error) {
        guard continuation != nil else { return }
        session?.cancel()
        finish(.failure(error))
    }

    private func finish(_ result: Result<URL, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        session = nil
        continuation.resume(with: result)
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApplication.shared.keyWindow
            ?? NSApplication.shared.windows.first(where: \.isVisible)
            ?? ASPresentationAnchor()
    }
}
