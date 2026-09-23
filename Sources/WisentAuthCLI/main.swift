import Darwin
import Foundation
import WisentAuth

@main
struct WisentAuthCommand {
    /// `otp verify` takes the action word, the email and the code.
    static let verifyArgumentCount = 3

    @MainActor
    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            guard !arguments.isEmpty else { throw CLIError.usage(Self.usage) }
            let store = WisentAuthStore(productName: "Wisent Auth CLI")
            await store.start()
            try await run(arguments, store: store)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            FileHandle.standardError.write(Data("wisent-auth: \(message)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }

    @MainActor
    static func run(_ rawArguments: [String], store: WisentAuthStore) async throws {
        var arguments = rawArguments
        let organizationSelector = try takeOption("--organization", from: &arguments)
        guard let command = arguments.first else { throw CLIError.usage(usage) }
        arguments.removeFirst()

        switch command {
        case "otp":
            try await runOTP(arguments, store: store)
        case "status":
            try noArguments(arguments)
            try output(StatusOutput(store: store))
        case "logout":
            try noArguments(arguments)
            await store.signOut()
            try output(MessageOutput(ok: true, message: "Signed out"))
        case "organization":
            try await runOrganization(arguments, selector: organizationSelector, store: store)
        case "invitation":
            try await runInvitation(arguments, selector: organizationSelector, store: store)
        case "member":
            try await runMember(arguments, selector: organizationSelector, store: store)
        case "ownership":
            try await runOwnership(arguments, selector: organizationSelector, store: store)
        case "help", "--help", "-h":
            try output(HelpOutput(usage: usage))
        default:
            throw CLIError.usage("Unknown command '\(command)'.\n\n\(usage)")
        }
    }

    @MainActor
    static func runOTP(_ arguments: [String], store: WisentAuthStore) async throws {
        guard let action = arguments.first else { throw CLIError.usage("otp requires request or verify") }
        switch action {
        case "request":
            guard arguments.count == 2 else { throw CLIError.usage("Usage: wisent-auth otp request <email>") }
            store.email = arguments[1]
            await store.sendCode()
            try succeeded(store)
            try output(MessageOutput(ok: true, message: "Verification code requested"))
        case "verify":
            guard arguments.count == Self.verifyArgumentCount else {
                throw CLIError.usage("Usage: wisent-auth otp verify <email> <six-digit-code>")
            }
            store.email = arguments[1]
            store.code = arguments[2]
            await store.verifyCode()
            try succeeded(store)
            guard let session = store.session else { throw CLIError.failure("Verification did not create a session") }
            try output(SessionOutput(session: session, organization: store.selectedOrganization))
        default:
            throw CLIError.usage("otp requires request or verify")
        }
    }

    @MainActor
    static func runOrganization(
        _ arguments: [String],
        selector: String?,
        store: WisentAuthStore
    ) async throws {
        guard let action = arguments.first else { throw CLIError.usage("organization requires an action") }
        let values = Array(arguments.dropFirst())
        switch action {
        case "list":
            try noArguments(values)
            try requireSignedIn(store)
            try output(store.organizations)
        case "create":
            guard values.count == 2 else {
                throw CLIError.usage("Usage: wisent-auth organization create <name> <slug>")
            }
            try requireSignedIn(store)
            await store.createOrganization(name: values[0], slug: values[1])
            try succeeded(store, organization: true)
            guard let organization = store.selectedOrganization else {
                throw CLIError.failure("Organization was created but could not be selected")
            }
            try output(organization)
        case "select":
            guard values.count == 1 else {
                throw CLIError.usage("Usage: wisent-auth organization select <id-or-slug>")
            }
            try await selectOrganization(values[0], store: store)
            try output(store.selectedOrganization!)
        case "show":
            try noArguments(values)
            try await prepareOrganization(selector: selector, management: false, store: store)
            try output(store.selectedOrganization!)
        case "rename":
            guard values.count == 1 else {
                throw CLIError.usage("Usage: wisent-auth organization rename <name> [--organization <id-or-slug>]")
            }
            try await prepareOrganization(selector: selector, management: false, store: store)
            await store.renameOrganization(name: values[0])
            try succeeded(store, organization: true)
            try output(store.selectedOrganization!)
        case "slug":
            guard values.count == 1 else {
                throw CLIError.usage("Usage: wisent-auth organization slug <slug> [--organization <id-or-slug>]")
            }
            try await prepareOrganization(selector: selector, management: false, store: store)
            await store.updateOrganizationSlug(values[0])
            try succeeded(store, organization: true)
            try output(store.selectedOrganization!)
        case "leave":
            try noArguments(values)
            try await prepareOrganization(selector: selector, management: true, store: store)
            let previous = store.selectedOrganization?.id
            await store.leaveOrganization()
            try succeeded(store, organization: true)
            try output(LifecycleOutput(ok: true, previousOrganizationID: previous, selected: store.selectedOrganization))
        case "delete":
            try noArguments(values)
            try await prepareOrganization(selector: selector, management: false, store: store)
            let previous = store.selectedOrganization?.id
            await store.deleteOrganization()
            try succeeded(store, organization: true)
            try output(LifecycleOutput(ok: true, previousOrganizationID: previous, selected: store.selectedOrganization))
        default:
            throw CLIError.usage("Unknown organization action '\(action)'")
        }
    }
}
