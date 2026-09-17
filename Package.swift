// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AgentSessions",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "AgentSessions", targets: ["AgentSessions"])
    ],
    targets: [
        .executableTarget(
            name: "AgentSessions",
            path: "Sources/AgentSessions"
        )
    ]
)
