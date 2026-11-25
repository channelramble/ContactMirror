import Foundation

/// A contact as it currently exists in one of the two address books.
public struct RemoteContact: Sendable {
    /// Provider identifier (Google resourceName / CNContact identifier).
    public var id: String
    public var record: ContactRecord
    /// Fingerprint of the contact photo ("" when there is none). Only comparable with
    /// earlier fingerprints from the same provider.
    public var photoKey: String
    /// Provider specific data, e.g. the Google etag.
    public var meta: [String: String]

    public init(id: String, record: ContactRecord, photoKey: String = "", meta: [String: String] = [:]) {
        self.id = id
        self.record = record.normalized()
        self.photoKey = photoKey
        self.meta = meta
    }
}

public protocol ContactProvider: AnyObject {
    var displayName: String { get }
    func fetchAll() async throws -> [RemoteContact]
    /// Creates the contact and returns it as stored by the provider.
    func create(_ record: ContactRecord) async throws -> RemoteContact
    /// Replaces the synced fields of `existing` with `record`; returns the stored result.
    func update(_ existing: RemoteContact, to record: ContactRecord) async throws -> RemoteContact
    func delete(_ existing: RemoteContact) async throws
    func photoData(for contact: RemoteContact) async throws -> Data?
    /// Sets (or removes, when `data` is nil) the photo and returns the stored result.
    func setPhoto(_ data: Data?, for contact: RemoteContact) async throws -> RemoteContact
}
