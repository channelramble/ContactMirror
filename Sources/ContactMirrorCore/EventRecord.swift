import Foundation

/// A change to one occurrence of a recurring event (moved/edited, or cancelled).
public struct EventOverride: Codable, Hashable, Sendable {
    /// When the occurrence would have started (same format as `EventRecord.start`).
    public var originalStart: String
    public var cancelled = false
    public var title = ""
    public var location = ""
    public var notes = ""
    public var allDay = false
    public var start = ""
    public var end = ""

    public init(originalStart: String, cancelled: Bool = false, title: String = "", location: String = "",
                notes: String = "", allDay: Bool = false, start: String = "", end: String = "") {
        self.originalStart = originalStart; self.cancelled = cancelled; self.title = title
        self.location = location; self.notes = notes; self.allDay = allDay; self.start = start; self.end = end
    }
}

/// A calendar event (or a whole recurring series): Google Calendar <-> iCloud Calendar.
/// Times are stored as UTC ("2026-01-31T15:00:00Z"); all-day dates as "2026-01-31"
/// with an exclusive end date.
public struct EventRecord: SyncableRecord {
    public var title = ""
    public var location = ""
    public var notes = ""
    public var url = ""
    public var allDay = false
    public var start = ""
    public var end = ""
    /// IANA time zone of a timed event ("" = unspecified).
    public var timeZone = ""
    /// Canonical RRULE without the "RRULE:" prefix, "" for a single event.
    public var recurrence = ""
    public var overrides: [EventOverride] = []
    public var busy = true

    public init() {}

    public func normalized() -> EventRecord {
        func t(_ s: String) -> String {
            s.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var r = self
        r.title = t(title); r.location = t(location); r.notes = t(notes); r.url = t(url)
        r.timeZone = allDay ? "" : t(timeZone)
        r.recurrence = RRule.canonical(recurrence)
        var seen = Set<String>()
        r.overrides = overrides
            .map { o in
                var o = o
                o.title = t(o.title); o.location = t(o.location); o.notes = t(o.notes)
                if o.cancelled { o.title = ""; o.location = ""; o.notes = ""; o.start = ""; o.end = ""; o.allDay = false }
                return o
            }
            .filter { seen.insert($0.originalStart).inserted }
            .sorted { $0.originalStart < $1.originalStart }
        if r.recurrence.isEmpty { r.overrides = [] }
        return r
    }

    public var displayName: String {
        let name = title.isEmpty ? "(untitled event)" : title
        return start.isEmpty ? name : "\(name) (\(start.prefix(10)))"
    }

    public var matchKeys: [[String]] {
        let r = normalized()
        guard !r.start.isEmpty else { return [] }
        return [["\(r.title.lowercased())|\(r.start)"]]
    }

    public static func union(primary p: EventRecord, secondary s: EventRecord) -> EventRecord {
        let p = p.normalized(), s = s.normalized()
        var r = p
        if r.location.isEmpty { r.location = s.location }
        if r.notes.isEmpty { r.notes = s.notes }
        if r.url.isEmpty { r.url = s.url }
        if r.timeZone.isEmpty { r.timeZone = s.timeZone }
        let have = Set(r.overrides.map(\.originalStart))
        r.overrides += s.overrides.filter { !have.contains($0.originalStart) }
        return r.normalized()
    }

    /// Start, end, all-day and time zone describe one moment together and are never mixed.
    public struct Timing: Equatable {
        var allDay: Bool; var start: String; var end: String; var timeZone: String
    }
    public var timing: Timing {
        get { Timing(allDay: allDay, start: start, end: end, timeZone: timeZone) }
        set { allDay = newValue.allDay; start = newValue.start; end = newValue.end; timeZone = newValue.timeZone }
    }

    public static var mergeFields: [MergeField<EventRecord>] {
        [.field(\.title), .field(\.location), .field(\.notes), .field(\.url), .field(\.busy),
         .field(\.recurrence), .field(\.overrides), .field(\.timing)]
    }
}

// MARK: - Date helpers

public enum EventTime {
    static let utc = TimeZone(identifier: "UTC")!

    static let utcFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = utc
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return f
    }()

    static func dayFormatter(_ tz: TimeZone = .current) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = tz
        f.dateFormat = "yyyy-MM-dd"
        return f
    }

    public static func utcString(_ d: Date) -> String { utcFormatter.string(from: d) }
    public static func date(fromUTC s: String) -> Date? { utcFormatter.date(from: s) }

    /// Parses RFC 3339 ("2026-01-31T10:00:00-05:00", with or without fractional seconds).
    public static func parseRFC3339(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }

    /// Local-midnight date for a "yyyy-MM-dd" string.
    public static func localDay(_ s: String) -> Date? { dayFormatter().date(from: s) }
    public static func dayString(_ d: Date) -> String { dayFormatter().string(from: d) }

    public static func addDays(_ s: String, _ n: Int) -> String {
        guard let d = localDay(s), let x = Calendar(identifier: .gregorian).date(byAdding: .day, value: n, to: d) else { return s }
        return dayString(x)
    }

    /// Parses an iCalendar date or date-time value ("20260131", "20260131T100000Z",
    /// or floating "20260131T100000" in `tz`) into the record's string format.
    public static func fromICal(_ v: String, tz: TimeZone?) -> String? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        if v.count == 8 {
            f.dateFormat = "yyyyMMdd"
            f.timeZone = .current
            guard let d = f.date(from: v) else { return nil }
            return dayString(d)
        }
        if v.hasSuffix("Z") {
            f.timeZone = utc
            f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        } else {
            f.timeZone = tz ?? .current
            f.dateFormat = "yyyyMMdd'T'HHmmss"
        }
        guard let d = f.date(from: v) else { return nil }
        return utcString(d)
    }

    /// Google instance id suffix for an occurrence ("20260131T150000Z" / "20260131").
    public static func instanceSuffix(_ originalStart: String) -> String {
        if originalStart.count == 10 { return originalStart.replacingOccurrences(of: "-", with: "") }
        return originalStart.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: ":", with: "")
    }
}
