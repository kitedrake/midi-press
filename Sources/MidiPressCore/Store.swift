import Foundation

/// Saves and loads `setup.json` in `~/Library/Application Support/MidiPress`.
public final class Store {
    public enum LoadResult {
        case missing
        case loaded(Setup)
        /// Saved by a newer MidiPress: used as far as it can be read, but never overwritten.
        case newer(Setup?, schema: Int)
        /// Couldn't be read; the file was moved aside (to `movedTo`) so nothing is lost.
        case unreadable(movedTo: URL?, error: String)
    }

    public let folder: URL
    public var fileURL: URL { folder.appendingPathComponent("setup.json") }

    public static var defaultFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MidiPress", isDirectory: true)
    }

    public init(folder: URL = Store.defaultFolder) {
        self.folder = folder
    }

    public func load() -> LoadResult {
        guard let data = try? Data(contentsOf: fileURL) else { return .missing }
        let schema = (try? JSONDecoder().decode(SchemaOnly.self, from: data))?.schema ?? 1
        do {
            let setup = try Self.decoder.decode(Setup.self, from: data)
            return schema > Setup.currentSchema ? .newer(setup, schema: schema) : .loaded(setup)
        } catch {
            if schema > Setup.currentSchema { return .newer(nil, schema: schema) }
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let aside = folder.appendingPathComponent("setup.unreadable-\(stamp).json")
            let moved = (try? FileManager.default.moveItem(at: fileURL, to: aside)) != nil
            return .unreadable(movedTo: moved ? aside : nil, error: String(describing: error))
        }
    }

    public func save(_ setup: Setup) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Self.encoder.encode(setup).write(to: fileURL, options: .atomic)
    }

    private struct SchemaOnly: Decodable { var schema: Int? }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    static let decoder = JSONDecoder()
}

/// Mappings exported to share or back up (File › Export Mappings…).
public struct MappingFile: Codable {
    public var schema: Int
    public var app: String
    public var mappings: [Mapping]

    public init(mappings: [Mapping]) {
        schema = Setup.currentSchema
        app = "MidiPress"
        self.mappings = mappings
    }

    public func encoded() throws -> Data { try Store.encoder.encode(self) }

    /// Reads an export or a whole `setup.json`. Mappings get new IDs so they never clash with existing ones.
    public static func mappings(from data: Data) throws -> [Mapping] {
        struct AnyFile: Decodable { var mappings: [Mapping] }
        return try Store.decoder.decode(AnyFile.self, from: data).mappings.map { mapping in
            var copy = mapping
            copy.id = UUID()
            copy.steps = copy.steps.map { Step($0.action) }
            return copy
        }
    }
}
