<!-- wisent-banner:start -->
<p align="center">
  <img src="assets/readme-banner.webp" alt="wisent-desktop-auth by Wisent" width="100%">
</p>
<!-- wisent-banner:end -->

<!-- wisent-readme-signals:start -->
[![Source](https://img.shields.io/badge/GitHub-Source-181717?logo=github)](https://github.com/wisent-ai/wisent-desktop-auth) [![Issues](https://img.shields.io/badge/GitHub-Issues-181717?logo=github)](https://github.com/wisent-ai/wisent-desktop-auth/issues) [![Wisent](https://img.shields.io/badge/Wisent-Website-0B0B0B)](https://wisent.com) [![Discord](https://img.shields.io/badge/Discord-Join-5865F2?logo=discord&logoColor=white)](https://discord.gg/qRjpkthq54) [![LinkedIn](https://img.shields.io/badge/LinkedIn-Follow-0A66C2?logo=linkedin&logoColor=white)](https://www.linkedin.com/company/wisent-ai/) [![X](https://img.shields.io/badge/X-Follow-000000?logo=x&logoColor=white)](https://x.com/wisentai) [![Enterprise](https://img.shields.io/badge/Enterprise-Book%20a%20call-0B0B0B?logo=calendly)](https://calendly.com/lbartoszcze)
<!-- wisent-readme-signals:end -->

# Wisent Desktop Auth

One Sign-In for Every Wisent App on Your Mac.

A growing fleet of desktop applications otherwise means a growing collection of
login screens, Keychain bugs and different ways a session dies on a Monday
morning. Wisent Desktop Auth is the one Swift package they share: sign-in,
organization selection, member management, session refresh and the Keychain
persistence underneath. Failures come back classified, so an app can tell an
expired session from a network problem from a revoked seat. Add the package and
the login screen is already finished.

Sign In Once. Everywhere.

It authenticates a person and exposes selected organization identity to a host
application. It does not decide product authorization, entitlements, billing,
model/workload credentials, or access to customer resources.

[Quick start](#quick-start) · [Public interfaces](#primary-interfaces) ·
[Trust boundary](#security-and-privacy) ·
[Canonical repository](https://github.com/wisent-ai/wisent-desktop-auth)

Current boundary: public Swift package source for macOS 14+ using Swift tools
5.10 and the macOS Security framework. No stable binary framework, hosted identity
SLA, or independent product entitlement service is promised here.

## Problem and intended users

Native product applications otherwise tend to implement subtly different login,
token storage, refresh, organization selection, invitation review, and outage UI.
Those differences produce inconsistent security behavior and can misreport an
identity-provider outage as a wrong password or missing account.

Wisent Desktop Auth serves:

- **Wisent macOS application developers** embedding a standard SwiftUI identity
  gate;
- **organization members** signing in by email OTP, Apple, Google, or GitHub and
  choosing the organization in which the host app will operate;
- **organization owners/admins** creating, renaming, switching and managing
  organizations, invitations, members, roles and ownership through approved
  Supabase RPCs;
- **operators** relying on a stable failure taxonomy and private diagnostics when
  identity infrastructure fails.

## Product boundaries

### Included

- `WisentAuth` Swift library product for macOS 14+;
- `WisentPermissionCenter`, a read-only permission-status API that never
  triggers a macOS consent dialog;
- reusable `WisentAuthGate` SwiftUI view and account/organization UI;
- `WisentAuthStore` observable state machine;
- email one-time-code request and verification;
- optional Apple, Google and GitHub OAuth via `ASWebAuthenticationSession` with
  PKCE;
- session restoration, refresh before expiry, sign-out, and live cross-process
  propagation of shared session and organization changes;
- organization creation, discovery, rename, slug update, selection, switching,
  leaving, deletion and ownership transfer;
- typed central organization-management permissions and exact-set assignment;
- invitation review, server-rendered email delivery and resend status, plus
  member/invitation listing, role management, removal, and cancellation;
- the `wisent-auth` JSON CLI backed by the same store and persisted session;
- shared access and refresh token persistence in macOS Keychain, with one-time
  migration from each host's former bundle-scoped session;
- classified user-safe failures and separately logged operator diagnostics.

### Explicit non-goals and limitations

- Authentication is not authorization. Organization-scoped host requests use
  `Authorization: Bearer <Supabase JWT>` and
  `X-Wisent-Organization-ID: <uuid>`; every host service must validate both and
  verify membership server-side.
- `WisentOrganization.managementPermissions` and member permission arrays are UI
  capability hints. Supabase RPCs/RLS remain the enforcement boundary, and owner
  authority cannot be manufactured by client state.
- The four central permissions do not describe product-specific authorization.
  Product plans, entitlements, feature gates, data policies, and billing remain
  owned by each product.
- It does not store or broker model-provider, workload, browser-workflow, payment,
  or customer-data credentials.
- It does not provision a Supabase project, database schema, email delivery,
  OAuth provider, or callback registration.
- The convenience store initializer uses production defaults plus process
  environment overrides. A custom `WisentAuthConfiguration` cannot currently be
  injected through the package's public store initializer.
- Host applications own bundle identity, URL-scheme declaration, app signing,
  sandbox/entitlements, and release configuration.
- A valid client session can still be unauthorized, revoked, expired, or bound to
  an organization the downstream product does not serve.
- Network/provider availability and Supabase operational guarantees are outside
  this package.

### Supported authentication paths

| Path | Client behavior | External requirement |
|---|---|---|
| Apple OAuth | browser session with PKCE callback | configured Supabase provider and URL scheme |
| Email OTP | request code, verify code, persist session | Supabase email auth/delivery |
| Google OAuth | browser session with PKCE callback | configured Supabase provider and URL scheme |
| GitHub OAuth | browser session with PKCE callback | configured Supabase provider and URL scheme |
| Restore/refresh | load Keychain session, refresh near expiry | valid refresh token and reachable identity service |

OAuth can be disabled with `WISENT_AUTH_OAUTH_ENABLED=0` while retaining email OTP.

## Core use cases

### Gate a native product surface

- **Actor:** a Wisent macOS user.
- **Initial state:** the host creates a `WisentAuthStore` and wraps protected UI in
  `WisentAuthGate`.
- **Outcome:** protected content renders only after a session and organization
  resolve to `.ready`; the identity is injected into SwiftUI environment values.
- **Boundary:** the host still sends the token to its own service and handles
  authorization refusal.

### Restore a prior identity

- **Actor:** a returning local user.
- **Initial state:** this app bundle has a stored Keychain identity.
- **Outcome:** a sufficiently fresh shared session is restored, or a near-expiry
  session is refreshed after re-reading the Keychain item so another process's
  rotated refresh token is never deliberately reused. Session, organization
  switch and sign-out changes propagate live between Wisent apps through macOS
  distributed notifications.
- **Boundary:** an authentication rejection clears the invalid session; transient
  infrastructure failure is classified rather than deliberately erasing it.

### Manage the organization lifecycle

- **Actor:** a selected-organization member, admin or owner.
- **Initial state:** the server-returned membership role and central permission
  array suggest the requested operation and the session is fresh.
- **Outcome:** users can create, reload, switch and leave organizations; owners
  can delegate any subset of rename, invite, removal, and cancellation to
  non-owners; owners retain exclusive lifecycle, role, permission, transfer, and
  deletion operations.
- **Boundary:** roles and management permissions drive presentation, but server
  authorization is authoritative; client visibility cannot grant permission.

## How it works

```text
Host SwiftUI application
  └─ WisentAuthGate(store)
          │ .task -> store.start()
          ▼
    WisentAuthStore state machine
          │
          ├─ Supabase Auth REST (OTP, OAuth/PKCE, refresh, logout)
          ├─ Supabase REST/RPC (organizations, invites, members)
          ├─ macOS Keychain (stored session + selected organization ID)
          ├─ macOS distributed notifications (session/org/sign-out propagation)
          └─ WisentFailureClassifier (safe UI message + operator log)
                         │
                         ▼
      WisentIdentity(user, email, organization, access token)
                         │
                         ▼
              host product service authorization
```

The store is `@MainActor`. Network requests run through an actor-backed identity
client. The gate calls `start()` once, renders each authentication state, and
places the ready `WisentIdentity` in the SwiftUI environment.

## Quick start

### Prerequisites

- macOS 14 or newer;
- Swift 5.10 or newer;
- a host app with a stable bundle identifier;
- a Supabase identity project whose auth, organization tables/RPCs, RLS, email,
  and chosen OAuth providers match this package's contract.

Add the package:

```swift
.package(
    url: "https://github.com/wisent-ai/wisent-desktop-auth.git",
    from: "0.1.0"
)
```

Add the product to the application target:

```swift
.product(name: "WisentAuth", package: "wisent-desktop-auth")
```

Packaged hosts must build the shared Keychain helper from the resolved package
checkout, place it at
`Contents/Helpers/WisentIdentityKeychainHelper`, and sign it with the same stable
Wisent identity and the fixed identifier
`ai.wisent.identity.keychain-helper`:

```sh
AUTH_CHECKOUT=.build/checkouts/wisent-desktop-auth
"$AUTH_CHECKOUT/scripts/build-keychain-helper.sh" \
  "$APP_BUNDLE/Contents/Helpers/WisentIdentityKeychainHelper"
codesign --force --identifier ai.wisent.identity.keychain-helper \
  --sign "$CODESIGN_IDENTITY" \
  "$APP_BUNDLE/Contents/Helpers/WisentIdentityKeychainHelper"
```

The helper sends the session only through inherited pipes and owns the one
shared login-Keychain item. Unbundled clients discover an executable helper from
`WISENT_IDENTITY_KEYCHAIN_HELPER`, a `wisent-identity-keychain-helper` beside
their executable, or
`$HOME/.local/libexec/wisent/WisentIdentityKeychainHelper`, in that order after
the application-bundled location.

Install the shared JSON CLI and its helper for the current user:

```sh
swift build -c release --product wisent-auth
swift build -c release --product wisent-identity-keychain-helper
install -d "$HOME/.local/bin" "$HOME/.local/libexec/wisent"
install -m 755 .build/release/wisent-auth "$HOME/.local/bin/wisent-auth"
install -m 755 .build/release/wisent-identity-keychain-helper \
  "$HOME/.local/libexec/wisent/WisentIdentityKeychainHelper"
```

See [Organization administration](docs/organization-administration.md) for the
role and permission matrices, invitation delivery semantics, GUI paths, complete
CLI reference, and server refusal boundaries.

Wrap the application content:

```swift
import SwiftUI
import WisentAuth

@main
struct ExampleApp: App {
    @StateObject private var auth = WisentAuthStore(productName: "Example")

    var body: some Scene {
        WindowGroup {
            WisentAuthGate(store: auth) {
                ProductRootView()
            }
        }
    }
}
```

Read the selected identity in a descendant view:

```swift
struct ProductRootView: View {
    @Environment(\.wisentIdentity) private var identity

    var body: some View {
        Text(identity?.organization.name ?? "No organization")
    }
}
```

Expected result: the gate restores a valid stored session or displays sign-in;
after identity and organization resolution it renders `ProductRootView`.

For OAuth, register the callback scheme in the host app's `CFBundleURLTypes` and
with the identity provider. The default redirect is
`<bundle-identifier>://auth-callback`.

## Primary interfaces

### `WisentAuthStore`

Create one store per host application identity surface:

```swift
let auth = WisentAuthStore(productName: "Weles")
```

Public observable state includes status, session, organization list/selection,
identity, busy flags, pending invitations with delivery state, management lists
with typed permission arrays, and classified failures. Public operations cover
start, OTP/OAuth sign-in, email change, organization lifecycle and selection,
invitation send/resend/review/cancellation, exact-set member permission updates,
role/removal/ownership management, failure retry, and sign-out.

Do not copy the access token into app preferences, logs, crash metadata, or UI.
Use it only for authorized requests to the host product service.

### `WisentAuthGate`

```swift
WisentAuthGate(store: auth) {
    ProductRootView()
}
```

The gate owns the common restoring, signed-out, code-entry, invitation,
organization-picker, ready-content, account-toolbar, and organization-management
presentation. Host content remains application-owned.

### Environment identity

```swift
@Environment(\.wisentIdentity) private var identity: WisentIdentity?
```

A ready identity exposes:

- user ID and email;
- selected organization ID, slug, name, raw compatibility role, typed
  `organization.organizationRole: WisentOrganizationRole?`, and typed
  `organization.managementPermissions`;
- current access token.

Authorize an organization-scoped product request without constructing a header
dictionary:

```swift
guard let identity else { return }
var request = URLRequest(url: endpoint)
identity.authorize(&request)
```

This writes exactly `Authorization: Bearer <Supabase JWT>` and
`X-Wisent-Organization-ID: <uuid>`. User-owned resources remain user-scoped;
services must not infer organization ownership for them. Workload and service
tokens are not human login sessions and must not be wrapped in a manufactured
`WisentIdentity` or organization context.

Absence means the protected content is outside a ready identity state; do not
manufacture an anonymous/product fallback.

### Configuration

The public convenience initializer uses:

| Variable | Meaning | Default behavior |
|---|---|---|
| `SUPABASE_URL` | identity API base | Wisent production project URL |
| `SUPABASE_ANON_KEY` | public Supabase client key | Wisent production anon key |
| `WISENT_AUTH_CALLBACK_SCHEME` | app URL callback scheme | host bundle identifier |
| `WISENT_AUTH_REDIRECT_URL` | OAuth redirect URL | `<scheme>://auth-callback` |
| `WISENT_AUTH_OAUTH_ENABLED` | OAuth presentation | enabled unless exactly `0` |

The canonical production identity URL is
`https://alvaewvbyxpgwdpugnxy.supabase.co`.

The Supabase anon key identifies the public client; it is not a service-role
secret. Never put a service-role key into this client package or host app.

## Failure semantics

The library classifies failures by stable code, service, impact, retryability,
and user-safe title/message. It distinguishes authentication rejection from
rate limiting, network, timeout, upstream identity, storage, invalid response,
configuration, cancellation, and unknown failures.

Raw URLs, upstream bodies, and Keychain status details are reserved for operator
logging and do not enter the public `WisentFailure` UI payload. A host should use
the classified failure rather than parsing text in `errorMessage`.

## Security and privacy

- Access and refresh tokens are saved as one generic login-Keychain item owned
  by the selected executable `WisentIdentityKeychainHelper`. Packaged clients
  sign an identical helper identifier with the same Wisent signing identity, so
  Keychain evaluates one designated requirement without a restricted
  access-group entitlement or provisioning profile.
- Keychain storage protects persistence; it does not prevent a compromised host
  process from reading the public in-memory identity/access token.
- The default shared session begins refresh five minutes before expiry. The
  store re-reads the Keychain item immediately before refresh so it does not use
  a token already rotated by another process. Servers must still validate every
  request and handle revocation/expiry.
- Session replacement, organization switching and sign-out are propagated
  between running Wisent apps with a system distributed notification. The
  notification contains no token or other secret; recipients re-read Keychain.
- OAuth uses `ASWebAuthenticationSession`, a five-minute client timeout, and PKCE
  S256. Callback scheme/provider registration must exactly match the host.
- Email addresses, user IDs, organization metadata, invitations, membership,
  roles, access tokens, and refresh tokens are sensitive identity data.
- Do not log tokens, upstream response bodies, invitation tokens, or full request
  headers. Restrict operator logs and retention.
- Supabase RLS and `authorize_organization(target_org_id uuid)` must fail closed.
  UI role checks, selected organization IDs and request headers are
  attacker-controlled client input.
- Share only the user's Wisent identity session. Provider, workload, browser,
  payment, customer-resource and service credentials remain outside the shared
  store and under their owning product or Skarbiec boundary.
- Production GUI hosts must package and sign the fixed-identifier helper.
  Unbundled tools use only an executable helper discovered through the documented
  environment, sibling, or canonical user-libexec locations; otherwise storage
  falls back to the caller's isolated Keychain item.

## Operational model

- **Configuration:** bundle identifier, public Supabase URL/anon key, callback
  scheme/redirect, and OAuth enablement.
- **State:** observable in-memory state plus Keychain session and selected
  organization ID.
- **Credentials:** user access/refresh tokens in Keychain; no service-role or
  downstream workload credentials.
- **Observability:** classified user-safe failures and subsystem diagnostics via
  the package's operator logger.
- **Recovery:** retry when classified retryable; reauthenticate on rejected/expired
  identity; repair configuration/provider callback/RLS at the owning system.
- **Cost:** identity-provider requests, email delivery, OAuth/provider service,
  database RPCs, and operational support; no billing logic is implemented here.

## Project status and support

- **Maturity:** public development Swift package used by Wisent macOS products.
- **Compatibility:** macOS 14+, Swift tools 5.10, SwiftUI,
  AuthenticationServices, and Security.
- **Distribution:** Swift Package Manager source dependency; no stable binary
  framework distribution is promised.
- **Issues:** [`wisent-ai/wisent-desktop-auth`](https://github.com/wisent-ai/wisent-desktop-auth/issues).
- **Security:** use private GitHub Security Advisories; never attach tokens,
  invitation material, upstream identity bodies, customer organization/member
  data, callback secrets, or Keychain exports to a public issue.
- **License:** Apache License 2.0; see [`LICENSE`](LICENSE).
