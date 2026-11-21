import AppKit
import MidiPressCore
import Observation
import SwiftUI

/// One step of a mapping: a shortcut, a wait, text to type or an app to switch to.
struct StepRow: View {
    @Environment(AppModel.self) private var model
    @Binding var step: Step
    let index: Int
    let count: Int
    let move: (Int) -> Void
    let delete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text("\(index + 1)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 16, alignment: .trailing)
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            content
            Spacer(minLength: 4)
            Button { move(-1) } label: { Image(systemName: "chevron.up") }
                .disabled(index == 0)
                .help("Move up")
            Button { move(1) } label: { Image(systemName: "chevron.down") }
                .disabled(index == count - 1)
                .help("Move down")
            Button(action: delete) { Image(systemName: "minus.circle.fill") }
                .foregroundStyle(.secondary)
                .help("Remove this step")
        }
        .buttonStyle(.borderless)
        .contextMenu {
            Button("Move Up") { move(-1) }.disabled(index == 0)
            Button("Move Down") { move(1) }.disabled(index == count - 1)
            Divider()
            Button("Remove", role: .destructive, action: delete)
        }
    }

    private var symbol: String {
        switch step.action {
        case .shortcut: "command"
        case .delay: "timer"
        case .text: "character.cursor.ibeam"
        case .activate: "macwindow"
        }
    }

    @ViewBuilder private var content: some View {
        switch step.action {
        case .shortcut(let shortcut, let times):
            ShortcutField(shortcut: Binding(get: { shortcut }, set: { step.action = .shortcut($0, times: times) }))
            Stepper(value: Binding(get: { times }, set: { step.action = .shortcut(shortcut, times: max(1, min(99, $0))) }), in: 1...99) {
                Text(times == 1 ? "once" : "\(times) times")
                    .monospacedDigit()
                    .foregroundStyle(times == 1 ? .secondary : .primary)
            }
            .help("How many times to press it")
        case .delay(let ms):
            Text("Wait")
            NumberInput(value: Binding(get: { ms }, set: { step.action = .delay(milliseconds: $0) }), range: 0...600_000, step: 50)
            Text("ms").foregroundStyle(.secondary)
        case .text(let text):
            TextField("Text to type", text: Binding(get: { text }, set: { step.action = .text($0) }), prompt: Text("Text to type"))
                .textFieldStyle(.roundedBorder)
        case .activate(let app):
            Text("Switch to")
            AppMenu(app: app) { step.action = .activate($0) }
        }
    }
}

/// Picks an app for a Switch to App step.
struct AppMenu: View {
    @Environment(AppModel.self) private var model
    let app: AppRef
    let set: (AppRef) -> Void

    var body: some View {
        Menu {
            ForEach(model.appChoices) { choice in
                Button { set(choice) } label: { Label { Text(choice.name) } icon: { Image(nsImage: model.icon(for: choice)) } }
            }
            Divider()
            Button("Choose App…") { if let chosen = model.chooseApp() { set(chosen) } }
        } label: {
            Label { Text(app.name) } icon: { Image(nsImage: model.icon(for: app)) }
        }
        .fixedSize()
    }
}

// MARK: - Shortcut recording

/// The one shortcut field that is recording, and its key monitor. Recording ends with a key, a second click,
/// another field starting, or the window losing focus.
@MainActor
@Observable
final class ShortcutRecorder {
    static let shared = ShortcutRecorder()

    private(set) var active: UUID?
    /// Modifiers held so far while recording.
    private(set) var held: Modifiers = []
    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var resignObserver: Any?

    func start(_ id: UUID, onShortcut: @escaping (Shortcut) -> Void) {
        stop()
        active = id
        held = []
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            let isFlags = event.type == .flagsChanged
            let keyCode = event.keyCode
            let modifiers = Modifiers(event.modifierFlags)
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let self, self.active == id else { return false }
                if isFlags {
                    self.held = modifiers
                    return true
                }
                guard !KeyCatalog.modifierOnlyCodes.contains(keyCode) else { return true }
                onShortcut(Shortcut(keyCode: keyCode, modifiers: modifiers))
                self.stop()
                return true
            }
            return consumed ? nil : event  // a recorded key never reaches the app's own menus
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: nil,
                                                                queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        monitor = nil
        resignObserver = nil
        active = nil
        held = []
    }
}

extension Modifiers {
    init(_ flags: NSEvent.ModifierFlags) {
        self.init()
        if flags.contains(.control) { insert(.control) }
        if flags.contains(.option) { insert(.option) }
        if flags.contains(.shift) { insert(.shift) }
        if flags.contains(.command) { insert(.command) }
    }
}

/// Shows a shortcut; click it and press keys to record a new one. The menu beside it picks keys that can't be
/// typed here (ones macOS keeps for itself) and toggles modifiers.
struct ShortcutField: View {
    @Binding var shortcut: Shortcut
    @State private var id = UUID()
    private var recorder: ShortcutRecorder { ShortcutRecorder.shared }

    var body: some View {
        let recording = recorder.active == id
        HStack(spacing: 2) {
            Button {
                if recording { recorder.stop() } else { recorder.start(id) { shortcut = $0 } }
            } label: {
                Text(recording ? (recorder.held.isEmpty ? "Type shortcut…" : recorder.held.symbols + " …") : shortcut.display)
                    .font(.system(.body, design: .rounded).weight(recording ? .regular : .semibold))
                    .foregroundStyle(recording ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                    .frame(minWidth: 120)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 7).fill(.quaternary.opacity(recording ? 0.4 : 1)))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(recording ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), lineWidth: 1.5))
            }
            .buttonStyle(.plain)
            .help(recording ? "Press the keys (click again to cancel)" : "Click, then press the shortcut")
            .accessibilityLabel(recording ? "Recording shortcut" : "Shortcut \(shortcut.display)")
            Menu {
                KeyMenu(shortcut: $shortcut)
            } label: {
                Image(systemName: "keyboard.chevron.compact.down")
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.borderless)
            .fixedSize()
            .help("Pick a key or modifiers from a list")
        }
        .onDisappear { if recorder.active == id { recorder.stop() } }
    }
}

struct KeyMenu: View {
    @Binding var shortcut: Shortcut

    var body: some View {
        ForEach(KeyCatalog.Group.allCases, id: \.self) { group in
            Menu(group.rawValue) {
                ForEach(KeyCatalog.keys.filter { $0.group == group }, id: \.code) { key in
                    Button {
                        shortcut.keyCode = key.code
                    } label: {
                        if key.code == shortcut.keyCode {
                            Label(KeyCatalog.longName(for: key.code), systemImage: "checkmark")
                        } else {
                            Text(KeyCatalog.longName(for: key.code))
                        }
                    }
                }
            }
        }
        Divider()
        ForEach(Modifiers.ordered, id: \.2) { modifier, symbol, name in
            Toggle("\(symbol) \(name.capitalized)", isOn: Binding(
                get: { shortcut.modifiers.contains(modifier) },
                set: { if $0 { shortcut.modifiers.insert(modifier) } else { shortcut.modifiers.remove(modifier) } }))
        }
    }
}

// MARK: - Numbers

/// A labelled number with a stepper, clamped to its range.
struct NumberField: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    var note: String?
    var unit: String?
    var step = 1

    init(_ title: String, value: Binding<Int>, range: ClosedRange<Int>, note: String? = nil, unit: String? = nil, step: Int = 1) {
        self.title = title
        _value = value
        self.range = range
        self.note = note
        self.unit = unit
        self.step = step
    }

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                if let note {
                    Text(note)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                NumberInput(value: $value, range: range, step: step)
                if let unit { Text(unit).foregroundStyle(.secondary) }
            }
        }
    }
}

struct NumberInput: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    var step = 1

    var body: some View {
        HStack(spacing: 2) {
            TextField("", value: Binding(get: { value }, set: { value = min(range.upperBound, max(range.lowerBound, $0)) }),
                      format: .number.grouping(.never))
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: range.upperBound > 9999 ? 72 : 52)
                .textFieldStyle(.roundedBorder)
            Stepper("", value: $value, in: range, step: step)
                .labelsHidden()
        }
    }
}
