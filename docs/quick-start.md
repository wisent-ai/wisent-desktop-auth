<!-- Moved out of README.md; the README links here. -->
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
swift build --package-path "$AUTH_CHECKOUT" --configuration release \
  --product wisent-identity-keychain-helper --scratch-path .build/identity-helper
install -m 0755 .build/identity-helper/release/wisent-identity-keychain-helper \
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
