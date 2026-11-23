// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AgentCommander",
    platforms: [.macOS(.v26)],
    products: [.executable(name: "AgentCommander", targets: ["AgentCommander"])],
    targets: [
        .executableTarget(
            name: "AgentCommander",
            resources: [.copy("Resources/HarnessIcons")]
        )
    ]
)
