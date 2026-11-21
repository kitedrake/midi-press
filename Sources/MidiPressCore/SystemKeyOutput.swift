import AppKit
import ApplicationServices
import CoreGraphics

/// Presses keys for real (Quartz events) and brings apps to the front.
///
/// Posting key events needs the Accessibility permission (System Settings › Privacy & Security ›
/// Accessibility); without it macOS drops them silently, so the app checks `isTrusted` and says so.
public final class SystemKeyOutput: KeyOutput, @unchecked Sendable {
    /// Marks MidiPress's own events (`eventSourceUserData`), so they can be told apart from real typing.
    public static let marker: Int64 = 0x4D44_5052  // "MDPR"

    private let source: CGEventSource?

    public init() {
        // A private event source: the flags on each event are exactly the ones set here, whatever keys are held
        // on the real keyboard.
        source = CGEventSource(stateID: .privateState)
        // Don't lock out the real keyboard and mouse for a moment after each synthetic event.
        source?.localEventsSuppressionInterval = 0
    }

    // MARK: Permission

    /// Whether macOS lets MidiPress press keys (Accessibility).
    public static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows macOS's own prompt, which leads to the Accessibility list in System Settings.
    public static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    public static let accessibilitySettingsURL =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!

    // MARK: KeyOutput

    public func post(_ event: KeyEvent, toProcess pid: pid_t?) {
        let cgEvent: CGEvent?
        switch event {
        case .key(let code, let down, let flags):
            cgEvent = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
            cgEvent?.flags = CGEventFlags(rawValue: flags)
        case .text(let text, let down):
            cgEvent = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
            cgEvent?.flags = []
            let units = Array(text.utf16)
            cgEvent?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
        }
        guard let cgEvent else { return }
        cgEvent.setIntegerValueField(.eventSourceUserData, value: Self.marker)
        if let pid {
            cgEvent.postToPid(pid)
        } else {
            cgEvent.post(tap: .cghidEventTap)
        }
    }

    public func frontmostApp() -> RunningApp? {
        onMain { NSWorkspace.shared.frontmostApplication.map(RunningApp.init) }
    }

    public func runningApp(bundleID: String) -> RunningApp? {
        onMain {
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .first { !$0.isTerminated }
                .map(RunningApp.init)
        }
    }

    /// Asks politely first; if macOS declines (it can refuse activation requests from an app in the background),
    /// uses Accessibility to make the app frontmost, then opens it as the Dock would.
    public func activate(_ app: RunningApp) -> Bool {
        let deadline = Date().addingTimeInterval(2)
        onMain { _ = NSRunningApplication(processIdentifier: app.pid)?.activate(options: [.activateAllWindows]) }
        if waitUntilFront(app.pid, until: Date().addingTimeInterval(0.3)) { return settled() }
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(app.pid), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        if waitUntilFront(app.pid, until: Date().addingTimeInterval(0.3)) { return settled() }
        if let url = onMain({ NSRunningApplication(processIdentifier: app.pid)?.bundleURL }) {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        }
        return waitUntilFront(app.pid, until: deadline) ? settled() : false
    }

    public func launch(_ app: AppRef) -> RunningApp? {
        guard let url = onMain({ NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID) }) else { return nil }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var launched: NSRunningApplication?
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { running, _ in
            launched = running
            done.signal()
        }
        _ = done.wait(timeout: .now() + 20)
        guard let launched else { return nil }
        let deadline = Date().addingTimeInterval(20)
        while !onMain({ launched.isFinishedLaunching }), Date() < deadline { usleep(50_000) }
        _ = waitUntilFront(launched.processIdentifier, until: deadline)
        _ = settled()
        return onMain { RunningApp(launched) }
    }

    public func sleep(milliseconds: Int) {
        guard milliseconds > 0 else { return }
        usleep(useconds_t(milliseconds) * 1000)
    }

    // MARK: Helpers

    private func waitUntilFront(_ pid: pid_t, until deadline: Date) -> Bool {
        while Date() < deadline {
            if frontmostApp()?.pid == pid { return true }
            usleep(15_000)
        }
        return frontmostApp()?.pid == pid
    }

    /// Gives a newly active app a moment to make its window key before keys arrive.
    private func settled() -> Bool {
        usleep(80_000)
        return true
    }

    private func onMain<T>(_ body: () -> T) -> T {
        Thread.isMainThread ? body() : DispatchQueue.main.sync(execute: body)
    }
}

extension RunningApp {
    init(_ app: NSRunningApplication) {
        self.init(pid: app.processIdentifier, bundleID: app.bundleIdentifier,
                  name: app.localizedName ?? app.bundleIdentifier ?? "App \(app.processIdentifier)")
    }
}
