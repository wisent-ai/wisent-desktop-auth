<!-- Moved out of README.md; the README links here. -->
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

### iOS

The package builds for iOS 17 as well as macOS 14. On iOS it carries
`WisentAuthStore`, `WisentIdentity`, the Supabase client, the shared-session
Keychain store and the OAuth web sign-in; the SwiftUI screens
(`WisentAuthGate` and the sign-in, invitation and organization views) and the
macOS privacy probes are macOS-only, so an iOS app drives the store from its
own views. An iOS app must not keep its own Keychain session or run its own
`ASWebAuthenticationSession`: sign-in, restore and refresh go through the store.

An iOS app and its widgets share one session by naming the shared access group
they are signed with in Info.plist:

```xml
<key>WisentIdentityAccessGroup</key>
<string>$(AppIdentifierPrefix)com.wisent.ios.ai.wisent.identity</string>
```

The value has to end in `.ai.wisent.identity` and appear in the target's
`keychain-access-groups` entitlement. Without it the store keeps the session in
the app's own `<bundle id>.wisent-identity` item, which a widget cannot read.
`WisentPermissionCenter.report(required: [.sharedIdentityKeychain])` answers
`notGranted` in that case. There is no cross-app notification on iOS: another
process's sign-in is seen on the next `start()`.

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

