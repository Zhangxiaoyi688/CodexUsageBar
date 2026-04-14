// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CodexUsageBar",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "CodexUsageBar", targets: ["CodexUsageBar"]),
        .executable(name: "CodexUsageSmokeTest", targets: ["CodexUsageSmokeTest"])
    ],
    targets: [
        .target(name: "CodexUsageCore"),
        .executableTarget(
            name: "CodexUsageBar",
            dependencies: ["CodexUsageCore"]
        ),
        .executableTarget(
            name: "CodexUsageSmokeTest",
            dependencies: ["CodexUsageCore"]
        )
    ]
)
