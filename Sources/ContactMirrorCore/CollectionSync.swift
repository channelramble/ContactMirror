import Foundation
import CryptoKit
import EventKit

/// A Google calendar/task list linked to an iCloud calendar/reminder list.
public struct CollectionLink: Codable, Hashable, Sendable {
    public var googleID: String
    public var icloudID: String
    public var title: String
}

struct CollectionLinks: Codable {
    var links: [CollectionLink] = []

    static func load(_ url: URL) -> CollectionLinks {
        guard let d = try? Data(contentsOf: url), let l = try? JSONDecoder().decode(CollectionLinks.self, from: d) else { return CollectionLinks() }
        return l
    }

    func save(_ url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: url, options: .atomic)
    }
}

public enum CollectionMapper {
    /// Pairs every Google collection with an iCloud one: existing links first, then the two
    /// default collections, then equal names; anything left is created on the other side.
    public static func map(google: [SyncCollection], icloud: [SyncCollection], saved: [CollectionLink],
                           createInGoogle: (String) async throws -> String,
                           createInICloud: (String) async throws -> String,
                           log: (String) -> Void) async throws -> [CollectionLink] {
        let gByID = Dictionary(google.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let cByID = Dictionary(icloud.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var links: [CollectionLink] = []
        var usedG = Set<String>(), usedC = Set<String>()
        for l in saved where gByID[l.googleID] != nil && cByID[l.icloudID] != nil
            && !usedG.contains(l.googleID) && !usedC.contains(l.icloudID) {
            links.append(CollectionLink(googleID: l.googleID, icloudID: l.icloudID, title: gByID[l.googleID]!.title))
            usedG.insert(l.googleID); usedC.insert(l.icloudID)
        }
        var freeG = google.filter { !usedG.contains($0.id) }
        var freeC = icloud.filter { !usedC.contains($0.id) }

        if let gd = freeG.firstIndex(where: \.isDefault), let cd = freeC.firstIndex(where: \.isDefault) {
            links.append(CollectionLink(googleID: freeG[gd].id, icloudID: freeC[cd].id, title: freeG[gd].title))
            freeG.remove(at: gd); freeC.remove(at: cd)
        }
        for g in freeG {
            if let i = freeC.firstIndex(where: { $0.title.lowercased() == g.title.lowercased() }) {
                links.append(CollectionLink(googleID: g.id, icloudID: freeC[i].id, title: g.title))
                freeC.remove(at: i)
            } else {
                log("Creating “\(g.title)” in iCloud")
                let id = try await createInICloud(g.title)
                links.append(CollectionLink(googleID: g.id, icloudID: id, title: g.title))
            }
        }
        for c in freeC {
            log("Creating “\(c.title)” in Google")
            let id = try await createInGoogle(c.title)
            links.append(CollectionLink(googleID: id, icloudID: c.id, title: c.title))
        }
        return links
    }
}

/// Saves a copy of both sides before a sync changes anything.
public final class BackupWriter: @unchecked Sendable {
    public let folder: URL
    private var created = false

    public init(root: URL, date: Date = Date()) {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        folder = root.appendingPathComponent(f.string(from: date), isDirectory: true)
    }

    public func write(_ data: Data, name: String) throws {
        if !created {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            created = true
        }
        let safe = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        try data.write(to: folder.appendingPathComponent(safe))
    }

    public func writeJSON<R: SyncableRecord>(_ name: String, google: [RemoteItem<R>], icloud: [RemoteItem<R>]) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let both = BackupBoth(google: google.map { BackupEntry(id: $0.id, item: $0.record) },
                              icloud: icloud.map { BackupEntry(id: $0.id, item: $0.record) })
        try write(try enc.encode(both), name: name + ".json")
    }

    /// Keeps the `keep` most recent backup folders.
    public static func prune(root: URL, keep: Int = 15) {
        let all = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        let sorted = all.filter { $0.hasDirectoryPath }.sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in sorted.dropFirst(keep) { try? FileManager.default.removeItem(at: old) }
    }
}

struct BackupEntry<T: Codable>: Codable { var id: String; var item: T }
struct BackupBoth<T: Codable>: Codable { var google: [BackupEntry<T>]; var icloud: [BackupEntry<T>] }

public struct PausedDeletion: Sendable {
    public var what: String
    public var google: Int
    public var icloud: Int
    public init(what: String, google: Int, icloud: Int) { self.what = what; self.google = google; self.icloud = icloud }
}

/// Runs calendar and task syncs: maps collections, then one SyncEngine per linked pair.
public final class CollectionSyncRunner: @unchecked Sendable {
    let api: GoogleAPIClient
    let store: EKEventStore
    let stateDir: URL
    let accountKey: String
    public var log: (String) -> Void = { _ in }
    public var backup: BackupWriter?
    public private(set) var paused: [PausedDeletion] = []

    public init(api: GoogleAPIClient, store: EKEventStore, stateDir: URL, accountKey: String) {
        self.api = api
        self.store = store
        self.stateDir = stateDir
        self.accountKey = accountKey
    }

    func stateURL(_ kind: String, _ link: CollectionLink) -> URL {
        let h = SHA256.hash(data: Data("\(accountKey)|\(link.googleID)|\(link.icloudID)".utf8))
            .prefix(8).map { String(format: "%02x", $0) }.joined()
        return stateDir.appendingPathComponent("state-\(kind)-\(h).json")
    }

    func icloudCollections(_ type: EKEntityType) -> [SyncCollection] {
        let def = EventKitAccess.defaultCollection(store, type: type)?.calendarIdentifier
        return EventKitAccess.iCloudCollections(store, type: type).map {
            SyncCollection(id: $0.calendarIdentifier, title: $0.title, isDefault: $0.calendarIdentifier == def)
        }
    }

    func links(kind: String, google: [SyncCollection], icloud: [SyncCollection],
               createG: (String) async throws -> String, createC: (String) throws -> String) async throws -> [CollectionLink] {
        let url = stateDir.appendingPathComponent("links-\(kind)-\(accountKey.hashValueHex).json")
        var saved = CollectionLinks.load(url)
        saved.links = try await CollectionMapper.map(google: google, icloud: icloud, saved: saved.links,
                                                     createInGoogle: createG, createInICloud: { try createC($0) },
                                                     log: log)
        try saved.save(url)
        return saved.links
    }

    public func syncCalendars(options: SyncOptions) async throws -> SyncReport {
        guard EventKitAccess.isAuthorized(.event) else { throw EventKitError.notAuthorized("Calendars") }
        let window = CalendarWindow.standard()
        let gCals = try await GoogleCalendarProvider.calendars(api: api)
        let links = try await links(kind: "calendars", google: gCals, icloud: icloudCollections(.event),
                                    createG: { try await GoogleCalendarProvider.createCalendar(api: self.api, title: $0) },
                                    createC: { try EventKitAccess.createCollection(self.store, type: .event, title: $0) })
        var total = SyncReport()
        for link in links {
            let engine = SyncEngine<EventRecord>(
                google: GoogleCalendarProvider(api: api, calendarID: link.googleID, window: window),
                icloud: AppleCalendarProvider(store: store, calendarID: link.icloudID, window: window),
                stateURL: stateURL("calendar", link), what: "calendar “\(link.title)”")
            total = total + (try await run(engine, options: options, backupName: "calendar-\(link.title)"))
        }
        return total
    }

    public func syncTasks(options: SyncOptions) async throws -> SyncReport {
        guard EventKitAccess.isAuthorized(.reminder) else { throw EventKitError.notAuthorized("Reminders") }
        let gLists = try await GoogleTasksProvider.lists(api: api)
        let links = try await links(kind: "tasks", google: gLists, icloud: icloudCollections(.reminder),
                                    createG: { try await GoogleTasksProvider.createList(api: self.api, title: $0) },
                                    createC: { try EventKitAccess.createCollection(self.store, type: .reminder, title: $0) })
        var total = SyncReport()
        for link in links {
            let engine = SyncEngine<TaskRecord>(
                google: GoogleTasksProvider(api: api, listID: link.googleID),
                icloud: RemindersProvider(store: store, calendarID: link.icloudID),
                stateURL: stateURL("tasks", link), what: "task list “\(link.title)”")
            total = total + (try await run(engine, options: options, backupName: "tasks-\(link.title)"))
        }
        return total
    }

    private func run<R: SyncableRecord>(_ engine: SyncEngine<R>, options: SyncOptions, backupName: String) async throws -> SyncReport {
        engine.log = log
        if let backup { engine.backup = { g, c in try backup.writeJSON(backupName, google: g, icloud: c) } }
        do {
            return try await engine.sync(options: options)
        } catch let SyncError.massDeletion(what, g, c) {
            paused.append(PausedDeletion(what: what, google: g, icloud: c))
            log("Paused \(what): would delete \(g) from Google and \(c) from iCloud")
            return SyncReport()
        } catch let e as EventKitError {
            throw e
        } catch {
            // One collection failing (e.g. a calendar deleted mid-sync) shouldn't stop the others.
            var r = SyncReport()
            r.errors.append("\(engine.what): \(error.localizedDescription)")
            log("Error syncing \(engine.what): \(error.localizedDescription)")
            return r
        }
    }
}

extension String {
    var hashValueHex: String {
        SHA256.hash(data: Data(utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }
}
