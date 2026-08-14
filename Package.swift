// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "WisentDesktopAuth",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "WisentAuth", targets: ["WisentAuth"]),
        .library(name: "WisentPermissions", targets: ["WisentPermissions"]),
        .library(name: "WisentAuthOnboarding", targets: ["WisentAuthOnboarding"]),
        .executable(name: "wisent-auth-onboarding-host", targets: ["WisentAuthOnboardingHost"]),
    ],
    dependencies: [
        // Consumed by URL, not by sibling path: a path dependency inside a
        // package that others resolve by version can never be found in their
        // .build/checkouts, which silently downgraded every consumer to the
        // last tag that predated this dependency.
        .package(url: "https://github.com/wisent-ai/echo.git", from: "0.1.2"),
        .package(url: "https://github.com/wisent-ai/wisent-components.git", revision: "528a955"),
    ],
    targets: [
        .target(
            name: "WisentAuth",
            dependencies: [
                .product(name: "WisentDesignSystem", package: "wisent-components"),
            ],
            linkerSettings: [.linkedFramework("Security")]
        ),
        .target(
            name: "WisentPermissions",
            linkerSettings: [
                .linkedFramework("ApplicationServices"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Security"),
                .linkedFramework("UserNotifications"),
            ]
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
        .testTarget(
            name: "WisentAuthTests",
            dependencies: ["WisentAuth"]
        ),
    ]
)
