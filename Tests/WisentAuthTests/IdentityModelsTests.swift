import Foundation
import XCTest
@testable import WisentAuth

final class IdentityModelsTests: XCTestCase {
    func testMembershipDecodesOrganizationAndRole() throws {
        let data = Data(
            #"[{"org_id":"org-1","role":"admin","organizations":{"id":"org-1","slug":"wisent","name":"Wisent"}}]"#.utf8
        )

        let rows = try JSONDecoder().decode([MembershipRow].self, from: data)

        XCTAssertEqual(
            rows.map(\.value),
            [WisentOrganization(id: "org-1", slug: "wisent", name: "Wisent", role: "admin")]
        )
    }

    func testStoredIdentityRoundTripsSelectedOrganization() throws {
        let stored = StoredIdentity(
            session: WisentSession(
                accessToken: "access",
                refreshToken: "refresh",
                expiresAt: Date(timeIntervalSince1970: 1_900_000_000),
                userID: "user-1",
                email: "owner@wisent.ai"
            ),
            selectedOrganizationID: "org-1"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(StoredIdentity.self, from: encoder.encode(stored))

        XCTAssertEqual(decoded, stored)
    }

    func testProductionConfigurationUsesPerBundleCallback() {
        let configuration = WisentAuthConfiguration.production(bundleIdentifier: "ai.wisent.skarbiec.desktop")

        XCTAssertEqual(configuration.callbackScheme, "ai.wisent.skarbiec.desktop")
        XCTAssertEqual(configuration.redirectURL, "ai.wisent.skarbiec.desktop://auth-callback")
    }
}
