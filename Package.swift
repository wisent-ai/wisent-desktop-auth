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
