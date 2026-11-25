import MidiPressCore
import SwiftUI

/// The detail pane: what fires a mapping (When), which app gets the keys (Where) and the steps (Do).
struct MappingEditor: View {
    @Environment(AppModel.self) private var model
    let id: UUID

    var body: some View {
        if let mapping = model.binding(for: id) {
            Form {
                Section {
                    TextField("Name", text: mapping.name, prompt: Text("What it does, e.g. Bounce in Place"))
                    Toggle("Enabled", isOn: mapping.isEnabled)
                }
                TriggerSection(id: id, trigger: mapping.trigger)
                TargetSection(target: mapping.target)
                StepsSection(id: id, mapping: mapping)
            }
            .formStyle(.grouped)
        }
    }
}

// MARK: - When

struct TriggerSection: View {
    @Environment(AppModel.self) private var model
    let id: UUID
    @Binding var trigger: Trigger

    var body: some View {
        Section {
            LearnRow(id: id, trigger: trigger)
            Picker("Message", selection: $trigger.kind) {
                ForEach(MessageKind.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            if let title = trigger.kind.numberTitle {
                NumberField(title, value: $trigger.number, range: 0...127,
                            note: trigger.kind == .noteOn || trigger.kind == .noteOff ? NoteName.name(trigger.number) : nil)
            }
            if let valueTitle = trigger.kind.valueTitle {
                Picker(valueTitle, selection: $trigger.value.mode) {
                    Text("Any").tag(ValueMatch.Mode.any)
                    Text("Exactly").tag(ValueMatch.Mode.exactly)
                    Text("Between").tag(ValueMatch.Mode.between)
                }
                .pickerStyle(.segmented)
                switch trigger.value.mode {
                case .any:
                    EmptyView()
                case .exactly:
                    NumberField("\(valueTitle) is", value: $trigger.value.low, range: 0...trigger.kind.maxValue)
                case .between:
                    LabeledContent("\(valueTitle) from") {
                        HStack {
                            NumberInput(value: $trigger.value.low, range: 0...trigger.kind.maxValue)
                            Text("to")
                            NumberInput(value: $trigger.value.high, range: 0...trigger.kind.maxValue)
                        }
                    }
                }
                if trigger.value.mode != .any, trigger.kind == .controlChange || trigger.kind == .pitchBend {
                    Picker("Fires", selection: $trigger.fire) {
                        Text("On every matching message").tag(FireMode.everyMessage)
                        Text("Once each time the value enters the range").tag(FireMode.onEnter)
                    }
                }
            }
            Picker("Channel", selection: $trigger.channel) {
                Text("Any").tag(Int?.none)
                Divider()
                ForEach(0..<16, id: \.self) { Text("\($0 + 1)").tag(Int?.some($0)) }
            }
            Picker("Input", selection: $trigger.source) {
                Text("Any input").tag(SourceRef?.none)
                Divider()
                ForEach(sourceChoices, id: \.self) { ref in
                    Text(isConnected(ref) ? ref.name : "\(ref.name) (not connected)").tag(SourceRef?.some(ref))
                }
            }
        } header: {
            Text("When")
        } footer: {
            Text(footer)
        }
    }

    private var sourceChoices: [SourceRef] {
        var refs = model.sources.map(\.ref)
        if let port = model.virtualPort { refs.append(port) }
        if let saved = trigger.source, !refs.contains(saved) { refs.append(saved) }
        return refs
    }

    private func isConnected(_ ref: SourceRef) -> Bool {
        ref == model.virtualPort || model.sources.contains { !$0.isOffline && ref.matches($0.ref) }
    }

    private var footer: String {
        switch trigger.kind {
        case .controlChange:
            if trigger.value.mode == .any { return "Fires on every message from this controller: fine for a button, busy for a knob." }
            return trigger.fire == .onEnter
                ? "Fires once when a knob or fader moves into the range, and again only after it leaves and comes back."
                : "A pad set to send one value fires once per press. An endless encoder sends 1 (or 65) one way and 127 (or 63) the other: map each to its own shortcut."
        case .noteOn: return "Fires when the pad or key is pressed. Notes are named with middle C (60) as C3."
        case .noteOff: return "Fires when the pad or key is released (a Note On with velocity 0 counts too)."
        case .programChange: return "Fires when this program is selected."
        case .pitchBend: return "Pitch bend runs from 0 to 16383, with 8192 in the middle."
        }
    }
}

struct LearnRow: View {
    @Environment(AppModel.self) private var model
    let id: UUID
    let trigger: Trigger

    var body: some View {
        let listening = model.learning == id
        HStack(spacing: 10) {
            Image(systemName: listening ? "dot.radiowaves.left.and.right" : "pianokeys")
                .font(.title3)
                .foregroundStyle(listening ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .symbolEffect(.variableColor.iterative, isActive: listening)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(listening ? "Listening…" : trigger.summary)
                    .font(.title3.weight(.semibold))
                Text(listening ? "Press a pad, hit a button or move a control." : trigger.source.map { "From \($0.name)" } ?? "From any MIDI input")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Circle()
                .fill(model.flashing.contains(id) ? Color.green : Color.secondary.opacity(0.2))
                .frame(width: 10, height: 10)
                .help("Lights up when this mapping fires")
            if listening {
                Button("Cancel") { model.stopLearning() }
                    .buttonStyle(.glass)
            } else {
                Button("Learn") { model.startLearning(id) }
                    .buttonStyle(.glassProminent)
                    .help("Set the trigger, and the input it comes from, from the next MIDI message (⌘L)")
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Where

struct TargetSection: View {
    @Environment(AppModel.self) private var model
    @Binding var target: Target

    static let chooseTag = "\u{1}choose"

    var body: some View {
        Section {
            Picker("App", selection: appSelection) {
                Text("Whichever app is in front").tag(String?.none)
                Divider()
                ForEach(model.appChoices) { app in
                    Label { Text(app.name) } icon: { Image(nsImage: model.icon(for: app)) }
                        .tag(String?.some(app.bundleID))
                }
                Divider()
                Text("Choose App…").tag(String?.some(Self.chooseTag))
            }
            if target.app != nil {
                Picker("Keys go", selection: $target.mode) {
                    ForEach(TargetMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.radioGroup)
                if target.mode == .bringToFront {
                    Toggle("Switch back to the app that was in front", isOn: $target.returnToPrevious)
                }
            }
        } header: {
            Text("Where")
        } footer: {
            Text(footer)
        }
    }

    private var appSelection: Binding<String?> {
        Binding(
            get: { target.app?.bundleID },
            set: { value in
                if value == Self.chooseTag {
                    if let app = model.chooseApp() { target.app = app }
                } else if let value {
                    target.app = model.appChoices.first { $0.bundleID == value } ?? target.app
                } else {
                    target.app = nil
                }
            })
    }

    private var footer: String {
        guard let app = target.app else {
            return "Keys go to whatever app you're using when the mapping fires."
        }
        switch target.mode {
        case .whenFrontmost:
            return "Does nothing unless \(app.name) is the app in front. Map the same control in other apps to give it a different job in each."
        case .bringToFront:
            return "Brings \(app.name) forward first (if it's open), so it works from anywhere."
        case .background:
            return "\(app.name) stays where it is. Many apps ignore keys sent this way; if nothing happens, bring it to the front instead."
        }
    }
}

// MARK: - Do

struct StepsSection: View {
    @Environment(AppModel.self) private var model
    let id: UUID
    @Binding var mapping: Mapping

    var body: some View {
        Section {
            if mapping.steps.isEmpty {
                Text("Add the keys to press. Add more steps to press several shortcuts one after another.")
                    .foregroundStyle(.secondary)
            }
            ForEach($mapping.steps) { $step in
                StepRow(step: $step, index: mapping.steps.firstIndex { $0.id == step.id } ?? 0, count: mapping.steps.count,
                        move: { move(step.id, by: $0) }, delete: { delete(step.id) })
            }
            .onMove { mapping.steps.move(fromOffsets: $0, toOffset: $1) }
            HStack(spacing: 8) {
                Button { add(.shortcut(Shortcut(keyCode: KeyCode.returnKey), times: 1)) } label: { Label("Shortcut", systemImage: "command") }
                Button { add(.delay(milliseconds: 250)) } label: { Label("Wait", systemImage: "timer") }
                Button { add(.text("")) } label: { Label("Text", systemImage: "character.cursor.ibeam") }
                Button { addSwitch() } label: { Label("Switch to App", systemImage: "macwindow") }
                Spacer()
            }
            .buttonStyle(.glass)
            NumberField("Pause between steps", value: $mapping.stepPauseMS, range: 0...5000, unit: "ms", step: 10)
        } header: {
            HStack {
                Text("Do")
                Spacer()
                RunButton(id: id)
            }
        } footer: {
            Text("Steps run in order, with the pause after each one (and between repeats). A Wait step sets the gap itself. Stop a running mapping with ⌘. or from the menu bar.")
        }
    }

    private func add(_ action: Action) {
        mapping.steps.append(Step(action))
    }

    private func addSwitch() {
        let app = mapping.target.app ?? model.appChoices.first ?? AppRef(bundleID: "com.apple.finder", name: "Finder")
        add(.activate(app))
    }

    private func delete(_ stepID: UUID) {
        mapping.steps.removeAll { $0.id == stepID }
    }

    private func move(_ stepID: UUID, by offset: Int) {
        guard let index = mapping.steps.firstIndex(where: { $0.id == stepID }) else { return }
        let target = index + offset
        guard mapping.steps.indices.contains(target) else { return }
        mapping.steps.swapAt(index, target)
    }
}

struct RunButton: View {
    @Environment(AppModel.self) private var model
    let id: UUID

    var body: some View {
        if let countdown = model.countdown, countdown.mapping == id {
            HStack(spacing: 6) {
                Text("Switch to the app: running in \(countdown.seconds)…")
                    .foregroundStyle(.tint)
                Button("Cancel") { model.cancelCountdown() }
                    .controlSize(.small)
            }
            .textCase(nil)
        } else {
            Button { model.runNow(id) } label: { Label("Run Now", systemImage: "play.fill") }
                .controlSize(.small)
                .disabled(model.mapping(id)?.steps.isEmpty ?? true)
                .help("Run the steps now (⌘R). When the keys go to the app in front, you get three seconds to switch to it.")
                .textCase(nil)
        }
    }
}
