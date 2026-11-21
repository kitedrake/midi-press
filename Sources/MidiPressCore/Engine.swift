import Foundation

/// Ties MIDI to the macros: each message is matched against the mappings and the ones it fires are queued on the
/// runner. Thread-safe: messages arrive on Core MIDI's thread, the setup changes on the main thread.
public final class Engine: @unchecked Sendable {
    public let runner: MacroRunner
    /// Called for every message with the mappings it fired (Core MIDI's thread).
    public var onMessage: ((MIDIMessage, [Mapping]) -> Void)?

    private let lock = NSLock()
    private var matcher = Matcher()
    private var isActive = true
    private var keyHoldMS = Setup.defaultKeyHoldMS
    private var learning = false

    public init(output: KeyOutput) {
        runner = MacroRunner(output: output)
    }

    public func apply(_ setup: Setup) {
        lock.lock()
        if matcher.mappings.map(\.trigger) != setup.mappings.map(\.trigger) { matcher.reset() }
        matcher.mappings = setup.mappings
        isActive = setup.isActive
        keyHoldMS = setup.keyHoldMS
        lock.unlock()
    }

    /// While learning, messages are reported but fire nothing.
    public var isLearning: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return learning
        }
        set {
            lock.lock()
            learning = newValue
            lock.unlock()
        }
    }

    public func receive(_ messages: [MIDIMessage]) {
        for message in messages {
            lock.lock()
            let matched = matcher.match(message)
            let fired = (isActive && !learning) ? matched : []
            let hold = keyHoldMS
            lock.unlock()
            for mapping in fired { runner.enqueue(mapping, keyHoldMS: hold) }
            onMessage?(message, fired)
        }
    }

    /// Runs a mapping now, as if its trigger had arrived (Run Now in the editor).
    public func runNow(_ mapping: Mapping) {
        lock.lock()
        let hold = keyHoldMS
        lock.unlock()
        runner.enqueue(mapping, keyHoldMS: hold)
    }
}
