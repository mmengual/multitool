// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "StopChattering",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "StopChattering",
            path: "Sources/StopChattering"
        )
    ]
)
