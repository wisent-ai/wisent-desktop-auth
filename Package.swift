// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "WisentDesktopAuth",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "WisentAuth", targets: ["WisentAuth"]),
    ],
    targets: [
        .target(
            name: "WisentAuth",
            linkerSettings: [.linkedFramework("Security")]
        ),
        .testTarget(
            name: "WisentAuthTests",
            dependencies: ["WisentAuth"]
        ),
    ]
)
