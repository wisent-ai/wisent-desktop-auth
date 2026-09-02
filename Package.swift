// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "WisentDesktopAuth",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "WisentAuth", targets: ["WisentAuth"]),
        .library(name: "WisentAuthOnboarding", targets: ["WisentAuthOnboarding"]),
        .executable(name: "wisent-auth-onboarding-host", targets: ["WisentAuthOnboardingHost"]),
        .executable(
            name: "wisent-identity-keychain-helper",
            targets: ["WisentIdentityKeychainHelper"]
        ),
        .executable(name: "wisent-auth", targets: ["WisentAuthCLI"]),
    ],
    dependencies: [
        // Consumed by URL, not by sibling path: a path dependency inside a
        // package that others resolve by version can never be found in their
        // .build/checkouts, which silently downgraded every consumer to the
        // last tag that predated this dependency.
        .package(url: "https://github.com/wisent-ai/echo.git", from: "0.1.2"),
        .package(url: "https://github.com/wisent-ai/wisent-components.git", exact: "0.9.0"),
        // The fleet's failure catalogue, named by exact version rather than by a
        // commit: there is only one vocabulary if every consumer names the same
        // one, and a version is the spelling a reader can compare at a glance.
        // It is taggable because it declares no dependencies of its own, and tag
        // 1.0.0 points at b01a0c99 — the very commit the fleet already resolved,
        // so this names the same tree it always did.
        .package(
            url: "https://github.com/wisent-ai/wisent-errors",
            exact: "1.0.0"
        ),
    ],
    targets: [
        .target(
            name: "WisentAuth",
            dependencies: [
                .product(name: "WisentDesignSystem", package: "wisent-components"),
                .product(name: "WisentErrors", package: "wisent-errors"),
            ],
            resources: [.process("Resources")],
            linkerSettings: [.linkedFramework("Security")]
        ),
        .target(
            name: "WisentAuthOnboarding",
            dependencies: [
                "WisentAuth",
                .product(name: "WisentOnboarding", package: "echo"),
            ],
            path: "Sources/WisentOnboarding",
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "WisentAuthOnboardingHost",
            dependencies: [
                "WisentAuth",
                "WisentAuthOnboarding",
                .product(name: "WisentOnboarding", package: "echo"),
            ],
            path: "Sources/WisentAuthOnboardingHost"
        ),
        .executableTarget(
            name: "WisentIdentityKeychainHelper",
            linkerSettings: [.linkedFramework("Security")]
        ),
        .executableTarget(
            name: "WisentAuthCLI",
            dependencies: ["WisentAuth"]
        ),
        .testTarget(
            name: "WisentAuthTests",
            dependencies: ["WisentAuth"]
        ),
    ]
)
