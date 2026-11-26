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
    /// Each side as read back after the last sync; changes are detected per field against these.
    public var baseG: Record? = nil
    public var baseC: Record? = nil
    /// When this pair was last written. A side that is briefly missing right after a write is
    /// not treated as deleted (Google can take a few minutes to list new items).
    public var lastSynced: Date? = nil
}

public enum SyncStateError: Error, LocalizedError {
    case unreadable(String, String)
    public var errorDescription: String? {
        switch self {
        case let .unreadable(f, e): return "Sync state file \(f) couldn't be read (\(e)). Not syncing this item type to avoid duplicates; use Settings → Reset Sync Links if this persists."
        }
    }
}

public struct SyncState<Record: SyncableRecord>: Codable, Sendable {
    public var version = 1
    public var pairs: [PairState<Record>] = []
    public init() {}

    public static func load(from url: URL) -> SyncState {
        (try? loadChecked(from: url)) ?? SyncState()
    }

    /// Missing file = fresh start. An unreadable file is an error (never silently "forget"
    /// everything, which would re-match all items and resurrect deleted ones); the bad file is
    /// kept next to it for inspection.
    public static func loadChecked(from url: URL) throws -> SyncState {
        guard let data = try? Data(contentsOf: url) else { return SyncState() }
        do {
            return try JSONDecoder().decode(SyncState.self, from: data)
        } catch {
            let keep = url.appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970))")
            try? FileManager.default.copyItem(at: url, to: keep)
            throw SyncStateError.unreadable(url.lastPathComponent, error.localizedDescription)
        }
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: url, options: .atomic)
    }
}
