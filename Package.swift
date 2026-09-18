// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "WisentDesktopAuth",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "WisentAuth", targets: ["WisentAuth"]),
        .executable(
            name: "wisent-identity-keychain-helper",
            targets: ["WisentIdentityKeychainHelper"]
        ),
        .executable(name: "wisent-auth", targets: ["WisentAuthCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/wisent-ai/wisent-components.git", exact: "0.9.1"),
        // The fleet's failure catalogue, named by version: a package that
        // names a dependency by commit cannot itself be required by version,
        // and every desktop app requires this one by exact tag. Tag 1.1.0
        // points at be5aaa0 on wisent-errors main, past 559f63f (the explicit
        // policy refusals this package reads since 0.3.6).
        .package(url: "https://github.com/wisent-ai/wisent-errors", exact: "1.1.0"),
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
        .testTarget(
            name: "KeychainHelperJourneyTests",
            dependencies: ["WisentIdentityKeychainHelper", "WisentAuthCLI"],
            path: "Tests/keychain"
        ),
    ]
)
