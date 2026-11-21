import Foundation
import KeystrikeCore

/// `Keystrike --self-test [folder] | --list-inputs | --monitor | --help`
enum CommandLineTool {
    static func run(_ arguments: [String]) -> Int32 {
        switch arguments.first {
        case "--self-test": return SelfTest.run(folder: arguments.dropFirst().first)
        case "--list-inputs": return listInputs()
        case "--monitor": return monitor()
        default:
            print("""
            Keystrike: turns MIDI messages into keyboard shortcuts and macros.
              --list-inputs     The MIDI inputs Core MIDI offers, and whether Keystrike may press keys.
              --monitor         Prints incoming MIDI until Ctrl-C. Presses no keys.
              --self-test [dir] Checks MIDI decoding, matching, the macro runner, saving (in dir, or a temporary
                                folder) and a Core MIDI round trip through a temporary virtual input and port.
                                Presses no keys.
            """)
            return 0
        }
    }

    static func listInputs() -> Int32 {
        let sources = MIDIInput.sources()
        if sources.isEmpty { print("No MIDI inputs.") }
        for source in sources {
            print("\(source.name)\(source.isOffline ? " (offline)" : "")  [unique ID \(source.ref.uniqueID)]")
        }
        print("Accessibility (needed to press keys): \(SystemKeyOutput.isTrusted ? "allowed" : "not allowed") for this process")
        return 0
    }

    static func monitor() -> Int32 {
        let input = MIDIInput()
        input.onMessages = { messages in
            for message in messages { print("\(message.summary)  [\(message.source?.name ?? "?")]") }
            fflush(stdout)
        }
        do {
            try input.start(clientName: "Keystrike Monitor")
        } catch {
            print(error.localizedDescription)
            return 1
        }
        print("Listening to \(input.connectedCount) MIDI inputs. Ctrl-C to stop.")
        fflush(stdout)
        dispatchMain()
    }
}

/// Records what a run would do, without pressing anything.
final class RecordingOutput: KeyOutput, @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [KeyEvent] = []
    var front = RunningApp(pid: 1, bundleID: "com.example.front", name: "Front App")

    var events: [KeyEvent] {
        lock.lock()
        defer { lock.unlock() }
        return _events
    }

    func post(_ event: KeyEvent, toProcess pid: pid_t?) {
        lock.lock()
        _events.append(event)
        lock.unlock()
    }

    func frontmostApp() -> RunningApp? { front }
    func runningApp(bundleID: String) -> RunningApp? { bundleID == front.bundleID ? front : nil }
    func activate(_ app: RunningApp) -> Bool { true }
    func launch(_ app: AppRef) -> RunningApp? { nil }
    func sleep(milliseconds: Int) {}
}

enum SelfTest {
    static func run(folder: String?) -> Int32 {
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
            print("\(ok ? "ok  " : "FAIL") \(name)\(ok ? "" : ": \(detail())")")
            if !ok { failures += 1 }
        }
        let pads = SourceRef(uniqueID: 1, name: "Pads")

        // Decoding
        let words = [MIDITestSender.word(status: 0xB, channel: 0, 119, 1), MIDITestSender.word(status: 0x9, channel: 9, 36, 0)]
        let decoded = MIDIParser.parse(words: words, source: pads)
        check("decodes UMP channel messages", decoded == [
            MIDIMessage(kind: .controlChange, channel: 0, number: 119, value: 1, source: pads),
            MIDIMessage(kind: .noteOff, channel: 9, number: 36, value: 0, source: pads),
        ], "\(decoded)")

        // Matching
        let bounce = Mapping(name: "Bounce", trigger: Trigger(kind: .controlChange, number: 119, value: .exactly(1)),
                             steps: [.shortcut(KeyCode.b, [.control, .command]), .delay(100), Step(.text("ok"))])
        var matcher = Matcher(mappings: [bounce])
        check("CC 119 = 1 fires its mapping", matcher.match(decoded[0]).map(\.name) == ["Bounce"])
        check("CC 119 = 0 doesn't", matcher.match(MIDIMessage(kind: .controlChange, channel: 0, number: 119, value: 0)).isEmpty)

        // Running
        let output = RecordingOutput()
        let outcome = MacroRunner(output: output).run(bounce, keyHoldMS: 5)
        let expected: [KeyEvent] = [
            .key(code: 0x3B, down: true, flags: KeyCatalog.cgFlags([.control]).rawValue),
            .key(code: 0x37, down: true, flags: KeyCatalog.cgFlags([.control, .command]).rawValue),
            .key(code: KeyCode.b, down: true, flags: KeyCatalog.cgFlags([.control, .command]).rawValue),
            .key(code: KeyCode.b, down: false, flags: KeyCatalog.cgFlags([.control, .command]).rawValue),
            .key(code: 0x37, down: false, flags: KeyCatalog.cgFlags([.control]).rawValue),
            .key(code: 0x3B, down: false, flags: 0),
            .text("o", down: true), .text("o", down: false), .text("k", down: true), .text("k", down: false),
        ]
        if case .finished = outcome {
            check("runs a shortcut, a wait and text in order", output.events == expected, "\(output.events)")
        } else {
            check("runs a shortcut, a wait and text in order", false, "\(outcome)")
        }
        var onlyLogic = bounce
        onlyLogic.target = Target(app: AppRef(bundleID: "com.apple.logic10", name: "Logic Pro"), mode: .whenFrontmost)
        check("skips when its app isn't in front",
              MacroRunner(output: RecordingOutput()).run(onlyLogic, keyHoldMS: 5) == .skipped("Logic Pro isn't in front"))

        // Saving
        let base = folder.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("keystrike-self-test-\(UUID().uuidString)")
        let store = Store(folder: base)
        let setup = Setup(mappings: [bounce, onlyLogic])
        do {
            try store.save(setup)
            if case .loaded(let loaded) = store.load() {
                check("saves and loads mappings", loaded == setup)
            } else {
                check("saves and loads mappings", false, "couldn't load")
            }
        } catch {
            check("saves and loads mappings", false, error.localizedDescription)
        }
        if folder == nil { try? FileManager.default.removeItem(at: base) }

        // Core MIDI round trip: a temporary virtual input and Keystrike's own port, in this process.
        let midiOutput = RecordingOutput()
        let engine = Engine(output: midiOutput)
        engine.apply(Setup(mappings: [bounce]))
        let arrived = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var heard: Set<String> = []
        engine.onMessage = { message, fired in
            guard message.number == 119, !fired.isEmpty else { return }
            lock.lock()
            heard.insert(message.source?.name ?? "?")
            lock.unlock()
            arrived.signal()
        }
        let input = MIDIInput()
        input.onMessages = { engine.receive($0) }
        do {
            try input.start(clientName: "Keystrike Self-Test")
            try input.setVirtualPort(enabled: true, name: "Keystrike Self-Test Port", uniqueID: nil)
            let sender = try MIDITestSender(name: "Keystrike Self-Test Pads")
            input.reconnect()
            sender.emit([words[0]])
            let sent = sender.send([words[0]], toDestinationNamed: "Keystrike Self-Test Port")
            let both = arrived.wait(timeout: .now() + 5) == .success && arrived.wait(timeout: .now() + 5) == .success
            engine.runner.waitUntilIdle()
            lock.lock()
            let sources = heard
            lock.unlock()
            check("Core MIDI: a virtual input and the Keystrike port both fire the mapping", sent && both && sources.count == 2,
                  "port found: \(sent), heard from: \(sources.sorted())")
            check("Core MIDI: each run pressed its keys", midiOutput.events.count == expected.count * 2,
                  "\(midiOutput.events.count) events")
        } catch {
            check("Core MIDI round trip", false, error.localizedDescription)
        }

        print("Accessibility (needed to press keys): \(SystemKeyOutput.isTrusted ? "allowed" : "not allowed") for this process")
        print(failures == 0 ? "Self-test passed." : "Self-test failed: \(failures) problem(s).")
        return failures == 0 ? 0 : 1
    }
}
