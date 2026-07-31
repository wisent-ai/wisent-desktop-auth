# Wisent Desktop Auth

Shared Swift package for Wisent macOS applications that need a consistent sign-in UI, Supabase identity session handling, failure classification, and Keychain-backed credential storage.

## Scope

The package provides:

- reusable SwiftUI authentication views;
- observable authentication state for host applications;
- Supabase identity requests and session refresh;
- identity and session models;
- Keychain persistence through the macOS Security framework;
- stable user-facing classification of authentication failures.

It does not own product entitlements, billing, model credentials, workload credentials, or browser-workflow credentials. Host products receive identity state and consult their own service contracts for authorization.

## Dependency

Swift Package Manager:

```swift
.package(
    url: "https://github.com/wisent-ai/wisent-desktop-auth.git",
    from: "0.1.0"
)
```

Applications import the `WisentAuth` library product. Authentication configuration and service URLs remain application-owned; no customer credential is compiled into this package.

## Support and security

Public development source. No stable binary framework distribution is currently promised.

- Issues: [`wisent-ai/wisent-desktop-auth`](https://github.com/wisent-ai/wisent-desktop-auth/issues)
- Vulnerabilities: [private GitHub Security Advisory](https://github.com/wisent-ai/wisent-desktop-auth/security/advisories/new)
- License: Apache License 2.0; see [`LICENSE`](LICENSE)
