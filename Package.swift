// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "SteamXBridge",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "SteamXBridge", targets: ["SteamXBridgeApp"])
    ],
    targets: [
        .executableTarget(
            name: "SteamXBridgeApp",
            path: "Sources/SteamXBridgeApp"
        ),
        .testTarget(
            name: "SteamXBridgeAppTests",
            dependencies: ["SteamXBridgeApp"],
            path: "Tests/SteamXBridgeAppTests"
        )
    ]
)
