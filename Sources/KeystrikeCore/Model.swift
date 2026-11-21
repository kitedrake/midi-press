import Foundation

// MARK: - MIDI messages

/// The kinds of MIDI message a mapping can react to.
public enum MessageKind: String, Codable, CaseIterable, Sendable {
    case controlChange, noteOn, noteOff, programChange, pitchBend

    public var title: String {
        switch self {
        case .controlChange: "Control Change (CC)"
        case .noteOn: "Note On"
        case .noteOff: "Note Off"
        case .programChange: "Program Change"
        case .pitchBend: "Pitch Bend"
        }
    }

    public var shortTitle: String {
        switch self {
        case .controlChange: "CC"
        case .noteOn: "Note"
        case .noteOff: "Note Off"
        case .programChange: "Program"
        case .pitchBend: "Pitch Bend"
        }
    }

    /// What the message's number is called (nil: it has none).
    public var numberTitle: String? {
        switch self {
        case .controlChange: "Controller"
        case .noteOn, .noteOff: "Note"
        case .programChange: "Program"
        case .pitchBend: nil
        }
    }

    /// What the message's value is called (nil: a value isn't matched).
    public var valueTitle: String? {
        switch self {
        case .controlChange: "Value"
        case .noteOn, .noteOff: "Velocity"
        case .programChange: nil
        case .pitchBend: "Position"
        }
    }

    public var maxValue: Int { self == .pitchBend ? 16383 : 127 }
}

/// A MIDI input, remembered by Core MIDI's unique ID and its name (the name finds it again if the ID changes).
public struct SourceRef: Codable, Hashable, Sendable {
    public var uniqueID: Int32
    public var name: String

    public init(uniqueID: Int32, name: String) {
        self.uniqueID = uniqueID
        self.name = name
    }

    public func matches(_ other: SourceRef?) -> Bool {
        guard let other else { return false }
        return other.uniqueID == uniqueID || other.name == name
    }
}

/// One incoming channel message, already decoded.
public struct MIDIMessage: Hashable, Sendable {
    public var kind: MessageKind
    /// 0–15 (shown as 1–16).
    public var channel: Int
    /// Controller, note or program number; 0 for pitch bend.
    public var number: Int
    /// CC value or velocity (0–127), pitch bend position (0–16383, centre 8192); 0 for program change.
    public var value: Int
    public var source: SourceRef?

    public init(kind: MessageKind, channel: Int, number: Int, value: Int, source: SourceRef? = nil) {
        self.kind = kind
        self.channel = channel
        self.number = number
        self.value = value
        self.source = source
    }

    /// "CC 119 = 1 · ch 1"
    public var summary: String {
        let ch = "ch \(channel + 1)"
        switch kind {
        case .controlChange: return "CC \(number) = \(value) · \(ch)"
        case .noteOn: return "Note On \(NoteName.name(number)) (\(number)) vel \(value) · \(ch)"
        case .noteOff: return "Note Off \(NoteName.name(number)) (\(number)) · \(ch)"
        case .programChange: return "Program \(number) · \(ch)"
        case .pitchBend: return "Pitch Bend \(value) · \(ch)"
        }
    }
}

/// Note names with middle C (60) as C3, as Logic Pro and Ableton Live show them.
public enum NoteName {
    static let names = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]

    public static func name(_ note: Int) -> String {
        guard (0...127).contains(note) else { return "\(note)" }
        return "\(names[note % 12])\(note / 12 - 2)"
    }
}

// MARK: - Triggers

/// Which values of a message match.
public struct ValueMatch: Codable, Hashable, Sendable {
    public enum Mode: String, Codable, CaseIterable, Sendable { case any, exactly, between }

    public var mode: Mode
    /// The value for `exactly`, the lower end for `between`.
    public var low: Int
    /// The upper end for `between`.
    public var high: Int

    public init(mode: Mode = .any, low: Int = 0, high: Int = 127) {
        self.mode = mode
        self.low = low
        self.high = high
    }

    public static let any = ValueMatch()
    public static func exactly(_ value: Int) -> ValueMatch { ValueMatch(mode: .exactly, low: value, high: value) }
    public static func between(_ low: Int, _ high: Int) -> ValueMatch { ValueMatch(mode: .between, low: low, high: high) }

    public func contains(_ value: Int) -> Bool {
        switch mode {
        case .any: true
        case .exactly: value == low
        case .between: (min(low, high)...max(low, high)).contains(value)
        }
    }
}

/// When a matching message fires the mapping.
public enum FireMode: String, Codable, CaseIterable, Sendable {
    /// Every matching message (a pad that sends one message per press).
    case everyMessage
    /// Only when the value moves into the range from outside it (a knob or fader crossing a point fires once).
    case onEnter
}

public struct Trigger: Codable, Hashable, Sendable {
    public var kind: MessageKind
    /// 0–15, or nil for any channel.
    public var channel: Int?
    /// Controller, note or program number (ignored for pitch bend).
    public var number: Int
    /// Ignored for program change.
    public var value: ValueMatch
    public var fire: FireMode
    /// Only messages from this input; nil for any input.
    public var source: SourceRef?

    public init(kind: MessageKind = .controlChange, channel: Int? = nil, number: Int = 0, value: ValueMatch = .any,
                fire: FireMode = .everyMessage, source: SourceRef? = nil) {
        self.kind = kind
        self.channel = channel
        self.number = number
        self.value = value
        self.fire = fire
        self.source = source
    }

    /// Whether the message is the right kind, channel, number and input (values are checked separately).
    public func addresses(_ message: MIDIMessage) -> Bool {
        guard message.kind == kind else { return false }
        if let channel, channel != message.channel { return false }
        if kind != .pitchBend, message.number != number { return false }
        if let source, !source.matches(message.source) { return false }
        return true
    }

    public var usesValue: Bool { kind.valueTitle != nil }

    /// "CC 119 = 1", "Note C3 (60)", "Program 5"
    public var summary: String {
        var text: String
        switch kind {
        case .controlChange: text = "CC \(number)"
        case .noteOn: text = "Note \(NoteName.name(number))"
        case .noteOff: text = "Note Off \(NoteName.name(number))"
        case .programChange: text = "Program \(number)"
        case .pitchBend: text = "Pitch Bend"
        }
        if usesValue {
            switch value.mode {
            case .any: break
            case .exactly: text += " = \(value.low)"
            case .between: text += " \(min(value.low, value.high))–\(max(value.low, value.high))"
            }
        }
        if let channel { text += " · ch \(channel + 1)" }
        return text
    }
}

// MARK: - Keys

/// Modifier keys held with a key.
public struct Modifiers: OptionSet, Hashable, Sendable, Codable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let control = Modifiers(rawValue: 1 << 0)
    public static let option = Modifiers(rawValue: 1 << 1)
    public static let shift = Modifiers(rawValue: 1 << 2)
    public static let command = Modifiers(rawValue: 1 << 3)

    /// In the order macOS shows them (⌃⌥⇧⌘), with their names in the saved file.
    public static let ordered: [(Modifiers, String, String)] = [
        (.control, "⌃", "control"), (.option, "⌥", "option"), (.shift, "⇧", "shift"), (.command, "⌘", "command"),
    ]

    public var symbols: String { Self.ordered.filter { contains($0.0) }.map(\.1).joined() }

    public init(from decoder: Decoder) throws {
        let names = try decoder.singleValueContainer().decode([String].self)
        var value = Modifiers()
        for (modifier, _, name) in Self.ordered where names.contains(name) { value.insert(modifier) }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(Self.ordered.filter { contains($0.0) }.map(\.2))
    }
}

/// A key and the modifiers held with it. The key is a hardware key code (a position on the keyboard), so a
/// recorded shortcut presses the same key the user pressed, whatever the keyboard layout.
public struct Shortcut: Codable, Hashable, Sendable {
    public var keyCode: UInt16
    public var modifiers: Modifiers

    public init(keyCode: UInt16, modifiers: Modifiers = []) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    enum CodingKeys: String, CodingKey { case key, modifiers }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        keyCode = try container.decode(UInt16.self, forKey: .key)
        modifiers = try container.decodeIfPresent(Modifiers.self, forKey: .modifiers) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(keyCode, forKey: .key)
        try container.encode(modifiers, forKey: .modifiers)
    }

    /// "⌃⌥⌘B", "⇧F5", "Keypad 1"
    public var display: String {
        let key = KeyCatalog.name(for: keyCode)
        let symbols = modifiers.symbols
        guard !symbols.isEmpty else { return key }
        return symbols + (key.count > 1 && !KeyCatalog.isSymbol(key) ? " " : "") + key
    }
}

// MARK: - Apps

public struct AppRef: Codable, Hashable, Sendable, Identifiable {
    public var bundleID: String
    public var name: String
    public var id: String { bundleID }

    public init(bundleID: String, name: String) {
        self.bundleID = bundleID
        self.name = name
    }
}

/// Where the keys go.
public enum TargetMode: String, Codable, CaseIterable, Sendable {
    /// Run only while the app is in front; otherwise do nothing.
    case whenFrontmost
    /// Bring the app to the front, then press the keys.
    case bringToFront
    /// Send the keys to the app while it stays in the background (not every app accepts this).
    case background

    public var title: String {
        switch self {
        case .whenFrontmost: "Only when it's in front"
        case .bringToFront: "Bring it to the front first"
        case .background: "Send in the background"
        }
    }
}

public struct Target: Codable, Hashable, Sendable {
    /// Nil: whichever app is in front.
    public var app: AppRef?
    public var mode: TargetMode
    /// For `bringToFront`: switch back to the app that was in front before.
    public var returnToPrevious: Bool

    public init(app: AppRef? = nil, mode: TargetMode = .whenFrontmost, returnToPrevious: Bool = false) {
        self.app = app
        self.mode = mode
        self.returnToPrevious = returnToPrevious
    }

    public var summary: String {
        guard let app else { return "App in front" }
        switch mode {
        case .whenFrontmost: return "\(app.name), when in front"
        case .bringToFront: return returnToPrevious ? "\(app.name), then back" : "\(app.name), brought to front"
        case .background: return "\(app.name), in background"
        }
    }
}

// MARK: - Steps

public enum Action: Hashable, Sendable {
    /// Press a key with modifiers, `times` times (with the mapping's pause in between).
    case shortcut(Shortcut, times: Int)
    case delay(milliseconds: Int)
    /// Type text as if typed on the keyboard.
    case text(String)
    /// Bring an app to the front (opening it if it isn't running).
    case activate(AppRef)

    public var kindTitle: String {
        switch self {
        case .shortcut: "Shortcut"
        case .delay: "Wait"
        case .text: "Type Text"
        case .activate: "Switch to App"
        }
    }
}

public struct Step: Identifiable, Hashable, Sendable, Codable {
    public var id: UUID
    public var action: Action

    public init(id: UUID = UUID(), _ action: Action) {
        self.id = id
        self.action = action
    }

    public static func shortcut(_ keyCode: UInt16, _ modifiers: Modifiers = [], times: Int = 1) -> Step {
        Step(.shortcut(Shortcut(keyCode: keyCode, modifiers: modifiers), times: times))
    }

    public static func delay(_ milliseconds: Int) -> Step { Step(.delay(milliseconds: milliseconds)) }

    enum CodingKeys: String, CodingKey { case id, type, shortcut, times, milliseconds, text, app }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        switch try c.decode(String.self, forKey: .type) {
        case "shortcut":
            action = .shortcut(try c.decode(Shortcut.self, forKey: .shortcut),
                               times: max(1, try c.decodeIfPresent(Int.self, forKey: .times) ?? 1))
        case "delay":
            action = .delay(milliseconds: max(0, try c.decode(Int.self, forKey: .milliseconds)))
        case "text":
            action = .text(try c.decode(String.self, forKey: .text))
        case "activate":
            action = .activate(try c.decode(AppRef.self, forKey: .app))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown step type “\(other)”")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        switch action {
        case .shortcut(let shortcut, let times):
            try c.encode("shortcut", forKey: .type)
            try c.encode(shortcut, forKey: .shortcut)
            try c.encode(times, forKey: .times)
        case .delay(let ms):
            try c.encode("delay", forKey: .type)
            try c.encode(ms, forKey: .milliseconds)
        case .text(let text):
            try c.encode("text", forKey: .type)
            try c.encode(text, forKey: .text)
        case .activate(let app):
            try c.encode("activate", forKey: .type)
            try c.encode(app, forKey: .app)
        }
    }

    /// "⌃B", "⌘S ×3", "Wait 200 ms", "Type “hello”", "Switch to Logic Pro"
    public var summary: String {
        switch action {
        case .shortcut(let shortcut, let times): times > 1 ? "\(shortcut.display) ×\(times)" : shortcut.display
        case .delay(let ms): "Wait \(ms) ms"
        case .text(let text): "Type “\(text.count > 24 ? String(text.prefix(23)) + "…" : text)”"
        case .activate(let app): "Switch to \(app.name)"
        }
    }
}

// MARK: - Mappings

public struct Mapping: Identifiable, Hashable, Sendable, Codable {
    public var id: UUID
    public var name: String
    public var isEnabled: Bool
    public var trigger: Trigger
    public var target: Target
    public var steps: [Step]
    /// Pause after each step (and between repeats of a shortcut), in milliseconds.
    public var stepPauseMS: Int

    public static let defaultStepPauseMS = 50

    public init(id: UUID = UUID(), name: String, isEnabled: Bool = true, trigger: Trigger = Trigger(),
                target: Target = Target(), steps: [Step] = [], stepPauseMS: Int = Mapping.defaultStepPauseMS) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.trigger = trigger
        self.target = target
        self.steps = steps
        self.stepPauseMS = stepPauseMS
    }

    enum CodingKeys: String, CodingKey { case id, name, isEnabled, trigger, target, steps, stepPauseMS }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Mapping"
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        trigger = try c.decode(Trigger.self, forKey: .trigger)
        target = try c.decodeIfPresent(Target.self, forKey: .target) ?? Target()
        steps = try c.decodeIfPresent([Step].self, forKey: .steps) ?? []
        stepPauseMS = max(0, try c.decodeIfPresent(Int.self, forKey: .stepPauseMS) ?? Mapping.defaultStepPauseMS)
    }

    /// The steps as one line: "⌃B → Wait 200 ms → ↩"
    public var stepsSummary: String {
        steps.isEmpty ? "No steps" : steps.map(\.summary).joined(separator: " → ")
    }
}

/// Everything Keystrike saves: `setup.json`.
public struct Setup: Codable, Hashable, Sendable {
    public static let currentSchema = 1

    public var schema: Int
    /// Mappings fire only while this is on.
    public var isActive: Bool
    /// How long each key is held down, in milliseconds.
    public var keyHoldMS: Int
    /// Names of MIDI inputs Keystrike doesn't listen to.
    public var ignoredInputs: [String]
    public var mappings: [Mapping]

    public static let defaultKeyHoldMS = 12

    public init(isActive: Bool = true, keyHoldMS: Int = Setup.defaultKeyHoldMS, ignoredInputs: [String] = [],
                mappings: [Mapping] = []) {
        schema = Setup.currentSchema
        self.isActive = isActive
        self.keyHoldMS = keyHoldMS
        self.ignoredInputs = ignoredInputs
        self.mappings = mappings
    }

    enum CodingKeys: String, CodingKey { case schema, isActive, keyHoldMS, ignoredInputs, mappings }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decodeIfPresent(Int.self, forKey: .schema) ?? 1
        isActive = try c.decodeIfPresent(Bool.self, forKey: .isActive) ?? true
        keyHoldMS = min(500, max(1, try c.decodeIfPresent(Int.self, forKey: .keyHoldMS) ?? Setup.defaultKeyHoldMS))
        ignoredInputs = try c.decodeIfPresent([String].self, forKey: .ignoredInputs) ?? []
        mappings = try c.decodeIfPresent([Mapping].self, forKey: .mappings) ?? []
    }
}
