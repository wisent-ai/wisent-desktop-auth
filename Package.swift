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
    ],
    dependencies: [
        // Consumed by URL, not by sibling path: a path dependency inside a
        // package that others resolve by version can never be found in their
        // .build/checkouts, which silently downgraded every consumer to the
        // last tag that predated this dependency.
        .package(url: "https://github.com/wisent-ai/echo.git", from: "0.1.2"),
        .package(url: "https://github.com/wisent-ai/wisent-components.git", exact: "0.7.1"),
        // The fleet's failure catalogue, pinned to a commit rather than a range:
        // there is only one vocabulary if every consumer names the same one.
        .package(
            url: "https://github.com/wisent-ai/wisent-errors",
            revision: "b01a0c99766b5c6378ecdbf3921108420ba058f1"
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
        .testTarget(
            name: "WisentAuthTests",
            dependencies: ["WisentAuth"]
        ),
    ]
)
