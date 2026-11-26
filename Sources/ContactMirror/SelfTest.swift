import AppKit
import Contacts
import EventKit
import ContactMirrorCore

/// End-to-end test against the real Google account and the real iCloud data on this Mac.
/// Run with:  open -n -a ContactMirror --args --selftest /path/to/report.txt
///
/// Calendars and tasks use temporary calendars/lists that are deleted afterwards. Contacts
/// use the real address books (that's the only place they can live) with clearly named
/// "Zz Selftest" contacts that are removed at the end.
@MainActor
final class SelfTest {
    let output: URL
    var lines: [String] = []
    var failures = 0
    let model = AppModel.shared
    let stamp = String(Int(Date().timeIntervalSince1970) % 100000)

    init(output: URL) { self.output = output }

    func say(_ s: String) {
        lines.append(s)
        try? lines.joined(separator: "\n").write(to: output, atomically: true, encoding: .utf8)
    }

    func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
        if !ok { failures += 1 }
        say((ok ? "PASS " : "FAIL ") + name + (ok ? "" : "\n     " + detail()))
    }

    static func run(output: URL) async -> Int32 {
        let t = SelfTest(output: output)
        t.say("ContactMirror self-test \(Updater.currentVersion) — \(Date())")
        await t.runAll()
        t.say("DONE failures=\(t.failures)")
        return t.failures == 0 ? 0 : 1
    }

    func runAll() async {
        model.refreshAccountState()
        guard model.auth.isSignedIn else { check(false, "signed in to Google"); return }
        check(model.contactsAuthorized, "Contacts permission")
        check(EventKitAccess.isAuthorized(.event), "Calendar permission")
        check(EventKitAccess.isAuthorized(.reminder), "Reminders permission")
        let api = GoogleAPIClient(auth: model.auth)
        do { try await tasksTest(api) } catch { check(false, "tasks test threw", "\(error)") }
        do { try await calendarTest(api) } catch { check(false, "calendar test threw", "\(error)") }
        do { try await contactsTest() } catch { check(false, "contacts test threw", "\(error)") }
    }

    // MARK: Helpers

    func tempState() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("cm-selftest-\(UUID().uuidString).json")
    }

    /// Pretend the last sync was an hour ago so deletions aren't held by the grace period.
    func age<R: SyncableRecord>(_ url: URL, _: R.Type, only ids: Set<String>? = nil) {
        var st = SyncState<R>.load(from: url)
        for i in st.pairs.indices where ids == nil || ids!.contains(st.pairs[i].googleID) || ids!.contains(st.pairs[i].icloudID) {
            st.pairs[i].lastSynced = Date().addingTimeInterval(-3600)
        }
        try? st.save(to: url)
    }

    func engine<R: SyncableRecord>(_ g: any RecordProvider<R>, _ c: any RecordProvider<R>, _ state: URL, _ what: String,
                                   log: ((String) -> Void)? = nil) -> SyncEngine<R> {
        let e = SyncEngine<R>(google: g, icloud: c, stateURL: state, what: what)
        e.log = log ?? { _ in }
        return e
    }

    /// `only`: judge only errors mentioning this text (other real items may have their own issues).
    func sync<R: SyncableRecord>(_ e: SyncEngine<R>, _ label: String, only: String? = nil) async throws -> SyncReport {
        let r = try await e.sync()
        say("     \(label): \(r)")
        let relevant = only.map { o in r.errors.filter { $0.contains(o) } } ?? r.errors
        check(relevant.isEmpty, "\(label) without errors", relevant.joined(separator: "; "))
        if let only, r.errors.count > relevant.count {
            say("     note: \(r.errors.count - relevant.count) unrelated real contact(s) failed, e.g. \(r.errors.first { !$0.contains(only) } ?? "")")
        }
        return r
    }

    func sameMultiset<T: Hashable>(_ a: [T], _ b: [T]) -> Bool {
        var d: [T: Int] = [:]
        for x in a { d[x, default: 0] += 1 }
        for x in b { d[x, default: 0] -= 1 }
        return d.values.allSatisfy { $0 == 0 }
    }

    // MARK: Tasks

    struct TaskView: Hashable { var title, notes, due: String; var completed: Bool }
    func view(_ t: TaskRecord) -> TaskView { let n = t.normalized(); return TaskView(title: n.title, notes: n.notes, due: n.due, completed: n.completed) }

    func tasksTest(_ api: GoogleAPIClient) async throws {
        say("\n== Tasks (temporary list) ==")
        let store = EKEventStore()
        let title = "CM Selftest \(stamp)"
        let gList = try await GoogleTasksProvider.createList(api: api, title: title)
        let cList = try EventKitAccess.createCollection(store, type: .reminder, title: title)
        do { try await tasksBody(api, store, gList, cList) } catch { check(false, "tasks test threw", "\(error)") }
        _ = try? await api.request("DELETE", "https://tasks.googleapis.com/tasks/v1/users/@me/lists/\(gList)", mutation: true)
        if let cal = store.calendar(withIdentifier: cList) { try? store.removeCalendar(cal, commit: true) }
        say("     (temporary task lists removed)")
    }

    func tasksBody(_ api: GoogleAPIClient, _ store: EKEventStore, _ gList: String, _ cList: String) async throws {
        let g = GoogleTasksProvider(api: api, listID: gList)
        let c = RemindersProvider(store: store, calendarID: cList)
        let state = tempState()
        let e = engine(g, c, state, "tasks")

        let g1 = try await g.create(TaskRecord(title: "G task with due", notes: "from google", due: "2026-12-20"))
        _ = try await g.create(TaskRecord(title: "G done task", completed: true))
        let c1 = try await c.create(TaskRecord(title: "C reminder", notes: "from icloud"))
        // A reminder with a due *time*: Google keeps the date, Apple must keep the time.
        let c2 = try await c.create(TaskRecord(title: "C reminder timed", due: "2026-12-21"))
        if let r = store.calendarItem(withIdentifier: c2.id) as? EKReminder {
            var dc = r.dueDateComponents ?? DateComponents(); dc.hour = 15; dc.minute = 30
            r.dueDateComponents = dc; try store.save(r, commit: true)
        }
        _ = try await sync(e, "first sync")
        func compare(_ label: String) async throws {
            let gs = try await g.fetchAll().map { view($0.record) }, cs = try await c.fetchAll().map { view($0.record) }
            check(sameMultiset(gs, cs), "tasks identical \(label) (\(gs.count) vs \(cs.count))", "google=\(gs.sorted { $0.title < $1.title })\n     icloud=\(cs.sorted { $0.title < $1.title })")
        }
        try await compare("after first sync")
        let r2 = try await sync(e, "second sync")
        check(r2.changeCount == 0, "no ping-pong on tasks", "\(r2)")

        // Edits on both sides
        var gl = try await g.fetchAll()
        let gItem = gl.first { $0.id == g1.id }!
        var ge = gItem.record; ge.completed = true; ge.notes = "edited in google"
        _ = try await g.update(gItem, to: ge)
        var cl = try await c.fetchAll()
        let cItem = cl.first { $0.id == c1.id }!
        var ce = cItem.record; ce.title = "C reminder (renamed)"; ce.due = "2026-12-24"
        _ = try await c.update(cItem, to: ce)
        _ = try await sync(e, "sync after edits")
        try await compare("after edits")
        if let r = store.calendarItem(withIdentifier: c2.id) as? EKReminder {
            check(r.dueDateComponents?.hour == 15 && r.dueDateComponents?.minute == 30, "reminder due time preserved", "\(String(describing: r.dueDateComponents))")
        }

        // Conflict on the same field: Google wins by default
        gl = try await g.fetchAll(); cl = try await c.fetchAll()
        let gc = gl.first { $0.record.title == "G done task" }!
        let cc = cl.first { $0.record.title == "G done task" }!
        var gx = gc.record; gx.notes = "google side"; _ = try await g.update(gc, to: gx)
        var cx = cc.record; cx.notes = "icloud side"; cx.due = "2026-12-30"; _ = try await c.update(cc, to: cx)
        _ = try await sync(e, "sync after conflict")
        let after = try await g.fetchAll().first { $0.record.title == "G done task" }?.record
        check(after?.notes == "google side" && after?.due == "2026-12-30", "conflict: same field → Google wins, other field merged", "\(String(describing: after))")
        try await compare("after conflict")

        // Deletions both ways
        gl = try await g.fetchAll(); cl = try await c.fetchAll()
        try await g.delete(gl.first { $0.record.title == "G task with due" }!)
        try await c.delete(cl.first { $0.record.title == "C reminder timed" }!)
        age(state, TaskRecord.self)
        _ = try await sync(e, "sync after deletions")
        try await compare("after deletions")
        let remaining = try await c.fetchAll().map(\.record.title).sorted()
        check(remaining == ["C reminder (renamed)", "G done task"], "deletions propagated", "\(remaining)")
        let r3 = try await sync(e, "final sync")
        check(r3.changeCount == 0, "tasks stable at the end", "\(r3)")
    }

    // MARK: Calendar

    struct EventView: Hashable {
        var title, location, notes, start, end, recurrence: String
        var allDay: Bool
        var overrides: [String]
    }

    func view(_ e: EventRecord) -> EventView {
        let n = e.normalized()
        return EventView(title: n.title, location: n.location, notes: n.notes, start: n.start, end: n.end,
                         recurrence: n.recurrence, allDay: n.allDay,
                         overrides: n.overrides.map { "\($0.originalStart)|\($0.cancelled)|\($0.title)|\($0.start)|\($0.end)" })
    }

    func at(_ daysFromNow: Int, _ hour: Int, _ minute: Int = 0, tz: String) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: tz)!
        let base = cal.date(byAdding: .day, value: daysFromNow, to: Date())!
        var dc = cal.dateComponents([.year, .month, .day], from: base)
        dc.hour = hour; dc.minute = minute
        return cal.date(from: dc)!
    }

    func timed(_ title: String, _ start: Date, minutes: Int, tz: String, rrule: String = "") -> EventRecord {
        var e = EventRecord()
        e.title = title; e.start = EventTime.utcString(start); e.end = EventTime.utcString(start.addingTimeInterval(Double(minutes) * 60))
        e.timeZone = tz; e.recurrence = rrule
        return e
    }

    /// Occurrences as each side actually expands them (title + start), in a range.
    func occurrences(api: GoogleAPIClient, gCal: String, store: EKEventStore, cCal: String, from: Date, to: Date) async throws -> ([String], [String]) {
        var g: [String] = []
        var token: String?
        repeat {
            var q = ["singleEvents": "true", "timeMin": EventTime.utcString(from), "timeMax": EventTime.utcString(to), "maxResults": "2500"]
            if let token { q["pageToken"] = token }
            let path = "https://www.googleapis.com/calendar/v3/calendars/\(gCal.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)/events"
            let json = try await api.request("GET", path, query: q)
            for ev in json["items"] as? [[String: Any]] ?? [] where (ev["status"] as? String) != "cancelled" {
                let st = ev["start"] as? [String: Any] ?? [:]
                let s = (st["date"] as? String) ?? (st["dateTime"] as? String).flatMap(EventTime.parseRFC3339).map(EventTime.utcString) ?? "?"
                g.append("\(ev["summary"] as? String ?? "")@\(s)")
            }
            token = json["nextPageToken"] as? String
        } while token != nil
        let cal = store.calendar(withIdentifier: cCal)!
        let c = store.events(matching: store.predicateForEvents(withStart: from, end: to, calendars: [cal])).map { e -> String in
            let s = e.isAllDay ? EventTime.dayString(e.startDate) : EventTime.utcString(e.startDate)
            return "\(e.title ?? "")@\(s)"
        }
        return (g.sorted(), c.sorted())
    }

    func calendarTest(_ api: GoogleAPIClient) async throws {
        say("\n== Calendar (temporary calendar) ==")
        let store = EKEventStore()
        let title = "CM Selftest \(stamp)"
        let gCal = try await GoogleCalendarProvider.createCalendar(api: api, title: title)
        let cCal = try EventKitAccess.createCollection(store, type: .event, title: title)
        do { try await calendarBody(api, store, gCal, cCal) } catch { check(false, "calendar test threw", "\(error)") }
        _ = try? await api.request("DELETE", "https://www.googleapis.com/calendar/v3/calendars/\(gCal.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)", mutation: true)
        if let cal = store.calendar(withIdentifier: cCal) { try? store.removeCalendar(cal, commit: true) }
        say("     (temporary calendars removed)")
    }

    func calendarBody(_ api: GoogleAPIClient, _ store: EKEventStore, _ gCal: String, _ cCal: String) async throws {
        let window = CalendarWindow.standard()
        let g = GoogleCalendarProvider(api: api, calendarID: gCal, window: window)
        let c = AppleCalendarProvider(store: store, calendarID: cCal, window: window)
        let state = tempState()
        var engineLog: [String] = []
        let e = engine(g, c, state, "calendar") { engineLog.append($0) }

        let ny = "America/New_York"
        _ = try await g.create({ var x = timed("G timed", at(3, 14, tz: ny), minutes: 90, tz: ny); x.location = "Office"; x.notes = "Agenda"; return x }())
        var allDay = EventRecord(); allDay.title = "G all-day"; allDay.allDay = true
        allDay.start = EventTime.dayString(at(5, 12, tz: TimeZone.current.identifier)); allDay.end = EventTime.addDays(allDay.start, 2)
        _ = try await g.create(allDay)
        var weekly = timed("G weekly", at(2, 10, tz: ny), minutes: 60, tz: ny, rrule: "FREQ=WEEKLY;COUNT=6")
        let w0 = at(2, 10, tz: ny)
        let occ2 = EventTime.utcString(w0.addingTimeInterval(7 * 86400))
        let occ3 = EventTime.utcString(w0.addingTimeInterval(14 * 86400))
        weekly.overrides = [EventOverride(originalStart: occ2, cancelled: true),
                            EventOverride(originalStart: occ3, title: "G weekly (moved)", start: EventTime.utcString(w0.addingTimeInterval(14 * 86400 + 7200)),
                                          end: EventTime.utcString(w0.addingTimeInterval(14 * 86400 + 10800)))]
        _ = try await g.create(weekly)
        // Crosses the US daylight-saving change on 14 March 2027.
        var dstStart = DateComponents(); dstStart.year = 2027; dstStart.month = 3; dstStart.day = 1; dstStart.hour = 9
        var nyCal = Calendar(identifier: .gregorian); nyCal.timeZone = TimeZone(identifier: ny)!
        _ = try await g.create(timed("G DST weekly", nyCal.date(from: dstStart)!, minutes: 30, tz: ny, rrule: "FREQ=WEEKLY;BYDAY=MO;COUNT=4"))

        _ = try await c.create(timed("C timed", at(4, 16, tz: "Europe/London"), minutes: 45, tz: "Europe/London"))
        var cAllDay = EventRecord(); cAllDay.title = "C all-day"; cAllDay.allDay = true
        cAllDay.start = EventTime.dayString(at(6, 12, tz: TimeZone.current.identifier)); cAllDay.end = EventTime.addDays(cAllDay.start, 1)
        _ = try await c.create(cAllDay)
        var daily = timed("C daily", at(8, 8, tz: ny), minutes: 30, tz: ny, rrule: "FREQ=DAILY;COUNT=4")
        let d0 = at(8, 8, tz: ny)
        daily.overrides = [EventOverride(originalStart: EventTime.utcString(d0.addingTimeInterval(86400)), title: "C daily (edited)",
                                         start: EventTime.utcString(d0.addingTimeInterval(86400 + 3600)), end: EventTime.utcString(d0.addingTimeInterval(86400 + 5400)))]
        _ = try await c.create(daily)

        func compare(_ label: String) async throws {
            let gs = try await g.fetchAll().map { view($0.record) }, cs = try await c.fetchAll().map { view($0.record) }
            check(sameMultiset(gs, cs), "events identical \(label) (\(gs.count) vs \(cs.count))",
                  "google=\(gs.sorted { $0.title < $1.title })\n     icloud=\(cs.sorted { $0.title < $1.title })")
            let (go, co) = try await occurrences(api: api, gCal: gCal, store: store, cCal: cCal,
                                                 from: Date().addingTimeInterval(-86400), to: Date().addingTimeInterval(500 * 86400))
            check(go == co, "every occurrence identical \(label) (\(go.count) vs \(co.count))",
                  "only google=\(Set(go).subtracting(co).sorted())\n     only icloud=\(Set(co).subtracting(go).sorted())")
        }

        _ = try await sync(e, "first sync")
        try await compare("after first sync")
        engineLog.removeAll()
        let r2 = try await sync(e, "second sync")
        check(r2.changeCount == 0, "no ping-pong on events", "\(r2)\n     \(engineLog.joined(separator: "\n     "))")

        // Edits on both sides
        var gl = try await g.fetchAll(), cl = try await c.fetchAll()
        let gt = gl.first { $0.record.title == "G timed" }!
        var gtr = gt.record; gtr.start = EventTime.utcString(at(3, 15, tz: ny)); gtr.end = EventTime.utcString(at(3, 16, 30, tz: ny))
        _ = try await g.update(gt, to: gtr)
        let ct = cl.first { $0.record.title == "C timed" }!
        var ctr = ct.record; ctr.title = "C timed (renamed)"; ctr.location = "Café"
        _ = try await c.update(ct, to: ctr)
        let cd = cl.first { $0.record.title == "C daily" }!
        var cdr = cd.record; cdr.recurrence = "FREQ=DAILY;INTERVAL=2;COUNT=3"; cdr.overrides = []
        _ = try await c.update(cd, to: cdr)
        let gw = gl.first { $0.record.title == "G weekly" }!
        var gwr = gw.record; gwr.notes = "series notes"
        _ = try await g.update(gw, to: gwr)
        _ = try await sync(e, "sync after edits")
        try await compare("after edits")
        engineLog.removeAll()
        let r3 = try await sync(e, "sync after edits (2)")
        check(r3.changeCount == 0, "events stable after edits", "\(r3)\n     \(engineLog.joined(separator: "\n     "))")

        // Delete a single occurrence on the Apple side ("this event only") → must reach Google.
        if let gwID = (try await c.fetchAll()).first(where: { $0.record.title == "G weekly" })?.id,
           let master = store.calendarItem(withIdentifier: gwID) as? EKEvent {
            let occs = store.events(matching: store.predicateForEvents(withStart: Date(), end: Date().addingTimeInterval(60 * 86400),
                                                                       calendars: [store.calendar(withIdentifier: cCal)!]))
                .filter { AppleCalendarProvider.seriesKey($0) == AppleCalendarProvider.seriesKey(master) && !$0.isDetached }
                .sorted { $0.startDate < $1.startDate }
            if occs.count >= 3 {
                try store.remove(occs[occs.count - 1], span: .thisEvent, commit: true)
                _ = try await sync(e, "sync after deleting one iCloud occurrence")
                try await compare("after deleting one iCloud occurrence")
            } else {
                check(false, "found occurrences to delete", "\(occs.count)")
            }
        }

        // Deletions both ways
        gl = try await g.fetchAll(); cl = try await c.fetchAll()
        try await g.delete(gl.first { $0.record.title == "G all-day" }!)
        try await c.delete(cl.first { $0.record.title == "C timed (renamed)" }!)
        try await g.delete(gl.first { $0.record.title == "G DST weekly" }!)
        age(state, EventRecord.self)
        _ = try await sync(e, "sync after deletions")
        try await compare("after deletions")
        let titles = try await c.fetchAll().map(\.record.title).sorted()
        check(titles == ["C all-day", "C daily", "G timed", "G weekly"], "event deletions propagated", "\(titles)")
    }

    // MARK: Contacts

    func contactsTest() async throws {
        say("\n== Contacts (real address books, temporary \"Zz Selftest\" contacts) ==")
        let containerID = model.effectiveContainerID
        guard !containerID.isEmpty else { check(false, "iCloud contacts container found"); return }
        let notes = AppleContactsProvider.notesAccessible()
        let g = GoogleContactsProvider(auth: model.auth, syncNotes: notes)
        let c = AppleContactsProvider(containerID: containerID, syncNotes: notes)
        let state = model.stateURL(notes: notes)
        var engineLog: [String] = []
        let e = engine(g, c, state, "contacts") { engineLog.append($0) }
        let tag = "Zz Selftest \(stamp)"
        func isTest(_ r: ContactRecord) -> Bool { r.familyName.hasPrefix(tag) }

        // Bring the real address books up to date first so later checks only see our changes.
        _ = try await sync(e, "baseline sync (real contacts)", only: "Zz Selftest")

        var gr = ContactRecord(); gr.givenName = "Gina"; gr.familyName = tag + " G"
        gr.emails = [LabeledValue(label: "work", value: "gina.\(stamp)@example.com")]
        gr.phones = [LabeledValue(label: "mobile", value: "+1 561 555 \(stamp.suffix(4))")]
        gr.addresses = [PostalAddress(label: "home", street: "1 Test St\nApt 2", city: "Boca Raton", region: "FL", postalCode: "33431", country: "USA", countryCode: "us")]
        gr.birthday = DateValue(year: nil, month: 7, day: 4); gr.organization = "Selftest Inc"; gr.jobTitle = "QA"
        gr.urls = [LabeledValue(label: "homepage", value: "https://example.com/gina")]
        gr.relations = [LabeledValue(label: "spouse", value: "Gus")]
        let gNew = try await g.create(gr)
        var cr = ContactRecord(); cr.givenName = "Carl"; cr.familyName = tag + " C"; cr.nickname = "Carlito"
        cr.emails = [LabeledValue(label: "home", value: "carl.\(stamp)@example.com")]
        cr.phones = [LabeledValue(label: "iphone", value: "+1 561 555 01\(stamp.suffix(2))")]
        cr.dates = [DateValue(label: "anniversary", year: 2015, month: 6, day: 1)]
        let cNew = try await c.create(cr)

        func compare(_ label: String) async throws {
            let gs = try await g.fetchAll().map(\.record).filter(isTest).map(\.fingerprint)
            let cs = try await c.fetchAll().map(\.record).filter(isTest).map(\.fingerprint)
            if !sameMultiset(gs, cs) {
                let gd = try await g.fetchAll().map(\.record).filter(isTest), cd = try await c.fetchAll().map(\.record).filter(isTest)
                check(false, "test contacts identical \(label)", "google=\(gd)\n     icloud=\(cd)")
            } else {
                check(true, "test contacts identical \(label) (\(gs.count) each)")
            }
        }
        _ = try await sync(e, "sync after adding test contacts", only: tag)
        try await compare("after adding")
        engineLog.removeAll()
        _ = try await sync(e, "second sync", only: tag)
        let churn = engineLog.filter { $0.contains(tag) }
        check(churn.isEmpty, "no ping-pong on test contacts", churn.joined(separator: "\n     "))

        // Edits on both sides
        var gl = try await g.fetchAll(), cl = try await c.fetchAll()
        let gi = gl.first { $0.id == gNew.id }!
        var ge = gi.record; ge.jobTitle = "QA Lead"; ge.phones.append(LabeledValue(label: "work", value: "+1 561 555 9999"))
        _ = try await g.update(gi, to: ge)
        let ci = cl.first { $0.id == cNew.id }!
        var ce = ci.record; ce.organization = "Carl Co"; ce.emails = []
        _ = try await c.update(ci, to: ce)
        _ = try await sync(e, "sync after edits", only: tag)
        try await compare("after edits")

        // A contact with a note: macOS only lets Contacts.app edit it (AppleScript fallback).
        let noteName = tag + " N"
        do {
            try ContactsAppleScriptBridge.makeContactWithNote(first: "Nora", last: noteName)
            _ = try await sync(e, "sync after adding contact with note", only: tag)
            gl = try await g.fetchAll()
            if let gn = gl.first(where: { $0.record.familyName == noteName }) {
                var gnr = gn.record; gnr.jobTitle = "Has a note"
                _ = try await g.update(gn, to: gnr)
                _ = try await sync(e, "sync after editing note-contact in Google", only: tag)
                let cn = try await c.fetchAll().first { $0.record.familyName == noteName }
                check(cn?.record.jobTitle == "Has a note", "contact with a note updated in iCloud (AppleScript fallback)", "\(String(describing: cn?.record))")
            } else {
                check(false, "contact with note reached Google")
            }
        } catch {
            let code = (error as NSError).code
            if code == -1712 || code == -1743 || "\(error)".contains("-1712") || "\(error)".contains("-1743") {
                say("SKIP contact-with-note test: macOS is waiting for permission for ContactMirror to control Contacts")
            } else {
                check(false, "contact-with-note test", "\(error.localizedDescription)")
            }
        }

        // Deletions both ways
        gl = try await g.fetchAll(); cl = try await c.fetchAll()
        var ids = Set<String>()
        for x in gl where isTest(x.record) { ids.insert(x.id) }
        for x in cl where isTest(x.record) { ids.insert(x.id) }
        if let x = gl.first(where: { $0.record.familyName == tag + " G" }) { try await g.delete(x) }
        if let x = cl.first(where: { $0.record.familyName == tag + " C" }) { try await c.delete(x) }
        if let x = cl.first(where: { $0.record.familyName == noteName }) { try await c.delete(x) }
        age(state, ContactRecord.self, only: ids)
        _ = try await sync(e, "sync after deleting test contacts", only: tag)
        let leftG = try await g.fetchAll().filter { isTest($0.record) }
        let leftC = try await c.fetchAll().filter { isTest($0.record) }
        check(leftG.isEmpty && leftC.isEmpty, "contact deletions propagated both ways",
              "left in google=\(leftG.map(\.record.displayName)) icloud=\(leftC.map(\.record.displayName))")
        // Safety net: never leave test contacts behind.
        for x in leftG { try? await g.delete(x) }
        for x in leftC { try? await c.delete(x) }
    }
}

/// Small AppleScript helper used only by the self-test.
enum ContactsAppleScriptBridge {
    static func makeContactWithNote(first: String, last: String) throws {
        let script = """
        tell application "Contacts"
        make new person with properties {first name:"\(first)", last name:"\(last)", note:"Selftest note"}
        save
        end tell
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        let err = Pipe(); p.standardError = err
        try p.run(); p.waitUntilExit()
        if p.terminationStatus != 0 {
            throw NSError(domain: "SelfTest", code: Int(p.terminationStatus), userInfo: [NSLocalizedDescriptionKey:
                String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "osascript failed"])
        }
    }
}

extension SelfTest {
    /// Dumps how EventKit identifies occurrences of a recurring event with an edited occurrence.
    static func diagnoseEventKit(output: URL) async -> Int32 {
        var out: [String] = []
        let store = EKEventStore()
        do {
            let calID = try EventKitAccess.createCollection(store, type: .event, title: "CM Diag \(Int(Date().timeIntervalSince1970) % 10000)")
            let cal = store.calendar(withIdentifier: calID)!
            let e = EKEvent(eventStore: store)
            e.calendar = cal; e.title = "diag series"
            e.timeZone = TimeZone(identifier: "America/New_York")
            e.startDate = Date().addingTimeInterval(3 * 86400).rounded(); e.endDate = e.startDate.addingTimeInterval(3600)
            e.recurrenceRules = [EKRecurrenceRule(recurrenceWith: .daily, interval: 1, end: EKRecurrenceEnd(occurrenceCount: 5))]
            try store.save(e, span: .futureEvents, commit: true)
            out.append("master saved id=\(e.calendarItemIdentifier) ext=\(e.calendarItemExternalIdentifier ?? "nil") eventId=\(e.eventIdentifier ?? "nil")")
            func dump(_ label: String) {
                let evs = store.events(matching: store.predicateForEvents(withStart: Date(), end: Date().addingTimeInterval(20 * 86400), calendars: [cal]))
                out.append("-- \(label)")
                for x in evs {
                    out.append("  \(x.title ?? "") id=\(x.calendarItemIdentifier) ext=\(x.calendarItemExternalIdentifier ?? "nil") eventId=\(x.eventIdentifier ?? "nil") detached=\(x.isDetached) rules=\(x.hasRecurrenceRules) occ=\(x.occurrenceDate.map(EventTime.utcString) ?? "nil") start=\(EventTime.utcString(x.startDate))")
                }
            }
            dump("before edit")
            let evs = store.events(matching: store.predicateForEvents(withStart: Date(), end: Date().addingTimeInterval(20 * 86400), calendars: [cal]))
            if evs.count > 2 {
                let o = evs[1]; o.title = "diag edited"; o.startDate = o.startDate.addingTimeInterval(3600); o.endDate = o.endDate.addingTimeInterval(3600)
                try store.save(o, span: .thisEvent, commit: true)
                let d = evs[2]
                try store.remove(d, span: .thisEvent, commit: true)
            }
            dump("after edit + delete (fresh query)")
            let store2 = EKEventStore()
            let cal2 = store2.calendar(withIdentifier: calID)!
            let evs2 = store2.events(matching: store2.predicateForEvents(withStart: Date(), end: Date().addingTimeInterval(20 * 86400), calendars: [cal2]))
            out.append("-- new store")
            for x in evs2 {
                out.append("  \(x.title ?? "") id=\(x.calendarItemIdentifier) ext=\(x.calendarItemExternalIdentifier ?? "nil") eventId=\(x.eventIdentifier ?? "nil") detached=\(x.isDetached) rules=\(x.hasRecurrenceRules) occ=\(x.occurrenceDate.map(EventTime.utcString) ?? "nil")")
            }
            if let m = store2.calendarItem(withIdentifier: e.calendarItemIdentifier) as? EKEvent {
                out.append("calendarItem(withIdentifier: master) -> \(m.title ?? "") start=\(EventTime.utcString(m.startDate)) detached=\(m.isDetached)")
            }
            if let ext = e.calendarItemExternalIdentifier {
                for x in store2.calendarItems(withExternalIdentifier: ext) {
                    out.append("byExternal -> \(x.title ?? "") id=\(x.calendarItemIdentifier) \((x as? EKEvent).map { "detached=\($0.isDetached)" } ?? "")")
                }
            }
            try? store2.removeCalendar(cal2, commit: true)
        } catch { out.append("ERROR \(error)") }
        try? out.joined(separator: "\n").write(to: output, atomically: true, encoding: .utf8)
        return 0
    }
}

extension Date {
    func rounded() -> Date { Date(timeIntervalSince1970: (timeIntervalSince1970 / 3600).rounded() * 3600) }
}
