// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AgentCommander",
    platforms: [.macOS(.v26)],
    products: [.executable(name: "AgentCommander", targets: ["AgentCommander"])],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.20.0")
    ],
    targets: [
        .executableTarget(
            name: "AgentCommander",
            dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")],
            resources: [.copy("Resources/HarnessIcons")]
        ),
        .testTarget(name: "AgentCommanderTests", dependencies: ["AgentCommander"])
    ]
)
