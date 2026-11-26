import Foundation
import EventKit

/// Events are synced inside a rolling window (EventKit can only query bounded ranges).
public struct CalendarWindow: Sendable {
    public var start: Date
    public var end: Date

    public static func standard(now: Date = Date()) -> CalendarWindow {
        CalendarWindow(start: now.addingTimeInterval(-365 * 86400), end: now.addingTimeInterval(730 * 86400))
    }

    /// An item missing on one side only counts as deleted if it's well inside the window;
    /// near the edges it may simply have fallen outside one side's query.
    public func isSafeToDelete(_ r: EventRecord) -> Bool {
        let margin: TimeInterval = 14 * 86400
        let lo = start.addingTimeInterval(margin), hi = end.addingTimeInterval(-margin)
        let s = r.allDay ? EventTime.localDay(r.start) : EventTime.date(fromUTC: r.start)
        guard let s else { return false }
        if r.recurrence.isEmpty { return s > lo && s < hi }
        if let until = RRule.untilDate(r.recurrence) { return until > lo && s < hi }
        if RRule.hasCount(r.recurrence) {
            let tz = TimeZone(identifier: r.timeZone) ?? .current
            guard let all = RecurrenceExpander.expand(r.recurrence, start: s, timeZone: tz, allDay: r.allDay, until: end),
                  let last = all.last else { return s > lo && s < hi }
            return last > lo && s < hi
        }
        return s < hi
    }

    func contains(_ originalStart: String) -> Bool {
        let d = originalStart.count == 10 ? EventTime.localDay(originalStart) : EventTime.date(fromUTC: originalStart)
        guard let d else { return false }
        return d >= start && d <= end
    }
}

// MARK: - Google Calendar

public final class GoogleCalendarProvider: RecordProvider, @unchecked Sendable {
    public typealias Record = EventRecord
    public let displayName = "Google Calendar"
    static let base = "https://www.googleapis.com/calendar/v3/"
    let api: GoogleAPIClient
    public let calendarID: String
    let window: CalendarWindow

    public init(api: GoogleAPIClient, calendarID: String, window: CalendarWindow) {
        self.api = api
        self.calendarID = calendarID
        self.window = window
    }

    var eventsPath: String {
        Self.base + "calendars/\(calendarID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? calendarID)/events"
    }

    /// Google only accepts http(s) links on events (Apple allows e.g. messages:// links).
    static func googleAcceptsURL(_ s: String) -> Bool {
        let l = s.lowercased()
        return l.hasPrefix("http://") || l.hasPrefix("https://")
    }

    public static func calendars(api: GoogleAPIClient) async throws -> [SyncCollection] {
        var out: [SyncCollection] = []
        var token: String?
        repeat {
            var q = ["minAccessRole": "owner", "maxResults": "250"]
            if let token { q["pageToken"] = token }
            let json = try await api.request("GET", base + "users/me/calendarList", query: q)
            for c in json["items"] as? [[String: Any]] ?? [] {
                guard let id = c["id"] as? String, (c["deleted"] as? Bool) != true else { continue }
                let primary = (c["primary"] as? Bool) == true
                let title = (c["summaryOverride"] as? String) ?? (c["summary"] as? String) ?? id
                out.append(SyncCollection(id: id, title: title, isDefault: primary))
            }
            token = json["nextPageToken"] as? String
        } while token != nil
        return out
    }

    public static func createCalendar(api: GoogleAPIClient, title: String) async throws -> String {
        let json = try await api.request("POST", base + "calendars",
                                         body: ["summary": title, "timeZone": TimeZone.current.identifier],
                                         mutation: true, idempotent: false)
        guard let id = json["id"] as? String else { throw GoogleAPIError(status: 0, message: "no calendar id") }
        return id
    }

    // MARK: Fetch

    public func fetchAll() async throws -> [RemoteItem<EventRecord>] {
        var raw: [[String: Any]] = []
        var token: String?
        repeat {
            var q = [
                "singleEvents": "false", "showDeleted": "true", "maxResults": "2500",
                "timeMin": EventTime.utcString(window.start), "timeMax": EventTime.utcString(window.end),
            ]
            if let token { q["pageToken"] = token }
            let json = try await api.request("GET", eventsPath, query: q)
            raw += json["items"] as? [[String: Any]] ?? []
            token = json["nextPageToken"] as? String
        } while token != nil
        return items(from: raw)
    }

    func items(from raw: [[String: Any]]) -> [RemoteItem<EventRecord>] {
        var masters: [[String: Any]] = []
        var exceptions: [String: [[String: Any]]] = [:]
        for e in raw {
            let type = e["eventType"] as? String ?? "default"
            if type == "birthday" || type == "workingLocation" { continue }
            if let parent = e["recurringEventId"] as? String {
                exceptions[parent, default: []].append(e)
            } else if (e["status"] as? String) != "cancelled" {
                masters.append(e)
            }
        }
        return masters.compactMap { m in
            guard let id = m["id"] as? String else { return nil }
            return item(master: m, exceptions: exceptions[id] ?? [])
        }
    }

    func item(master m: [String: Any], exceptions: [[String: Any]]) -> RemoteItem<EventRecord> {
        var r = EventRecord()
        r.title = m["summary"] as? String ?? ""
        r.location = m["location"] as? String ?? ""
        r.notes = m["description"] as? String ?? ""
        r.url = (m["source"] as? [String: Any])?["url"] as? String ?? ""
        r.busy = (m["transparency"] as? String) != "transparent"
        let (allDay, start, tz) = Self.time(m["start"] as? [String: Any])
        let (_, end, _) = Self.time(m["end"] as? [String: Any])
        r.allDay = allDay; r.start = start; r.end = end; r.timeZone = tz

        let lines = m["recurrence"] as? [String] ?? []
        var extras: [String] = []
        for line in lines {
            if line.uppercased().hasPrefix("RRULE:") {
                if r.recurrence.isEmpty { r.recurrence = String(line.dropFirst(6)) }
            } else {
                extras.append(line)
                if line.uppercased().hasPrefix("EXDATE") { r.overrides += Self.exdates(line, allDay: allDay) }
            }
        }
        for e in exceptions {
            let (oAllDay, orig, _) = Self.time(e["originalStartTime"] as? [String: Any])
            guard !orig.isEmpty else { continue }
            if (e["status"] as? String) == "cancelled" {
                r.overrides.append(EventOverride(originalStart: orig, cancelled: true))
            } else {
                let (sAllDay, s, _) = Self.time(e["start"] as? [String: Any])
                let (_, en, _) = Self.time(e["end"] as? [String: Any])
                r.overrides.append(EventOverride(originalStart: orig, title: e["summary"] as? String ?? "",
                                                 location: e["location"] as? String ?? "",
                                                 notes: e["description"] as? String ?? "",
                                                 allDay: sAllDay || (oAllDay && s.count == 10), start: s, end: en))
            }
        }
        r.overrides = r.overrides.filter { window.contains($0.originalStart) }

        let type = m["eventType"] as? String ?? "default"
        let organizer = m["organizer"] as? [String: Any]
        let organizerIsSelf = organizer == nil || (organizer?["self"] as? Bool) == true
        let readOnly = type != "default" || !organizerIsSelf
        var meta: [String: String] = [
            "iCalUID": m["iCalUID"] as? String ?? "",
            "recurrenceExtra": GoogleContactsProvider.jsonString(extras),
        ]
        if m["source"] != nil { meta["hasSource"] = "1" }
        return RemoteItem(id: m["id"] as? String ?? "", record: r, meta: meta, readOnly: readOnly)
    }

    /// (allDay, value, timeZone) from a Google EventDateTime.
    static func time(_ t: [String: Any]?) -> (Bool, String, String) {
        guard let t else { return (false, "", "") }
        if let d = t["date"] as? String { return (true, d, "") }
        if let dt = t["dateTime"] as? String, let d = EventTime.parseRFC3339(dt) {
            return (false, EventTime.utcString(d), t["timeZone"] as? String ?? "")
        }
        return (false, "", "")
    }

    static func exdates(_ line: String, allDay: Bool) -> [EventOverride] {
        guard let colon = line.lastIndex(of: ":") else { return [] }
        let params = line[..<colon].split(separator: ";")
        var tz: TimeZone?
        for p in params where p.uppercased().hasPrefix("TZID=") { tz = TimeZone(identifier: String(p.dropFirst(5))) }
        return line[line.index(after: colon)...].split(separator: ",").compactMap { v in
            guard var s = EventTime.fromICal(String(v), tz: tz) else { return nil }
            if allDay && s.count > 10, let d = EventTime.date(fromUTC: s) { s = EventTime.dayString(d) }
            return EventOverride(originalStart: s, cancelled: true)
        }
    }

    // MARK: Write

    static func timeBody(allDay: Bool, value: String, tz: String) -> [String: Any] {
        if allDay { return ["date": value, "dateTime": NSNull(), "timeZone": NSNull()] }
        return ["dateTime": value, "timeZone": tz.isEmpty ? TimeZone.current.identifier : tz, "date": NSNull()]
    }

    func body(_ record: EventRecord, existing: RemoteItem<EventRecord>?) -> [String: Any] {
        let r = record.normalized()
        var b: [String: Any] = [
            "summary": r.title, "location": r.location, "description": r.notes,
            "transparency": r.busy ? "opaque" : "transparent",
            "start": Self.timeBody(allDay: r.allDay, value: r.start, tz: r.timeZone),
            "end": Self.timeBody(allDay: r.allDay, value: r.end, tz: r.timeZone),
        ]
        if r.recurrence.isEmpty {
            b["recurrence"] = []
        } else {
            // Keep Google's own EXDATE/RDATE lines: iCloud can't express them, so they never come from there.
            let extras = (existing?.meta["recurrenceExtra"]).map { s in
                ((try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String]) ?? []
            } ?? []
            b["recurrence"] = ["RRULE:" + r.recurrence] + extras
        }
        if Self.googleAcceptsURL(r.url) {
            b["source"] = ["url": r.url, "title": r.title.isEmpty ? r.url : r.title]
        } else if existing?.meta["hasSource"] == "1" {
            b["source"] = NSNull()
        }
        return b
    }

    public func create(_ record: EventRecord) async throws -> RemoteItem<EventRecord> {
        var b = body(record, existing: nil)
        b = b.filter { !($0.value is NSNull) }
        b["start"] = (b["start"] as? [String: Any])?.filter { !($0.value is NSNull) }
        b["end"] = (b["end"] as? [String: Any])?.filter { !($0.value is NSNull) }
        if (b["recurrence"] as? [String])?.isEmpty == true { b["recurrence"] = nil }
        let json = try await api.request("POST", eventsPath, body: b, mutation: true, idempotent: false)
        guard let id = json["id"] as? String else { throw GoogleAPIError(status: 0, message: "bad event response") }
        try await applyOverrides(record.normalized(), existing: [], masterID: id)
        return try await readBack(id: id, uid: json["iCalUID"] as? String)
    }

    public func update(_ existing: RemoteItem<EventRecord>, to record: EventRecord) async throws -> RemoteItem<EventRecord> {
        let json = try await api.request("PATCH", eventsPath + "/" + existing.id,
                                         body: body(record, existing: existing), mutation: true)
        try await applyOverrides(record.normalized(), existing: existing.record.overrides, masterID: existing.id)
        return try await readBack(id: existing.id, uid: (json["iCalUID"] as? String) ?? existing.meta["iCalUID"])
    }

    func applyOverrides(_ r: EventRecord, existing: [EventOverride], masterID: String) async throws {
        guard !r.recurrence.isEmpty else { return }
        for o in r.overrides where !existing.contains(o) {
            let iid = masterID + "_" + EventTime.instanceSuffix(o.originalStart)
            do {
                if o.cancelled {
                    _ = try await api.request("DELETE", eventsPath + "/" + iid, mutation: true)
                } else {
                    var b: [String: Any] = ["summary": o.title, "location": o.location, "description": o.notes]
                    if !o.start.isEmpty && !o.end.isEmpty {
                        b["start"] = Self.timeBody(allDay: o.allDay, value: o.start, tz: r.timeZone)
                        b["end"] = Self.timeBody(allDay: o.allDay, value: o.end, tz: r.timeZone)
                    }
                    _ = try await api.request("PATCH", eventsPath + "/" + iid, body: b, mutation: true)
                }
            } catch let e as GoogleAPIError where e.status == 404 || e.status == 410 {
                continue // occurrence doesn't exist (any more)
            }
        }
    }

    func readBack(id: String, uid: String?) async throws -> RemoteItem<EventRecord> {
        if let uid, !uid.isEmpty {
            let json = try await api.request("GET", eventsPath, query: ["iCalUID": uid, "showDeleted": "true",
                                                                       "singleEvents": "false", "maxResults": "2500"])
            let list = json["items"] as? [[String: Any]] ?? []
            if let master = list.first(where: { ($0["id"] as? String) == id }) {
                let ex = list.filter { ($0["recurringEventId"] as? String) == id }
                return item(master: master, exceptions: ex)
            }
        }
        let m = try await api.request("GET", eventsPath + "/" + id)
        return item(master: m, exceptions: [])
    }

    public func delete(_ existing: RemoteItem<EventRecord>) async throws {
        do { _ = try await api.request("DELETE", eventsPath + "/" + existing.id, mutation: true) }
        catch let e as GoogleAPIError where e.status == 404 || e.status == 410 { return }
    }

    public func isSafeToDelete(_ item: RemoteItem<EventRecord>) -> Bool { window.isSafeToDelete(item.record) }
}

// MARK: - iCloud Calendar (EventKit)

public final class AppleCalendarProvider: RecordProvider, @unchecked Sendable {
    public typealias Record = EventRecord
    public let displayName = "iCloud Calendar"
    let store: EKEventStore
    public let calendarID: String
    let window: CalendarWindow

    public init(store: EKEventStore, calendarID: String, window: CalendarWindow) {
        self.store = store
        self.calendarID = calendarID
        self.window = window
    }

    var calendar: EKCalendar {
        get throws {
            guard EventKitAccess.isAuthorized(.event) else { throw EventKitError.notAuthorized("Calendars") }
            guard let c = store.calendar(withIdentifier: calendarID) else { throw EventKitError.collectionMissing(calendarID) }
            return c
        }
    }

    func windowEvents(_ cal: EKCalendar) -> [EKEvent] {
        store.events(matching: store.predicateForEvents(withStart: window.start, end: window.end, calendars: [cal]))
    }

    public func fetchAll() async throws -> [RemoteItem<EventRecord>] {
        let cal = try calendar
        var groups: [String: [EKEvent]] = [:]
        var order: [String] = []
        for e in windowEvents(cal) {
            let key = Self.seriesKey(e)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(e)
        }
        return order.map { item(groups[$0]!) }
    }

    /// Edited ("detached") occurrences get their own calendarItemIdentifier in EventKit and an
    /// external identifier of the form "<series UID>/RID=<original start>", so group by the UID.
    public static func seriesKey(_ e: EKEvent) -> String {
        if let ext = e.calendarItemExternalIdentifier, !ext.isEmpty {
            return "uid:" + (ext.components(separatedBy: "/RID=").first ?? ext)
        }
        return "id:" + e.calendarItemIdentifier
    }

    /// When an occurrence would have started. For a detached occurrence EventKit's
    /// occurrenceDate is its *new* start; the original is only in the "/RID=" suffix
    /// (seconds since 2001-01-01).
    static func originalDate(_ e: EKEvent) -> Date? {
        if e.isDetached, let ext = e.calendarItemExternalIdentifier,
           let r = ext.components(separatedBy: "/RID=").dropFirst().first, let secs = Double(r) {
            return Date(timeIntervalSinceReferenceDate: secs)
        }
        return e.occurrenceDate ?? e.startDate
    }

    static func originalString(_ d: Date, allDay: Bool) -> String {
        guard allDay else { return EventTime.utcString(d) }
        // All-day recurrence IDs may be stored as UTC midnight (floating) or local midnight.
        if Int(d.timeIntervalSince1970) % 86400 == 0 { return EventTime.dayFormatter(EventTime.utc).string(from: d) }
        return EventTime.dayString(d)
    }

    /// The series master (or the plain event) for a group of occurrences.
    func master(of group: [EKEvent]) -> EKEvent {
        let plain = group.first { !$0.isDetached } ?? group[0]
        let recurring = group.contains { $0.hasRecurrenceRules || $0.isDetached }
        if recurring {
            if !plain.isDetached, let m = store.calendarItem(withIdentifier: plain.calendarItemIdentifier) as? EKEvent { return m }
            if let ext = group[0].calendarItemExternalIdentifier,
               let uid = ext.components(separatedBy: "/RID=").first,
               let m = store.calendarItems(withExternalIdentifier: uid).compactMap({ $0 as? EKEvent })
                .first(where: { !$0.isDetached && $0.calendar?.calendarIdentifier == calendarID }) {
                return m
            }
        }
        return plain
    }

    static func times(_ e: EKEvent, allDay: Bool) -> (String, String) {
        if allDay {
            let cal = Calendar.current
            let s = cal.startOfDay(for: e.startDate)
            let eod = cal.startOfDay(for: e.endDate)
            let endExclusive = (e.endDate == eod && e.endDate > e.startDate) ? eod : cal.date(byAdding: .day, value: 1, to: eod)!
            return (EventTime.dayString(s), EventTime.dayString(endExclusive))
        }
        return (EventTime.utcString(e.startDate), EventTime.utcString(e.endDate))
    }

    func item(_ group: [EKEvent]) -> RemoteItem<EventRecord> {
        let master = master(of: group)

        var r = EventRecord()
        r.title = master.title ?? ""
        r.location = master.location ?? ""
        r.notes = master.notes ?? ""
        r.url = master.url?.absoluteString ?? ""
        r.allDay = master.isAllDay
        (r.start, r.end) = Self.times(master, allDay: master.isAllDay)
        r.timeZone = master.isAllDay ? "" : (master.timeZone?.identifier ?? "")
        r.busy = master.availability != .free
        if let rule = master.recurrenceRules?.first { r.recurrence = RRule.fromEventKit(rule, allDay: master.isAllDay) }
        if !r.recurrence.isEmpty {
            r.overrides = group.filter(\.isDetached).compactMap { occ in
                guard let od = Self.originalDate(occ) else { return nil }
                let orig = Self.originalString(od, allDay: master.isAllDay)
                let (s, e) = Self.times(occ, allDay: occ.isAllDay)
                return EventOverride(originalStart: orig, title: occ.title ?? "", location: occ.location ?? "",
                                     notes: occ.notes ?? "", allDay: occ.isAllDay, start: s, end: e)
            }
            r.overrides += cancelledOccurrences(master: master, group: group, rrule: r.recurrence)
        }
        let readOnly = master.organizer.map { !$0.isCurrentUser } ?? false
        return RemoteItem(id: master.calendarItemIdentifier, record: r, readOnly: readOnly)
    }

    /// Occurrences the rule produces inside the window that EventKit no longer returns were
    /// deleted on the Apple side ("delete this event only").
    func cancelledOccurrences(master: EKEvent, group: [EKEvent], rrule: String) -> [EventOverride] {
        let tz = master.timeZone ?? .current
        guard let expected = RecurrenceExpander.expand(rrule, start: master.startDate, timeZone: tz,
                                                        allDay: master.isAllDay, until: window.end) else { return [] }
        let inWindow = expected.filter { $0 >= window.start && $0 <= window.end }
        // Only judge occurrences that lie entirely inside the window the occurrences were fetched for.
        let present = group.compactMap(Self.originalDate)
        let missing = inWindow.filter { d in
            !present.contains { master.isAllDay ? Calendar.current.isDate($0, inSameDayAs: d) : abs($0.timeIntervalSince(d)) < 60 }
        }
        // Sanity check: if most occurrences look "missing", our expansion disagrees with Apple's
        // and we'd rather report nothing than delete the wrong instances.
        if missing.count > 2 && missing.count * 2 > inWindow.count { return [] }
        return missing.map { EventOverride(originalStart: master.isAllDay ? EventTime.dayString($0) : EventTime.utcString($0), cancelled: true) }
    }

    static func setTimes(_ e: EKEvent, allDay: Bool, start: String, end: String, tz: String) {
        e.isAllDay = allDay
        if allDay {
            guard let s = EventTime.localDay(start) else { return }
            let endEx = EventTime.localDay(end) ?? Calendar.current.date(byAdding: .day, value: 1, to: s)!
            e.timeZone = nil
            e.startDate = s
            e.endDate = max(s, endEx.addingTimeInterval(-1))
        } else {
            guard let s = EventTime.date(fromUTC: start) else { return }
            e.timeZone = TimeZone(identifier: tz) ?? .current
            e.startDate = s
            e.endDate = EventTime.date(fromUTC: end) ?? s.addingTimeInterval(3600)
        }
    }

    func apply(_ record: EventRecord, to e: EKEvent) {
        let r = record.normalized()
        e.title = r.title
        e.location = r.location.isEmpty ? nil : r.location
        e.notes = r.notes.isEmpty ? nil : r.notes
        e.url = r.url.isEmpty ? nil : URL(string: r.url)
        Self.setTimes(e, allDay: r.allDay, start: r.start, end: r.end, tz: r.timeZone)
        if e.calendar?.supportedEventAvailabilities.contains(.busy) ?? false {
            e.availability = r.busy ? .busy : .free
        }
        if r.recurrence.isEmpty {
            if e.hasRecurrenceRules { e.recurrenceRules = nil }
        } else if let rule = RRule.toEventKit(r.recurrence, allDay: r.allDay) {
            e.recurrenceRules = [rule]
        }
    }

    public func create(_ record: EventRecord) async throws -> RemoteItem<EventRecord> {
        let e = EKEvent(eventStore: store)
        e.calendar = try calendar
        apply(record, to: e)
        try store.save(e, span: .futureEvents, commit: true)
        try applyOverrides(record.normalized(), existing: [], id: e.calendarItemIdentifier)
        return try readBack(e.calendarItemIdentifier)
    }

    public func update(_ existing: RemoteItem<EventRecord>, to record: EventRecord) async throws -> RemoteItem<EventRecord> {
        guard let e = store.calendarItem(withIdentifier: existing.id) as? EKEvent else { throw EventKitError.notFound }
        apply(record, to: e)
        try store.save(e, span: .futureEvents, commit: true)
        try applyOverrides(record.normalized(), existing: existing.record.overrides, id: existing.id)
        return try readBack(existing.id)
    }

    func occurrence(id: String, originalStart: String, allDay: Bool) throws -> EKEvent? {
        let cal = try calendar
        let orig = allDay ? EventTime.localDay(originalStart) : EventTime.date(fromUTC: originalStart)
        guard let orig else { return nil }
        let key = (store.calendarItem(withIdentifier: id) as? EKEvent).map(Self.seriesKey) ?? "id:" + id
        func matches(_ e: EKEvent) -> Bool {
            guard e.calendarItemIdentifier == id || Self.seriesKey(e) == key, let od = Self.originalDate(e) else { return false }
            return allDay ? Calendar.current.isDate(od, inSameDayAs: orig) : abs(od.timeIntervalSince(orig)) < 60
        }
        let near = store.events(matching: store.predicateForEvents(withStart: orig.addingTimeInterval(-86400),
                                                                   end: orig.addingTimeInterval(2 * 86400), calendars: [cal]))
        if let e = near.first(where: matches) { return e }
        return windowEvents(cal).first(where: matches) // a detached occurrence may have moved far away
    }

    func applyOverrides(_ r: EventRecord, existing: [EventOverride], id: String) throws {
        guard !r.recurrence.isEmpty else { return }
        for o in r.overrides where !existing.contains(o) {
            guard let occ = try occurrence(id: id, originalStart: o.originalStart, allDay: r.allDay) else { continue }
            if o.cancelled {
                try store.remove(occ, span: .thisEvent, commit: true)
            } else {
                occ.title = o.title
                occ.location = o.location.isEmpty ? nil : o.location
                occ.notes = o.notes.isEmpty ? nil : o.notes
                if !o.start.isEmpty && !o.end.isEmpty {
                    Self.setTimes(occ, allDay: o.allDay, start: o.start, end: o.end, tz: r.timeZone)
                }
                try store.save(occ, span: .thisEvent, commit: true)
            }
        }
    }

    func readBack(_ id: String) throws -> RemoteItem<EventRecord> {
        let cal = try calendar
        let key = (store.calendarItem(withIdentifier: id) as? EKEvent).map(Self.seriesKey) ?? "id:" + id
        let group = windowEvents(cal).filter { $0.calendarItemIdentifier == id || Self.seriesKey($0) == key }
        if !group.isEmpty { return item(group) }
        guard let e = store.calendarItem(withIdentifier: id) as? EKEvent else { throw EventKitError.notFound }
        return item([e])
    }

    public func delete(_ existing: RemoteItem<EventRecord>) async throws {
        guard let e = store.calendarItem(withIdentifier: existing.id) as? EKEvent else { return }
        try store.remove(e, span: .futureEvents, commit: true)
    }

    public func isSafeToDelete(_ item: RemoteItem<EventRecord>) -> Bool { window.isSafeToDelete(item.record) }
}
