import XCTest
@testable import MidiPressCore

final class MIDIParserTests: XCTestCase {
    let pads = SourceRef(uniqueID: 42, name: "Pads")

    func word(_ status: UInt8, _ channel: UInt8, _ d1: UInt8, _ d2: UInt8) -> UInt32 {
        MIDITestSender.word(status: status, channel: channel, d1, d2)
    }

    func testDecodesChannelVoiceMessagesFromUMPWords() {
        let messages = MIDIParser.parse(words: [
            word(0xB, 0, 119, 1),       // CC 119 = 1, channel 1
            word(0x9, 9, 36, 100),      // note on C1, channel 10
            word(0x9, 9, 36, 0),        // note on with velocity 0: a note off
            word(0x8, 9, 36, 64),       // note off
            word(0xC, 2, 5, 0),         // program 5, channel 3
            word(0xE, 0, 0x00, 0x40),   // pitch bend centre (8192)
        ], source: pads)
        XCTAssertEqual(messages, [
            MIDIMessage(kind: .controlChange, channel: 0, number: 119, value: 1, source: pads),
            MIDIMessage(kind: .noteOn, channel: 9, number: 36, value: 100, source: pads),
            MIDIMessage(kind: .noteOff, channel: 9, number: 36, value: 0, source: pads),
            MIDIMessage(kind: .noteOff, channel: 9, number: 36, value: 64, source: pads),
            MIDIMessage(kind: .programChange, channel: 2, number: 5, value: 0, source: pads),
            MIDIMessage(kind: .pitchBend, channel: 0, number: 0, value: 8192, source: pads),
        ])
    }

    func testSkipsOtherPacketTypesByTheirLength() {
        let messages = MIDIParser.parse(words: [
            0x1000_F800,                          // system real-time (1 word)
            0x3000_0000, 0x0000_0000,             // SysEx 7 (2 words)
            0x4090_3C00, 0xFFFF_0000,             // MIDI 2.0 note on (2 words): not decoded
            0x5000_0000, 0, 0, 0,                 // data 128 (4 words)
            word(0xB, 15, 7, 127),
        ], source: nil)
        XCTAssertEqual(messages, [MIDIMessage(kind: .controlChange, channel: 15, number: 7, value: 127)])
    }

    func testDecodesMIDI1BytesWithRunningStatusAndSysExAndRealTime() {
        let messages = MIDIParser.parse(bytes: [
            0xB0, 119, 1, 119, 0,           // CC with running status
            0xF8,                           // clock in between
            0xF0, 0x7E, 0x01, 0xF7,         // SysEx
            0x91, 60, 0x7F, 0xF8, 62, 0,    // note on, clock, running-status note on with velocity 0
        ], source: nil)
        XCTAssertEqual(messages.map(\.summary), [
            "CC 119 = 1 · ch 1", "CC 119 = 0 · ch 1", "Note On C3 (60) vel 127 · ch 2", "Note Off D3 (62) · ch 2",
        ])
    }

    func testNoteNamesUseC3ForMiddleC() {
        XCTAssertEqual(NoteName.name(60), "C3")
        XCTAssertEqual(NoteName.name(0), "C-2")
        XCTAssertEqual(NoteName.name(127), "G8")
        XCTAssertEqual(NoteName.name(37), "C♯1")
    }
}

final class MatcherTests: XCTestCase {
    let pads = SourceRef(uniqueID: 42, name: "Pads")
    let keys = SourceRef(uniqueID: 7, name: "Keyboard")

    func cc(_ number: Int, _ value: Int, channel: Int = 0, source: SourceRef? = nil) -> MIDIMessage {
        MIDIMessage(kind: .controlChange, channel: channel, number: number, value: value, source: source ?? pads)
    }

    func mapping(_ name: String, _ trigger: Trigger, enabled: Bool = true) -> Mapping {
        Mapping(name: name, isEnabled: enabled, trigger: trigger, steps: [.shortcut(KeyCode.b, [.control])])
    }

    func testExactValueOfAController() {
        var matcher = Matcher(mappings: [mapping("Bounce", Trigger(kind: .controlChange, number: 119, value: .exactly(1)))])
        XCTAssertEqual(matcher.match(cc(119, 1)).map(\.name), ["Bounce"])
        XCTAssertEqual(matcher.match(cc(119, 0)).map(\.name), [])
        XCTAssertEqual(matcher.match(cc(118, 1)).map(\.name), [])
        XCTAssertEqual(matcher.match(cc(119, 1)).map(\.name), ["Bounce"], "every message fires again")
    }

    func testChannelInputAndEnabledFilters() {
        var matcher = Matcher(mappings: [
            mapping("Any", Trigger(number: 20)),
            mapping("Ch 2", Trigger(channel: 1, number: 20)),
            mapping("Keyboard only", Trigger(number: 20, source: keys)),
            mapping("Off", Trigger(number: 20), enabled: false),
        ])
        XCTAssertEqual(matcher.match(cc(20, 5)).map(\.name), ["Any"])
        XCTAssertEqual(matcher.match(cc(20, 5, channel: 1)).map(\.name), ["Any", "Ch 2"])
        XCTAssertEqual(matcher.match(cc(20, 5, source: keys)).map(\.name), ["Any", "Keyboard only"])
        // An input is found again by name when its ID changed (unplugged and plugged into another port).
        XCTAssertEqual(matcher.match(cc(20, 5, source: SourceRef(uniqueID: 99, name: "Keyboard"))).map(\.name), ["Any", "Keyboard only"])
    }

    func testOnEnterFiresOncePerCrossing() {
        var matcher = Matcher(mappings: [mapping("Up", Trigger(number: 1, value: .between(100, 127), fire: .onEnter))])
        let fired = [10, 60, 101, 110, 127, 90, 105, 120].map { matcher.match(cc(1, $0)).count }
        XCTAssertEqual(fired, [0, 0, 1, 0, 0, 0, 1, 0])
    }

    func testOnEnterFiresOnTheFirstValueSeenInRange() {
        var matcher = Matcher(mappings: [mapping("Up", Trigger(number: 1, value: .between(100, 127), fire: .onEnter))])
        XCTAssertEqual(matcher.match(cc(1, 120)).count, 1)
    }

    func testNotesProgramsAndPitchBend() {
        var matcher = Matcher(mappings: [
            mapping("Hard hit", Trigger(kind: .noteOn, number: 36, value: .between(100, 127))),
            mapping("Release", Trigger(kind: .noteOff, number: 36)),
            mapping("Program 5", Trigger(kind: .programChange, number: 5, value: .exactly(99))),
            mapping("Bend up", Trigger(kind: .pitchBend, number: 77, value: .between(12000, 16383), fire: .onEnter)),
        ])
        XCTAssertEqual(matcher.match(MIDIMessage(kind: .noteOn, channel: 0, number: 36, value: 80)).map(\.name), [])
        XCTAssertEqual(matcher.match(MIDIMessage(kind: .noteOn, channel: 0, number: 36, value: 120)).map(\.name), ["Hard hit"])
        XCTAssertEqual(matcher.match(MIDIMessage(kind: .noteOff, channel: 0, number: 36, value: 0)).map(\.name), ["Release"])
        XCTAssertEqual(matcher.match(MIDIMessage(kind: .programChange, channel: 0, number: 5, value: 0)).map(\.name), ["Program 5"],
                       "program change ignores the value")
        XCTAssertEqual(matcher.match(MIDIMessage(kind: .pitchBend, channel: 0, number: 0, value: 16000)).map(\.name), ["Bend up"],
                       "pitch bend has no number")
    }

    func testLearnTakesTheInputTheMessageCameFrom() {
        var trigger = Trigger(kind: .noteOn, channel: 3, number: 40, value: .between(10, 20), fire: .onEnter, source: keys)
        trigger.learn(cc(119, 1, channel: 1, source: pads))
        XCTAssertEqual(trigger, Trigger(kind: .controlChange, channel: 1, number: 119, value: .exactly(1), fire: .everyMessage, source: pads))
        // The same CC from another controller doesn't fire it.
        var matcher = Matcher(mappings: [mapping("Pads", trigger)])
        XCTAssertEqual(matcher.match(cc(119, 1, channel: 1, source: pads)).map(\.name), ["Pads"])
        XCTAssertEqual(matcher.match(cc(119, 1, channel: 1, source: keys)).map(\.name), [])
        // Notes learn any velocity.
        trigger.learn(MIDIMessage(kind: .noteOn, channel: 9, number: 36, value: 98, source: keys))
        XCTAssertEqual(trigger, Trigger(kind: .noteOn, channel: 9, number: 36, value: .any, source: keys))
    }

    func testTriggerSummaries() {
        XCTAssertEqual(Trigger(kind: .controlChange, number: 119, value: .exactly(1)).summary, "CC 119 = 1")
        XCTAssertEqual(Trigger(kind: .noteOn, channel: 9, number: 36).summary, "Note C1 · ch 10")
        XCTAssertEqual(Trigger(kind: .controlChange, number: 7, value: .between(127, 100)).summary, "CC 7 100–127")
        XCTAssertEqual(Trigger(kind: .programChange, number: 3, value: .exactly(5)).summary, "Program 3")
    }
}

/// Real Core MIDI in this process: a virtual source plays the part of a controller.
final class CoreMIDITests: XCTestCase {
    func testMessagesFromAnInputAndTheVirtualPortReachTheEngine() throws {
        let output = FakeOutput()
        let engine = Engine(output: output)
        engine.apply(Setup(mappings: [
            Mapping(name: "Bounce", trigger: Trigger(number: 119, value: .exactly(1)), steps: [.shortcut(KeyCode.b, [.control])]),
        ]))
        let input = MIDIInput()
        let received = expectation(description: "two messages from two routes")
        received.expectedFulfillmentCount = 2
        let lock = NSLock()
        var sources: [String] = []
        engine.onMessage = { message, fired in
            guard message.number == 119 else { return }
            lock.lock()
            sources.append("\(message.source?.name ?? "?"): \(fired.map(\.name))")
            lock.unlock()
            received.fulfill()
        }
        input.onMessages = { engine.receive($0) }
        try input.start(clientName: "MidiPress Test")
        try input.setVirtualPort(enabled: true, name: "MidiPress Test Port", uniqueID: nil)
        let sender = try MIDITestSender(name: "MidiPress Test Pads")
        input.reconnect()
        sender.emit([MIDITestSender.word(status: 0xB, channel: 0, 119, 1)])
        XCTAssertTrue(sender.send([MIDITestSender.word(status: 0xB, channel: 0, 119, 1)], toDestinationNamed: "MidiPress Test Port"))
        wait(for: [received], timeout: 5)
        engine.runner.waitUntilIdle()
        XCTAssertEqual(Set(sources), ["MidiPress Test Pads: [\"Bounce\"]", "MidiPress Test Port (virtual port): [\"Bounce\"]"])
        XCTAssertEqual(output.keys.count, 4 * 2, "⌃ down, B down, B up, ⌃ up, twice")
    }
}
