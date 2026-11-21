// swift-tools-version: 6.2
import PackageDescription

// Keystrike: turns MIDI messages (a pad, a button, a knob) into keyboard shortcuts and macros on macOS.
let package = Package(
    name: "Keystrike",
    platforms: [.macOS(.v26)],
    dependencies: [
        // In-app updates (release builds only; see build.sh). Pinned: bump deliberately.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
    ],
    targets: [
        // Engine, no UI: model, MIDI input and parsing, matching, the macro runner and key output.
        .target(
            name: "KeystrikeCore",
            path: "Sources/KeystrikeCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Keystrike",
            dependencies: ["KeystrikeCore", .product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Keystrike",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "KeystrikeCoreTests",
            dependencies: ["KeystrikeCore"],
            path: "Tests/KeystrikeCoreTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
