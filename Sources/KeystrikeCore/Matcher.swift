import Foundation

/// Decodes MIDI into `MIDIMessage`s.
public enum MIDIParser {
    /// Decodes Universal MIDI Packet words (what Core MIDI delivers with the MIDI 1.0 protocol). Only MIDI 1.0
    /// channel voice messages (type 2) are kept; everything else is skipped by its length.
    public static func parse(words: UnsafeBufferPointer<UInt32>, source: SourceRef?) -> [MIDIMessage] {
        var messages: [MIDIMessage] = []
        var index = 0
        while index < words.count {
            let word = words[index]
            let type = word >> 28
            if type == 0x2, let message = channelVoice(word, source: source) { messages.append(message) }
            index += wordCount(ofType: type)
        }
        return messages
    }

    public static func parse(words: [UInt32], source: SourceRef?) -> [MIDIMessage] {
        words.withUnsafeBufferPointer { parse(words: $0, source: source) }
    }

    /// Packet lengths by message type, from the UMP specification.
    static func wordCount(ofType type: UInt32) -> Int {
        switch type {
        case 0x0, 0x1, 0x2, 0x6, 0x7: 1
        case 0x3, 0x4, 0x8, 0x9, 0xA: 2
        case 0xB, 0xC: 3
        default: 4
        }
    }

    static func channelVoice(_ word: UInt32, source: SourceRef?) -> MIDIMessage? {
        let status = Int((word >> 20) & 0xF)
        let channel = Int((word >> 16) & 0xF)
        let data1 = Int((word >> 8) & 0x7F)
        let data2 = Int(word & 0x7F)
        return message(status: status, channel: channel, data1: data1, data2: data2, source: source)
    }

    /// Decodes MIDI 1.0 bytes (running status supported; system messages skipped).
    public static func parse(bytes: [UInt8], source: SourceRef?) -> [MIDIMessage] {
        var messages: [MIDIMessage] = []
        var running: UInt8?
        var index = 0
        while index < bytes.count {
            var status = bytes[index]
            if status >= 0xF8 { index += 1; continue }  // real-time bytes can appear anywhere
            if status >= 0xF0 {  // system common / exclusive: skip to the next status byte
                running = nil
                index += 1
                while index < bytes.count, bytes[index] < 0x80 || bytes[index] == 0xF7 { index += 1 }
                continue
            }
            if status >= 0x80 {
                running = status
                index += 1
            } else if let running {
                status = running
            } else {
                index += 1
                continue
            }
            let kind = status >> 4
            let needed = (kind == 0xC || kind == 0xD) ? 1 : 2
            guard index + needed <= bytes.count else { break }
            let data1 = Int(bytes[index] & 0x7F)
            let data2 = needed == 2 ? Int(bytes[index + 1] & 0x7F) : 0
            index += needed
            if let message = message(status: Int(kind), channel: Int(status & 0xF), data1: data1, data2: data2, source: source) {
                messages.append(message)
            }
        }
        return messages
    }

    static func message(status: Int, channel: Int, data1: Int, data2: Int, source: SourceRef?) -> MIDIMessage? {
        switch status {
        case 0x8: return MIDIMessage(kind: .noteOff, channel: channel, number: data1, value: data2, source: source)
        case 0x9:
            // Note On with velocity 0 is a Note Off.
            return MIDIMessage(kind: data2 == 0 ? .noteOff : .noteOn, channel: channel, number: data1, value: data2, source: source)
        case 0xB: return MIDIMessage(kind: .controlChange, channel: channel, number: data1, value: data2, source: source)
        case 0xC: return MIDIMessage(kind: .programChange, channel: channel, number: data1, value: 0, source: source)
        case 0xE: return MIDIMessage(kind: .pitchBend, channel: channel, number: 0, value: data1 | (data2 << 7), source: source)
        default: return nil
        }
    }
}

/// Decides which mappings a message fires. Keeps the last value of every controller so "only when the value
/// enters the range" fires once per crossing.
public struct Matcher {
    public var mappings: [Mapping]
    private var lastValues: [ValueKey: Int] = [:]

    struct ValueKey: Hashable {
        var source: Int32?
        var kind: MessageKind
        var channel: Int
        var number: Int
    }

    public init(mappings: [Mapping] = []) {
        self.mappings = mappings
    }

    /// The enabled mappings the message fires, in list order.
    public mutating func match(_ message: MIDIMessage) -> [Mapping] {
        let key = ValueKey(source: message.source?.uniqueID, kind: message.kind, channel: message.channel, number: message.number)
        let previous = lastValues[key]
        lastValues[key] = message.value
        return mappings.filter { mapping in
            guard mapping.isEnabled, mapping.trigger.addresses(message) else { return false }
            let trigger = mapping.trigger
            guard trigger.usesValue else { return true }
            guard trigger.value.contains(message.value) else { return false }
            if trigger.fire == .onEnter, let previous, trigger.value.contains(previous) { return false }
            return true
        }
    }

    /// Forgets the remembered values (after the mappings change, so a range crossing isn't missed).
    public mutating func reset() { lastValues = [:] }
}
