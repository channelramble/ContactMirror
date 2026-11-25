import XCTest
@testable import ContactMirrorCore

final class MockProvider: ContactProvider {
    let displayName: String
    var contacts: [String: (ContactRecord, Data?)] = [:]
    var order: [String] = []
    var writes = 0
    private var next = 0

    init(_ name: String) { displayName = name }

    func add(_ r: ContactRecord, photo: Data? = nil) -> String {
        next += 1
        let id = "\(displayName)-\(next)"
        contacts[id] = (r.normalized(), photo)
        order.append(id)
        return id
    }

    func remote(_ id: String) -> RemoteContact {
        let (r, p) = contacts[id]!
        return RemoteContact(id: id, record: r, photoKey: p.map { "\(displayName)-photo-\($0.hashValue)" } ?? "")
    }

    func fetchAll() async throws -> [RemoteContact] { order.filter { contacts[$0] != nil }.map(remote) }
    func create(_ record: ContactRecord) async throws -> RemoteContact { writes += 1; return remote(add(record)) }
    func update(_ existing: RemoteContact, to record: ContactRecord) async throws -> RemoteContact {
        writes += 1
        contacts[existing.id]!.0 = record.normalized()
        return remote(existing.id)
    }
    func delete(_ existing: RemoteContact) async throws { writes += 1; contacts[existing.id] = nil }
    func photoData(for contact: RemoteContact) async throws -> Data? { contacts[contact.id]?.1 }
    func setPhoto(_ data: Data?, for contact: RemoteContact) async throws -> RemoteContact {
        writes += 1
        contacts[contact.id]!.1 = data
        return remote(contact.id)
    }

    var records: [ContactRecord] { order.compactMap { contacts[$0]?.0 } }
}

func person(_ given: String, _ family: String, email: String? = nil, phone: String? = nil) -> ContactRecord {
    var r = ContactRecord()
    r.givenName = given
    r.familyName = family
    if let email { r.emails = [LabeledValue(label: "home", value: email)] }
    if let phone { r.phones = [LabeledValue(label: "mobile", value: phone)] }
    return r
}

final class SyncEngineTests: XCTestCase {
    var g: MockProvider!
    var c: MockProvider!
    var engine: SyncEngine!
    var stateURL: URL!

    override func setUp() {
        g = MockProvider("g")
        c = MockProvider("c")
        stateURL = FileManager.default.temporaryDirectory.appendingPathComponent("state-\(UUID().uuidString).json")
        engine = SyncEngine(google: g, icloud: c, stateURL: stateURL)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: stateURL) }

    func assertIdentical(file: StaticString = #filePath, line: UInt = #line) {
        let a = g.records.map(\.fingerprint).sorted()
        let b = c.records.map(\.fingerprint).sorted()
        XCTAssertEqual(a, b, "sides differ", file: file, line: line)
    }

    func testInitialSyncCopiesBothWays() async throws {
        _ = g.add(person("Ada", "Lovelace", email: "ada@example.com"))
        _ = c.add(person("Alan", "Turing", phone: "+44 20 1234 5678"))
        let r = try await engine.sync()
        XCTAssertEqual(r.createdInGoogle, 1)
        XCTAssertEqual(r.createdInICloud, 1)
        XCTAssertEqual(g.records.count, 2)
        assertIdentical()
        // Second run is a no-op
        g.writes = 0; c.writes = 0
        let r2 = try await engine.sync()
        XCTAssertEqual(r2.changeCount, 0)
        XCTAssertEqual(g.writes + c.writes, 0)
    }

    func testInitialSyncMatchesAndMergesDuplicates() async throws {
        var a = person("Grace", "Hopper", email: "grace@navy.mil")
        a.jobTitle = "Rear Admiral"
        _ = g.add(a)
        var b = person("Grace", "Hopper", email: "GRACE@navy.mil", phone: "555-0100")
        b.organization = "US Navy"
        _ = c.add(b)
        let r = try await engine.sync()
        XCTAssertEqual(r.matched, 1)
        XCTAssertEqual(r.createdInGoogle + r.createdInICloud, 0)
        XCTAssertEqual(g.records.count, 1)
        XCTAssertEqual(c.records.count, 1)
        let merged = g.records[0]
        XCTAssertEqual(merged.jobTitle, "Rear Admiral")
        XCTAssertEqual(merged.organization, "US Navy")
        XCTAssertEqual(merged.phones.count, 1)
        XCTAssertEqual(merged.emails.count, 1)
        assertIdentical()
    }

    func testEditPropagatesFromEitherSide() async throws {
        let gid = g.add(person("Katherine", "Johnson", email: "kj@nasa.gov"))
        try await engine.sync()
        g.contacts[gid]!.0.jobTitle = "Mathematician"
        try await engine.sync()
        XCTAssertEqual(c.records.first?.jobTitle, "Mathematician")
        let cid = c.order.first!
        c.contacts[cid]!.0.phones = [LabeledValue(label: "work", value: "555-1234")]
        try await engine.sync()
        XCTAssertEqual(g.records.first?.phones.first?.value, "555-1234")
        assertIdentical()
    }

    func testConflictMergesFieldsAndPrefersGoogleOnSameField() async throws {
        let gid = g.add(person("Hedy", "Lamarr"))
        try await engine.sync()
        let cid = c.order.first!
        g.contacts[gid]!.0.jobTitle = "Inventor"
        g.contacts[gid]!.0.nickname = "G-nick"
        c.contacts[cid]!.0.organization = "Hollywood"
        c.contacts[cid]!.0.nickname = "C-nick"
        try await engine.sync()
        let rec = g.records[0]
        XCTAssertEqual(rec.jobTitle, "Inventor")
        XCTAssertEqual(rec.organization, "Hollywood")
        XCTAssertEqual(rec.nickname, "G-nick")
        assertIdentical()
    }

    func testDeletionPropagates() async throws {
        let gid = g.add(person("Joan", "Clarke"))
        _ = g.add(person("Mary", "Somerville"))
        try await engine.sync()
        // Simulate the grace period having passed
        var st = SyncState.load(from: stateURL)
        for i in st.pairs.indices { st.pairs[i].lastSynced = Date().addingTimeInterval(-3600) }
        try st.save(to: stateURL)
        g.contacts[gid] = nil
        let r = try await engine.sync()
        XCTAssertEqual(r.deletedFromICloud, 1)
        XCTAssertEqual(c.records.count, 1)
        assertIdentical()
    }

    func testRecentlyWrittenContactIsNotDeleted() async throws {
        let gid = g.add(person("Joan", "Clarke"))
        try await engine.sync()
        g.contacts[gid] = nil // e.g. Google not listing it yet
        let r = try await engine.sync()
        XCTAssertEqual(r.deletedFromICloud, 0)
        XCTAssertEqual(c.records.count, 1)
    }

    func testMassDeletionIsBlocked() async throws {
        for i in 0..<30 { _ = g.add(person("P\(i)", "X", email: "p\(i)@x.com")) }
        try await engine.sync()
        var st = SyncState.load(from: stateURL)
        for i in st.pairs.indices { st.pairs[i].lastSynced = Date().addingTimeInterval(-3600) }
        try st.save(to: stateURL)
        g.contacts.removeAll()
        do {
            try await engine.sync()
            XCTFail("expected mass deletion guard")
        } catch SyncError.massDeletion(let dg, let dc) {
            XCTAssertEqual(dg, 0)
            XCTAssertEqual(dc, 30)
        }
        XCTAssertEqual(c.records.count, 30)
        var opts = SyncOptions()
        opts.allowMassDeletion = true
        try await engine.sync(options: opts)
        XCTAssertEqual(c.records.count, 0)
    }

    func testEditAfterDeleteOnOtherSideRecreates() async throws {
        let gid = g.add(person("Rosalind", "Franklin"))
        try await engine.sync()
        var st = SyncState.load(from: stateURL)
        for i in st.pairs.indices { st.pairs[i].lastSynced = Date().addingTimeInterval(-3600) }
        try st.save(to: stateURL)
        let cid = c.order.first!
        c.contacts[cid]!.0.jobTitle = "Chemist"
        g.contacts[gid] = nil
        try await engine.sync()
        XCTAssertEqual(g.records.count, 1)
        XCTAssertEqual(g.records.first?.jobTitle, "Chemist")
        assertIdentical()
    }

    func testPhotosCopy() async throws {
        let gid = g.add(person("Marie", "Curie"), photo: Data([1, 2, 3]))
        try await engine.sync()
        let cid = c.order.first!
        XCTAssertEqual(c.contacts[cid]!.1, Data([1, 2, 3]))
        c.contacts[cid]!.1 = Data([9, 9])
        try await engine.sync()
        XCTAssertEqual(g.contacts[gid]!.1, Data([9, 9]))
        c.contacts[cid]!.1 = nil
        try await engine.sync()
        XCTAssertNil(g.contacts[gid]!.1)
    }

    func testBackupCalledBeforeChanges() async throws {
        var called = 0
        engine.backup = { _, _ in called += 1 }
        _ = g.add(person("A", "B"))
        try await engine.sync()
        XCTAssertEqual(called, 1)
        try await engine.sync()
        XCTAssertEqual(called, 1, "no backup when nothing changes")
    }

    func testLabelsCanonical() {
        XCTAssertEqual(Labels.canonical("_$!<Mobile>!$_"), "mobile")
        XCTAssertEqual(Labels.canonical("homeFax"), "homefax")
        XCTAssertEqual(Labels.canonical("Gym"), "Gym")
    }

    func testVersionCompare() {
        XCTAssertTrue(Updater.isNewer("v1.2.0", than: "1.1.9"))
        XCTAssertFalse(Updater.isNewer("1.0", than: "1.0.0"))
        XCTAssertTrue(Updater.isNewer("2", than: "1.99.99"))
    }

    func testGoogleRoundTrip() {
        var r = person("Ada", "Lovelace", email: "ada@example.com", phone: "123")
        r.addresses = [PostalAddress(label: "home", street: "1 Main St", city: "London", countryCode: "gb")]
        r.birthday = DateValue(year: nil, month: 12, day: 10)
        r.dates = [DateValue(label: "anniversary", year: 1835, month: 7, day: 8)]
        r.urls = [LabeledValue(label: "homepage", value: "https://ada.example")]
        r.note = "Hello"
        var body = GoogleContactsProvider.personBody(r, includeNotes: true)
        body["resourceName"] = "people/c1"
        let back = GoogleContactsProvider.record(from: body, includeNotes: true)
        XCTAssertEqual(back, r.normalized())
    }

    func testAmbiguousSharedPhoneIsNotMerged() async throws {
        _ = g.add(person("Ann", "Office", phone: "555-123-4567"))
        _ = c.add(person("Bob", "Office", phone: "555-123-4567"))
        _ = c.add(person("Cat", "Office", phone: "555-123-4567"))
        let r = try await engine.sync()
        XCTAssertEqual(r.matched, 0)
        XCTAssertEqual(g.records.count, 3)
        XCTAssertEqual(c.records.count, 3)
        assertIdentical()
    }

    func testFailedItemKeepsOldLinkAndRetries() async throws {
        let gid = g.add(person("Ida", "Rhodes"))
        try await engine.sync()
        g.contacts[gid]!.0.jobTitle = "Engineer"
        let failing = FailingProvider(wrapping: c)
        let e2 = SyncEngine(google: g, icloud: failing, stateURL: stateURL)
        let r = try await e2.sync()
        XCTAssertEqual(r.errors.count, 1)
        try await engine.sync()
        XCTAssertEqual(c.records.first?.jobTitle, "Engineer")
    }

    func testUpdateBodyPreservesExtraOrganizations() {
        var r = person("Ada", "Lovelace")
        r.organization = "Analytical Engines"
        let existing = RemoteContact(id: "people/c1", record: r, meta: [
            "etag": "E", "source": "{\"type\":\"CONTACT\",\"id\":\"abc\",\"etag\":\"S\"}",
            "organizations": "[{\"name\":\"Old\",\"type\":\"work\"},{\"name\":\"Second\"}]",
        ])
        let body = GoogleContactsProvider.updateBody(r, existing: existing, includeNotes: false)
        let orgs = body["organizations"] as! [[String: Any]]
        XCTAssertEqual(orgs.count, 2)
        XCTAssertEqual(orgs[0]["name"] as? String, "Analytical Engines")
        XCTAssertEqual(orgs[0]["type"] as? String, "work")
        XCTAssertEqual(orgs[1]["name"] as? String, "Second")
        XCTAssertEqual(body["etag"] as? String, "E")
        XCTAssertNotNil(body["metadata"])
    }
}

final class FailingProvider: ContactProvider {
    let inner: MockProvider
    init(wrapping p: MockProvider) { inner = p }
    var displayName: String { inner.displayName }
    func fetchAll() async throws -> [RemoteContact] { try await inner.fetchAll() }
    func create(_ record: ContactRecord) async throws -> RemoteContact { throw URLError(.timedOut) }
    func update(_ existing: RemoteContact, to record: ContactRecord) async throws -> RemoteContact { throw URLError(.timedOut) }
    func delete(_ existing: RemoteContact) async throws { throw URLError(.timedOut) }
    func photoData(for contact: RemoteContact) async throws -> Data? { nil }
    func setPhoto(_ data: Data?, for contact: RemoteContact) async throws -> RemoteContact { throw URLError(.timedOut) }
}
