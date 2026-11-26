import XCTest
@testable import ContactMirrorCore

/// A provider that can't store some fields (like the AppleScript fallback can't store dates).
final class LossyMock: RecordProvider {
    typealias Record = ContactRecord
    let displayName = "lossy"
    var items: [String: ContactRecord] = [:]
    var order: [String] = []
    private var n = 0
    func strip(_ r: ContactRecord) -> ContactRecord { var r = r.normalized(); r.dates = []; return r }
    @discardableResult func add(_ r: ContactRecord) -> String { n += 1; let id = "l\(n)"; items[id] = strip(r); order.append(id); return id }
    func fetchAll() async throws -> [RemoteItem<ContactRecord>] { order.compactMap { id in items[id].map { RemoteItem(id: id, record: $0) } } }
    func create(_ r: ContactRecord) async throws -> RemoteItem<ContactRecord> { let id = add(r); return RemoteItem(id: id, record: items[id]!) }
    func update(_ e: RemoteItem<ContactRecord>, to r: ContactRecord) async throws -> RemoteItem<ContactRecord> {
        items[e.id] = strip(r); return RemoteItem(id: e.id, record: items[e.id]!)
    }
    func delete(_ e: RemoteItem<ContactRecord>) async throws { items[e.id] = nil }
}

final class RegressionTests: XCTestCase {
    func tmp() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("rg-\(UUID()).json") }

    func testFieldOneSideCantStoreIsNeverDeletedFromTheOther() async throws {
        let g = GenericMock<ContactRecord>("g"), c = LossyMock()
        let e = SyncEngine<ContactRecord>(google: g, icloud: c, stateURL: tmp())
        var r = ContactRecord(); r.givenName = "Ann"; r.familyName = "Lee"
        r.dates = [DateValue(label: "anniversary", year: 2010, month: 5, day: 1)]
        let gid = g.add(r)
        try await e.sync()
        // Edit something else in iCloud: Google must keep the anniversary.
        let cid = c.order[0]
        c.items[cid]!.jobTitle = "Chef"
        try await e.sync()
        XCTAssertEqual(g.items[gid]!.jobTitle, "Chef")
        XCTAssertEqual(g.items[gid]!.dates.count, 1, "anniversary was deleted from Google")
        let again = try await e.sync()
        XCTAssertEqual(again.changeCount, 0)
    }

    func testIdenticalItemsWithoutUniqueKeysArePairedNotDuplicated() async throws {
        let g = GenericMock<ContactRecord>("g"), c = GenericMock<ContactRecord>("c")
        let e = SyncEngine<ContactRecord>(google: g, icloud: c, stateURL: tmp())
        var j = ContactRecord(); j.givenName = "John"; j.familyName = "Smith"
        g.add(j); g.add(j); c.add(j); c.add(j)
        try await e.sync()
        XCTAssertEqual(g.records.count, 2)
        XCTAssertEqual(c.records.count, 2)
    }

    func testSideSuddenlyEmptyPausesEvenForSmallLists() async throws {
        let g = GenericMock<TaskRecord>("g"), c = GenericMock<TaskRecord>("c")
        let st = tmp()
        let e = SyncEngine<TaskRecord>(google: g, icloud: c, stateURL: st, what: "tasks")
        for i in 0..<4 { g.add(TaskRecord(title: "t\(i)")) }
        try await e.sync()
        var s = SyncState<TaskRecord>.load(from: st)
        for i in s.pairs.indices { s.pairs[i].lastSynced = .distantPast }
        try s.save(to: st)
        c.items.removeAll()
        do { try await e.sync(); XCTFail("expected pause") } catch SyncError.massDeletion {}
        XCTAssertEqual(g.records.count, 4)
        var opts = SyncOptions(); opts.allowMassDeletionFor = ["tasks"]
        try await e.sync(options: opts)
        XCTAssertEqual(g.records.count, 0)
    }

    func testReadOnlyICloudItemIsNeverWrittenWhenMatching() async throws {
        let g = GenericMock<EventRecord>("g"), c = GenericMock<EventRecord>("c")
        let e = SyncEngine<EventRecord>(google: g, icloud: c, stateURL: tmp())
        var ev = EventRecord(); ev.title = "Invite"; ev.start = "2026-12-01T10:00:00Z"; ev.end = "2026-12-01T11:00:00Z"
        var gv = ev; gv.notes = "google notes"
        g.add(gv)
        let cid = c.add(ev); c.readOnly.insert(cid)
        try await e.sync() // GenericMock asserts if the read-only item is written
        XCTAssertEqual(g.records.first?.notes, "", "Google copy follows the read-only invitation")
    }

    func testOldCompletedTaskDoesNotCompleteNewOpenOne() async throws {
        let g = GenericMock<TaskRecord>("g"), c = GenericMock<TaskRecord>("c")
        let e = SyncEngine<TaskRecord>(google: g, icloud: c, stateURL: tmp())
        g.add(TaskRecord(title: "Call mom", due: "2025-01-01", completed: true))
        let cid = c.add(TaskRecord(title: "Call mom", due: "2026-12-01"))
        try await e.sync()
        XCTAssertFalse(c.items[cid]!.completed)
        XCTAssertEqual(c.records.count, 2)
    }

    func testCorruptStateIsNotSilentlyReset() async throws {
        let g = GenericMock<TaskRecord>("g"), c = GenericMock<TaskRecord>("c")
        let st = tmp()
        try Data("{not json".utf8).write(to: st)
        let e = SyncEngine<TaskRecord>(google: g, icloud: c, stateURL: st)
        g.add(TaskRecord(title: "x"))
        do { try await e.sync(); XCTFail("expected error") } catch is SyncStateError {}
        XCTAssertEqual(c.records.count, 0)
    }

    func testCollectionDeletedOnOneSideIsNotRecreated() async throws {
        var created: [String] = []
        let saved = [CollectionLink(googleID: "g1", icloudID: "c1", title: "Work")]
        let links = try await CollectionMapper.map(
            google: [SyncCollection(id: "g1", title: "Work", isDefault: false), SyncCollection(id: "g2", title: "College ", isDefault: false)],
            icloud: [SyncCollection(id: "c2", title: "college", isDefault: false)],
            saved: saved,
            createInGoogle: { created.append("G:" + $0); return "x" }, createInICloud: { created.append("C:" + $0); return "y" },
            log: { _ in })
        XCTAssertEqual(created, [], "nothing recreated, trailing space matched")
        XCTAssertTrue(links.contains { $0.googleID == "g1" && $0.icloudID == "c1" })
        XCTAssertTrue(links.contains { $0.googleID == "g2" && $0.icloudID == "c2" })
    }

    func testTextOnlyGoogleBirthdayIsKept() {
        var r = ContactRecord(); r.givenName = "A"
        let person: [String: Any] = ["resourceName": "people/1", "etag": "e", "names": [["givenName": "A"]],
                                     "birthdays": [["text": "sometime in May"]]]
        let item = GoogleContactsProvider.remote(from: person, includeNotes: false)!
        let body = GoogleContactsProvider.updateBody(r, existing: item, includeNotes: false)
        XCTAssertEqual((body["birthdays"] as? [[String: Any]])?.first?["text"] as? String, "sometime in May")
    }
}

final class StubbornMock: RecordProvider {
    typealias Record = ContactRecord
    let displayName = "stubborn"
    var inner = GenericMock<ContactRecord>("c")
    var failing: Set<String> = []
    func fetchAll() async throws -> [RemoteItem<ContactRecord>] { try await inner.fetchAll() }
    func create(_ r: ContactRecord) async throws -> RemoteItem<ContactRecord> { try await inner.create(r) }
    func update(_ e: RemoteItem<ContactRecord>, to r: ContactRecord) async throws -> RemoteItem<ContactRecord> {
        if failing.contains(e.id) { throw NSError(domain: "x", code: 134092) }
        return try await inner.update(e, to: r)
    }
    func delete(_ e: RemoteItem<ContactRecord>) async throws { try await inner.delete(e) }
}

final class ErrorIsolationTests: XCTestCase {
    func testManyFailingItemsDoNotBlockOthers() async throws {
        let g = GenericMock<ContactRecord>("g"), c = StubbornMock()
        let e = SyncEngine<ContactRecord>(google: g, icloud: c, stateURL: FileManager.default.temporaryDirectory.appendingPathComponent("ei-\(UUID()).json"))
        for i in 0..<20 { var r = ContactRecord(); r.givenName = "P\(i)"; r.emails = [LabeledValue(label: "home", value: "p\(i)@x.com")]; g.add(r) }
        try await e.sync()
        c.failing = Set(c.inner.order)
        for id in g.order { g.items[id]!.jobTitle = "changed" }
        var newOne = ContactRecord(); newOne.givenName = "Newbie"; g.add(newOne)
        let r = try await e.sync()
        XCTAssertEqual(r.errors.count, 20)
        XCTAssertTrue(c.inner.records.contains { $0.givenName == "Newbie" }, "new contact was blocked by failing ones")
    }
}
