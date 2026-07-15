import CryptoKit
import Foundation

actor SupabaseIdentityClient {
    private let configuration: WisentAuthConfiguration
    private let session: URLSession

    init(configuration: WisentAuthConfiguration, session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
    }

    func requestOTP(email: String) async throws {
        _ = try await authPOST(path: "/auth/v1/otp", body: ["email": email, "create_user": true])
    }

    func verifyOTP(email: String, code: String) async throws -> WisentSession {
        let data = try await authPOST(
            path: "/auth/v1/verify",
            body: ["type": "email", "email": email, "token": code]
        )
        return try Self.decodeSession(data)
    }

    func refresh(refreshToken: String) async throws -> WisentSession {
        let data = try await authPOST(
            path: "/auth/v1/token?grant_type=refresh_token",
            body: ["refresh_token": refreshToken]
        )
        return try Self.decodeSession(data)
    }

    func signOut(accessToken: String) async throws {
        _ = try await authPOST(path: "/auth/v1/logout", body: [:], accessToken: accessToken)
    }

    func oauthAuthorizeURL(provider: String, challenge: String) throws -> URL {
        guard var components = URLComponents(string: normalizedBaseURL + "/auth/v1/authorize") else {
            throw WisentAuthError.malformedURL(normalizedBaseURL)
        }
        components.queryItems = [
            URLQueryItem(name: "provider", value: provider),
            URLQueryItem(name: "redirect_to", value: configuration.redirectURL),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "s256"),
        ]
        guard let url = components.url else { throw WisentAuthError.malformedURL(components.string ?? "authorize") }
        return url
    }

    func exchangeCode(_ code: String, verifier: String) async throws -> WisentSession {
        let data = try await authPOST(
            path: "/auth/v1/token?grant_type=pkce",
            body: ["auth_code": code, "code_verifier": verifier]
        )
        return try Self.decodeSession(data)
    }

    func signInWithApple(idToken: String, nonce: String) async throws -> WisentSession {
        let data = try await authPOST(
            path: "/auth/v1/token?grant_type=id_token",
            body: ["provider": "apple", "id_token": idToken, "nonce": nonce]
        )
        return try Self.decodeSession(data)
    }

    func organizations(session identity: WisentSession) async throws -> [WisentOrganization] {
        let userID = Self.queryValue(identity.userID)
        let data = try await rest(
            method: "GET",
            path: "/rest/v1/organization_members?select=org_id,role,organizations(id,slug,name)&user_id=eq.\(userID)&order=created_at.asc",
            accessToken: identity.accessToken
        )
        return try JSONDecoder().decode([MembershipRow].self, from: data).map(\.value)
    }

    func bootstrapOrganization(session identity: WisentSession) async throws -> String {
        let data = try await rest(
            method: "POST",
            path: "/rest/v1/rpc/bootstrap_user",
            body: [:],
            accessToken: identity.accessToken
        )
        guard let id = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? String,
              !id.isEmpty else {
            throw WisentAuthError.noOrganization
        }
        return id
    }

    private var normalizedBaseURL: String {
        var value = configuration.supabaseURL
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }

    private func authPOST(
        path: String,
        body: [String: Any],
        accessToken: String? = nil
    ) async throws -> Data {
        try await request(
            method: "POST",
            path: path,
            body: body,
            accessToken: accessToken ?? configuration.anonKey
        )
    }

    private func rest(
        method: String,
        path: String,
        body: [String: Any]? = nil,
        accessToken: String
    ) async throws -> Data {
        try await request(method: method, path: path, body: body, accessToken: accessToken)
    }

    private func request(
        method: String,
        path: String,
        body: [String: Any]?,
        accessToken: String
    ) async throws -> Data {
        guard let url = URL(string: normalizedBaseURL + path) else {
            throw WisentAuthError.malformedURL(normalizedBaseURL + path)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 30
        request.setValue(configuration.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw WisentAuthError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            throw WisentAuthError.http(http.statusCode, String(decoding: data, as: UTF8.self))
        }
        return data
    }

    private static func decodeSession(_ data: Data) throws -> WisentSession {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = object["access_token"] as? String,
              let refreshToken = object["refresh_token"] as? String,
              let user = object["user"] as? [String: Any],
              let userID = user["id"] as? String else {
            throw WisentAuthError.malformedSession
        }
        let expiresAt: Date
        if let absolute = object["expires_at"] as? Double {
            expiresAt = Date(timeIntervalSince1970: absolute)
        } else if let duration = object["expires_in"] as? Double {
            expiresAt = Date().addingTimeInterval(duration)
        } else {
            expiresAt = Date().addingTimeInterval(3600)
        }
        return WisentSession(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: expiresAt,
            userID: userID,
            email: user["email"] as? String ?? ""
        )
    }

    private static func queryValue(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?#")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

struct PKCEPair: Sendable {
    let verifier: String
    let challenge: String

    init() {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<64).map { _ in UInt8.random(in: 0...255, using: &generator) }
        verifier = Data(bytes).base64URLEncoded
        challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
    }
}

private extension Data {
    var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
