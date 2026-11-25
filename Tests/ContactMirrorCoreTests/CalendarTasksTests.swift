import XCTest
import EventKit
@testable import ContactMirrorCore

final class GenericMock<R: SyncableRecord>: RecordProvider {
    typealias Record = R
    let displayName: String
    var items: [String: R] = [:]
    var order: [String] = []
    var readOnly: Set<String> = []
    private var next = 0
    init(_ name: String) { displayName = name }

    @discardableResult func add(_ r: R) -> String {
        next += 1
        let id = "\(displayName)-\(next)"
        items[id] = r.normalized(); order.append(id)
        return id
    }
    func item(_ id: String) -> RemoteItem<R> { RemoteItem(id: id, record: items[id]!, readOnly: readOnly.contains(id)) }
    func fetchAll() async throws -> [RemoteItem<R>] { order.filter { items[$0] != nil }.map(item) }
    func create(_ r: R) async throws -> RemoteItem<R> { item(add(r)) }
    func update(_ e: RemoteItem<R>, to r: R) async throws -> RemoteItem<R> {
        XCTAssertFalse(readOnly.contains(e.id), "wrote to a read-only item")
        items[e.id] = r.normalized(); return item(e.id)
    }
    func delete(_ e: RemoteItem<R>) async throws {
        XCTAssertFalse(readOnly.contains(e.id), "deleted a read-only item")
        items[e.id] = nil
    }
    var records: [R] { order.compactMap { items[$0] } }
}

final class CalendarTasksTests: XCTestCase {
    func tmpState() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("st-\(UUID()).json") }

    func event(_ title: String, _ start: String, rrule: String = "") -> EventRecord {
        var e = EventRecord()
        e.title = title
        e.start = start
        e.end = EventTime.utcString(EventTime.date(fromUTC: start)!.addingTimeInterval(3600))
        e.timeZone = "Europe/London"
        e.recurrence = rrule
        return e
    }

    func testRRuleCanonical() {
        XCTAssertEqual(RRule.canonical("RRULE:FREQ=WEEKLY;WKST=SU;BYDAY=FR,MO;INTERVAL=1"), "FREQ=WEEKLY;BYDAY=MO,FR")
        XCTAssertEqual(RRule.canonical("freq=monthly;byday=-1fr;count=5"), "FREQ=MONTHLY;BYDAY=-1FR;COUNT=5")
        XCTAssertEqual(RRule.canonical(""), "")
    }

    func testRRuleEventKitRoundTrip() {
        for s in ["FREQ=WEEKLY;BYDAY=MO,WE,FR", "FREQ=MONTHLY;INTERVAL=2;BYDAY=2TU", "FREQ=YEARLY;BYMONTH=3;BYMONTHDAY=15;COUNT=10",
                  "FREQ=DAILY;UNTIL=20271231T170000Z", "FREQ=MONTHLY;BYMONTHDAY=-1"] {
            let rule = RRule.toEventKit(s, allDay: false)
            XCTAssertNotNil(rule, s)
            XCTAssertEqual(RRule.fromEventKit(rule!, allDay: false), RRule.canonical(s))
        }
        let allDay = RRule.toEventKit("FREQ=WEEKLY;UNTIL=20271231", allDay: true)!
        XCTAssertEqual(RRule.fromEventKit(allDay, allDay: true), "FREQ=WEEKLY;UNTIL=20271231")
    }

    func testExdateParsing() {
        let o = GoogleCalendarProvider.exdates("EXDATE;TZID=America/New_York:20261201T090000,20261208T090000", allDay: false)
        XCTAssertEqual(o.map(\.originalStart), ["2026-12-01T14:00:00Z", "2026-12-08T14:00:00Z"])
        XCTAssertTrue(o.allSatisfy(\.cancelled))
        XCTAssertEqual(GoogleCalendarProvider.exdates("EXDATE;VALUE=DATE:20261201", allDay: true).first?.originalStart, "2026-12-01")
    }

    func testGoogleEventParsing() {
        let p = GoogleCalendarProvider(api: GoogleAPIClient(auth: GoogleAuth()), calendarID: "c", window: .standard())
        let now = EventTime.utcString(Date())
        let master: [String: Any] = [
            "id": "abc", "summary": "Standup", "iCalUID": "abc@google.com",
            "start": ["dateTime": now.replacingOccurrences(of: "Z", with: "+00:00"), "timeZone": "Europe/London"],
            "end": ["dateTime": now, "timeZone": "Europe/London"],
            "recurrence": ["RRULE:FREQ=DAILY;WKST=MO", "EXDATE;VALUE=DATE-TIME:20990101T000000Z"],
            "organizer": ["self": true],
        ]
        let cancelled: [String: Any] = ["id": "abc_x", "recurringEventId": "abc", "status": "cancelled",
                                        "originalStartTime": ["dateTime": now]]
        let invite: [String: Any] = ["id": "inv", "summary": "Lunch", "start": ["date": "2026-12-01"], "end": ["date": "2026-12-02"],
                                     "organizer": ["email": "someone@example.com"]]
        let items = p.items(from: [master, cancelled, invite, ["id": "gone", "status": "cancelled"]])
        XCTAssertEqual(items.count, 2)
        let s = items.first { $0.id == "abc" }!
        XCTAssertEqual(s.record.recurrence, "FREQ=DAILY")
        XCTAssertEqual(s.record.overrides.count, 1, "EXDATE outside the window is dropped, cancellation kept")
        XCTAssertTrue(s.record.overrides[0].cancelled)
        XCTAssertFalse(s.readOnly)
        let i = items.first { $0.id == "inv" }!
        XCTAssertTrue(i.readOnly)
        XCTAssertTrue(i.record.allDay)
        // Write body keeps Google's EXDATE lines
        let body = p.body(s.record, existing: s)
        XCTAssertEqual((body["recurrence"] as? [String])?.count, 2)
    }

    func testEventSyncBothWaysAndConflictKeepsTimeTogether() async throws {
        let g = GenericMock<EventRecord>("g"), c = GenericMock<EventRecord>("c")
        let engine = SyncEngine<EventRecord>(google: g, icloud: c, stateURL: tmpState(), what: "calendar")
        let gid = g.add(event("Dentist", "2026-12-01T09:00:00Z"))
        c.add(event("Gym", "2026-12-02T18:00:00Z", rrule: "FREQ=WEEKLY;BYDAY=WE"))
        try await engine.sync()
        XCTAssertEqual(g.records.count, 2)
        XCTAssertEqual(Set(g.records.map(\.fingerprint)), Set(c.records.map(\.fingerprint)))

        // Google moves the event, iCloud renames it: both edits survive, times stay consistent.
        let cid = c.order.first { c.items[$0]?.title == "Dentist" }!
        g.items[gid]!.start = "2026-12-01T10:00:00Z"; g.items[gid]!.end = "2026-12-01T11:00:00Z"
        c.items[cid]!.title = "Dentist (Dr. Lee)"
        try await engine.sync()
        XCTAssertEqual(g.items[gid]!.title, "Dentist (Dr. Lee)")
        XCTAssertEqual(c.items[cid]!.start, "2026-12-01T10:00:00Z")
        XCTAssertEqual(c.items[cid]!.end, "2026-12-01T11:00:00Z")
    }

    func testReadOnlyInviteIsMirroredButNeverWritten() async throws {
        let g = GenericMock<EventRecord>("g"), c = GenericMock<EventRecord>("c")
        let engine = SyncEngine<EventRecord>(google: g, icloud: c, stateURL: tmpState(), what: "calendar")
        let gid = g.add(event("Team offsite", "2026-12-05T09:00:00Z"))
        g.readOnly.insert(gid)
        try await engine.sync()
        let cid = c.order.first!
        c.items[cid]!.title = "Changed on iPhone"
        try await engine.sync()
        XCTAssertEqual(g.items[gid]!.title, "Team offsite")
        XCTAssertEqual(c.items[cid]!.title, "Team offsite", "iCloud copy is reset to the invitation")
    }

    func testEventDeletionOutsideWindowIsHeld() {
        let w = CalendarWindow.standard()
        XCTAssertTrue(w.isSafeToDelete(event("x", EventTime.utcString(Date().addingTimeInterval(30 * 86400)))))
        XCTAssertFalse(w.isSafeToDelete(event("x", EventTime.utcString(Date().addingTimeInterval(-360 * 86400)))))
        XCTAssertTrue(w.isSafeToDelete(event("x", EventTime.utcString(Date().addingTimeInterval(-900 * 86400)), rrule: "FREQ=WEEKLY")))
    }

    func testTaskSync() async throws {
        let g = GenericMock<TaskRecord>("g"), c = GenericMock<TaskRecord>("c")
        let engine = SyncEngine<TaskRecord>(google: g, icloud: c, stateURL: tmpState(), what: "tasks")
        let gid = g.add(TaskRecord(title: "Buy milk", due: "2026-12-01"))
        c.add(TaskRecord(title: "Buy milk", notes: "2%", due: "2026-12-01"))
        c.add(TaskRecord(title: "Call mum"))
        let r = try await engine.sync()
        XCTAssertEqual(r.matched, 1)
        XCTAssertEqual(g.records.count, 2)
        XCTAssertEqual(g.items[gid]!.notes, "2%")
        let cid = c.order.first!
        c.items[cid]!.completed = true
        try await engine.sync()
        XCTAssertTrue(g.items[gid]!.completed)
    }

    func testCollectionMapping() async throws {
        var createdC: [String] = [], createdG: [String] = []
        let links = try await CollectionMapper.map(
            google: [SyncCollection(id: "g1", title: "me@gmail.com", isDefault: true), SyncCollection(id: "g2", title: "Work", isDefault: false),
                     SyncCollection(id: "g3", title: "Travel", isDefault: false)],
            icloud: [SyncCollection(id: "c1", title: "Home", isDefault: true), SyncCollection(id: "c2", title: "work", isDefault: false),
                     SyncCollection(id: "c3", title: "Family", isDefault: false)],
            saved: [],
            createInGoogle: { createdG.append($0); return "new-g-\($0)" },
            createInICloud: { createdC.append($0); return "new-c-\($0)" },
            log: { _ in })
        XCTAssertEqual(links.count, 4)
        XCTAssertTrue(links.contains { $0.googleID == "g1" && $0.icloudID == "c1" })
        XCTAssertTrue(links.contains { $0.googleID == "g2" && $0.icloudID == "c2" })
        XCTAssertEqual(createdC, ["Travel"])
        XCTAssertEqual(createdG, ["Family"])
    }
}

final class AppleScriptTests: XCTestCase {
    func testGeneratedScriptCompiles() throws {
        var r = ContactRecord()
        r.namePrefix = "Dr"; r.givenName = "Emily \"Em\""; r.familyName = "Harrison"; r.nickname = "Em"
        r.phoneticGivenName = "Em"; r.phoneticMiddleName = "X"; r.organization = "Clinic"; r.jobTitle = "Dentist"
        r.emails = [LabeledValue(label: "work", value: "em@example.com")]
        r.phones = [LabeledValue(label: "iphone", value: "+1 555 0100"), LabeledValue(label: "homefax", value: "1")]
        r.urls = [LabeledValue(label: "homepage", value: "https://x.example")]
        r.relations = [LabeledValue(label: "spouse", value: "Sam")]
        r.addresses = [PostalAddress(label: "home", street: "1 Main\nApt 2", city: "Town", region: "FL", postalCode: "33000", country: "USA", countryCode: "us")]
        r.birthday = DateValue(year: 1990, month: 2, day: 28)
        let script = ContactsAppleScript.updateScript(id: "ABC:ABPerson", record: r)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cm-\(UUID()).applescript")
        try script.write(to: url, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osacompile")
        let out = url.deletingPathExtension().appendingPathExtension("scpt")
        p.arguments = ["-o", out.path, url.path]
        let err = Pipe(); p.standardError = err
        try p.run(); p.waitUntilExit()
        let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(p.terminationStatus, 0, "osacompile failed: \(msg)\n\(script)")
        try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(at: out)
    }
}
