import KeystrikeCore
import SwiftUI

/// The sidebar: every mapping, with what fires it and what it does.
struct MappingList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        // A plain stack, not safeAreaInset: views pinned with safeAreaInset in the sidebar can blank it on macOS 26.
        VStack(spacing: 0) {
            List(selection: $model.selection) {
                Section("Mappings") {
                    ForEach(model.setup.mappings) { mapping in
                        MappingRow(mapping: mapping)
                            .tag(mapping.id)
                            .contextMenu { MappingMenu(id: mapping.id) }
                    }
                    .onMove { model.move(from: $0, to: $1) }
                }
            }
            InputsFooter()
        }
    }
}

struct MappingMenu: View {
    @Environment(AppModel.self) private var model
    let id: UUID

    var body: some View {
        Button("Run Now") { model.runNow(id) }
        Button("Learn Trigger") {
            model.selection = id
            model.startLearning(id)
        }
        Divider()
        Button("Duplicate") { model.duplicate(id) }
        Button("Export…") { model.exportMappings([id]) }
        Divider()
        Button("Delete", role: .destructive) { model.delete(id) }
    }
}

struct MappingRow: View {
    @Environment(AppModel.self) private var model
    let mapping: Mapping

    var body: some View {
        HStack(spacing: 10) {
            Toggle("Enabled", isOn: Binding(get: { mapping.isEnabled }, set: { value in model.update(mapping.id) { $0.isEnabled = value } }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .help(mapping.isEnabled ? "On: click to turn this mapping off" : "Off: click to turn this mapping on")
            VStack(alignment: .leading, spacing: 2) {
                Text(mapping.name.isEmpty ? "Untitled" : mapping.name)
                    .fontWeight(.medium)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(model.learning == mapping.id ? "Listening…" : mapping.trigger.summary)
                        .foregroundStyle(model.learning == mapping.id ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    Text("→").foregroundStyle(.tertiary)
                    Text(mapping.stepsSummary)
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
                .lineLimit(1)
            }
            .opacity(mapping.isEnabled ? 1 : 0.5)
            Spacer(minLength: 4)
            if let app = mapping.target.app {
                Image(nsImage: model.icon(for: app))
                    .help(mapping.target.summary)
            }
            Circle()
                .fill(model.flashing.contains(mapping.id) ? Color.green : Color.clear)
                .frame(width: 7, height: 7)
                .animation(.easeOut(duration: 0.25), value: model.flashing.contains(mapping.id))
                .accessibilityHidden(true)
        }
        .padding(.vertical, 3)
    }
}

/// Which MIDI inputs Keystrike hears, at the foot of the sidebar.
struct InputsFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            if let error = model.midiError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            } else if model.listenedSourceCount == 0 {
                Label("No MIDI inputs connected", systemImage: "cable.connector.slash")
                    .foregroundStyle(.secondary)
            } else {
                Label {
                    Text(model.sources.filter { !$0.isOffline && !model.setup.ignoredInputs.contains($0.name) }
                        .map(\.name).joined(separator: ", "))
                        .lineLimit(2)
                } icon: {
                    Image(systemName: "cable.connector")
                }
                .foregroundStyle(.secondary)
                .help("The MIDI inputs Keystrike listens to. Choose them in Settings.")
            }
            if model.offersVirtualPort {
                Label("MIDI port “Keystrike” open to other apps", systemImage: "arrow.down.to.line")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }
}
