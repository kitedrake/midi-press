import XCTest
@testable import MidiPressCore

final class StoreTests: XCTestCase {
    var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("midipress-tests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    static let sample = Setup(keyHoldMS: 20, ignoredInputs: ["IAC Driver Bus 1"], mappings: [
        Mapping(name: "Bounce in Place", trigger: Trigger(kind: .controlChange, channel: 0, number: 119, value: .exactly(1),
                                                         source: SourceRef(uniqueID: 5, name: "Pads")),
                target: Target(app: .logic, mode: .bringToFront, returnToPrevious: true),
                steps: [.shortcut(KeyCode.b, [.control, .command]), .delay(300), Step(.text("Take 2")), Step(.activate(.logic)),
                        .shortcut(KeyCode.downArrow, times: 4)],
                stepPauseMS: 80),
        Mapping(name: "Off", isEnabled: false, trigger: Trigger(kind: .noteOn, number: 36, value: .between(64, 127), fire: .onEnter)),
    ])

    func testRoundTrip() throws {
        let store = Store(folder: folder)
        guard case .missing = store.load() else { return XCTFail("no file yet") }
        try store.save(Self.sample)
        guard case .loaded(let loaded) = store.load() else { return XCTFail("should load") }
        XCTAssertEqual(loaded, Self.sample)
    }

    func testFileIsReadableJSON() throws {
        let store = Store(folder: folder)
        try store.save(Self.sample)
        let text = try String(contentsOf: store.fileURL, encoding: .utf8)
        XCTAssertTrue(text.contains("\"type\" : \"shortcut\""))
        XCTAssertTrue(text.contains("\"modifiers\" : [\n") && text.contains("\"control\"") && text.contains("\"command\""))
        XCTAssertTrue(text.contains("\"mode\" : \"bringToFront\""))
        XCTAssertTrue(text.contains("\"schema\" : 1"))
    }

    func testMissingFieldsGetDefaults() throws {
        let json = #"{"mappings":[{"name":"Min","trigger":{"kind":"noteOn","number":36,"value":{"mode":"any","low":0,"high":127},"fire":"everyMessage"},"steps":[{"type":"shortcut","shortcut":{"key":49}}]}]}"#
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = Store(folder: folder)
        try Data(json.utf8).write(to: store.fileURL)
        guard case .loaded(let setup) = store.load() else { return XCTFail() }
        XCTAssertTrue(setup.isActive)
        XCTAssertEqual(setup.keyHoldMS, Setup.defaultKeyHoldMS)
        let mapping = try XCTUnwrap(setup.mappings.first)
        XCTAssertTrue(mapping.isEnabled)
        XCTAssertNil(mapping.target.app)
        XCTAssertEqual(mapping.stepPauseMS, Mapping.defaultStepPauseMS)
        XCTAssertEqual(mapping.steps.first?.action, .shortcut(Shortcut(keyCode: 49), times: 1))
    }

    func testANewerFileIsReadButFlagged() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = Store(folder: folder)
        try Data(#"{"schema":9,"mappings":[]}"#.utf8).write(to: store.fileURL)
        guard case .newer(_, let schema) = store.load() else { return XCTFail() }
        XCTAssertEqual(schema, 9)
    }

    func testAnUnreadableFileIsMovedAsideNotLost() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = Store(folder: folder)
        try Data("not json".utf8).write(to: store.fileURL)
        guard case .unreadable(let aside, _) = store.load(), let aside else { return XCTFail() }
        XCTAssertEqual(try String(contentsOf: aside, encoding: .utf8), "not json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    func testImportedMappingsGetNewIDs() throws {
        let data = try MappingFile(mappings: Self.sample.mappings).encoded()
        let imported = try MappingFile.mappings(from: data)
        XCTAssertEqual(imported.map(\.name), ["Bounce in Place", "Off"])
        XCTAssertNotEqual(imported[0].id, Self.sample.mappings[0].id)
        XCTAssertNotEqual(imported[0].steps[0].id, Self.sample.mappings[0].steps[0].id)
        XCTAssertEqual(imported[0].steps.map(\.action), Self.sample.mappings[0].steps.map(\.action))
        // A whole setup.json imports too.
        try Store(folder: folder).save(Self.sample)
        XCTAssertEqual(try MappingFile.mappings(from: Data(contentsOf: Store(folder: folder).fileURL)).count, 2)
    }
}

final class KeyCatalogTests: XCTestCase {
    func testShortcutDisplay() {
        XCTAssertEqual(Shortcut(keyCode: 0x7A, modifiers: [.shift]).display, "⇧ F1")
        XCTAssertEqual(Shortcut(keyCode: KeyCode.returnKey, modifiers: [.command, .control]).display, "⌃⌘↩")
        XCTAssertEqual(Shortcut(keyCode: 0x53).display, "Keypad 1")
        XCTAssertEqual(Shortcut(keyCode: KeyCode.space, modifiers: [.option]).display, "⌥ Space")
        XCTAssertEqual(Modifiers([.command, .shift, .option, .control]).symbols, "⌃⌥⇧⌘")
    }

    func testLetterKeysAreNamedFromTheLayout() {
        // Whatever the layout, the A key types a letter, shown uppercased.
        let name = KeyCatalog.name(for: KeyCode.a)
        XCTAssertEqual(name.count, 1)
        XCTAssertEqual(name, name.uppercased())
    }

    func testEveryCatalogKeyHasANameAndNoModifierKeysAreListed() {
        for key in KeyCatalog.keys {
            XCTAssertFalse(KeyCatalog.name(for: key.code).isEmpty)
            XCTAssertFalse(KeyCatalog.modifierOnlyCodes.contains(key.code))
        }
        XCTAssertEqual(Set(KeyCatalog.keys.map(\.code)).count, KeyCatalog.keys.count, "no duplicates")
    }

    func testStepSummaries() {
        XCTAssertEqual(Step.shortcut(KeyCode.s, [.command], times: 3).summary, "⌘\(KeyCatalog.name(for: KeyCode.s)) ×3")
        XCTAssertEqual(Step.delay(250).summary, "Wait 250 ms")
        XCTAssertEqual(Step(.text("A long piece of text to type")).summary, "Type “A long piece of text to…”")
        XCTAssertEqual(Step(.activate(.logic)).summary, "Switch to Logic Pro")
    }
}
