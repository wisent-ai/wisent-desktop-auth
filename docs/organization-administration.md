# Organization administration

Organization administration is shared across Wisent applications. Membership, central management permissions, invitations, and organization lifecycle operations belong to the organization identity service; permissions specific to a product remain in that product.

The canonical public URL for this document is <https://oko.wisent.com/docs/organization-administration>.

## Roles

Every membership has exactly one role.

| Role | Central management permissions by default | Organization lifecycle authority |
|---|---|---|
| Owner | All four | Change name and slug; change roles and management permissions; transfer ownership; delete the organization |
| Admin | All four | Only actions allowed by the membership's current management-permission set |
| Member | None | Only actions allowed by the membership's current management-permission set |

Existing admins are initialized with all four central management permissions and existing members with none. Owners always have all four, regardless of the stored array. An owner may assign any subset of the four permissions to an admin or member. Changing a person's role resets that person's permission set to the defaults in this table; it does not preserve a custom set from the previous role.

Only owners can change a member's role, change a member's management permissions, transfer ownership, change the organization slug, or delete the organization. Those powers cannot be delegated through a management permission.

## Central management permissions

| Permission | Allows | Does not allow |
|---|---|---|
| `organization.rename` | Change the organization's display name | Change its slug or delete it |
| `members.invite` | Invite or resend an invitation for the `member` role | Invite an `admin` or `owner` unless the actor is an owner |
| `members.remove` | Remove a member-role membership | Remove an admin or owner unless the actor is an owner; change roles or permissions |
| `invitations.cancel` | Cancel a pending member-role invitation | Cancel an admin or owner invitation unless the actor is an owner |

An owner can target owner, admin, and member roles. A non-owner with a relevant permission can target only the member role. These arrays drive what clients show, but they are not an authorization boundary: database RPCs validate the session, selected organization, current membership, target role, and permission again.

Product-specific permissions, plans, feature access, data policies, billing, seat rules, and workload credentials are outside this permission set and remain owned by each product.

## Invitations and delivery

Creating an invitation saves or refreshes its database record, rotates its acceptance token and expiry, assigns a new delivery ID, and then attempts email delivery. Explicit resend does the same rotation before another delivery attempt. The recipient must sign in with the exact invited email address and review **Invitations** in a Wisent application.

Each pending invitation reports:

- `delivery_id`: the identity of the current delivery;
- `delivery_status`: `pending`, `sent`, or `failed`;
- `delivery_attempts`: attempts made for the current invitation record;
- `delivered_at`: successful delivery time, when present;
- `provider_message_id`: email provider message identity, when present;
- `last_delivery_error`: operator diagnostic for the latest failure, when present.

A saved invitation and a delivered email are distinct outcomes. If persistence succeeds but email delivery fails, clients report **Invitation was saved, but its email was not delivered. Retry it below.** The invitation stays pending with `delivery_status: failed`; it is not rolled back, and an authorized person can use **Retry delivery** or `wisent-auth invitation resend`. Re-inviting the same pending email is also a fresh delivery and invalidates the previous token.

Invitation email is rendered by Wisent's identity integration, not by the client. The delivery ID is also the provider idempotency identity, so retrying the same integration request does not intentionally duplicate a message.

## Native application paths

In a macOS Wisent application:

1. Open the account menu in the application toolbar.
2. Under **Organization**, choose **Manage organization…**.
3. The sheet shows only controls suggested by the selected membership's role and management-permission array.

The organization sheet contains, when allowed:

- **Organization details** for display-name changes and owner-only slug changes;
- **Invite a teammate** for invitation creation;
- **Members**, with owner-only role and management-permission controls and permitted removal actions;
- **Pending invitations**, including delivery state, **Resend** or **Retry delivery**, and **Cancel**;
- owner-only organization deletion and the available leave action.

To review invitations received by the signed-in address, open the same account menu and choose **Review invitations…** under **Invitations**. Accepting selects the joined organization; declining removes the pending invitation.

The fixed Wisent organization is managed centrally. Its local name, slug, and deletion controls are intentionally unavailable.

## Command-line installation

Build the two executable products, then install the CLI and helper in their canonical user locations:

```sh
swift build -c release --product wisent-auth
swift build -c release --product wisent-identity-keychain-helper
install -d "$HOME/.local/bin" "$HOME/.local/libexec/wisent"
install -m 755 .build/release/wisent-auth "$HOME/.local/bin/wisent-auth"
install -m 755 .build/release/wisent-identity-keychain-helper \
  "$HOME/.local/libexec/wisent/WisentIdentityKeychainHelper"
```

`wisent-auth` uses the same `WisentAuthStore` and persisted session as the native clients. Helper discovery is ordered: a helper bundled in an application, `WISENT_IDENTITY_KEYCHAIN_HELPER`, `wisent-identity-keychain-helper` beside the running CLI, then `$HOME/.local/libexec/wisent/WisentIdentityKeychainHelper`. A candidate must be executable. The environment variable is useful for a staged signed helper; it does not make a non-executable file valid.

Commands write one JSON value to standard output. Failures write an actionable message to standard error and exit nonzero. Arguments containing spaces must be shell-quoted. Commands that accept `--organization <id-or-slug>` use that organization for the operation; otherwise they use the persisted selected organization.

## Complete CLI reference

### Authentication and session

| Command | Result |
|---|---|
| `wisent-auth otp request <email>` | Request a six-digit email OTP |
| `wisent-auth otp verify <email> <six-digit-code>` | Verify the OTP, persist the shared session, and resolve organizations and received invitations |
| `wisent-auth status` | Report sign-in state, user identity, accessible organizations, selected organization, and received-invitation count |
| `wisent-auth logout` | Revoke the current access token when reachable and clear the shared persisted session |

OTP verification takes the email again deliberately, so request and verification can be separate processes without persisting an unverified address.

### Organizations

| Command | Result |
|---|---|
| `wisent-auth organization list` | List accessible memberships, including role and `management_permissions` |
| `wisent-auth organization create <name> <slug>` | Create and select an organization owned by the current user |
| `wisent-auth organization select <id-or-slug>` | Persist the selected accessible organization |
| `wisent-auth organization show [--organization <id-or-slug>]` | Show one membership and organization |
| `wisent-auth organization rename <name> [--organization <id-or-slug>]` | Change the display name; requires owner or `organization.rename` |
| `wisent-auth organization slug <slug> [--organization <id-or-slug>]` | Change the slug; owner only |
| `wisent-auth organization leave [--organization <id-or-slug>]` | Leave; an owner must transfer ownership before leaving when required by the server |
| `wisent-auth organization delete [--organization <id-or-slug>]` | Permanently delete; owner only |

### Invitations

| Command | Result |
|---|---|
| `wisent-auth invitation list [--organization <id-or-slug>]` | Return `received` invitations for the signed-in address and `pending` invitations for the selected organization |
| `wisent-auth invitation send <email> [owner\|admin\|member] [--organization <id-or-slug>]` | Save and deliver an invitation; role defaults to `member` |
| `wisent-auth invitation resend <invitation-id> [--organization <id-or-slug>]` | Rotate token, expiry, and delivery ID, then deliver again |
| `wisent-auth invitation accept <invitation-id>` | Accept a received invitation and select the organization |
| `wisent-auth invitation decline <invitation-id>` | Decline a received invitation |
| `wisent-auth invitation cancel <invitation-id> [--organization <id-or-slug>]` | Cancel an organization's pending invitation |

Received-invitation JSON deliberately omits the acceptance token. On a saved-but-undelivered create or resend, the command exits nonzero with the distinct delivery message; listing invitations shows the retained failed delivery record.

### Members and ownership

| Command | Result |
|---|---|
| `wisent-auth member list [--organization <id-or-slug>]` | List members, roles, and `management_permissions` |
| `wisent-auth member role <user-id> <owner\|admin\|member> [--organization <id-or-slug>]` | Set a role and reset permissions to that role's defaults; owner only |
| `wisent-auth member permissions <user-id> [permission ...] [--organization <id-or-slug>]` | Replace the complete central permission set; owner only. Supply no permissions to clear the set |
| `wisent-auth member remove <user-id> [--organization <id-or-slug>]` | Remove a membership when the actor may target that role |
| `wisent-auth ownership transfer <user-id> [--organization <id-or-slug>]` | Transfer ownership to another member; owner only |

For `member permissions`, each value must be exactly one of `organization.rename`, `members.invite`, `members.remove`, or `invitations.cancel`. The operation is exact-set replacement, not additive: omitted permissions are removed. Duplicate values have no additional effect and output follows the canonical order above.

## Refusal boundaries

The server, not the GUI or CLI, makes the final decision. It refuses at least these boundaries:

- no valid authenticated session or no membership in the selected organization;
- an actor without the required central permission;
- any non-owner attempting a slug change, role change, permission change, ownership transfer, or organization deletion;
- a non-owner targeting an owner or admin role with invite, resend, removal, or cancellation;
- an owner leaving when ownership must first be transferred;
- a target member or invitation that does not belong to the selected organization;
- invalid names, slugs, email addresses, roles, permission values, expired invitations, or a slug already in use;
- modification or deletion forbidden for the fixed Wisent organization.

Hiding a control is only a usability hint. Constructing a direct request, modifying client state, or using a stale decoded permission array never grants authority. Human user access tokens must not be substituted for workload credentials, and workload or service tokens must not be presented as human organization memberships.
