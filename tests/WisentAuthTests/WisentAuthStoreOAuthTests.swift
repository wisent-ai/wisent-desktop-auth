import Foundation
import XCTest
@testable import WisentAuth

@MainActor
final class WisentAuthStoreOAuthTests: XCTestCase {
    func testCancelOAuthSignInReleasesBusyState() async {
        let webSession = HangingOAuthWebSession()
        let store = makeStore(webSession: webSession)

        let signIn = Task { await store.signInWithGoogle() }
        for _ in 0..<100 {
            if webSession.didStart { break }
            await Task.yield()
        }
        guard webSession.didStart else {
            signIn.cancel()
            XCTFail("OAuth session did not start")
            return
        }

        XCTAssertTrue(store.isBusy)
        XCTAssertTrue(store.isOAuthBusy)
        store.cancelOAuthSignIn()
        await signIn.value

        XCTAssertTrue(webSession.didCancel)
        XCTAssertFalse(store.isBusy)
        XCTAssertFalse(store.isOAuthBusy)
        XCTAssertNil(store.errorMessage)
    }

    func testOAuthTimeoutReleasesBusyStateAndReportsFailure() async {
        let webSession = FailingOAuthWebSession(error: WisentAuthError.webAuthenticationTimedOut)
        let store = makeStore(webSession: webSession)

        await store.signInWithGoogle()

        XCTAssertFalse(store.isBusy)
        XCTAssertFalse(store.isOAuthBusy)
        XCTAssertEqual(store.errorMessage, "Browser sign-in did not respond. Cancel it or try again.")
    }

    private func makeStore(webSession: any OAuthWebSession) -> WisentAuthStore {
        WisentAuthStore(
            productName: "Tama",
            bundleIdentifier: "ai.wisent.tama.desktop",
            configuration: WisentAuthConfiguration(
                supabaseURL: "https://identity.example.com",
                anonKey: "anon-key",
                redirectURL: "ai.wisent.tama.desktop://auth-callback",
                callbackScheme: "ai.wisent.tama.desktop",
                oauthEnabled: true
            ),
            persistence: EmptyIdentityPersistence(),
            webSessionFactory: { webSession }
        )
    }
}

private struct EmptyIdentityPersistence: IdentityPersistence {
    func load() throws -> StoredIdentity? { nil }
    func save(_ value: StoredIdentity) throws {}
    func clear() throws {}
}

@MainActor
private final class HangingOAuthWebSession: OAuthWebSession {
    private var continuation: CheckedContinuation<URL, Error>?
    private(set) var didStart = false
    private(set) var didCancel = false

    func start(url: URL, callbackScheme: String) async throws -> URL {
        didStart = true
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func cancel() {
        didCancel = true
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(throwing: CancellationError())
    }
}

@MainActor
private final class FailingOAuthWebSession: OAuthWebSession {
    private let error: Error

    init(error: Error) {
        self.error = error
    }

    func start(url: URL, callbackScheme: String) async throws -> URL {
        throw error
    }

    func cancel() {}
}
