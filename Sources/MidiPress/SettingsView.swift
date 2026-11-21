import AppKit
import MidiPressCore
import ServiceManagement
import SwiftUI

/// Whether MidiPress shows a Dock icon. Without one it lives in the menu bar (mappings never need the window).
enum DockIcon {
    static let key = "showsDockIcon"

    static var isShown: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }

    @MainActor static func apply(_ shown: Bool) {
        NSApp.setActivationPolicy(shown ? .regular : .accessory)
        // Switching policy can send the app behind other apps; keep the window that was just used in front.
        DispatchQueue.main.async { NSApp.activate() }
    }
}

/// MidiPress › Settings…: login, Dock icon, key timing, MIDI inputs and the virtual port.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(DockIcon.key) private var showsDockIcon = true
    @State private var loginStatus = SMAppService.Status.notRegistered
    @State private var loginError: String?

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Toggle("Open at login", isOn: Binding(
                    get: { loginStatus == .enabled || loginStatus == .requiresApproval },
                    set: { setOpensAtLogin($0) }))
                if loginStatus == .requiresApproval {
                    HStack {
                        Text("macOS needs your approval in System Settings › General › Login Items.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
                if let loginError {
                    Text(loginError).font(.callout).foregroundStyle(.red)
                }
                Toggle("Show in Dock", isOn: $showsDockIcon)
            } footer: {
                Text("Mappings work as long as MidiPress is open, also with its window closed. Without the Dock icon, open the window and these settings from the menu bar icon.")
            }

            Section {
                NumberField("Hold each key for", value: $model.setup.keyHoldMS, range: 1...500, unit: "ms")
            } header: {
                Text("Keys")
            } footer: {
                Text("Some apps miss keys pressed very briefly. If a shortcut is ignored, hold keys longer or add a pause between steps.")
            }

            Section {
                if model.sources.isEmpty {
                    Text("No MIDI inputs. Connect a controller; it shows up here.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.sources) { source in
                    Toggle(isOn: Binding(get: { !model.setup.ignoredInputs.contains(source.name) },
                                         set: { model.setListening(to: source, $0) })) {
                        HStack {
                            Text(source.name)
                            if source.isOffline { Text("offline").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
                Toggle("Offer a MIDI port named “MidiPress”", isOn: $model.offersVirtualPort)
                if let error = model.virtualPortError {
                    Text(error).font(.callout).foregroundStyle(.red)
                }
            } header: {
                Text("MIDI Inputs")
            } footer: {
                Text("MidiPress listens to the inputs that are on. Other apps (a DAW's MIDI output, a script) can also send to the “MidiPress” port.")
            }

            Section {
                LabeledContent("Accessibility") {
                    if model.isTrusted {
                        Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        HStack {
                            Label("Not allowed", systemImage: "xmark.circle.fill").foregroundStyle(.orange)
                            Button("Allow…") { model.requestTrust() }
                        }
                    }
                }
            } header: {
                Text("Permission")
            } footer: {
                Text("macOS only lets apps with Accessibility access press keys for you. MidiPress sends nothing anywhere: it reads MIDI and presses keys on this Mac.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            loginStatus = model.isDemo ? .notRegistered : SMAppService.mainApp.status
            model.refreshSources()
            model.checkTrust()
        }
        .onChange(of: showsDockIcon) { _, shown in if !model.isDemo { DockIcon.apply(shown) } }
    }

    private func setOpensAtLogin(_ on: Bool) {
        guard !model.isDemo else { return }  // screenshots never register a login item
        loginError = nil
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            loginError = "Couldn't change it: \(error.localizedDescription)"
        }
        loginStatus = SMAppService.mainApp.status
    }
}
