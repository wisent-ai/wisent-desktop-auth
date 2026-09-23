import AppKit
import SwiftUI
import WisentDesignSystem

struct OrganizationManagementView: View {
    @ObservedObject var store: WisentAuthStore
    @Environment(\.dismiss) var dismiss
    @State var organizationName = ""
    @State var organizationSlug = ""
    @State var memberPendingRemoval: WisentOrganizationMember?
    @State var memberPendingOwnershipTransfer: WisentOrganizationMember?
    @State var isLeaveConfirmationPresented = false
    @State var isDeleteConfirmationPresented = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(store.selectedOrganization?.name ?? "Organization")
                        .font(.title2.bold())
                    Text("Organization, team and access")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if store.isOrganizationBusy {
                    WisentSkeleton(.pill, width: 90, height: 14)
                }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(20)

            Divider()

            if store.selectedOrganization?.isFixedWisentOrganization == true {
                GroupBox("Managed centrally") {
                    Label(
                        "The Wisent organization is managed centrally. Its name, slug, and deletion settings cannot be changed here.",
                        systemImage: "lock.shield"
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                }
                .padding(.horizontal, 20)
                .padding(.top, 14)
            } else if store.selectedOrganization?.hasManagementPermission(.organizationRename) == true
                || store.selectedOrganization?.organizationRole == .owner
            {
                GroupBox("Organization details") {
                    VStack(spacing: 10) {
                        HStack {
                            TextField("Organization name", text: $organizationName)
                                .textFieldStyle(.roundedBorder)
                                .disabled(
                                    store.selectedOrganization?.hasManagementPermission(
                                        .organizationRename
                                    ) != true
                                )
                            if store.selectedOrganization?.hasManagementPermission(
                                .organizationRename
                            ) == true {
                                Button("Save name") {
                                    Task { await store.renameOrganization(name: organizationName) }
                                }
                            }
                        }
                        if store.selectedOrganization?.organizationRole == .owner {
                            HStack {
                                TextField("organization-slug", text: $organizationSlug)
                                    .textFieldStyle(.roundedBorder)
                                Button("Save slug") {
                                    Task { await store.updateOrganizationSlug(organizationSlug) }
                                }
                            }
                        }
                    }
                    .padding(.top, 4)
                }
                .padding(.horizontal, 20)
                .padding(.top, 14)
            }

            if let organization = store.selectedOrganization,
               organization.hasManagementPermission(.membersInvite) {
                GroupBox("Invite a teammate") {
                    HStack(spacing: 10) {
                        TextField("teammate@company.com", text: $store.inviteEmail)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("wisent.auth.invite-email")
                        Picker("Role", selection: $store.inviteRole) {
                            ForEach(availableInviteRoles, id: \.self) { role in
                                Text(role.rawValue.capitalized).tag(role)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 120)
                        Button("Send invite") {
                            Task { await store.sendOrganizationInvitation() }
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("wisent.auth.send-invite")
                    }
                    .padding(.top, 4)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            }

            if let error = store.organizationError {
                WisentFailureBanner(
                    message: error,
                    failure: store.organizationFailure,
                    identifier: "wisent.auth.organization-error",
                    retry: { await store.loadOrganizationManagement() }
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, BannerLayout.horizontalPadding)
                .padding(.bottom, BannerLayout.bottomPadding)
            }

            List {
                Section("Members") {
                    ForEach(store.organizationMembers) { member in
                        memberRow(member)
                    }
                }

                if (store.selectedOrganization?.hasManagementPermission(.membersInvite) == true
                    || store.selectedOrganization?.hasManagementPermission(.invitationsCancel) == true),
                   !store.organizationInvitations.isEmpty {
                    Section("Pending invitations") {
                        ForEach(store.organizationInvitations) { invitation in
                            invitationRow(invitation)
                        }
                    }
                }

                if canLeaveSelectedOrganization || canDeleteSelectedOrganization {
                    Section {
                        if canLeaveSelectedOrganization {
                            Button("Leave organization…", role: .destructive) {
                                isLeaveConfirmationPresented = true
                            }
                        }
                        if canDeleteSelectedOrganization {
                            Button("Delete organization…", role: .destructive) {
                                isDeleteConfirmationPresented = true
                            }
                        }
                    }
                }
            }
            .overlay {
                if store.isOrganizationBusy && store.organizationMembers.isEmpty {
                    WisentSkeletonList(rows: 4, lines: 2, media: true, label: "Loading team")
                        .padding(20)
                }
            }
        }
        .frame(minWidth: 720, minHeight: 680)
        .disabled(store.isOrganizationBusy)
        .task {
            organizationName = store.selectedOrganization?.name ?? ""
            organizationSlug = store.selectedOrganization?.slug ?? ""
            await store.loadOrganizationManagement()
        }
        .alert(
            "Remove member?",
            isPresented: Binding(
                get: { memberPendingRemoval != nil },
                set: { if !$0 { memberPendingRemoval = nil } }
            ),
            presenting: memberPendingRemoval
        ) { member in
            Button("Remove", role: .destructive) {
                Task { await store.removeOrganizationMember(member) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { member in
            Text("\(member.email) will lose access to this organization.")
        }
        .alert(
            "Transfer ownership?",
            isPresented: Binding(
                get: { memberPendingOwnershipTransfer != nil },
                set: { if !$0 { memberPendingOwnershipTransfer = nil } }
            ),
            presenting: memberPendingOwnershipTransfer
        ) { member in
            Button("Transfer", role: .destructive) {
                Task { await store.transferOrganizationOwnership(to: member) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { member in
            Text("\(member.email) will become an owner and your role will become admin.")
        }
        .alert("Leave organization?", isPresented: $isLeaveConfirmationPresented) {
            Button("Leave", role: .destructive) {
                Task {
                    let previousID = store.selectedOrganization?.id
                    await store.leaveOrganization()
                    if store.selectedOrganization?.id != previousID { dismiss() }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You will lose access to this organization's data.")
        }
        .alert("Delete organization?", isPresented: $isDeleteConfirmationPresented) {
            Button("Delete", role: .destructive) {
                Task {
                    let previousID = store.selectedOrganization?.id
                    await store.deleteOrganization()
                    if store.selectedOrganization?.id != previousID { dismiss() }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes the organization and its access.")
        }
        .accessibilityIdentifier("wisent.auth.organization-management")
    }
}
