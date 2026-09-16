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
        .package(
            url: "https://github.com/wisent-ai/wisent-errors",
            revision: "559f63fbe2c6ed3f5e6faac807e1a3363928689b"
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
