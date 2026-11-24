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
            dependencies: [
                "MultitoolShared",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/Multitool",
            linkerSettings: [
                // Sparkle.framework is copied into Contents/Frameworks by scripts/build-app.sh.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        ),
        // Read-only privileged helper, run as root by launchd (SMAppService.daemon).
        .executableTarget(
            name: "MultitoolHelper",
            dependencies: ["MultitoolShared"],
            path: "Sources/MultitoolHelper"
        ),
        // Reads and writes macOS's per-app menu bar switches. Signed with Developer ID and
        // an app-group entitlement by scripts/build-app.sh, launched by the app.
        .executableTarget(
            name: "MultitoolVisibility",
            path: "Sources/MultitoolVisibility"
        ),
        // What the app and the helper share: the XPC protocol and the process sampler.
        .target(
            name: "MultitoolShared",
            path: "Sources/MultitoolShared"
        ),
    ]
)
