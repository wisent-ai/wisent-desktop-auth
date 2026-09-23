import Foundation

extension SupabaseIdentityClient {
    func deliverInvitation(
        body: [String: Any],
        organizationID: String,
        session identity: WisentSession
    ) async throws -> WisentOrganizationInvite {
        do {
            let data = try await rest(
                method: "POST",
                path: "/functions/v1/organization-invitations",
                body: body,
                accessToken: identity.accessToken,
                organizationID: organizationID
            )
            return try Self.decode(InvitationFunctionResponse.self, from: data).invitation
        } catch let error as WisentAuthError {
            guard case let .http(response, _) = error,
                  response.status == Self.badGatewayStatus,
                  let data = response.body.data(using: .utf8),
                  let payload = try? Self.decode(InvitationFunctionResponse.self, from: data),
                  payload.error?.code == "delivery_failed" else {
                throw error
            }
            throw WisentAuthError.invitationSavedButUndelivered(payload.invitation)
        }
    }

    struct InvitationFunctionResponse: Decodable {
        struct FunctionError: Decodable {
            let code: String
            let message: String
        }

        let invitation: WisentOrganizationInvite
        let error: FunctionError?
    }

    func rpc(
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

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
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

    static func decodeIdentifier(_ data: Data) throws -> String {
        guard let identifier = try JSONSerialization.jsonObject(
            with: data,
            options: [.fragmentsAllowed]
        ) as? String, !identifier.isEmpty else {
            throw WisentAuthError.noOrganization
        }
        return identifier
    }

    static func organizationRefusal(from data: Data) -> WisentOrganizationRefusal? {
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

    var normalizedBaseURL: String {
        var value = configuration.supabaseURL
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }

    func authPOST(
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

    func rest(
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

    func request(
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

    static func decodeSession(_ data: Data) throws -> WisentSession {
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

    static func queryValue(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?#")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
