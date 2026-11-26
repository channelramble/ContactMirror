import Foundation
import CryptoKit

/// Anything ContactMirror can keep identical between Google and iCloud (contacts, events, tasks).
public protocol SyncableRecord: Codable, Hashable, Sendable {
    /// Canonical form: trimmed, labels canonicalised, empty entries removed.
    func normalized() -> Self
    var displayName: String { get }
    /// Merge used the first time two items are linked: nothing should be lost.
    static func union(primary: Self, secondary: Self) -> Self
    /// The fields that are merged independently when both sides changed.
    static var mergeFields: [MergeField<Self>] { get }
    /// Keys used to link items that aren't linked yet, strongest tier first. A key only
    /// links two items if it identifies exactly one unlinked item on each side.
    var matchKeys: [[String]] { get }
}

/// One independently mergeable field (or group of fields that must move together).
public struct MergeField<R> {
    let apply: (_ r: inout R, _ a: R, _ baseA: R, _ b: R, _ baseB: R, _ preferA: Bool, _ keepA: Bool) -> Void

    public static func field<T: Equatable>(_ kp: WritableKeyPath<R, T>) -> MergeField<R> {
        MergeField { r, a, baseA, b, baseB, preferA, keepA in
            let ac = a[keyPath: kp] != baseA[keyPath: kp], bc = b[keyPath: kp] != baseB[keyPath: kp]
            if ac && bc { r[keyPath: kp] = preferA ? a[keyPath: kp] : b[keyPath: kp] }
            else if ac { r[keyPath: kp] = a[keyPath: kp] }
            else if bc { r[keyPath: kp] = b[keyPath: kp] }
            else { r[keyPath: kp] = keepA ? a[keyPath: kp] : b[keyPath: kp] }
        }
    }
}

extension SyncableRecord {
    /// Field-by-field merge. Each side is compared with *its own* state after the last sync, so a
    /// field one side simply can't store is never mistaken for a deletion. Fields neither side
    /// changed keep the value of the side being written (`keepA`).
    public static func merge(_ a: Self, baseA: Self, _ b: Self, baseB: Self, preferA: Bool, keepA: Bool) -> Self {
        let a = a.normalized(), b = b.normalized(), baseA = baseA.normalized(), baseB = baseB.normalized()
        var r = keepA ? a : b
        for f in mergeFields { f.apply(&r, a, baseA, b, baseB, preferA, keepA) }
        return r.normalized()
    }

    /// Classic three-way merge with one shared base (used in tests).
    public static func merge3(base: Self, a: Self, b: Self, preferA: Bool) -> Self {
        merge(a, baseA: base, b, baseB: base, preferA: preferA, keepA: preferA)
    }

    /// Stable fingerprint of the normalised record.
    public var fingerprint: String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let data = (try? enc.encode(normalized())) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// An item as it currently exists on one side.
public struct RemoteItem<Record: SyncableRecord>: Sendable {
    /// Provider identifier (Google resource id / Apple identifier).
    public var id: String
    public var record: Record
    /// Fingerprint of the item's photo ("" when there is none); only comparable with
    /// earlier fingerprints from the same provider.
    public var photoKey: String
    /// Provider-specific data, e.g. etags or fields that aren't synced but must be preserved.
    public var meta: [String: String]
    /// The item can't be changed on this side (e.g. a calendar invitation you don't organise).
    /// The other side is kept equal to it instead.
    public var readOnly: Bool

    public init(id: String, record: Record, photoKey: String = "", meta: [String: String] = [:], readOnly: Bool = false) {
        self.id = id
        self.record = record.normalized()
        self.photoKey = photoKey
        self.meta = meta
        self.readOnly = readOnly
    }
}

public protocol RecordProvider<Record>: AnyObject {
    associatedtype Record: SyncableRecord
    var displayName: String { get }
    func fetchAll() async throws -> [RemoteItem<Record>]
    /// Creates the item and returns it as stored by the provider.
    func create(_ record: Record) async throws -> RemoteItem<Record>
    /// Replaces the synced fields of `existing` with `record`; returns the stored result.
    func update(_ existing: RemoteItem<Record>, to record: Record) async throws -> RemoteItem<Record>
    func delete(_ existing: RemoteItem<Record>) async throws
    func photoData(for item: RemoteItem<Record>) async throws -> Data?
    /// Sets (or removes, when `data` is nil) the photo and returns the stored result.
    func setPhoto(_ data: Data?, for item: RemoteItem<Record>) async throws -> RemoteItem<Record>
    /// False when the item's absence on the *other* side might just mean it fell outside a
    /// fetch window, so it must not be treated as a deletion.
    func isSafeToDelete(_ item: RemoteItem<Record>) -> Bool
}

extension RecordProvider {
    public func photoData(for item: RemoteItem<Record>) async throws -> Data? { nil }
    public func setPhoto(_ data: Data?, for item: RemoteItem<Record>) async throws -> RemoteItem<Record> { item }
    public func isSafeToDelete(_ item: RemoteItem<Record>) -> Bool { true }
}

public typealias RemoteContact = RemoteItem<ContactRecord>
public typealias ContactProvider = RecordProvider<ContactRecord>
