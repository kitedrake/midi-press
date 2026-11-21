import AppKit
import MidiPressCore
import SwiftUI

/// Window › MIDI Monitor: incoming messages, the mappings they fired, and how each run went.
struct MonitorView: View {
    @Environment(AppModel.self) private var model

    static let timeFormat: Date.FormatStyle = .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits)
        .secondFraction(.fractional(3))

    var body: some View {
        ScrollViewReader { proxy in
            List(model.log) { line in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(line.date, format: Self.timeFormat)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Image(systemName: symbol(line))
                        .foregroundStyle(color(line))
                        .frame(width: 16)
                    Text(line.text)
                        .font(.callout.monospacedDigit())
                        .textSelection(.enabled)
                    Spacer(minLength: 8)
                    if let source = line.source {
                        Text(source)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .id(line.id)
            }
            .overlay {
                if model.log.isEmpty {
                    ContentUnavailableView("No MIDI yet", systemImage: "waveform.path.ecg",
                                           description: Text("Play a pad, a key or a knob: each message shows here with the mappings it fired."))
                }
            }
            .onChange(of: model.log.last?.id) { _, last in
                if let last { proxy.scrollTo(last, anchor: .bottom) }
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button { copy() } label: { Label("Copy", systemImage: "doc.on.doc") }
                    .help("Copy the log as text")
                    .disabled(model.log.isEmpty)
                Button { model.log.removeAll() } label: { Label("Clear", systemImage: "trash") }
                    .help("Clear the log")
                    .disabled(model.log.isEmpty)
            }
        }
        .navigationTitle("MIDI Monitor")
        .frame(minWidth: 460, minHeight: 260)
    }

    private func symbol(_ line: LogLine) -> String {
        switch line.kind {
        case .midi(_, let fired): fired.isEmpty ? "pianokeys" : "bolt.fill"
        case .run(_, let outcome):
            switch outcome {
            case .finished: "checkmark.circle.fill"
            case .skipped: "arrow.uturn.right.circle"
            case .failed, .dropped: "exclamationmark.triangle.fill"
            case .stopped: "stop.circle"
            }
        case .note: "info.circle"
        }
    }

    private func color(_ line: LogLine) -> Color {
        switch line.kind {
        case .midi(_, let fired): fired.isEmpty ? .secondary : .accentColor
        case .run(_, let outcome):
            switch outcome {
            case .finished: .green
            case .failed, .dropped: .orange
            default: .secondary
            }
        case .note: .secondary
        }
    }

    private func copy() {
        let text = model.log.map { line in
            "\(line.date.formatted(Self.timeFormat))  \(line.text)" + (line.source.map { "  [\($0)]" } ?? "")
        }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
