import Foundation

/// Expands a (canonical) RRULE into occurrence start dates, for the subset of rules that
/// Google Calendar and Apple Calendar create in practice. Returns nil for anything it does
/// not fully understand, so callers can fall back to doing nothing.
///
/// Used to notice occurrences that were deleted on the Apple side: EventKit exposes no
/// exception dates, an occurrence just stops being returned.
public enum RecurrenceExpander {
    static let dayCodes = ["SU": 1, "MO": 2, "TU": 3, "WE": 4, "TH": 5, "FR": 6, "SA": 7] // Calendar weekday numbers

    struct ByDay { var ordinal: Int; var weekday: Int }

    /// - Parameters:
    ///   - start: first occurrence (DTSTART); for all-day events local midnight.
    ///   - timeZone: wall-clock zone the rule repeats in.
    ///   - until: stop after this date (exclusive upper bound of the search).
    ///   - limit: safety cap on generated occurrences.
    public static func expand(_ rule: String, start: Date, timeZone: TimeZone, allDay: Bool,
                              until searchEnd: Date, limit: Int = 5000) -> [Date]? {
        let p = RRule.parse(rule)
        guard let freq = p["FREQ"] else { return nil }
        let supported: Set<String> = ["FREQ", "INTERVAL", "COUNT", "UNTIL", "BYDAY", "BYMONTHDAY", "BYMONTH", "BYSETPOS", "WKST"]
        guard Set(p.keys).isSubset(of: supported) else { return nil }
        let interval = max(1, Int(p["INTERVAL"] ?? "1") ?? 1)
        let count = p["COUNT"].flatMap(Int.init)
        var untilDate: Date?
        if let u = p["UNTIL"] {
            guard let s = EventTime.fromICal(u, tz: timeZone) else { return nil }
            if s.count == 10 {
                // Date-only UNTIL includes that whole day.
                guard let d = EventTime.localDay(s) else { return nil }
                untilDate = Calendar(identifier: .gregorian).date(byAdding: .day, value: 1, to: d)!.addingTimeInterval(-1)
            } else {
                untilDate = EventTime.date(fromUTC: s)
            }
        }
        var byDay: [ByDay] = []
        if let v = p["BYDAY"] {
            for t in v.split(separator: ",") {
                let code = String(t.suffix(2))
                guard let wd = dayCodes[code] else { return nil }
                let ord = t.count > 2 ? Int(t.dropLast(2)) : 0
                guard let ord else { return nil }
                byDay.append(ByDay(ordinal: ord, weekday: wd))
            }
        }
        func ints(_ k: String) -> [Int]? {
            guard let v = p[k] else { return nil }
            let a = v.split(separator: ",").compactMap { Int($0) }
            return a.isEmpty ? nil : a
        }
        let byMonthDay = ints("BYMONTHDAY"), byMonth = ints("BYMONTH"), bySetPos = ints("BYSETPOS")
        if bySetPos != nil && !(freq == "MONTHLY" || freq == "YEARLY") { return nil }

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = allDay ? .current : timeZone
        cal.firstWeekday = 2 // WKST=MO (RFC 5545 default)
        let s = cal.dateComponents([.year, .month, .day, .hour, .minute, .second, .weekday], from: start)
        let hour = s.hour ?? 0, minute = s.minute ?? 0, second = s.second ?? 0

        func at(_ y: Int, _ m: Int, _ d: Int) -> Date? {
            var dc = DateComponents()
            dc.year = y; dc.month = m; dc.day = d; dc.hour = hour; dc.minute = minute; dc.second = second
            guard let date = cal.date(from: dc) else { return nil }
            // Reject rolled-over dates such as 31 February.
            let back = cal.dateComponents([.year, .month, .day], from: date)
            return (back.year == y && back.month == m && back.day == d) ? date : nil
        }
        func daysIn(_ y: Int, _ m: Int) -> Int {
            cal.range(of: .day, in: .month, for: cal.date(from: DateComponents(year: y, month: m, day: 1))!)!.count
        }
        /// Candidate days in a month for BYDAY/BYMONTHDAY rules.
        func monthDays(_ y: Int, _ m: Int) -> [Int] {
            let n = daysIn(y, m)
            var days: [Int] = []
            if let bmd = byMonthDay {
                days = bmd.map { $0 > 0 ? $0 : n + $0 + 1 }.filter { (1...n).contains($0) }
            } else if !byDay.isEmpty {
                for bd in byDay {
                    let matching = (1...n).filter { cal.component(.weekday, from: cal.date(from: DateComponents(year: y, month: m, day: $0))!) == bd.weekday }
                    if bd.ordinal == 0 { days += matching }
                    else if bd.ordinal > 0, bd.ordinal <= matching.count { days.append(matching[bd.ordinal - 1]) }
                    else if bd.ordinal < 0, -bd.ordinal <= matching.count { days.append(matching[matching.count + bd.ordinal]) }
                }
            } else {
                days = [s.day!].filter { $0 <= n }
            }
            days = Array(Set(days)).sorted()
            if let sp = bySetPos {
                days = sp.compactMap { i in
                    let idx = i > 0 ? i - 1 : days.count + i
                    return days.indices.contains(idx) ? days[idx] : nil
                }.sorted()
            }
            return days
        }

        var out: [Date] = []
        var produced = 0
        func emit(_ d: Date) -> Bool { // returns false to stop
            if d < start { return true }
            if let untilDate, d > untilDate { return false }
            if d > searchEnd { return false }
            produced += 1
            out.append(d)
            if let count, produced >= count { return false }
            return produced < limit
        }

        switch freq {
        case "DAILY":
            if byMonthDay != nil { return nil }
            var k = 0
            while true {
                guard let day = cal.date(byAdding: .day, value: k * interval, to: cal.startOfDay(for: start)) else { return nil }
                let c = cal.dateComponents([.year, .month, .day, .weekday], from: day)
                let okDay = byDay.isEmpty || byDay.contains { $0.weekday == c.weekday && $0.ordinal == 0 }
                let okMonth = byMonth?.contains(c.month!) ?? true
                if okDay && okMonth, let d = at(c.year!, c.month!, c.day!) { if !emit(d) { break } }
                if day > searchEnd || k > 100_000 { break }
                k += 1
            }
        case "WEEKLY":
            if byMonthDay != nil || byDay.contains(where: { $0.ordinal != 0 }) { return nil }
            let weekdays = byDay.isEmpty ? [s.weekday!] : byDay.map(\.weekday)
            // Monday of DTSTART's week
            let startDay = cal.startOfDay(for: start)
            let offset = (cal.component(.weekday, from: startDay) + 5) % 7
            let weekStart = cal.date(byAdding: .day, value: -offset, to: startDay)!
            var k = 0
            outer: while true {
                let ws = cal.date(byAdding: .day, value: 7 * k * interval, to: weekStart)!
                let days = weekdays.map { (($0 + 5) % 7) }.sorted().map { cal.date(byAdding: .day, value: $0, to: ws)! }
                for day in days {
                    let c = cal.dateComponents([.year, .month, .day], from: day)
                    if let bm = byMonth, !bm.contains(c.month!) { continue }
                    if let d = at(c.year!, c.month!, c.day!) { if !emit(d) { break outer } }
                }
                if ws > searchEnd || k > 20_000 { break }
                k += 1
            }
        case "MONTHLY":
            var k = 0
            outer: while true {
                let first = cal.date(byAdding: .month, value: k * interval, to: cal.date(from: DateComponents(year: s.year, month: s.month, day: 1))!)!
                let c = cal.dateComponents([.year, .month], from: first)
                if byMonth == nil || byMonth!.contains(c.month!) {
                    for day in monthDays(c.year!, c.month!) {
                        if let d = at(c.year!, c.month!, day) { if !emit(d) { break outer } }
                    }
                }
                if first > searchEnd || k > 5000 { break }
                k += 1
            }
        case "YEARLY":
            let months = byMonth ?? [s.month!]
            var k = 0
            outer: while true {
                let y = s.year! + k * interval
                for m in months.sorted() {
                    let days = (byMonthDay == nil && byDay.isEmpty) ? [s.day!].filter { $0 <= daysIn(y, m) } : monthDays(y, m)
                    for day in days {
                        if let d = at(y, m, day) { if !emit(d) { break outer } }
                    }
                }
                if let jan = cal.date(from: DateComponents(year: y, month: 1, day: 1)), jan > searchEnd { break }
                if k > 500 { break }
                k += 1
            }
        default:
            return nil
        }
        return out
    }
}
