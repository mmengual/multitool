// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Multitool",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "Multitool",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Multitool",
            linkerSettings: [
                // Sparkle.framework is copied into Contents/Frameworks by scripts/build-app.sh.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        )
    ]
)
