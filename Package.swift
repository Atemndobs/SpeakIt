// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SpeakIt",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "2.0.0")
    ],
    targets: [
        // Networking, models and credential storage for the ElevenLabs
        // provider. Split out from the app so it can be tested: SpeakIt is an
        // @main executable and executables are awkward to import from a test
        // target. This half has no AppKit dependency.
        .target(name: "ElevenLabsKit"),
        .executableTarget(
            name: "SpeakIt",
            dependencies: ["KeyboardShortcuts", "ElevenLabsKit"]
        ),
        .testTarget(
            name: "ElevenLabsKitTests",
            dependencies: ["ElevenLabsKit"]
        ),
    ]
)
