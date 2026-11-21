import AppKit
import MidiPressCore
import SwiftUI

@main
enum Main {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if ["--self-test", "--list-inputs", "--monitor", "--help"].contains(arguments.first ?? "") {
            exit(CommandLineTool.run(arguments))
        }
        MidiPressApp.main()
    }
}

struct MidiPressApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel.shared

    var body: some Scene {
        Window("MidiPress", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 860, minHeight: 540)
                .onAppear {
                    model.start()
                    Snapshot.runIfRequested(model)
                }
        }
        .defaultSize(width: 1080, height: 720)
        .commands {
            if let updates = Updates.shared {
                CommandGroup(after: .appInfo) { UpdateCommands(updates: updates) }
            }
            CommandGroup(replacing: .newItem) {
                Button("New Mapping") { model.addMapping() }
                    .keyboardShortcut("n")
                Button("Duplicate Mapping") { if let id = model.selection { model.duplicate(id) } }
                    .keyboardShortcut("d")
                    .disabled(model.selection == nil)
                Divider()
                Button("Import Mappings…") { model.importMappings() }
                Button("Export All Mappings…") { model.exportMappings() }
                    .disabled(model.setup.mappings.isEmpty)
                Button("Export Selected Mapping…") { if let id = model.selection { model.exportMappings([id]) } }
                    .disabled(model.selection == nil)
            }
            CommandGroup(after: .pasteboard) {
                // No ⌘⌫: in a text field it clears the line, and here it would delete the whole mapping.
                Button("Delete Mapping") { if let id = model.selection { model.delete(id) } }
                    .disabled(model.selection == nil)
            }
            CommandMenu("Mappings") {
                Toggle("Mappings Active", isOn: Binding(get: { model.setup.isActive }, set: { model.setup.isActive = $0 }))
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                Divider()
                Button(model.learning == nil ? "Learn Trigger" : "Stop Learning") {
                    if model.learning != nil { model.stopLearning() } else if let id = model.selection { model.startLearning(id) }
                }
                .keyboardShortcut("l")
                .disabled(model.selection == nil && model.learning == nil)
                Button("Run Now") { if let id = model.selection { model.runNow(id) } }
                    .keyboardShortcut("r")
                    .disabled(model.selection == nil)
                Button("Stop Running Mappings") { model.stopAll() }
                    .keyboardShortcut(".")
                Divider()
                ShowMonitorButton()
                    .keyboardShortcut("m", modifiers: [.command, .option])
            }
        }

        MenuBarExtra("MidiPress", systemImage: "pianokeys") {
            MenuBarContent()
                .environment(model)
        }

        Window("MIDI Monitor", id: "monitor") {
            MonitorView()
                .environment(model)
        }
        .defaultSize(width: 620, height: 420)

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        if !DockIcon.isShown { NSApp.setActivationPolicy(.accessory) }
    }

    /// Listening starts with the app, not with the window (which a menu-bar-only setup may never show).
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.start() }
    }

    /// Mappings keep working from the menu bar when the window is closed.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.stop() }
    }
}

struct ShowMonitorButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("MIDI Monitor") {
            openWindow(id: "monitor")
            NSApp.activate()
        }
    }
}

struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Toggle("Mappings Active", isOn: Binding(get: { model.setup.isActive }, set: { model.setup.isActive = $0 }))
        Text("\(model.setup.mappings.filter(\.isEnabled).count) mappings · \(model.listenedSourceCount) MIDI inputs")
        if !model.isTrusted {
            Divider()
            Text("MidiPress can't press keys yet")
            Button("Allow in Accessibility Settings…") { model.requestTrust() }
        }
        Divider()
        Button("Stop Running Mappings") { model.stopAll() }
        Divider()
        Button("Open MidiPress") {
            openWindow(id: "main")
            NSApp.activate()
        }
        ShowMonitorButton()
        Button("Settings…") {
            NSApp.activate()
            openSettings()
        }
        .keyboardShortcut(",")
        if let updates = Updates.shared {
            Button("Check for Updates…") {
                NSApp.activate()
                updates.checkNow()
            }
        }
        Button("Quit MidiPress") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            MappingList()
                .navigationSplitViewColumnWidth(min: 240, ideal: 290, max: 400)
        } detail: {
            Group {
                if let id = model.selection, model.mapping(id) != nil {
                    MappingEditor(id: id)
                        .id(id)
                } else if model.setup.mappings.isEmpty {
                    EmptyState()
                } else {
                    Text("Select a mapping")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            // An overlay, not a view above the form: changing the form's layout here blanks the sidebar on macOS 26.
            .overlay(alignment: .bottom) {
                if !model.isTrusted { AccessibilityBanner() }
            }
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Toggle(isOn: $model.setup.isActive) {
                        Label("Active", systemImage: "power")
                    }
                    .help(model.setup.isActive ? "Mappings are active. Click to pause them all." : "Mappings are paused. Click to turn them on.")
                    Button { model.addMapping() } label: { Label("New Mapping", systemImage: "plus") }
                        .help("Add a mapping: press a pad or move a control to set what fires it")
                    Button {
                        openWindow(id: "monitor")
                    } label: { Label("MIDI Monitor", systemImage: "waveform.path.ecg") }
                        .help("Show incoming MIDI and what each mapping did")
                }
            }
        }
        .navigationTitle("MidiPress")
        .navigationSubtitle(subtitle)
        .alert("MidiPress", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {
            Button("OK") { model.alert = nil }
        } message: {
            Text(model.alert ?? "")
        }
    }

    private var subtitle: String {
        guard model.setup.isActive else { return "Paused" }
        let inputs = model.listenedSourceCount
        return inputs == 1 ? "Listening to 1 MIDI input" : "Listening to \(inputs) MIDI inputs"
    }
}

/// Posting keys needs the Accessibility permission; until it's given macOS drops them without a word.
struct AccessibilityBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "hand.raised.fill")
                .font(.title2)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("MidiPress needs Accessibility access to press keys.")
                    .font(.headline)
                Text("Turn MidiPress on in System Settings › Privacy & Security › Accessibility. Mappings fire, but no keys reach your apps until then.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Allow…") { model.requestTrust() }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .padding(.horizontal, 24)
        .padding(.bottom, 18)
        .frame(maxWidth: 760)
    }
}

struct EmptyState: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "pianokeys")
                .font(.system(size: 50, weight: .light))
                .foregroundStyle(.secondary)
            VStack(spacing: 6) {
                Text("Turn MIDI into keystrokes")
                    .font(.title2.weight(.semibold))
                Text("Press a pad, hit a button or turn a knob on any MIDI controller, and MidiPress presses\nkeyboard shortcuts for you: one, or a whole sequence with pauses, in the app you choose.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button("New Mapping") { model.addMapping() }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
            Text("Then press the pad or move the control that should fire it.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
