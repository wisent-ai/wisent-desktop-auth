import CryptoKit
import Foundation

actor SupabaseIdentityClient {
    /// The invitation function answers Bad Gateway when the invitation was saved but its mail was not delivered.
    static let badGatewayStatus = 502

    let configuration: WisentAuthConfiguration
    let session: URLSession

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
            path: "/rest/v1/organization_members?select=org_id,role,management_permissions,organizations(id,slug,name)&user_id=eq.\(userID)&order=created_at.asc",
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
