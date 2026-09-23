import AppKit
import SwiftUI
import WisentDesignSystem

struct OrganizationPickerView: View {
    @ObservedObject var store: WisentAuthStore
    @State var organizationName = ""
    @State var organizationSlug = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Choose an organization", systemImage: "building.2")
                .font(.title2.bold())
            Text("Your permissions and organization data are scoped to this selection.")
                .foregroundStyle(.secondary)

            ForEach(store.organizations) { organization in
                Button {
                    Task { await store.selectOrganization(organization) }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(organization.name).font(.headline)
                            Text(organization.slug).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(organization.role.capitalized)
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.secondary.opacity(0.12), in: Capsule())
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(14)
                .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityIdentifier("wisent.auth.organization.\(organization.id)")
            }

            GroupBox(store.organizations.isEmpty ? "Create your organization" : "Create another") {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Organization name", text: $organizationName)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("wisent.auth.create-organization-name")
                    HStack {
                        TextField("organization-slug", text: $organizationSlug)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("wisent.auth.create-organization-slug")
                        Button("Create") {
                            Task {
                                await store.createOrganization(
                                    name: organizationName,
                                    slug: organizationSlug
                                )
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("wisent.auth.create-organization")
                    }
                }
                .padding(.top, 4)
            }

            if let error = store.organizationError {
                WisentFailureBanner(
                    message: error,
                    failure: store.organizationFailure,
                    identifier: "wisent.auth.organization-create-error",
                    retry: { await store.reloadOrganizations() }
                )
            }

            HStack {
                Text(store.session?.email ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Sign out") { Task { await store.signOut() } }
            }
        }
        .padding(40)
        .frame(minWidth: 560, minHeight: 520)
        .disabled(store.isOrganizationBusy)
        .accessibilityIdentifier("wisent.auth.organization-picker")
    }
}

struct OrganizationInvitationReviewView: View {
    @ObservedObject var store: WisentAuthStore
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Organization invitations", systemImage: "envelope.badge")
                .font(.title2.bold())
            Text(
                store.selectedOrganization == nil
                    ? "Accept an invitation or create an organization to continue."
                    : "You can review these now or continue in your current organization."
            )
            .foregroundStyle(.secondary)

            ForEach(store.pendingInvitations) { invitation in
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(invitation.organizationName)
                                .font(.headline)
                            Text("Role: \(invitation.role.capitalized)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let expiresAt = invitation.expiresAt {
                            Text("Expires \(expiresAt.formatted(date: .abbreviated, time: .omitted))")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    HStack {
                        Spacer()
                        Button("Decline", role: .destructive) {
                            Task { await store.declineInvitation(invitation) }
                        }
                        Button("Accept") {
                            Task { await store.acceptInvitation(invitation) }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding(16)
                .background(.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityIdentifier("wisent.auth.invitation.\(invitation.id)")
            }

            if store.isBusy {
                WisentSkeleton(.pill, width: 140, height: 14)
            }
            if let error = store.errorMessage {
                WisentFailureBanner(
                    message: error,
                    failure: store.failure,
                    identifier: "wisent.auth.invitation-error",
                    retry: { await store.retry() }
                )
            }

            HStack {
                if store.selectedOrganization != nil {
                    Button("Continue to workspace") { dismiss() }
                }
                Text(store.session?.email ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Sign out") { Task { await store.signOut() } }
            }
        }
        .padding(40)
        .frame(minWidth: 580, minHeight: 420)
        .disabled(store.isBusy)
        .accessibilityIdentifier("wisent.auth.invitation-review")
    }
}
