import Foundation
@testable import KeystrikeCore

/// Records what the runner would do, with a made-up set of running apps. Sleeping only adds up time.
final class FakeOutput: KeyOutput, @unchecked Sendable {
    enum Record: Equatable {
        case down(UInt16, flags: UInt64, pid: pid_t?)
        case up(UInt16, flags: UInt64, pid: pid_t?)
        case text(String, down: Bool, pid: pid_t?)
        case activate(String)
        case launch(String)
        case sleep(Int)
    }

    private let lock = NSLock()
    private var _records: [Record] = []
    var apps: [RunningApp]
    var front: RunningApp?
    var refusesActivation = false
    var installed: [String: RunningApp] = [:]
    /// Called on every sleep (lets a test stop a run part-way).
    var onSleep: ((Int) -> Void)?

    init(apps: [RunningApp] = FakeOutput.defaultApps, front: RunningApp? = FakeOutput.defaultApps.first) {
        self.apps = apps
        self.front = front
    }

    static let finder = RunningApp(pid: 100, bundleID: "com.apple.finder", name: "Finder")
    static let logic = RunningApp(pid: 200, bundleID: "com.apple.logic10", name: "Logic Pro")
    static let defaultApps = [finder, logic]

    var records: [Record] {
        lock.lock()
        defer { lock.unlock() }
        return _records
    }

    /// Key and text events only.
    var keys: [Record] {
        records.filter {
            switch $0 {
            case .down, .up, .text: true
            default: false
            }
        }
    }

    var sleptMS: Int {
        records.reduce(0) { total, record in
            if case .sleep(let ms) = record { return total + ms }
            return total
        }
    }

    private func add(_ record: Record) {
        lock.lock()
        _records.append(record)
        lock.unlock()
    }

    func post(_ event: KeyEvent, toProcess pid: pid_t?) {
        switch event {
        case .key(let code, let down, let flags): add(down ? .down(code, flags: flags, pid: pid) : .up(code, flags: flags, pid: pid))
        case .text(let text, let down): add(.text(text, down: down, pid: pid))
        }
    }

    func frontmostApp() -> RunningApp? { front }

    func runningApp(bundleID: String) -> RunningApp? { apps.first { $0.bundleID == bundleID } }

    func activate(_ app: RunningApp) -> Bool {
        add(.activate(app.name))
        guard !refusesActivation else { return false }
        front = app
        return true
    }

    func launch(_ app: AppRef) -> RunningApp? {
        add(.launch(app.name))
        guard let running = installed[app.bundleID] else { return nil }
        apps.append(running)
        front = running
        return running
    }

    func sleep(milliseconds: Int) {
        add(.sleep(milliseconds))
        onSleep?(milliseconds)
    }
}

extension AppRef {
    static let logic = AppRef(bundleID: "com.apple.logic10", name: "Logic Pro")
}
