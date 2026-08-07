// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "WisentDesktopAuth",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "WisentAuth", targets: ["WisentAuth"]),
        .library(name: "WisentAuthOnboarding", targets: ["WisentAuthOnboarding"]),
        .executable(name: "wisent-auth-onboarding-host", targets: ["WisentAuthOnboardingHost"]),
    ],
    dependencies: [
        .package(path: "../echo"),
    ],
    targets: [
        .target(
            name: "WisentAuth",
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
        .testTarget(
            name: "WisentAuthTests",
            dependencies: ["WisentAuth"]
        ),
    ]
)
