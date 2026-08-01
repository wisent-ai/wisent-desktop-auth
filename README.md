# Wisent Desktop Auth

<!-- wisent-readme-signals:start -->
[![Version check](https://github.com/wisent-ai/wisent-desktop-auth/actions/workflows/version-check.yml/badge.svg?branch=main)](https://github.com/wisent-ai/wisent-desktop-auth/actions/workflows/version-check.yml)
[![Release](https://img.shields.io/github/v/release/wisent-ai/wisent-desktop-auth?display_name=tag&sort=semver)](https://github.com/wisent-ai/wisent-desktop-auth/releases)
[![Downloads](https://img.shields.io/github/downloads/wisent-ai/wisent-desktop-auth/total)](https://github.com/wisent-ai/wisent-desktop-auth/releases)
[![License](https://img.shields.io/github/license/wisent-ai/wisent-desktop-auth)](https://github.com/wisent-ai/wisent-desktop-auth)
[![Discord](https://img.shields.io/badge/Discord-Join%20Wisent-5865F2?logo=discord&logoColor=white)](https://discord.gg/qRjpkthq54)
<!-- wisent-readme-signals:end -->


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
