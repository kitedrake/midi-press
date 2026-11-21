import CoreMIDI
import Foundation

/// A MIDI input Core MIDI offers.
public struct MIDISourceInfo: Identifiable, Hashable, Sendable {
    public var ref: SourceRef
    public var isOffline: Bool
    public var id: Int32 { ref.uniqueID }
    public var name: String { ref.name }

    public init(ref: SourceRef, isOffline: Bool) {
        self.ref = ref
        self.isOffline = isOffline
    }
}

public struct MIDIError: LocalizedError {
    public var operation: String
    public var status: OSStatus
    public var errorDescription: String? { "\(operation) failed (Core MIDI error \(status))." }
}

/// Listens to every MIDI input (except ignored ones) and, optionally, to a virtual MIDI port named "MidiPress"
/// that other apps (a DAW, a script) can send to.
public final class MIDIInput: @unchecked Sendable {
    public static let defaultPortName = "MidiPress"

    /// Called on Core MIDI's receive thread with each batch of decoded messages.
    public var onMessages: (([MIDIMessage]) -> Void)?
    /// Called on the main thread when inputs appear, disappear or go offline.
    public var onSourcesChanged: (() -> Void)?

    private var client = MIDIClientRef()
    private var port = MIDIPortRef()
    private var destination = MIDIEndpointRef()
    private var destinationRef: SourceRef?
    private let lock = NSLock()
    /// Connected sources: endpoint → token passed as the connection's refCon.
    private var connections: [MIDIEndpointRef: Int] = [:]
    private var tokens: [Int: SourceRef] = [:]
    private var nextToken = 1
    private var ignored: Set<String> = []
    private var isStarted = false

    public init() {}

    deinit {
        if destination != 0 { MIDIEndpointDispose(destination) }
        if port != 0 { MIDIPortDispose(port) }
        if client != 0 { MIDIClientDispose(client) }
    }

    public func start(clientName: String = "MidiPress") throws {
        guard !isStarted else { return }
        var status = MIDIClientCreateWithBlock(clientName as CFString, &client) { [weak self] notification in
            guard notification.pointee.messageID == .msgSetupChanged else { return }
            DispatchQueue.main.async {
                self?.reconnect()
                self?.onSourcesChanged?()
            }
        }
        guard status == noErr else { throw MIDIError(operation: "Creating the MIDI client", status: status) }
        status = MIDIInputPortCreateWithProtocol(client, "\(clientName) Input" as CFString, ._1_0, &port) { [weak self] list, refCon in
            self?.receive(list, token: Int(bitPattern: refCon))
        }
        guard status == noErr else { throw MIDIError(operation: "Creating the MIDI input port", status: status) }
        isStarted = true
        reconnect()
    }

    /// Inputs (by name) not to listen to.
    public func setIgnored(_ names: Set<String>) {
        lock.lock()
        ignored = names
        lock.unlock()
        reconnect()
    }

    /// Connects every source that isn't ignored and disconnects the rest. Safe to call at any time.
    public func reconnect() {
        guard isStarted else { return }
        let sources = Self.sourceEndpoints()
        lock.lock()
        let ignored = ignored
        var wanted: [MIDIEndpointRef: SourceRef] = [:]
        for (endpoint, ref) in sources where !ignored.contains(ref.name) && endpoint != destination { wanted[endpoint] = ref }
        for (endpoint, token) in connections where wanted[endpoint] == nil {
            MIDIPortDisconnectSource(port, endpoint)
            connections[endpoint] = nil
            tokens[token] = nil
        }
        for (endpoint, ref) in wanted {
            if let token = connections[endpoint] {
                tokens[token] = ref  // renamed
                continue
            }
            let token = nextToken
            nextToken += 1
            tokens[token] = ref
            if MIDIPortConnectSource(port, endpoint, UnsafeMutableRawPointer(bitPattern: token)) == noErr {
                connections[endpoint] = token
            } else {
                tokens[token] = nil
            }
        }
        lock.unlock()
    }

    public var connectedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return connections.count
    }

    /// Offers (or removes) the virtual MIDI port. `uniqueID` is the one used before, so apps that remember ports
    /// by ID find it again; returns the port's unique ID to save, or nil when it's off.
    @discardableResult
    public func setVirtualPort(enabled: Bool, name: String = MIDIInput.defaultPortName, uniqueID: Int32?) throws -> Int32? {
        guard isStarted else { return nil }
        if destination != 0 {
            MIDIEndpointDispose(destination)
            destination = 0
            lock.lock()
            destinationRef = nil
            lock.unlock()
        }
        guard enabled else { return nil }
        let status = MIDIDestinationCreateWithProtocol(client, name as CFString, ._1_0, &destination) { [weak self] list, _ in
            guard let self else { return }
            self.lock.lock()
            let ref = self.destinationRef
            self.lock.unlock()
            self.receive(list, source: ref)
        }
        guard status == noErr else { throw MIDIError(operation: "Creating the virtual MIDI port", status: status) }
        if let uniqueID, uniqueID != 0 {
            _ = MIDIObjectSetIntegerProperty(destination, kMIDIPropertyUniqueID, uniqueID)  // fails if taken: keep the new one
        }
        var actual: Int32 = 0
        MIDIObjectGetIntegerProperty(destination, kMIDIPropertyUniqueID, &actual)
        lock.lock()
        destinationRef = SourceRef(uniqueID: actual, name: "\(name) (virtual port)")
        lock.unlock()
        return actual
    }

    // MARK: Receiving

    private func receive(_ list: UnsafePointer<MIDIEventList>, token: Int) {
        lock.lock()
        let source = tokens[token]
        lock.unlock()
        receive(list, source: source)
    }

    private func receive(_ list: UnsafePointer<MIDIEventList>, source: SourceRef?) {
        var messages: [MIDIMessage] = []
        Self.forEachPacket(list) { words in messages += MIDIParser.parse(words: words, source: source) }
        if !messages.isEmpty { onMessages?(messages) }
    }

    static let wordsOffset = MemoryLayout<MIDIEventPacket>.offset(of: \MIDIEventPacket.words)!

    /// Visits each packet's words without copying whole packets (a list's packets are only as long as their words).
    static func forEachPacket(_ list: UnsafePointer<MIDIEventList>, _ body: (UnsafeBufferPointer<UInt32>) -> Void) {
        for packet in list.unsafeSequence() {
            let count = min(Int(packet.pointee.wordCount), 64)
            let words = UnsafeRawPointer(packet).advanced(by: wordsOffset).assumingMemoryBound(to: UInt32.self)
            body(UnsafeBufferPointer(start: words, count: count))
        }
    }

    // MARK: Listing

    public static func sources() -> [MIDISourceInfo] {
        sourceEndpoints().map { endpoint, ref in
            var offline: Int32 = 0
            MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyOffline, &offline)
            return MIDISourceInfo(ref: ref, isOffline: offline != 0)
        }
    }

    static func sourceEndpoints() -> [(MIDIEndpointRef, SourceRef)] {
        (0..<MIDIGetNumberOfSources()).compactMap { index in
            let endpoint = MIDIGetSource(index)
            guard endpoint != 0 else { return nil }
            return (endpoint, SourceRef(uniqueID: integer(endpoint, kMIDIPropertyUniqueID), name: displayName(endpoint)))
        }
    }

    static func integer(_ object: MIDIObjectRef, _ property: CFString) -> Int32 {
        var value: Int32 = 0
        MIDIObjectGetIntegerProperty(object, property, &value)
        return value
    }

    static func displayName(_ object: MIDIObjectRef) -> String {
        for property in [kMIDIPropertyDisplayName, kMIDIPropertyName] {
            var name: Unmanaged<CFString>?
            if MIDIObjectGetStringProperty(object, property, &name) == noErr, let value = name?.takeRetainedValue() as String?,
               !value.isEmpty {
                return value
            }
        }
        return "MIDI Input"
    }
}

/// A virtual MIDI source and an output port, for sending test messages (self-test and tests). Not used by the app.
public final class MIDITestSender {
    private var client = MIDIClientRef()
    private var source = MIDIEndpointRef()
    private var output = MIDIPortRef()
    public let name: String

    public init(name: String) throws {
        self.name = name
        var status = MIDIClientCreateWithBlock("\(name) Client" as CFString, &client, nil)
        guard status == noErr else { throw MIDIError(operation: "Creating a test MIDI client", status: status) }
        status = MIDISourceCreateWithProtocol(client, name as CFString, ._1_0, &source)
        guard status == noErr else { throw MIDIError(operation: "Creating a test MIDI source", status: status) }
        status = MIDIOutputPortCreate(client, "\(name) Output" as CFString, &output)
        guard status == noErr else { throw MIDIError(operation: "Creating a test MIDI output", status: status) }
    }

    deinit {
        MIDIEndpointDispose(source)
        MIDIPortDispose(output)
        MIDIClientDispose(client)
    }

    /// MIDI 1.0 channel voice message as a UMP word.
    public static func word(status: UInt8, channel: UInt8, _ data1: UInt8, _ data2: UInt8) -> UInt32 {
        0x2000_0000 | UInt32(status & 0xF) << 20 | UInt32(channel & 0xF) << 16 | UInt32(data1 & 0x7F) << 8 | UInt32(data2 & 0x7F)
    }

    /// Sends from the virtual source (as a controller plugged in would).
    public func emit(_ words: [UInt32]) {
        withList(words) { MIDIReceivedEventList(source, $0) }
    }

    /// Sends to a destination by name (as a DAW sending to MidiPress's port would). False if there is no such port.
    public func send(_ words: [UInt32], toDestinationNamed destinationName: String) -> Bool {
        let count = MIDIGetNumberOfDestinations()
        guard let destination = (0..<count).map(MIDIGetDestination).first(where: { MIDIInput.displayName($0) == destinationName })
        else { return false }
        withList(words) { MIDISendEventList(output, destination, $0) }
        return true
    }

    private func withList(_ words: [UInt32], _ body: (UnsafePointer<MIDIEventList>) -> Void) {
        // On the heap, so the packet pointers Core MIDI hands back stay valid between calls.
        let size = 1024
        let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 8)
        defer { raw.deallocate() }
        let list = raw.bindMemory(to: MIDIEventList.self, capacity: 1)
        var packet = MIDIEventListInit(list, ._1_0)
        for word in words {
            var w = word
            packet = MIDIEventListAdd(list, size, packet, 0, 1, &w)
        }
        body(list)
    }
}
