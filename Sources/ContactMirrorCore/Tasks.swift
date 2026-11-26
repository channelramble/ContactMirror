import Foundation
import EventKit

// MARK: - Record

/// A to-do item: Google Tasks <-> iCloud Reminders. Google Tasks only stores a due *date*,
/// so that's what is synced (a reminder's time of day is kept on the Apple side).
public struct TaskRecord: SyncableRecord {
    public var title = ""
    public var notes = ""
    /// "yyyy-MM-dd" or "".
    public var due = ""
    public var completed = false

    public init(title: String = "", notes: String = "", due: String = "", completed: Bool = false) {
        self.title = title; self.notes = notes; self.due = due; self.completed = completed
    }

    public func normalized() -> TaskRecord {
        func t(_ s: String) -> String {
            s.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return TaskRecord(title: t(title), notes: t(notes), due: String(t(due).prefix(10)), completed: completed)
    }

    public var displayName: String { title.isEmpty ? "(untitled task)" : title }

    public var matchKeys: [[String]] {
        let r = normalized()
        guard !r.title.isEmpty else { return [] }
        // Completion state is part of the key so an old finished task never "completes" a new open one.
        return [["\(r.title.lowercased())|\(r.due)|\(r.completed)"], ["\(r.title.lowercased())|\(r.completed)"]]
    }

    public static func union(primary p: TaskRecord, secondary s: TaskRecord) -> TaskRecord {
        let p = p.normalized(), s = s.normalized()
        var r = p
        if r.title.isEmpty { r.title = s.title }
        if r.notes.isEmpty { r.notes = s.notes }
        else if !s.notes.isEmpty && !r.notes.contains(s.notes) { r.notes += "\n\n" + s.notes }
        if r.due.isEmpty { r.due = s.due }
        r.completed = p.completed || s.completed
        return r
    }

    public static var mergeFields: [MergeField<TaskRecord>] { [.field(\.title), .field(\.notes), .field(\.due), .field(\.completed)] }
}

// MARK: - Google Tasks

public struct SyncCollection: Hashable, Sendable {
    public var id: String
    public var title: String
    public var isDefault: Bool
}

public final class GoogleTasksProvider: RecordProvider, @unchecked Sendable {
    public typealias Record = TaskRecord
    public let displayName = "Google Tasks"
    static let base = "https://tasks.googleapis.com/tasks/v1/"
    let api: GoogleAPIClient
    public let listID: String

    public init(api: GoogleAPIClient, listID: String) {
        self.api = api
        self.listID = listID
    }

    var listPath: String { Self.base + "lists/\(listID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? listID)/tasks" }

    public static func lists(api: GoogleAPIClient) async throws -> [SyncCollection] {
        var out: [SyncCollection] = []
        var defaultID = ""
        if let d = try? await api.request("GET", base + "users/@me/lists/@default") { defaultID = d["id"] as? String ?? "" }
        var token: String?
        repeat {
            var q = ["maxResults": "100"]
            if let token { q["pageToken"] = token }
            let json = try await api.request("GET", base + "users/@me/lists", query: q)
            for l in json["items"] as? [[String: Any]] ?? [] {
                guard let id = l["id"] as? String else { continue }
                out.append(SyncCollection(id: id, title: l["title"] as? String ?? "", isDefault: id == defaultID))
            }
            token = json["nextPageToken"] as? String
        } while token != nil
        return out
    }

    public static func createList(api: GoogleAPIClient, title: String) async throws -> String {
        let json = try await api.request("POST", base + "users/@me/lists", body: ["title": title], mutation: true, idempotent: false)
        guard let id = json["id"] as? String else { throw GoogleAPIError(status: 0, message: "no list id") }
        return id
    }

    public func fetchAll() async throws -> [RemoteItem<TaskRecord>] {
        var out: [RemoteItem<TaskRecord>] = []
        var token: String?
        repeat {
            var q = ["maxResults": "100", "showCompleted": "true", "showHidden": "true", "showDeleted": "false"]
            if let token { q["pageToken"] = token }
            let json = try await api.request("GET", listPath, query: q)
            for t in json["items"] as? [[String: Any]] ?? [] {
                if (t["deleted"] as? Bool) == true { continue }
                if let item = Self.item(from: t) { out.append(item) }
            }
            token = json["nextPageToken"] as? String
        } while token != nil
        return out
    }

    static func item(from t: [String: Any]) -> RemoteItem<TaskRecord>? {
        guard let id = t["id"] as? String else { return nil }
        let r = TaskRecord(title: t["title"] as? String ?? "", notes: t["notes"] as? String ?? "",
                           due: String((t["due"] as? String ?? "").prefix(10)),
                           completed: (t["status"] as? String) == "completed")
        return RemoteItem(id: id, record: r, meta: ["etag": t["etag"] as? String ?? ""])
    }

    static func body(_ r: TaskRecord) -> [String: Any] {
        let r = r.normalized()
        var b: [String: Any] = ["title": r.title, "notes": r.notes,
                                "status": r.completed ? "completed" : "needsAction"]
        b["due"] = r.due.isEmpty ? NSNull() : "\(r.due)T00:00:00.000Z"
        if !r.completed { b["completed"] = NSNull() }
        return b
    }

    public func create(_ record: TaskRecord) async throws -> RemoteItem<TaskRecord> {
        var b = Self.body(record)
        b = b.filter { !($0.value is NSNull) }
        let json = try await api.request("POST", listPath, body: b, mutation: true, idempotent: false)
        guard let item = Self.item(from: json) else { throw GoogleAPIError(status: 0, message: "bad task response") }
        return item
    }

    public func update(_ existing: RemoteItem<TaskRecord>, to record: TaskRecord) async throws -> RemoteItem<TaskRecord> {
        let json = try await api.request("PATCH", listPath + "/" + existing.id, body: Self.body(record), mutation: true)
        guard let item = Self.item(from: json) else { throw GoogleAPIError(status: 0, message: "bad task response") }
        return item
    }

    public func delete(_ existing: RemoteItem<TaskRecord>) async throws {
        do { _ = try await api.request("DELETE", listPath + "/" + existing.id, mutation: true) }
        catch let e as GoogleAPIError where e.status == 404 || e.status == 410 { return }
    }
}

// MARK: - iCloud Reminders

public enum EventKitError: Error, LocalizedError {
    case notAuthorized(String)
    case collectionMissing(String)
    case notFound
    case fetchFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notAuthorized(let what): return "ContactMirror doesn't have full access to \(what). Allow it in System Settings → Privacy & Security → \(what)."
        case .collectionMissing(let name): return "The iCloud list or calendar “\(name)” no longer exists."
        case .notFound: return "Item no longer exists."
        case .fetchFailed(let what): return "Couldn't read \(what) from this Mac. Not syncing it this time."
        }
    }
}

public enum EventKitAccess {
    public static func isAuthorized(_ type: EKEntityType) -> Bool {
        let s = EKEventStore.authorizationStatus(for: type)
        if #available(macOS 14.0, *) { return s == .fullAccess }
        return s == .authorized
    }

    public static func isDenied(_ type: EKEntityType) -> Bool {
        let s = EKEventStore.authorizationStatus(for: type)
        if #available(macOS 14.0, *), s == .writeOnly { return true }
        return s == .denied || s == .restricted
    }

    public static func isUndetermined(_ type: EKEntityType) -> Bool {
        EKEventStore.authorizationStatus(for: type) == .notDetermined
    }

    public static func request(_ type: EKEntityType) async -> Bool {
        let store = EKEventStore()
        if #available(macOS 14.0, *) {
            switch type {
            case .event: return (try? await store.requestFullAccessToEvents()) ?? false
            default: return (try? await store.requestFullAccessToReminders()) ?? false
            }
        }
        return (try? await store.requestAccess(to: type)) ?? false
    }

    /// Writable calendars / reminder lists in the iCloud account.
    public static func iCloudCollections(_ store: EKEventStore, type: EKEntityType) -> [EKCalendar] {
        store.calendars(for: type).filter { cal in
            cal.allowsContentModifications && cal.type == .calDAV && isICloud(cal.source)
        }
    }

    public static func isICloud(_ source: EKSource?) -> Bool {
        guard let source else { return false }
        return source.sourceType == .calDAV && source.title.lowercased().contains("icloud")
    }

    public static func iCloudSource(_ store: EKEventStore, type: EKEntityType) -> EKSource? {
        if let s = iCloudCollections(store, type: type).first?.source { return s }
        return store.sources.first(where: { isICloud($0) })
    }

    public static func defaultCollection(_ store: EKEventStore, type: EKEntityType) -> EKCalendar? {
        let d = type == .event ? store.defaultCalendarForNewEvents : store.defaultCalendarForNewReminders()
        guard let d, isICloud(d.source), d.allowsContentModifications else { return nil }
        return d
    }

    public static func createCollection(_ store: EKEventStore, type: EKEntityType, title: String) throws -> String {
        guard let source = iCloudSource(store, type: type) else { throw EventKitError.collectionMissing("iCloud") }
        let cal = EKCalendar(for: type, eventStore: store)
        cal.title = title
        cal.source = source
        try store.saveCalendar(cal, commit: true)
        return cal.calendarIdentifier
    }
}

public final class RemindersProvider: RecordProvider, @unchecked Sendable {
    public typealias Record = TaskRecord
    public let displayName = "iCloud Reminders"
    let store: EKEventStore
    public let calendarID: String

    public init(store: EKEventStore, calendarID: String) {
        self.store = store
        self.calendarID = calendarID
    }

    var calendar: EKCalendar {
        get throws {
            guard EventKitAccess.isAuthorized(.reminder) else { throw EventKitError.notAuthorized("Reminders") }
            guard let c = store.calendar(withIdentifier: calendarID) else { throw EventKitError.collectionMissing(calendarID) }
            return c
        }
    }

    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func record(from r: EKReminder) -> TaskRecord {
        var due = ""
        if let dc = r.dueDateComponents, let y = dc.year, let m = dc.month, let d = dc.day,
           y != NSDateComponentUndefined, m != NSDateComponentUndefined, d != NSDateComponentUndefined {
            due = String(format: "%04d-%02d-%02d", y, m, d)
        }
        return TaskRecord(title: r.title ?? "", notes: r.notes ?? "", due: due, completed: r.isCompleted)
    }

    static func item(_ r: EKReminder) -> RemoteItem<TaskRecord> {
        RemoteItem(id: r.calendarItemIdentifier, record: record(from: r))
    }

    public func fetchAll() async throws -> [RemoteItem<TaskRecord>] {
        let cal = try calendar
        let predicate = store.predicateForReminders(in: [cal])
        // nil means the fetch failed, which must never look like "the list is empty".
        let fetched: [EKReminder]? = await withCheckedContinuation { cont in
            store.fetchReminders(matching: predicate) { cont.resume(returning: $0) }
        }
        guard let reminders = fetched else { throw EventKitError.fetchFailed("Reminders") }
        return reminders.map(Self.item)
    }

    func apply(_ record: TaskRecord, to r: EKReminder) {
        let rec = record.normalized()
        r.title = rec.title
        r.notes = rec.notes.isEmpty ? nil : rec.notes
        if rec.due.isEmpty {
            r.dueDateComponents = nil
        } else if let date = Self.dayFormatter.date(from: rec.due) {
            let cal = Calendar(identifier: .gregorian)
            var dc = cal.dateComponents([.year, .month, .day], from: date)
            // Keep a time of day set on the Apple side if the day didn't change.
            if let old = r.dueDateComponents, old.year == dc.year, old.month == dc.month, old.day == dc.day {
                dc = old
            }
            r.dueDateComponents = dc
        }
        if r.isCompleted != rec.completed { r.isCompleted = rec.completed }
    }

    public func create(_ record: TaskRecord) async throws -> RemoteItem<TaskRecord> {
        let r = EKReminder(eventStore: store)
        r.calendar = try calendar
        apply(record, to: r)
        try store.save(r, commit: true)
        return Self.item(r)
    }

    func reminder(_ id: String) throws -> EKReminder {
        guard let r = store.calendarItem(withIdentifier: id) as? EKReminder else { throw EventKitError.notFound }
        return r
    }

    public func update(_ existing: RemoteItem<TaskRecord>, to record: TaskRecord) async throws -> RemoteItem<TaskRecord> {
        let r = try reminder(existing.id)
        apply(record, to: r)
        try store.save(r, commit: true)
        return Self.item(r)
    }

    public func delete(_ existing: RemoteItem<TaskRecord>) async throws {
        guard let r = try? reminder(existing.id) else { return }
        try store.remove(r, commit: true)
    }
}
