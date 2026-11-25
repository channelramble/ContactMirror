import Foundation

/// What the engine remembers about one Google item <-> iCloud item link.
public struct PairState<Record: SyncableRecord>: Codable, Hashable, Sendable {
    public var googleID: String
    public var icloudID: String
    /// Fingerprints of each side as read back right after the last sync.
    public var googleHash: String
    public var icloudHash: String
    public var googlePhotoKey: String
    public var icloudPhotoKey: String
    /// The record both sides were set to at the last sync (base for three-way merges).
    public var base: Record
    /// When this pair was last written. A side that is briefly missing right after a write is
    /// not treated as deleted (Google can take a few minutes to list new items).
    public var lastSynced: Date? = nil
}

public struct SyncState<Record: SyncableRecord>: Codable, Sendable {
    public var version = 1
    public var pairs: [PairState<Record>] = []
    public init() {}

    public static func load(from url: URL) -> SyncState {
        guard let data = try? Data(contentsOf: url),
              let s = try? JSONDecoder().decode(SyncState.self, from: data) else { return SyncState() }
        return s
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: url, options: .atomic)
    }
}
