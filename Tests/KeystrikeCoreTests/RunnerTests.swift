import CoreGraphics
import XCTest
@testable import KeystrikeCore

final class RunnerTests: XCTestCase {
    let control = UInt16(0x3B), option = UInt16(0x3A), shift = UInt16(0x38), command = UInt16(0x37)

    func flags(_ f: CGEventFlags) -> UInt64 { f.rawValue }

    func testShortcutPressesModifiersInOrderAndReleasesInReverse() {
        let output = FakeOutput()
        let runner = MacroRunner(output: output)
        let outcome = runner.run(Mapping(name: "Bounce", steps: [.shortcut(KeyCode.b, [.command, .control, .option])]), keyHoldMS: 12)
        guard case .finished = outcome else { return XCTFail("\(outcome)") }
        let all: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand]
        XCTAssertEqual(output.keys, [
            .down(control, flags: flags(.maskControl), pid: nil),
            .down(option, flags: flags([.maskControl, .maskAlternate]), pid: nil),
            .down(command, flags: flags(all), pid: nil),
            .down(KeyCode.b, flags: flags(all), pid: nil),
            .up(KeyCode.b, flags: flags(all), pid: nil),
            .up(command, flags: flags([.maskControl, .maskAlternate]), pid: nil),
            .up(option, flags: flags(.maskControl), pid: nil),
            .up(control, flags: 0, pid: nil),
        ])
        XCTAssertEqual(output.sleptMS, 12, "the key is held for the hold time")
    }

    func testArrowKeysCarryTheFlagsARealKeyboardSends() {
        let output = FakeOutput()
        _ = MacroRunner(output: output).run(Mapping(name: "Down", steps: [.shortcut(KeyCode.downArrow, [.shift])]), keyHoldMS: 5)
        XCTAssertEqual(output.keys[1], .down(KeyCode.downArrow, flags: flags([.maskShift, .maskNumericPad, .maskSecondaryFn]), pid: nil))
    }

    func testPausesGoBetweenStepsAndRepeatsButExplicitWaitsReplaceThem() {
        let output = FakeOutput()
        let mapping = Mapping(name: "Macro", steps: [
            .shortcut(KeyCode.downArrow, times: 3),   // 3 presses, 2 pauses
            .shortcut(KeyCode.returnKey),             // pause before it
            .delay(200),                              // no pause around a wait
            .shortcut(KeyCode.escape),
        ], stepPauseMS: 40)
        _ = MacroRunner(output: output).run(mapping, keyHoldMS: 10)
        // 5 presses × 10 ms hold + 3 pauses × 40 ms + 200 ms wait
        XCTAssertEqual(output.sleptMS, 5 * 10 + 3 * 40 + 200)
        XCTAssertEqual(output.keys.filter { if case .down = $0 { true } else { false } }.count, 5)
    }

    func testTypesTextCharacterByCharacterWithReturnForLineBreaks() {
        let output = FakeOutput()
        _ = MacroRunner(output: output).run(Mapping(name: "Type", steps: [Step(.text("hé\nx"))]), keyHoldMS: 1)
        XCTAssertEqual(output.keys, [
            .text("h", down: true, pid: nil), .text("h", down: false, pid: nil),
            .text("é", down: true, pid: nil), .text("é", down: false, pid: nil),
            .down(KeyCode.returnKey, flags: 0, pid: nil), .up(KeyCode.returnKey, flags: 0, pid: nil),
            .text("x", down: true, pid: nil), .text("x", down: false, pid: nil),
        ])
    }

    func testOnlyWhenFrontmostSkipsOtherwise() {
        let output = FakeOutput(front: FakeOutput.finder)
        let mapping = Mapping(name: "Logic only", target: Target(app: .logic, mode: .whenFrontmost), steps: [.shortcut(KeyCode.r)])
        XCTAssertEqual(MacroRunner(output: output).run(mapping, keyHoldMS: 5), .skipped("Logic Pro isn't in front"))
        XCTAssertTrue(output.keys.isEmpty)
        output.front = FakeOutput.logic
        guard case .finished = MacroRunner(output: output).run(mapping, keyHoldMS: 5) else { return XCTFail() }
        XCTAssertEqual(output.keys.count, 2)
    }

    func testKeysForTheFrontAppArentSentToKeystrikeItself() {
        let keystrike = RunningApp(pid: 300, bundleID: "com.kitedrake.keystrike", name: "Keystrike")
        let output = FakeOutput(apps: FakeOutput.defaultApps + [keystrike], front: keystrike)
        let runner = MacroRunner(output: output)
        runner.protectedApp = ("com.kitedrake.keystrike", "Keystrike")
        XCTAssertEqual(runner.run(Mapping(name: "Save", steps: [.shortcut(KeyCode.s, [.command])]), keyHoldMS: 5),
                       .skipped("Keystrike is in front; switch to the app the keys are for"))
        XCTAssertTrue(output.keys.isEmpty)
        // A mapping that brings its own app forward, or switches app first, still runs.
        let targeted = Mapping(name: "Bounce", target: Target(app: .logic, mode: .bringToFront), steps: [.shortcut(KeyCode.b)])
        guard case .finished = runner.run(targeted, keyHoldMS: 5) else { return XCTFail() }
        output.front = keystrike
        guard case .finished = runner.run(Mapping(name: "Switch", steps: [Step(.activate(.logic)), .shortcut(KeyCode.space)]),
                                          keyHoldMS: 5) else { return XCTFail() }
    }

    func testBringToFrontActivatesThenSwitchesBack() {
        let output = FakeOutput(front: FakeOutput.finder)
        let mapping = Mapping(name: "Bounce", target: Target(app: .logic, mode: .bringToFront, returnToPrevious: true),
                              steps: [.shortcut(KeyCode.b, [.control])])
        guard case .finished = MacroRunner(output: output).run(mapping, keyHoldMS: 5) else { return XCTFail() }
        let order = output.records.compactMap { record -> String? in
            switch record {
            case .activate(let name): "activate \(name)"
            case .down(let code, _, _) where code == KeyCode.b: "B"
            default: nil
            }
        }
        XCTAssertEqual(order, ["activate Logic Pro", "B", "activate Finder"])
    }

    func testBringToFrontSkipsWhenTheAppIsntOpenAndFailsWhenItWontComeForward() {
        let closed = FakeOutput(apps: [FakeOutput.finder], front: FakeOutput.finder)
        let mapping = Mapping(name: "Bounce", target: Target(app: .logic, mode: .bringToFront), steps: [.shortcut(KeyCode.b)])
        XCTAssertEqual(MacroRunner(output: closed).run(mapping, keyHoldMS: 5), .skipped("Logic Pro isn't open"))
        let stubborn = FakeOutput(front: FakeOutput.finder)
        stubborn.refusesActivation = true
        XCTAssertEqual(MacroRunner(output: stubborn).run(mapping, keyHoldMS: 5), .failed("Couldn't bring Logic Pro to the front"))
        XCTAssertTrue(stubborn.keys.isEmpty)
    }

    func testBackgroundSendsToTheProcess() {
        let output = FakeOutput(front: FakeOutput.finder)
        let mapping = Mapping(name: "Play", target: Target(app: .logic, mode: .background), steps: [.shortcut(KeyCode.space)])
        _ = MacroRunner(output: output).run(mapping, keyHoldMS: 5)
        XCTAssertEqual(output.keys, [.down(KeyCode.space, flags: 0, pid: 200), .up(KeyCode.space, flags: 0, pid: 200)])
        XCTAssertFalse(output.records.contains(.activate("Logic Pro")))
    }

    func testSwitchToAppStepOpensAnAppThatIsntRunning() {
        let output = FakeOutput(apps: [FakeOutput.finder], front: FakeOutput.finder)
        output.installed["com.apple.logic10"] = FakeOutput.logic
        let mapping = Mapping(name: "Open", steps: [Step(.activate(.logic)), .shortcut(KeyCode.space)])
        guard case .finished = MacroRunner(output: output).run(mapping, keyHoldMS: 5) else { return XCTFail() }
        XCTAssertEqual(output.records.first, .launch("Logic Pro"))
        XCTAssertEqual(MacroRunner(output: FakeOutput(apps: [])).run(mapping, keyHoldMS: 5), .failed("Couldn't open Logic Pro"))
    }

    func testStopAllInterruptsALongWaitAndDropsQueuedRuns() {
        let output = FakeOutput()
        let runner = MacroRunner(output: output)
        let started = expectation(description: "the wait began")
        var once = true
        output.onSleep = { _ in
            if once { once = false; started.fulfill() }
            Thread.sleep(forTimeInterval: 0.002)
        }
        let lock = NSLock()
        var outcomes: [RunEvent.Outcome] = []
        runner.onEvent = { event in lock.lock(); outcomes.append(event.outcome); lock.unlock() }
        let long = Mapping(name: "Long", steps: [.delay(60_000), .shortcut(KeyCode.a)])
        runner.enqueue(long, keyHoldMS: 5)
        runner.enqueue(long, keyHoldMS: 5)
        wait(for: [started], timeout: 2)
        runner.stopAll()
        runner.waitUntilIdle()
        XCTAssertEqual(outcomes, [.stopped, .stopped])
        XCTAssertTrue(output.keys.isEmpty)
        XCTAssertLessThan(output.sleptMS, 60_000)
        // Runs queued after stopping go ahead.
        runner.enqueue(Mapping(name: "After", steps: [.shortcut(KeyCode.a)]), keyHoldMS: 5)
        runner.waitUntilIdle()
        XCTAssertEqual(output.keys.count, 2)
    }

    func testTooManyWaitingRunsAreDropped() {
        let output = FakeOutput()
        let gate = DispatchSemaphore(value: 0)
        output.onSleep = { _ in gate.wait() }
        let runner = MacroRunner(output: output)
        let lock = NSLock()
        var dropped = 0
        runner.onEvent = { event in
            if event.outcome == .dropped { lock.lock(); dropped += 1; lock.unlock() }
        }
        let mapping = Mapping(name: "Knob", steps: [.delay(10)])
        for _ in 0..<(MacroRunner.maxPending + 5) { runner.enqueue(mapping, keyHoldMS: 1) }
        XCTAssertEqual(dropped, 5)
        output.onSleep = nil
        for _ in 0..<(MacroRunner.maxPending + 5) { gate.signal() }
        runner.waitUntilIdle()
        XCTAssertEqual(runner.pendingCount, 0)
    }

    func testEngineFiresOnlyWhileActiveAndNotLearning() {
        let output = FakeOutput()
        let engine = Engine(output: output)
        var setup = Setup(mappings: [Mapping(name: "A", trigger: Trigger(number: 1), steps: [.shortcut(KeyCode.a)])])
        engine.apply(setup)
        let message = MIDIMessage(kind: .controlChange, channel: 0, number: 1, value: 64)
        var fired: [[String]] = []
        engine.onMessage = { _, mappings in fired.append(mappings.map(\.name)) }
        engine.receive([message])
        engine.isLearning = true
        engine.receive([message])
        engine.isLearning = false
        setup.isActive = false
        engine.apply(setup)
        engine.receive([message])
        engine.runner.waitUntilIdle()
        XCTAssertEqual(fired, [["A"], [], []])
        XCTAssertEqual(output.keys.count, 2)
    }
}
