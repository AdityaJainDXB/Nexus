// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Nexus",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Nexus", targets: ["Nexus"]),
        .executable(name: "nexusctl", targets: ["nexusctl"]),
        .library(name: "NexusCore", targets: ["NexusCore"]),
    ],
    targets: [
        .target(
            name: "NexusCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(name: "Nexus", dependencies: ["NexusCore"]),
        .executableTarget(name: "nexusctl", dependencies: ["NexusCore"]),
        .testTarget(name: "NexusCoreTests", dependencies: ["NexusCore"]),
    ]
)
