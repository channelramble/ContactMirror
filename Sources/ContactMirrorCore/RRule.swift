import Foundation
import EventKit

/// Conversion between iCalendar RRULE strings (Google) and EKRecurrenceRule (Apple).
public enum RRule {
    static let order = ["FREQ", "INTERVAL", "BYDAY", "BYMONTHDAY", "BYMONTH", "BYYEARDAY", "BYWEEKNO", "BYSETPOS", "COUNT", "UNTIL"]
    static let weekdays = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"] // EKWeekday raw value - 1

    public static func parse(_ s: String) -> [String: String] {
        var rule = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if rule.uppercased().hasPrefix("RRULE:") { rule = String(rule.dropFirst(6)) }
        var out: [String: String] = [:]
        for part in rule.split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 { out[kv[0].uppercased()] = kv[1].uppercased() }
        }
        return out
    }

    /// Canonical string: fixed key order, sorted list values, defaults removed.
    public static func canonical(_ s: String) -> String {
        var p = parse(s)
        guard let freq = p["FREQ"], !freq.isEmpty else { return "" }
        p["FREQ"] = freq
        if p["INTERVAL"] == "1" { p["INTERVAL"] = nil }
        p["WKST"] = nil
        if let byday = p["BYDAY"] {
            p["BYDAY"] = byday.split(separator: ",").map(String.init).sorted { a, b in
                let da = weekdays.firstIndex(of: String(a.suffix(2))) ?? 0
                let db = weekdays.firstIndex(of: String(b.suffix(2))) ?? 0
                // Monday-first order
                return ((da + 6) % 7, a) < ((db + 6) % 7, b)
            }.joined(separator: ",")
        }
        for k in ["BYMONTHDAY", "BYMONTH", "BYYEARDAY", "BYWEEKNO", "BYSETPOS"] {
            if let v = p[k] { p[k] = v.split(separator: ",").compactMap { Int($0) }.sorted().map(String.init).joined(separator: ",") }
        }
        return order.compactMap { k in p[k].map { "\(k)=\($0)" } }.joined(separator: ";")
    }

    public static func toEventKit(_ s: String, allDay: Bool) -> EKRecurrenceRule? {
        let p = parse(s)
        let freq: EKRecurrenceFrequency
        switch p["FREQ"] {
        case "DAILY": freq = .daily
        case "WEEKLY": freq = .weekly
        case "MONTHLY": freq = .monthly
        case "YEARLY": freq = .yearly
        default: return nil
        }
        let interval = Int(p["INTERVAL"] ?? "1") ?? 1
        func ints(_ k: String) -> [NSNumber]? {
            guard let v = p[k] else { return nil }
            let list = v.split(separator: ",").compactMap { Int($0) }.map { NSNumber(value: $0) }
            return list.isEmpty ? nil : list
        }
        var days: [EKRecurrenceDayOfWeek]?
        if let byday = p["BYDAY"] {
            days = byday.split(separator: ",").compactMap { token in
                let t = String(token)
                guard let idx = weekdays.firstIndex(of: String(t.suffix(2))),
                      let wd = EKWeekday(rawValue: idx + 1) else { return nil }
                let n = Int(t.dropLast(2)) ?? 0
                return n == 0 ? EKRecurrenceDayOfWeek(wd) : EKRecurrenceDayOfWeek(wd, weekNumber: n)
            }
        }
        var end: EKRecurrenceEnd?
        if let count = p["COUNT"].flatMap(Int.init) {
            end = EKRecurrenceEnd(occurrenceCount: count)
        } else if let until = p["UNTIL"], let s = EventTime.fromICal(until, tz: nil) {
            let d = s.count == 10
                ? EventTime.localDay(s).flatMap { Calendar.current.date(byAdding: DateComponents(day: 1, second: -1), to: $0) }
                : EventTime.date(fromUTC: s)
            if let d { end = EKRecurrenceEnd(end: d) }
        }
        return EKRecurrenceRule(recurrenceWith: freq, interval: interval, daysOfTheWeek: days,
                                daysOfTheMonth: ints("BYMONTHDAY"), monthsOfTheYear: ints("BYMONTH"),
                                weeksOfTheYear: ints("BYWEEKNO"), daysOfTheYear: ints("BYYEARDAY"),
                                setPositions: ints("BYSETPOS"), end: end)
    }

    public static func fromEventKit(_ r: EKRecurrenceRule, allDay: Bool) -> String {
        var p: [String: String] = [:]
        switch r.frequency {
        case .daily: p["FREQ"] = "DAILY"
        case .weekly: p["FREQ"] = "WEEKLY"
        case .monthly: p["FREQ"] = "MONTHLY"
        case .yearly: p["FREQ"] = "YEARLY"
        @unknown default: return ""
        }
        if r.interval > 1 { p["INTERVAL"] = String(r.interval) }
        if let days = r.daysOfTheWeek, !days.isEmpty {
            p["BYDAY"] = days.map { d in
                let code = weekdays[d.dayOfTheWeek.rawValue - 1]
                return d.weekNumber == 0 ? code : "\(d.weekNumber)\(code)"
            }.joined(separator: ",")
        }
        func list(_ a: [NSNumber]?) -> String? {
            guard let a, !a.isEmpty else { return nil }
            return a.map { $0.stringValue }.joined(separator: ",")
        }
        p["BYMONTHDAY"] = list(r.daysOfTheMonth)
        p["BYMONTH"] = list(r.monthsOfTheYear)
        p["BYYEARDAY"] = list(r.daysOfTheYear)
        p["BYWEEKNO"] = list(r.weeksOfTheYear)
        p["BYSETPOS"] = list(r.setPositions)
        if let end = r.recurrenceEnd {
            if end.occurrenceCount > 0 {
                p["COUNT"] = String(end.occurrenceCount)
            } else if let d = end.endDate {
                p["UNTIL"] = untilString(d, allDay: allDay)
            }
        }
        return canonical(order.compactMap { k in p[k].map { "\(k)=\($0)" } }.joined(separator: ";"))
    }

    static func untilString(_ d: Date, allDay: Bool) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        if allDay {
            f.timeZone = .current
            f.dateFormat = "yyyyMMdd"
        } else {
            f.timeZone = EventTime.utc
            f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        }
        return f.string(from: d)
    }

    /// When the series ends, if it has an UNTIL (nil for open-ended or COUNT rules).
    static func untilDate(_ s: String) -> Date? {
        guard let u = parse(s)["UNTIL"], let v = EventTime.fromICal(u, tz: nil) else { return nil }
        return v.count == 10 ? EventTime.localDay(v) : EventTime.date(fromUTC: v)
    }

    static func hasCount(_ s: String) -> Bool { parse(s)["COUNT"] != nil }
}
