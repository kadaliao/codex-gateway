// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CodexGatewayApp",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "CodexGatewayApp",
            path: "Sources/CodexGatewayApp"
        ),
        .testTarget(
            name: "CodexGatewayAppTests",
            dependencies: ["CodexGatewayApp"],
            path: "Tests/CodexGatewayAppTests"
        ),
    ]
)
