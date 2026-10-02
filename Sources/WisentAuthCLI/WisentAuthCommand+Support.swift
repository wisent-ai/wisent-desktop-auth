import CoreFoundation
import Darwin
import Foundation
import WisentAuth

extension WisentAuthCommand {
    @MainActor
    static func selectOrganization(_ selector: String, store: WisentAuthStore) async throws {
        try requireSignedIn(store)
        guard let organization = store.organizations.first(where: {
            $0.id == selector || $0.slug.caseInsensitiveCompare(selector) == .orderedSame
        }) else {
            throw CLIError.failure("No accessible organization matches '\(selector)'")
        }
        await store.selectOrganization(organization)
        try succeeded(store, organization: true)
        guard store.selectedOrganization?.id == organization.id else {
            throw CLIError.failure("Organization '\(selector)' could not be selected")
        }
    }

    @MainActor
    static func requireSignedIn(_ store: WisentAuthStore) throws {
        guard store.session != nil else {
            throw CLIError.failure("No saved session; run 'wisent-auth otp request <email>' then 'wisent-auth otp verify <email> <code>'")
        }
        try succeeded(store)
    }

    @MainActor
    static func succeeded(_ store: WisentAuthStore, organization: Bool = false) throws {
        if organization, let message = store.organizationError { throw CLIError.failure(message) }
        if let message = store.errorMessage { throw CLIError.failure(message) }
    }

    @MainActor
    static func organizationMember(
        _ userID: String,
        store: WisentAuthStore
    ) throws -> WisentOrganizationMember {
        guard let member = store.organizationMembers.first(where: { $0.userID == userID }) else {
            throw CLIError.failure("No organization member has user id '\(userID)'")
        }
        return member
    }

    @MainActor
    static func organizationInvitation(
        _ id: String,
        store: WisentAuthStore
    ) throws -> WisentOrganizationInvite {
        guard let invitation = store.organizationInvitations.first(where: { $0.id == id }) else {
            throw CLIError.failure("No pending organization invitation has id '\(id)'")
        }
        return invitation
    }

    @MainActor
    static func receivedInvitation(
        _ id: String,
        store: WisentAuthStore
    ) throws -> WisentUserInvite {
        guard let invitation = store.pendingInvitations.first(where: { $0.id == id }) else {
            throw CLIError.failure("No invitation received by this account has id '\(id)'")
        }
        return invitation
    }

    static func role(_ value: String) throws -> WisentOrganizationRole {
        guard let role = WisentOrganizationRole(rawValue: value.lowercased()) else {
            throw CLIError.usage("Role must be owner, admin, or member")
        }
        return role
    }

    static func permission(_ value: String) throws -> WisentOrganizationManagementPermission {
        guard let permission = WisentOrganizationManagementPermission(rawValue: value.lowercased()) else {
            let accepted = WisentOrganizationManagementPermission.allCases.map(\.rawValue).joined(separator: ", ")
            throw CLIError.usage("Unknown permission '\(value)'; expected one of: \(accepted)")
        }
        return permission
    }

    static func takeOption(_ name: String, from arguments: inout [String]) throws -> String? {
        guard let index = arguments.firstIndex(of: name) else { return nil }
        guard arguments.indices.contains(index + 1), !arguments[index + 1].hasPrefix("--") else {
            throw CLIError.usage("\(name) requires a value")
        }
        let value = arguments[index + 1]
        arguments.removeSubrange(index...(index + 1))
        return value
    }

    static func noArguments(_ arguments: [String]) throws {
        guard arguments.isEmpty else { throw CLIError.usage("Unexpected argument '\(arguments[0])'") }
    }

    @MainActor
    static func output<T: Encodable>(_ value: T) throws {
        if textOutput, let help = value as? HelpOutput {
            FileHandle.standardOutput.write(Data("\(help.usage)\n".utf8))
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        if textOutput {
            let decoded = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            let lines = textLines(decoded)
            FileHandle.standardOutput.write(Data("\(lines.joined(separator: "\n"))\n".utf8))
        } else {
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        }
    }

    private static func textLines(_ value: Any, path: String = "") -> [String] {
        if let object = value as? [String: Any] {
            if object.isEmpty { return ["\(path): {}"] }
            return object.keys.sorted().flatMap { key in
                textLines(object[key]!, path: path.isEmpty ? key : "\(path).\(key)")
            }
        }
        if let array = value as? [Any] {
            if array.isEmpty { return ["\(path): []"] }
            return array.enumerated().flatMap { index, item in textLines(item, path: "\(path)[\(index)]") }
        }
        if value is NSNull { return ["\(path): none"] }
        if let string = value as? String { return ["\(path): \(string.replacingOccurrences(of: "\n", with: "\\n"))"] }
        if let number = value as? NSNumber {
            let rendered = CFGetTypeID(number) == CFBooleanGetTypeID() ? (number.boolValue ? "true" : "false") : number.stringValue
            return ["\(path): \(rendered)"]
        }
        return ["\(path): \(value)"]
    }

    static let usage = """
    Usage: wisent-auth [--json|--text] <command>

      otp request <email>
      otp verify <email> <six-digit-code>
      status
      logout
      organization list
      organization create <name> <slug>
      organization select <id-or-slug>
      organization show|rename|slug|leave|delete [arguments] [--organization <id-or-slug>]
      invitation list|send|resend|accept|decline|cancel [arguments] [--organization <id-or-slug>]
      member list|role|permissions|remove [arguments] [--organization <id-or-slug>]
      ownership transfer <user-id> [--organization <id-or-slug>]
    """
}
