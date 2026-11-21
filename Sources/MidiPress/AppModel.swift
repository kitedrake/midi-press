import AppKit
import MidiPressCore
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// One line in the MIDI monitor.
struct LogLine: Identifiable, Hashable {
    enum Kind: Hashable {
        /// A message and the mappings it fired.
        case midi(MIDIMessage, fired: [String])
        /// The outcome of a run.
        case run(name: String, RunEvent.Outcome)
        case note(String)
    }

    let id = UUID()
    let date: Date
    let kind: Kind

    var text: String {
        switch kind {
        case .midi(let message, let fired):
            fired.isEmpty ? message.summary : "\(message.summary)  →  \(fired.joined(separator: ", "))"
        case .run(let name, let outcome):
            switch outcome {
            case .finished(let ms): "“\(name)” ran (\(ms) ms)"
            case .skipped(let reason): "“\(name)” skipped: \(reason)"
            case .failed(let reason): "“\(name)” failed: \(reason)"
            case .stopped: "“\(name)” stopped"
            case .dropped: "“\(name)” not run: too many runs waiting"
            }
        case .note(let text): text
        }
    }

    var source: String? {
        if case .midi(let message, _) = kind { return message.source?.name }
        return nil
    }

    var isProblem: Bool {
        if case .run(_, let outcome) = kind {
            switch outcome {
            case .failed, .dropped: return true
            default: return false
            }
        }
        return false
    }
}

/// Collects messages and run results from Core MIDI's and the runner's threads and hands them to the main thread
/// in batches, so a fast knob doesn't flood the UI.
final class EventInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [LogLine] = []
    private var fired: [UUID] = []
    private var learned: MIDIMessage?
    private var scheduled = false
    var deliver: (@MainActor ([LogLine], [UUID], MIDIMessage?) -> Void)?

    func message(_ message: MIDIMessage, fired mappings: [Mapping]) {
        add(LogLine(date: Date(), kind: .midi(message, fired: mappings.map(\.name))), fired: mappings.map(\.id), learned: message)
    }

    func run(_ event: RunEvent) {
        add(LogLine(date: Date(), kind: .run(name: event.name, event.outcome)), fired: [], learned: nil)
    }

    private func add(_ line: LogLine, fired ids: [UUID], learned message: MIDIMessage?) {
        lock.lock()
        lines.append(line)
        if lines.count > 400 { lines.removeFirst(lines.count - 400) }
        fired += ids
        // The first message after Learn is pressed (releases aren't what anyone means to learn).
        if learned == nil, let message, message.kind != .noteOff { learned = message }
        let needsFlush = !scheduled
        scheduled = true
        lock.unlock()
        guard needsFlush else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [self] in
            lock.lock()
            let batch = lines, ids = fired, message = learned
            lines = []
            fired = []
            learned = nil
            scheduled = false
            lock.unlock()
            MainActor.assumeIsolated { deliver?(batch, ids, message) }
        }
    }
}

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel(demo: ProcessInfo.processInfo.environment["MIDIPRESS_SNAPSHOT"] != nil)

    /// With `demo`, the made-up setup is there before any window is built (screenshots, see Snapshot).
    /// Otherwise the saved mappings are read here, also before any window exists: a sidebar list that fills in
    /// right after its window is built can come up blank on macOS 26.
    init(demo: Bool = false) {
        if demo { Demo.load(into: self) } else { loadSaved() }
    }

    var setup = Setup() {
        didSet { setupChanged(from: oldValue) }
    }
    var selection: UUID?
    var sources: [MIDISourceInfo] = []
    var log: [LogLine] = []
    /// The mapping whose trigger the next MIDI message sets.
    var learning: UUID?
    /// Mappings that just fired (their row lights up for a moment).
    var flashing: Set<UUID> = []
    var isTrusted = true
    /// Run Now's countdown, so there's time to switch to the app the keys are for.
    var countdown: (mapping: UUID, seconds: Int)?
    var alert: String?
    var isDemo = false
    /// False when setup.json came from a newer MidiPress: it is never overwritten.
    var canSave = true
    var virtualPortError: String?
    var midiError: String?

    @ObservationIgnored let engine = Engine(output: SystemKeyOutput())
    @ObservationIgnored let midi = MIDIInput()
    @ObservationIgnored let store = Store()
    @ObservationIgnored private let inbox = EventInbox()
    @ObservationIgnored private var started = false
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var learnTimeout: Task<Void, Never>?
    @ObservationIgnored private var countdownTask: Task<Void, Never>?
    @ObservationIgnored private var trustTimer: Timer?

    static var appVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev" }

    // MARK: Start and stop

    func start() {
        guard !started else { return }
        started = true
        guard !isDemo else { return }
        if let id = Bundle.main.bundleIdentifier { engine.runner.protectedApp = (id, "MidiPress") }
        inbox.deliver = { [weak self] lines, fired, learned in self?.receive(lines, fired: fired, learned: learned) }
        engine.onMessage = { [inbox] message, fired in inbox.message(message, fired: fired) }
        engine.runner.onEvent = { [inbox] event in inbox.run(event) }
        midi.onMessages = { [engine] messages in engine.receive(messages) }
        midi.onSourcesChanged = { [weak self] in self?.refreshSources() }
        engine.apply(setup)
        do {
            try midi.start()
            midi.setIgnored(Set(setup.ignoredInputs))
            applyVirtualPort()
        } catch {
            midiError = error.localizedDescription
        }
        refreshSources()
        checkTrust()
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AppModel.shared.checkTrust() }
        }
    }

    private func loadSaved() {
        switch store.load() {
        case .missing:
            setup = Setup()
        case .loaded(let loaded):
            setup = loaded
        case .newer(let loaded, let schema):
            setup = loaded ?? Setup()
            canSave = false
            alert = "Your mappings were saved by a newer version of MidiPress (format \(schema)). They're shown as far as this version can read them, and changes won't be saved. Update MidiPress to edit them."
        case .unreadable(let aside, let error):
            setup = Setup()
            alert = "MidiPress couldn't read its saved mappings, so it started empty. "
                + (aside.map { "The file was kept as \($0.lastPathComponent) in \($0.deletingLastPathComponent().path)." } ?? "")
                + "\n\n\(error)"
        }
        selection = setup.mappings.first?.id
    }

    func stop() {
        engine.runner.stopAll()
        saveNow()
    }

    private func setupChanged(from old: Setup) {
        guard old != setup else { return }
        engine.apply(setup)
        if old.ignoredInputs != setup.ignoredInputs, !isDemo { midi.setIgnored(Set(setup.ignoredInputs)) }
        scheduleSave()
    }

    private func scheduleSave() {
        guard !isDemo, canSave else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        guard !isDemo, canSave, started else { return }
        saveTask?.cancel()
        do {
            try store.save(setup)
        } catch {
            alert = "Couldn't save your mappings: \(error.localizedDescription)"
        }
    }

    // MARK: MIDI

    func refreshSources() {
        guard !isDemo else { return }
        sources = MIDIInput.sources().sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var listenedSourceCount: Int {
        sources.filter { !$0.isOffline && !setup.ignoredInputs.contains($0.name) }.count
    }

    static let virtualPortKey = "offersVirtualPort"
    static let virtualPortIDKey = "virtualPortUniqueID"

    var offersVirtualPort: Bool {
        get {
            access(keyPath: \.offersVirtualPort)
            return UserDefaults.standard.object(forKey: Self.virtualPortKey) as? Bool ?? true
        }
        set {
            withMutation(keyPath: \.offersVirtualPort) { UserDefaults.standard.set(newValue, forKey: Self.virtualPortKey) }
            applyVirtualPort()
        }
    }

    private func applyVirtualPort() {
        guard !isDemo else { return }
        do {
            let saved = UserDefaults.standard.object(forKey: Self.virtualPortIDKey) as? Int
            if let id = try midi.setVirtualPort(enabled: offersVirtualPort, uniqueID: saved.map { Int32(truncatingIfNeeded: $0) }) {
                UserDefaults.standard.set(Int(id), forKey: Self.virtualPortIDKey)
            }
            virtualPortError = nil
        } catch {
            virtualPortError = error.localizedDescription
        }
    }

    func setListening(to source: MIDISourceInfo, _ on: Bool) {
        var ignored = setup.ignoredInputs.filter { $0 != source.name }
        if !on { ignored.append(source.name) }
        setup.ignoredInputs = ignored.sorted()
    }

    private func receive(_ lines: [LogLine], fired: [UUID], learned: MIDIMessage?) {
        log.append(contentsOf: lines)
        if log.count > 500 { log.removeFirst(log.count - 500) }
        if !fired.isEmpty {
            let ids = Set(fired)
            flashing.formUnion(ids)
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(450))
                self?.flashing.subtract(ids)
            }
        }
        if let learned, let id = learning { learn(learned, into: id) }
    }

    // MARK: Learn

    func startLearning(_ id: UUID) {
        learning = id
        engine.isLearning = true
        learnTimeout?.cancel()
        learnTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled, self?.learning == id else { return }
            self?.stopLearning()
        }
    }

    func stopLearning() {
        learning = nil
        engine.isLearning = false
        learnTimeout?.cancel()
    }

    /// Sets a mapping's trigger from a message: its kind, number and channel; for a controller its exact value
    /// (a pad sends one value per press), for notes any velocity.
    func learn(_ message: MIDIMessage, into id: UUID) {
        update(id) { mapping in
            var trigger = mapping.trigger
            trigger.kind = message.kind
            trigger.number = message.number
            trigger.channel = message.channel
            switch message.kind {
            case .controlChange: trigger.value = .exactly(message.value)
            case .noteOn, .noteOff, .pitchBend, .programChange: trigger.value = .any
            }
            trigger.fire = .everyMessage
            if let source = trigger.source, !source.matches(message.source) { trigger.source = nil }
            mapping.trigger = trigger
        }
        stopLearning()
    }

    // MARK: Accessibility

    func checkTrust() {
        guard !isDemo else { return }
        isTrusted = SystemKeyOutput.isTrusted
        trustTimer?.invalidate()
        trustTimer = nil
        if !isTrusted {
            // macOS doesn't announce the change: look again every couple of seconds until it's allowed.
            trustTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
                MainActor.assumeIsolated {
                    let model = AppModel.shared
                    if SystemKeyOutput.isTrusted {
                        model.isTrusted = true
                        model.trustTimer?.invalidate()
                        model.trustTimer = nil
                    }
                }
            }
        }
    }

    func requestTrust() {
        guard !isDemo else { return }
        SystemKeyOutput.requestTrust()
        NSWorkspace.shared.open(SystemKeyOutput.accessibilitySettingsURL)
        checkTrust()
    }

    // MARK: Mappings

    func mapping(_ id: UUID?) -> Mapping? {
        guard let id else { return nil }
        return setup.mappings.first { $0.id == id }
    }

    func binding(for id: UUID) -> Binding<Mapping>? {
        guard setup.mappings.contains(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { [weak self] in self?.setup.mappings.first { $0.id == id } ?? Mapping(name: "") },
            set: { [weak self] new in self?.update(id) { $0 = new } })
    }

    func update(_ id: UUID, _ change: (inout Mapping) -> Void) {
        guard let index = setup.mappings.firstIndex(where: { $0.id == id }) else { return }
        change(&setup.mappings[index])
    }

    /// A new mapping, selected, listening for the control that should fire it.
    func addMapping() {
        let mapping = Mapping(name: nextName("New Mapping"), trigger: Trigger(kind: .controlChange, number: 0, value: .any))
        insert(mapping)
        startLearning(mapping.id)
    }

    func duplicate(_ id: UUID) {
        guard var copy = mapping(id) else { return }
        copy.id = UUID()
        copy.name = nextName(copy.name + " Copy")
        copy.steps = copy.steps.map { Step($0.action) }
        insert(copy, after: id)
    }

    private func insert(_ mapping: Mapping, after id: UUID? = nil) {
        if let id, let index = setup.mappings.firstIndex(where: { $0.id == id }) {
            setup.mappings.insert(mapping, at: index + 1)
        } else {
            setup.mappings.append(mapping)
        }
        selection = mapping.id
    }

    func delete(_ id: UUID) {
        guard let index = setup.mappings.firstIndex(where: { $0.id == id }) else { return }
        if learning == id { stopLearning() }
        setup.mappings.remove(at: index)
        if selection == id {
            selection = setup.mappings.indices.contains(index) ? setup.mappings[index].id : setup.mappings.last?.id
        }
    }

    func move(from offsets: IndexSet, to destination: Int) {
        setup.mappings.move(fromOffsets: offsets, toOffset: destination)
    }

    private func nextName(_ base: String) -> String {
        let names = Set(setup.mappings.map(\.name))
        guard names.contains(base) else { return base }
        var number = 2
        while names.contains("\(base) \(number)") { number += 1 }
        return "\(base) \(number)"
    }

    // MARK: Running

    /// Runs a mapping now. When the keys go to whichever app is in front (or only to an app that's in front),
    /// waits three seconds first so there's time to switch to it.
    func runNow(_ id: UUID) {
        guard let mapping = mapping(id), !isDemo else { return }
        countdownTask?.cancel()
        if let app = mapping.target.app, mapping.target.mode != .whenFrontmost, !app.bundleID.isEmpty {
            countdown = nil
            engine.runNow(mapping)
            return
        }
        countdownTask = Task { [weak self] in
            for seconds in stride(from: 3, through: 1, by: -1) {
                self?.countdown = (id, seconds)
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
            }
            self?.countdown = nil
            if let current = self?.mapping(id) { self?.engine.runNow(current) }
        }
    }

    func cancelCountdown() {
        countdownTask?.cancel()
        countdown = nil
    }

    func stopAll() {
        cancelCountdown()
        engine.runner.stopAll()
        log.append(LogLine(date: Date(), kind: .note("Stopped all running mappings")))
    }

    // MARK: Apps

    /// Apps to offer as targets: the ones in use by mappings, then the running ones.
    var appChoices: [AppRef] {
        var seen = Set<String>()
        var apps: [AppRef] = []
        func add(_ app: AppRef) {
            guard !app.bundleID.isEmpty, app.bundleID != Bundle.main.bundleIdentifier, seen.insert(app.bundleID).inserted else { return }
            apps.append(app)
        }
        for mapping in setup.mappings {
            if let app = mapping.target.app { add(app) }
            for step in mapping.steps { if case .activate(let app) = step.action { add(app) } }
        }
        if !isDemo {
            let running = NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular }
                .compactMap { app -> AppRef? in
                    guard let id = app.bundleIdentifier else { return nil }
                    return AppRef(bundleID: id, name: app.localizedName ?? id)
                }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            running.forEach(add)
        } else {
            Demo.runningApps.forEach(add)
        }
        return apps
    }

    func chooseApp() -> AppRef? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Choose"
        panel.message = "Choose the app the keys are for."
        guard panel.runModal() == .OK, let url = panel.url, let bundle = Bundle(url: url), let id = bundle.bundleIdentifier
        else { return nil }
        let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        return AppRef(bundleID: id, name: name)
    }

    @ObservationIgnored private var iconCache: [String: NSImage] = [:]

    func icon(for app: AppRef) -> NSImage {
        if let cached = iconCache[app.bundleID] { return cached }
        let image: NSImage
        if isDemo, let symbol = Demo.appSymbols[app.bundleID],
           let drawn = NSImage(systemSymbolName: symbol, accessibilityDescription: app.name) {
            image = drawn
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID) {
            image = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            image = NSWorkspace.shared.icon(for: .application)
        }
        image.size = NSSize(width: 16, height: 16)
        iconCache[app.bundleID] = image
        return image
    }

    // MARK: Import and export

    func exportMappings(_ ids: [UUID]? = nil) {
        let mappings = ids.map { ids in setup.mappings.filter { ids.contains($0.id) } } ?? setup.mappings
        guard !mappings.isEmpty, !isDemo else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = mappings.count == 1 ? "\(mappings[0].name).json" : "MidiPress Mappings.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try MappingFile(mappings: mappings).encoded().write(to: url, options: .atomic)
        } catch {
            alert = "Couldn't export: \(error.localizedDescription)"
        }
    }

    func importMappings() {
        guard !isDemo else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        var added: [Mapping] = []
        for url in panel.urls {
            do {
                added += try MappingFile.mappings(from: Data(contentsOf: url))
            } catch {
                alert = "Couldn't import \(url.lastPathComponent): it isn't a MidiPress mappings file."
            }
        }
        guard !added.isEmpty else { return }
        setup.mappings += added
        selection = added.first?.id
    }

    // MARK: Demo

    func loadDemo(_ setup: Setup, sources: [MIDISourceInfo], log: [LogLine]) {
        isDemo = true
        started = true
        self.setup = setup
        self.sources = sources
        self.log = log
        selection = setup.mappings.first?.id
    }
}
