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


    func organizations(session identity: WisentSession) async throws -> [WisentOrganization] {
        let userID = Self.queryValue(identity.userID)
        let data = try await rest(
            method: "GET",
            path: "/rest/v1/organization_members?select=org_id,role,organizations(id,slug,name)&user_id=eq.\(userID)&order=created_at.asc",
            accessToken: identity.accessToken
        )
        return try JSONDecoder().decode([MembershipRow].self, from: data).map(\.value)
    }


    func authorizeOrganization(
        _ organizationID: String,
        session identity: WisentSession
    ) async throws -> OrganizationAuthorizationRow {
        let data = try await rpc(
            "authorize_organization",
            body: ["target_org_id": organizationID],
            session: identity,
            organizationID: organizationID
        )
        let rows = try Self.decode([OrganizationAuthorizationRow].self, from: data)
        guard rows.count == 1,
              let authorization = rows.first,
              authorization.userID == identity.userID,
              authorization.organizationID == organizationID else {
            throw WisentAuthError.organizationRefusal(.noMembership)
        }
        return authorization
    }

    func createOrganization(
        name: String,
        slug: String,
        session identity: WisentSession
    ) async throws -> String {
        let data = try await rpc(
            "create_organization",
            body: ["organization_name": name, "organization_slug": slug],
            session: identity
        )
        return try Self.decodeIdentifier(data)
    }

    func renameOrganization(
        _ organizationID: String,
        name: String,
        session identity: WisentSession
    ) async throws {
        _ = try await rpc(
            "rename_organization",
            body: ["target_org_id": organizationID, "new_name": name],
            session: identity,
            organizationID: organizationID
        )
    }

    func updateOrganizationSlug(
        _ organizationID: String,
        slug: String,
        session identity: WisentSession
    ) async throws {
        _ = try await rpc(
            "update_organization_slug",
            body: ["target_org_id": organizationID, "new_slug": slug],
            session: identity,
            organizationID: organizationID
        )
    }

    func leaveOrganization(
        _ organizationID: String,
        session identity: WisentSession
    ) async throws {
        _ = try await rpc(
            "leave_organization",
            body: ["target_org_id": organizationID],
            session: identity,
            organizationID: organizationID
        )
    }

    func deleteOrganization(
        _ organizationID: String,
        session identity: WisentSession
    ) async throws {
        _ = try await rpc(
            "delete_organization",
            body: ["target_org_id": organizationID],
            session: identity,
            organizationID: organizationID
        )
    }

    func transferOrganizationOwnership(
        _ organizationID: String,
        to userID: String,
        session identity: WisentSession
    ) async throws {
        _ = try await rpc(
            "transfer_organization_ownership",
            body: ["target_org_id": organizationID, "target_user_id": userID],
            session: identity,
            organizationID: organizationID
        )
    }

    func pendingInvitations(session identity: WisentSession) async throws -> [WisentUserInvite] {
        let data = try await rpc("list_invites_for_user", body: [:], session: identity)
        return try Self.decode([WisentUserInvite].self, from: data)
    }

    func acceptInvitation(_ invitation: WisentUserInvite, session identity: WisentSession) async throws -> String {
        let data = try await rpc(
            "accept_org_invite",
            body: ["invite_token": invitation.token],
            session: identity,
            organizationID: invitation.organizationID
        )
        guard let organizationID = try JSONSerialization.jsonObject(
            with: data,
            options: [.fragmentsAllowed]
        ) as? String, !organizationID.isEmpty else {
            throw WisentAuthError.noOrganization
        }
        return organizationID
    }

    func declineInvitation(_ invitation: WisentUserInvite, session identity: WisentSession) async throws {
        _ = try await rpc(
            "decline_org_invite",
            body: ["invite_id": invitation.id],
            session: identity,
            organizationID: invitation.organizationID
        )
    }

    func organizationMembers(
        organizationID: String,
        session identity: WisentSession
    ) async throws -> [WisentOrganizationMember] {
        let data = try await rpc(
            "list_org_members_for_org",
            body: ["target_org_id": organizationID],
            session: identity,
            organizationID: organizationID
        )
        return try Self.decode([WisentOrganizationMember].self, from: data)
    }

    func organizationInvitations(
        organizationID: String,
        session identity: WisentSession
    ) async throws -> [WisentOrganizationInvite] {
        let data = try await rpc(
            "list_org_invites_for_org",
            body: ["target_org_id": organizationID],
            session: identity,
            organizationID: organizationID
        )
        return try Self.decode([WisentOrganizationInvite].self, from: data)
    }

    func inviteMember(
        email: String,
        role: WisentOrganizationRole,
        organizationID: String,
        session identity: WisentSession
    ) async throws {
        _ = try await rpc(
            "invite_org_member_for_org",
            body: [
                "target_org_id": organizationID,
                "invitee_email": email,
                "invitee_role": role.rawValue,
            ],
            session: identity,
            organizationID: organizationID
        )
    }

    func cancelInvitation(
        id: String,
        organizationID: String,
        session identity: WisentSession
    ) async throws {
        _ = try await rpc(
            "cancel_org_invite_for_org",
            body: ["target_org_id": organizationID, "invite_id": id],
            session: identity,
            organizationID: organizationID
        )
    }

    func removeMember(
        userID: String,
        organizationID: String,
        session identity: WisentSession
    ) async throws {
        _ = try await rpc(
            "remove_org_member_from_org",
            body: ["target_org_id": organizationID, "member_user_id": userID],
            session: identity,
            organizationID: organizationID
        )
    }

    func updateMemberRole(
        userID: String,
        role: WisentOrganizationRole,
        organizationID: String,
        session identity: WisentSession
    ) async throws {
        _ = try await rpc(
            "update_org_member_role_for_org",
            body: [
                "target_org_id": organizationID,
                "member_user_id": userID,
                "new_role": role.rawValue,
            ],
            session: identity,
            organizationID: organizationID
        )
    }

    private func rpc(
        _ name: String,
        body: [String: Any],
        session identity: WisentSession,
        organizationID: String? = nil
    ) async throws -> Data {
        try await rest(
            method: "POST",
            path: "/rest/v1/rpc/\(name)",
            body: body,
            accessToken: identity.accessToken,
            organizationID: organizationID
        )
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            guard let date = fractional.date(from: raw) ?? plain.date(from: raw) else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath, debugDescription: "Invalid date: \(raw)")
                )
            }
            return date
        }
        return try decoder.decode(type, from: data)
    }

    private static func decodeIdentifier(_ data: Data) throws -> String {
        guard let identifier = try JSONSerialization.jsonObject(
            with: data,
            options: [.fragmentsAllowed]
        ) as? String, !identifier.isEmpty else {
            throw WisentAuthError.noOrganization
        }
        return identifier
    }

    private static func organizationRefusal(from data: Data) -> WisentOrganizationRefusal? {
        guard let object = try? JSONSerialization.jsonObject(
            with: data,
            options: [.fragmentsAllowed]
        ) else {
            return nil
        }
        let message: String?
        if let payload = object as? [String: Any] {
            message = payload["message"] as? String
        } else {
            message = object as? String
        }
        return message.flatMap(WisentOrganizationRefusal.init(rawValue:))
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
        accessToken: String,
        organizationID: String? = nil
    ) async throws -> Data {
        try await request(
            method: method,
            path: path,
            body: body,
            accessToken: accessToken,
            organizationID: organizationID
        )
    }

    private func request(
        method: String,
        path: String,
        body: [String: Any]?,
        accessToken: String,
        organizationID: String? = nil
    ) async throws -> Data {
        guard let url = URL(string: normalizedBaseURL + path) else {
            throw WisentAuthError.malformedURL(normalizedBaseURL + path)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 30
        request.setValue(configuration.anonKey, forHTTPHeaderField: "apikey")
        request.setValue(
            "Bearer \(accessToken)",
            forHTTPHeaderField: WisentAuthHeader.authorization
        )
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let organizationID {
            request.setValue(
                organizationID,
                forHTTPHeaderField: WisentAuthHeader.organizationID
            )
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await session.data(for: request)
        let point = WisentFailurePoint.forRequest(path: path)
        guard let http = response as? HTTPURLResponse else { throw WisentAuthError.invalidResponse(point) }
        guard (200...299).contains(http.statusCode) else {
            if path.hasPrefix("/rest/v1/rpc/"),
               let refusal = Self.organizationRefusal(from: data) {
                throw WisentAuthError.organizationRefusal(refusal)
            }
            throw WisentAuthError.http(
                WisentUpstreamResponse(
                    status: http.statusCode,
                    body: String(decoding: data, as: UTF8.self),
                    headerCode: http.value(forHTTPHeaderField: WisentFailureHeader.code),
                    headerImpact: http.value(forHTTPHeaderField: WisentFailureHeader.impact)
                ),
                point
            )
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
