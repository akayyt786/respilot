// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ResPilot",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "ResPilotCore", targets: ["ResPilotCore"]),
        .executable(name: "respilot", targets: ["respilot-cli"]),
        .executable(name: "ResPilotApp", targets: ["ResPilotApp"]),
    ],
    targets: [
        .target(
            name: "ResPilotCore",
            path: "Sources/ResPilotCore"
        ),
        .executableTarget(
            name: "respilot-cli",
            dependencies: ["ResPilotCore"],
            path: "Sources/respilot-cli"
        ),
        .executableTarget(
            name: "ResPilotApp",
            dependencies: ["ResPilotCore"],
            path: "Sources/ResPilotApp"
        ),
        .testTarget(
            name: "ResPilotCoreTests",
            dependencies: ["ResPilotCore"],
            path: "Tests/ResPilotCoreTests"
        ),
    ]
)
