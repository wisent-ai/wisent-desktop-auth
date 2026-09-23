import Foundation

struct StoredIdentity: Codable, Sendable, Equatable {
    let session: WisentSession
    var selectedOrganizationID: String?
}


struct OrganizationAuthorizationRow: Decodable, Sendable {
    let userID: String
    let organizationID: String
    let role: WisentOrganizationRole

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case organizationID = "organization_id"
        case role
    }
}

struct MembershipRow: Decodable, Sendable {
    struct Organization: Decodable, Sendable {
        let id: String
        let slug: String
        let name: String
    }

    let organizationID: String
    let role: WisentOrganizationRole
    let managementPermissions: [WisentOrganizationManagementPermission]
    let organization: Organization

    enum CodingKeys: String, CodingKey {
        case organizationID = "org_id"
        case role
        case managementPermissions = "management_permissions"
        case organization = "organizations"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        organizationID = try values.decode(String.self, forKey: .organizationID)
        role = try values.decode(WisentOrganizationRole.self, forKey: .role)
        let decodedPermissions = try values.decodeIfPresent(
            [WisentOrganizationManagementPermission].self,
            forKey: .managementPermissions
        )
        managementPermissions = role == .owner
            ? WisentOrganizationManagementPermission.allCases
            : decodedPermissions ?? []
        organization = try values.decode(Organization.self, forKey: .organization)
    }

    var value: WisentOrganization {
        WisentOrganization(
            id: organizationID,
            slug: organization.slug,
            name: organization.name,
            role: role,
            managementPermissions: managementPermissions
        )
    }
}
