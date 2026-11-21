// swift-tools-version: 6.2
import PackageDescription

// MidiPress: turns MIDI messages (a pad, a button, a knob) into keyboard shortcuts and macros on macOS.
let package = Package(
    name: "MidiPress",
    platforms: [.macOS(.v26)],
    dependencies: [
        // In-app updates (release builds only; see build.sh). Pinned: bump deliberately.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
    ],
    targets: [
        // Engine, no UI: model, MIDI input and parsing, matching, the macro runner and key output.
        .target(
            name: "MidiPressCore",
            path: "Sources/MidiPressCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "MidiPress",
            dependencies: ["MidiPressCore", .product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/MidiPress",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "MidiPressCoreTests",
            dependencies: ["MidiPressCore"],
            path: "Tests/MidiPressCoreTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
