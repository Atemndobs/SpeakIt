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
        // Engine-agnostic speech logic: sentence scheduling shared by every
        // provider, plus the Kokoro voice catalogue, install layout and daemon
        // protocol. Same reason ElevenLabsKit exists, applied to the parts that
        // are not specific to one vendor.
        .target(name: "SpeechKit"),
        .target(name: "ElevenLabsKit", dependencies: ["SpeechKit"]),
        .executableTarget(
            name: "SpeakIt",
            dependencies: ["KeyboardShortcuts", "ElevenLabsKit", "SpeechKit"]
        ),
        .testTarget(
            name: "ElevenLabsKitTests",
            dependencies: ["ElevenLabsKit", "SpeechKit"]
        ),
        .testTarget(
            name: "SpeechKitTests",
            dependencies: ["SpeechKit"]
        ),
    ]
)
