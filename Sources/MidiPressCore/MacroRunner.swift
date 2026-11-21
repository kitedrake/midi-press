import CoreGraphics
import Foundation

/// A running app, as the runner sees it.
public struct RunningApp: Hashable, Sendable {
    public var pid: pid_t
    public var bundleID: String?
    public var name: String

    public init(pid: pid_t, bundleID: String?, name: String) {
        self.pid = pid
        self.bundleID = bundleID
        self.name = name
    }
}

/// One synthetic keyboard event.
public enum KeyEvent: Hashable, Sendable {
    /// A key going down or up; `flags` are `CGEventFlags` raw values.
    case key(code: UInt16, down: Bool, flags: UInt64)
    /// A character typed regardless of the keyboard layout.
    case text(String, down: Bool)
}

/// Where the runner's keys and app switches go: the real system (`SystemKeyOutput`) or a recording stand-in in
/// tests. Called from the runner's queue.
public protocol KeyOutput: AnyObject {
    /// Posts to the whole system (as a keyboard would), or to one process when `pid` is set.
    func post(_ event: KeyEvent, toProcess pid: pid_t?)
    func frontmostApp() -> RunningApp?
    func runningApp(bundleID: String) -> RunningApp?
    /// Brings the app to the front; true once it is in front.
    func activate(_ app: RunningApp) -> Bool
    /// Opens the app and brings it to the front; nil if it can't be opened.
    func launch(_ app: AppRef) -> RunningApp?
    func sleep(milliseconds: Int)
}

public struct RunEvent: Sendable {
    public enum Outcome: Hashable, Sendable {
        case finished(milliseconds: Int)
        case skipped(String)
        case failed(String)
        /// Stopped with Stop All before it finished.
        case stopped
        /// Not run: too many runs were waiting.
        case dropped
    }

    public var mappingID: UUID
    public var name: String
    public var outcome: Outcome
}

/// Runs mappings' steps one mapping at a time, in the order they were fired, on its own queue.
public final class MacroRunner: @unchecked Sendable {
    public let output: KeyOutput
    /// Called on the runner's queue after every run.
    public var onEvent: ((RunEvent) -> Void)?
    /// Runs waiting beyond this are dropped (a knob mapped to a long macro can't pile up minutes of work).
    public static let maxPending = 64
    /// Keys meant for "whichever app is in front" aren't sent while this app (MidiPress itself) is in front, so a
    /// pad pressed while editing never types into the editor or fires its menu shortcuts.
    public var protectedApp: (bundleID: String, name: String)?

    private let queue = DispatchQueue(label: "MidiPress.macros", qos: .userInteractive)
    private let lock = NSLock()
    private var generation = 0
    private var pending = 0

    public init(output: KeyOutput) {
        self.output = output
    }

    public var pendingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return pending
    }

    public func enqueue(_ mapping: Mapping, keyHoldMS: Int) {
        lock.lock()
        guard pending < Self.maxPending else {
            lock.unlock()
            onEvent?(RunEvent(mappingID: mapping.id, name: mapping.name, outcome: .dropped))
            return
        }
        pending += 1
        let generation = generation
        lock.unlock()
        queue.async { [self] in
            let outcome = run(mapping, keyHoldMS: keyHoldMS, generation: generation)
            lock.lock()
            pending -= 1
            lock.unlock()
            onEvent?(RunEvent(mappingID: mapping.id, name: mapping.name, outcome: outcome))
        }
    }

    /// Stops the running macro at its next step and drops the waiting ones. A key already going down is let up.
    public func stopAll() {
        lock.lock()
        generation += 1
        lock.unlock()
    }

    /// Waits until everything queued so far has run (tests and the self-test).
    public func waitUntilIdle() { queue.sync {} }

    private func isCurrent(_ generation: Int?) -> Bool {
        guard let generation else { return true }
        lock.lock()
        defer { lock.unlock() }
        return generation == self.generation
    }

    /// Runs one mapping on the calling thread.
    public func run(_ mapping: Mapping, keyHoldMS: Int, generation: Int? = nil) -> RunEvent.Outcome {
        guard isCurrent(generation) else { return .stopped }
        var pid: pid_t?
        var previous: RunningApp?
        if mapping.target.app == nil, let protectedApp, output.frontmostApp()?.bundleID == protectedApp.bundleID,
           !mapping.steps.contains(where: \.isActivate) {
            return .skipped("\(protectedApp.name) is in front; switch to the app the keys are for")
        }
        if let app = mapping.target.app {
            switch mapping.target.mode {
            case .whenFrontmost:
                guard output.frontmostApp()?.bundleID == app.bundleID else { return .skipped("\(app.name) isn't in front") }
            case .bringToFront:
                guard let running = output.runningApp(bundleID: app.bundleID) else { return .skipped("\(app.name) isn't open") }
                let front = output.frontmostApp()
                if front?.pid != running.pid {
                    previous = front
                    guard output.activate(running) else { return .failed("Couldn't bring \(app.name) to the front") }
                }
            case .background:
                guard let running = output.runningApp(bundleID: app.bundleID) else { return .skipped("\(app.name) isn't open") }
                pid = running.pid
            }
        }
        let started = DispatchTime.now()
        let hold = max(1, keyHoldMS)
        let pause = max(0, mapping.stepPauseMS)
        for (index, step) in mapping.steps.enumerated() {
            guard isCurrent(generation) else { return .stopped }
            switch step.action {
            case .shortcut(let shortcut, let times):
                for repeatIndex in 0..<max(1, times) {
                    if repeatIndex > 0 { guard wait(pause, generation) else { return .stopped } }
                    press(shortcut, hold: hold, pid: pid)
                }
            case .delay(let milliseconds):
                guard wait(milliseconds, generation) else { return .stopped }
            case .text(let text):
                guard type(text, hold: hold, pid: pid, generation: generation) else { return .stopped }
            case .activate(let app):
                guard let running = output.runningApp(bundleID: app.bundleID) ?? output.launch(app) else {
                    return .failed("Couldn't open \(app.name)")
                }
                if output.frontmostApp()?.pid != running.pid, !output.activate(running) {
                    return .failed("Couldn't bring \(app.name) to the front")
                }
            }
            // The pause goes between steps, but an explicit wait takes its place.
            if index < mapping.steps.count - 1, !step.isDelay, !mapping.steps[index + 1].isDelay {
                guard wait(pause, generation) else { return .stopped }
            }
        }
        if mapping.target.mode == .bringToFront, mapping.target.returnToPrevious, let previous {
            guard wait(pause, generation) else { return .stopped }
            _ = output.activate(previous)
        }
        let elapsed = Int((DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000)
        return .finished(milliseconds: elapsed)
    }

    /// Presses the modifiers in order, the key, then lets go in reverse, like fingers on a keyboard.
    func press(_ shortcut: Shortcut, hold: Int, pid: pid_t?) {
        var held = Modifiers()
        for (modifier, code) in KeyCatalog.modifierKeyCodes where shortcut.modifiers.contains(modifier) {
            held.insert(modifier)
            output.post(.key(code: code, down: true, flags: KeyCatalog.cgFlags(held).rawValue), toProcess: pid)
        }
        let flags = KeyCatalog.cgFlags(shortcut.modifiers).union(KeyCatalog.intrinsicFlags(for: shortcut.keyCode)).rawValue
        output.post(.key(code: shortcut.keyCode, down: true, flags: flags), toProcess: pid)
        output.sleep(milliseconds: hold)
        output.post(.key(code: shortcut.keyCode, down: false, flags: flags), toProcess: pid)
        for (modifier, code) in KeyCatalog.modifierKeyCodes.reversed() where shortcut.modifiers.contains(modifier) {
            held.remove(modifier)
            output.post(.key(code: code, down: false, flags: KeyCatalog.cgFlags(held).rawValue), toProcess: pid)
        }
    }

    /// Types characters one by one; line breaks and tabs press Return and Tab.
    func type(_ text: String, hold: Int, pid: pid_t?, generation: Int?) -> Bool {
        for (index, character) in text.enumerated() {
            guard isCurrent(generation) else { return false }
            if index > 0 { output.sleep(milliseconds: hold) }
            switch character {
            case "\n", "\r", "\r\n": press(Shortcut(keyCode: KeyCode.returnKey), hold: hold, pid: pid)
            case "\t": press(Shortcut(keyCode: KeyCode.tab), hold: hold, pid: pid)
            default:
                output.post(.text(String(character), down: true), toProcess: pid)
                output.sleep(milliseconds: hold)
                output.post(.text(String(character), down: false), toProcess: pid)
            }
        }
        return true
    }

    /// Sleeps in short slices so Stop All interrupts long waits.
    func wait(_ milliseconds: Int, _ generation: Int?) -> Bool {
        var remaining = milliseconds
        while remaining > 0 {
            let slice = min(remaining, 50)
            output.sleep(milliseconds: slice)
            remaining -= slice
            guard isCurrent(generation) else { return false }
        }
        return true
    }
}

extension Step {
    var isDelay: Bool {
        if case .delay = action { return true }
        return false
    }

    var isActivate: Bool {
        if case .activate = action { return true }
        return false
    }
}

/// Key codes used by name in code.
public enum KeyCode {
    public static let returnKey: UInt16 = 0x24
    public static let tab: UInt16 = 0x30
    public static let space: UInt16 = 0x31
    public static let escape: UInt16 = 0x35
    public static let leftArrow: UInt16 = 0x7B
    public static let rightArrow: UInt16 = 0x7C
    public static let downArrow: UInt16 = 0x7D
    public static let upArrow: UInt16 = 0x7E
    public static let a: UInt16 = 0x00
    public static let b: UInt16 = 0x0B
    public static let r: UInt16 = 0x0F
    public static let s: UInt16 = 0x01
    public static let z: UInt16 = 0x06
}
