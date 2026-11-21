import AppKit
import MidiPressCore
import SwiftUI

/// A made-up setup for screenshots and demos: no MIDI is opened, no keys are pressed, nothing is saved.
enum Demo {
    static let logic = AppRef(bundleID: "com.apple.logic10", name: "Logic Pro")
    static let finalCut = AppRef(bundleID: "com.apple.FinalCut", name: "Final Cut Pro")
    static let notes = AppRef(bundleID: "com.apple.Notes", name: "Notes")
    static let runningApps = [logic, finalCut, notes, AppRef(bundleID: "com.apple.Safari", name: "Safari")]
    /// Screenshots draw symbols instead of the real Mac's app icons.
    static let appSymbols = [
        logic.bundleID: "waveform", finalCut.bundleID: "film", notes.bundleID: "note.text", "com.apple.Safari": "safari",
    ]

    static let launchpad = SourceRef(uniqueID: 101, name: "Pad Controller")
    static let faders = SourceRef(uniqueID: 102, name: "Fader Box")

    static var setup: Setup {
        Setup(mappings: [
            Mapping(name: "Bounce in Place",
                    trigger: Trigger(kind: .controlChange, channel: 0, number: 119, value: .exactly(1)),
                    target: Target(app: logic, mode: .bringToFront, returnToPrevious: true),
                    steps: [.shortcut(KeyCode.b, [.control, .command]), .delay(400), .shortcut(KeyCode.returnKey)]),
            Mapping(name: "Zoom In", trigger: Trigger(kind: .controlChange, number: 20, value: .exactly(1), source: faders),
                    target: Target(app: logic), steps: [.shortcut(KeyCode.rightArrow, [.command])]),
            Mapping(name: "Zoom Out", trigger: Trigger(kind: .controlChange, number: 20, value: .exactly(127), source: faders),
                    target: Target(app: logic), steps: [.shortcut(KeyCode.leftArrow, [.command])]),
            Mapping(name: "Nudge Region Right ×4", trigger: Trigger(kind: .noteOn, channel: 9, number: 38),
                    target: Target(app: logic), steps: [.shortcut(KeyCode.rightArrow, [.option], times: 4)], stepPauseMS: 30),
            Mapping(name: "Blade at Playhead", trigger: Trigger(kind: .noteOn, channel: 9, number: 36),
                    target: Target(app: finalCut), steps: [.shortcut(KeyCode.b, [.command])]),
            Mapping(name: "Session Note", trigger: Trigger(kind: .programChange, number: 5),
                    target: Target(app: notes, mode: .bringToFront, returnToPrevious: true),
                    steps: [.shortcut(0x2D, [.command]), Step(.text("Take 3: keep the second chorus")), .shortcut(KeyCode.returnKey)]),
            Mapping(name: "Save Everywhere", isEnabled: false, trigger: Trigger(kind: .controlChange, number: 64, value: .between(64, 127), fire: .onEnter),
                    steps: [.shortcut(KeyCode.s, [.command])]),
        ])
    }

    static var sources: [MIDISourceInfo] {
        [MIDISourceInfo(ref: launchpad, isOffline: false), MIDISourceInfo(ref: faders, isOffline: false),
         MIDISourceInfo(ref: SourceRef(uniqueID: 103, name: "IAC Driver Bus 1"), isOffline: false)]
    }

    static func log(for setup: Setup) -> [LogLine] {
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        func at(_ seconds: Double, _ kind: LogLine.Kind) -> LogLine { LogLine(date: start + seconds, kind: kind) }
        return [
            at(0.0, .midi(MIDIMessage(kind: .controlChange, channel: 0, number: 21, value: 64, source: faders), fired: [])),
            at(0.4, .midi(MIDIMessage(kind: .controlChange, channel: 0, number: 20, value: 1, source: faders), fired: ["Zoom In"])),
            at(0.41, .run(name: "Zoom In", .finished(milliseconds: 14))),
            at(1.2, .midi(MIDIMessage(kind: .controlChange, channel: 0, number: 20, value: 127, source: faders), fired: ["Zoom Out"])),
            at(1.21, .run(name: "Zoom Out", .finished(milliseconds: 13))),
            at(3.0, .midi(MIDIMessage(kind: .noteOn, channel: 9, number: 36, value: 98, source: launchpad), fired: ["Blade at Playhead"])),
            at(3.01, .run(name: "Blade at Playhead", .skipped("Final Cut Pro isn't in front"))),
            at(3.1, .midi(MIDIMessage(kind: .noteOff, channel: 9, number: 36, value: 0, source: launchpad), fired: [])),
            at(5.0, .midi(MIDIMessage(kind: .controlChange, channel: 0, number: 119, value: 1, source: launchpad), fired: ["Bounce in Place"])),
            at(5.62, .run(name: "Bounce in Place", .finished(milliseconds: 612))),
            at(5.2, .midi(MIDIMessage(kind: .controlChange, channel: 0, number: 119, value: 0, source: launchpad), fired: [])),
        ]
    }

    @MainActor static func load(into model: AppModel) {
        let setup = setup
        model.loadDemo(setup, sources: sources, log: log(for: setup))
    }
}

/// Development aid: `MIDIPRESS_SNAPSHOT=<folder>` loads the demo setup, saves PNGs of the main states, each as
/// `<state>-light.png` and `<state>-dark.png`, and quits. Needs Screen Recording permission for the terminal.
enum Snapshot {
    static func runIfRequested(_ model: AppModel) {
        guard let folder = ProcessInfo.processInfo.environment["MIDIPRESS_SNAPSHOT"].map({ URL(fileURLWithPath: $0, isDirectory: true) })
        else { return }
        Task { @MainActor in
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            @MainActor func both(_ name: String, window: (@MainActor () -> NSWindow?)? = nil) async {
                for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
                    NSApp.appearance = NSAppearance(named: appearance)
                    try? await Task.sleep(for: .milliseconds(800))
                    if let window = window?() ?? mainWindow { capture(window, folder, "\(name)-\(suffix)") }
                }
            }
            NSApp.activate()
            mainWindow?.makeKeyAndOrderFront(nil)
            resize(1180, 800)
            try? await Task.sleep(for: .seconds(1))
            await both("mapping")  // Bounce in Place: When, Where, Do

            if let session = model.setup.mappings.first(where: { $0.name == "Session Note" }) { model.selection = session.id }
            await both("macro")

            model.selection = model.setup.mappings[1].id
            model.learning = model.setup.mappings[1].id
            await both("learning")
            model.learning = nil

            model.selection = model.setup.mappings.first?.id
            model.isTrusted = false
            await both("no-permission")
            model.isTrusted = true

            let demo = model.setup
            model.setup = Setup()
            model.selection = nil
            await both("empty")
            model.setup = demo
            model.selection = demo.mappings.first?.id

            if let item = NSApp.mainMenu?.items.first(where: { $0.title == "Mappings" })?.submenu,
               let index = item.items.firstIndex(where: { $0.title == "MIDI Monitor" }) {
                item.performActionForItem(at: index)
                try? await Task.sleep(for: .milliseconds(800))
            }
            if let monitor = NSApp.windows.first(where: { $0.isVisible && $0.title == "MIDI Monitor" }) {
                monitor.setContentSize(NSSize(width: 700, height: 420))
                await both("monitor", window: { monitor })
                monitor.close()
            } else {
                FileHandle.standardError.write(Data("Couldn't open the MIDI Monitor for a screenshot.\n".utf8))
            }

            if let appMenu = NSApp.mainMenu?.items.first?.submenu,
               let index = appMenu.items.firstIndex(where: { $0.title.hasPrefix("Settings") }) {
                appMenu.performActionForItem(at: index)
            }
            try? await Task.sleep(for: .milliseconds(900))
            if let settings = NSApp.windows.first(where: { $0.isVisible && $0 != mainWindow && $0.title != "MIDI Monitor"
                && ($0.identifier?.rawValue.localizedCaseInsensitiveContains("settings") ?? false) }) {
                await both("settings", window: { settings })
                settings.close()
            } else {
                let windows = NSApp.windows.map { "\($0.title)|\($0.identifier?.rawValue ?? "-")|\($0.isVisible)" }
                FileHandle.standardError.write(Data("Couldn't open Settings for a screenshot: \(windows)\n".utf8))
            }

            mainWindow?.makeKeyAndOrderFront(nil)
            resize(860, 540)
            await both("minimum-size")
            NSApp.terminate(nil)
        }
    }

    @MainActor static func resize(_ width: CGFloat, _ height: CGFloat) {
        guard let window = mainWindow else { return }
        var frame = window.frame
        frame.origin.y += frame.height - height
        frame.size = NSSize(width: width, height: height)
        window.setFrame(frame, display: true)
    }

    @MainActor static var mainWindow: NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.contentView != nil && $0.title == "MidiPress" }
            ?? NSApp.windows.first { $0.isVisible && $0.contentView != nil }
    }

    @MainActor static func capture(_ window: NSWindow, _ folder: URL, _ name: String) {
        let url = folder.appendingPathComponent(name + ".png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", url.path]
        try? process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 || !FileManager.default.fileExists(atPath: url.path) {
            FileHandle.standardError.write(Data("Couldn't capture \(name): screencapture needs Screen Recording permission.\n".utf8))
        }
    }
}
