import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct GoogleAPIError: Error, LocalizedError {
    public var status: Int
    public var message: String
    public var errorDescription: String? { "Google API error \(status): \(message)" }
}

/// Google Contacts via the People API.
public final class GoogleContactsProvider: ContactProvider, @unchecked Sendable {
    public let displayName = "Google"
    let auth: GoogleAuth
    /// When false, notes (biographies) are neither read nor written - used when the
    /// Mac side cannot access contact notes, so Google notes are never wiped.
    public var syncNotes: Bool
    private let base = "https://people.googleapis.com/v1/"
    private var lastMutation = Date.distantPast
    private let session: URLSession

    public init(auth: GoogleAuth, syncNotes: Bool) {
        self.auth = auth
        self.syncNotes = syncNotes
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 60
        self.session = URLSession(configuration: cfg)
    }

    var readFields: String {
        var f = "names,nicknames,organizations,emailAddresses,phoneNumbers,addresses,urls,birthdays,events,relations,imClients,photos,metadata"
        if syncNotes { f += ",biographies" }
        return f
    }

    var writeFields: String {
        var f = "names,nicknames,organizations,emailAddresses,phoneNumbers,addresses,urls,birthdays,events,relations,imClients"
        if syncNotes { f += ",biographies" }
        return f
    }

    // MARK: ContactProvider

    public func fetchAll() async throws -> [RemoteContact] {
        var out: [RemoteContact] = []
        var pageToken: String?
        repeat {
            var q = [
                "personFields": readFields,
                "pageSize": "1000",
                "sources": "READ_SOURCE_TYPE_CONTACT",
            ]
            if let pageToken { q["pageToken"] = pageToken }
            let json = try await request("GET", "people/me/connections", query: q)
            for p in json["connections"] as? [[String: Any]] ?? [] {
                if let c = Self.remote(from: p, includeNotes: syncNotes) { out.append(c) }
            }
            pageToken = json["nextPageToken"] as? String
        } while pageToken != nil
        return out
    }

    public func create(_ record: ContactRecord) async throws -> RemoteContact {
        // Not retried on network/server errors: the contact may already exist and a retry would duplicate it.
        let json = try await request("POST", "people:createContact", query: ["personFields": readFields],
                                     body: Self.personBody(record, includeNotes: syncNotes), mutation: true,
                                     idempotent: false)
        guard let c = Self.remote(from: json, includeNotes: syncNotes) else { throw GoogleAPIError(status: 0, message: "bad create response") }
        return c
    }

    public func update(_ existing: RemoteContact, to record: ContactRecord) async throws -> RemoteContact {
        var body = Self.updateBody(record, existing: existing, includeNotes: syncNotes)
        do {
            let json = try await request("PATCH", "\(existing.id):updateContact",
                                         query: ["updatePersonFields": writeFields, "personFields": readFields],
                                         body: body, mutation: true)
            guard let c = Self.remote(from: json, includeNotes: syncNotes) else { throw GoogleAPIError(status: 0, message: "bad update response") }
            return c
        } catch let e as GoogleAPIError where e.status == 400 && e.message.lowercased().contains("etag") {
            // Changed again since we listed it: fetch the fresh etag and retry once.
            let fresh = try await request("GET", existing.id, query: ["personFields": "metadata", "sources": "READ_SOURCE_TYPE_CONTACT"])
            body["etag"] = fresh["etag"] as? String ?? ""
            if let src = Self.contactSource(fresh) { body["metadata"] = ["sources": [src]] }
            let json = try await request("PATCH", "\(existing.id):updateContact",
                                         query: ["updatePersonFields": writeFields, "personFields": readFields],
                                         body: body, mutation: true)
            guard let c = Self.remote(from: json, includeNotes: syncNotes) else { throw GoogleAPIError(status: 0, message: "bad update response") }
            return c
        }
    }

    public func delete(_ existing: RemoteContact) async throws {
        do {
            _ = try await request("DELETE", "\(existing.id):deleteContact", mutation: true)
        } catch let e as GoogleAPIError where e.status == 404 {
            return // already gone
        }
    }

    public func photoData(for contact: RemoteContact) async throws -> Data? {
        guard !contact.photoKey.isEmpty else { return nil }
        let large = contact.photoKey.replacingOccurrences(of: "=s\\d+(-[a-z0-9-]+)?$", with: "=s1024",
                                                          options: .regularExpression)
        let (data, resp) = try await session.data(from: URL(string: large) ?? URL(string: contact.photoKey)!)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw GoogleAPIError(status: (resp as? HTTPURLResponse)?.statusCode ?? 0, message: "photo download failed")
        }
        return data
    }

    public func setPhoto(_ data: Data?, for contact: RemoteContact) async throws -> RemoteContact {
        let json: [String: Any]
        if let data {
            guard let jpeg = Self.jpegData(data) else { throw GoogleAPIError(status: 0, message: "unsupported image") }
            json = try await request("PATCH", "\(contact.id):updateContactPhoto",
                                     body: ["photoBytes": jpeg.base64EncodedString(), "personFields": readFields],
                                     mutation: true)
        } else {
            json = try await request("DELETE", "\(contact.id):deleteContactPhoto",
                                     query: ["personFields": readFields], mutation: true)
        }
        guard let person = json["person"] as? [String: Any],
              let c = Self.remote(from: person, includeNotes: syncNotes) else { return contact }
        return c
    }

    // MARK: HTTP

    func request(_ method: String, _ path: String, query: [String: String] = [:],
                 body: [String: Any]? = nil, mutation: Bool = false,
                 idempotent: Bool = true) async throws -> [String: Any] {
        var comps = URLComponents(string: base + path)!
        if !query.isEmpty { comps.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var attempt = 0
        var forcedRefresh = false
        while true {
            if mutation {
                // People API asks for sequential, paced writes per user.
                let wait = 0.35 - Date().timeIntervalSince(lastMutation)
                if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1e9)) }
                lastMutation = Date()
            }
            var req = URLRequest(url: comps.url!)
            req.httpMethod = method
            let token = try await auth.validAccessToken(forceRefresh: forcedRefresh)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            if let body {
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = try JSONSerialization.data(withJSONObject: body)
            }
            let (data, resp): (Data, URLResponse)
            do {
                (data, resp) = try await session.data(for: req)
            } catch {
                attempt += 1
                if attempt > 4 || !idempotent { throw error }
                try await Task.sleep(nanoseconds: UInt64(pow(2.0, Double(attempt)) * 1e9))
                continue
            }
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            if (200..<300).contains(status) { return json }
            if status == 401 && !forcedRefresh { forcedRefresh = true; continue }
            if (status == 429 || (idempotent && [500, 502, 503, 504].contains(status))) && attempt < 6 {
                attempt += 1
                var delay = pow(2.0, Double(attempt))
                if let ra = (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After"), let s = Double(ra) { delay = max(delay, s) }
                try await Task.sleep(nanoseconds: UInt64(min(delay, 90) * 1e9))
                continue
            }
            let msg = ((json["error"] as? [String: Any])?["message"] as? String) ?? String(data: data, encoding: .utf8) ?? ""
            throw GoogleAPIError(status: status, message: msg)
        }
    }

    // MARK: Mapping

    static func remote(from p: [String: Any], includeNotes: Bool) -> RemoteContact? {
        guard let rn = p["resourceName"] as? String else { return nil }
        var photoKey = ""
        if let photos = p["photos"] as? [[String: Any]],
           let photo = photos.first(where: { ($0["default"] as? Bool) != true }),
           let url = photo["url"] as? String {
            photoKey = url
        }
        var meta = ["etag": p["etag"] as? String ?? ""]
        if let src = contactSource(p) { meta["source"] = jsonString(src) }
        // Keep fields ContactMirror doesn't model so updates don't drop them.
        meta["organizations"] = jsonString(p["organizations"] ?? [])
        meta["nicknames"] = jsonString(p["nicknames"] ?? [])
        return RemoteContact(id: rn, record: record(from: p, includeNotes: includeNotes), photoKey: photoKey, meta: meta)
    }

    static func contactSource(_ p: [String: Any]) -> [String: Any]? {
        let sources = (p["metadata"] as? [String: Any])?["sources"] as? [[String: Any]] ?? []
        guard let s = sources.first(where: { ($0["type"] as? String) == "CONTACT" }) else { return nil }
        var out: [String: Any] = ["type": "CONTACT"]
        if let id = s["id"] { out["id"] = id }
        if let etag = s["etag"] { out["etag"] = etag }
        return out
    }

    static func jsonString(_ obj: Any) -> String {
        guard JSONSerialization.isValidJSONObject(obj),
              let d = try? JSONSerialization.data(withJSONObject: obj) else { return "[]" }
        return String(data: d, encoding: .utf8) ?? "[]"
    }

    static func jsonArray(_ s: String?) -> [[String: Any]] {
        guard let s, let d = s.data(using: .utf8) else { return [] }
        let arr = (try? JSONSerialization.jsonObject(with: d)) as? [[String: Any]] ?? []
        return arr.map { var x = $0; x["metadata"] = nil; return x }
    }

    /// Body for updateContact: the synced fields, plus the etag/source Google requires, while
    /// preserving extra organizations/nicknames and organization attributes we don't model.
    static func updateBody(_ record: ContactRecord, existing: RemoteContact, includeNotes: Bool) -> [String: Any] {
        let r = record.normalized()
        var body = personBody(r, includeNotes: includeNotes)
        body["etag"] = existing.meta["etag"] ?? ""
        if let src = existing.meta["source"], let d = src.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            body["metadata"] = ["sources": [obj]]
        }
        let orgs = jsonArray(existing.meta["organizations"])
        var first = orgs.first ?? [:]
        for (k, v) in [("name", r.organization), ("department", r.department), ("title", r.jobTitle)] {
            first[k] = v.isEmpty ? nil : v
        }
        let hasOrg = !(r.organization.isEmpty && r.department.isEmpty && r.jobTitle.isEmpty)
        body["organizations"] = (hasOrg ? [first] : []) + Array(orgs.dropFirst())
        let nicks = jsonArray(existing.meta["nicknames"])
        body["nicknames"] = (r.nickname.isEmpty ? [] : [["value": r.nickname]]) + Array(nicks.dropFirst())
        return body
    }

    static func record(from p: [String: Any], includeNotes: Bool) -> ContactRecord {
        var r = ContactRecord()
        func list(_ k: String) -> [[String: Any]] { p[k] as? [[String: Any]] ?? [] }
        func s(_ d: [String: Any], _ k: String) -> String { d[k] as? String ?? "" }
        func label(_ d: [String: Any]) -> String { s(d, "type") }

        if let n = list("names").first {
            r.namePrefix = s(n, "honorificPrefix"); r.givenName = s(n, "givenName")
            r.middleName = s(n, "middleName"); r.familyName = s(n, "familyName")
            r.nameSuffix = s(n, "honorificSuffix")
            r.phoneticGivenName = s(n, "phoneticGivenName"); r.phoneticMiddleName = s(n, "phoneticMiddleName")
            r.phoneticFamilyName = s(n, "phoneticFamilyName")
        }
        r.nickname = list("nicknames").first.map { s($0, "value") } ?? ""
        if let o = list("organizations").first {
            r.organization = s(o, "name"); r.department = s(o, "department"); r.jobTitle = s(o, "title")
        }
        r.emails = list("emailAddresses").map { LabeledValue(label: label($0), value: s($0, "value")) }
        r.phones = list("phoneNumbers").map { LabeledValue(label: label($0), value: s($0, "value")) }
        r.urls = list("urls").map { LabeledValue(label: label($0), value: s($0, "value")) }
        r.relations = list("relations").map { LabeledValue(label: label($0), value: s($0, "person")) }
        r.instantMessages = list("imClients").map { LabeledValue(label: s($0, "protocol"), value: s($0, "username")) }
        r.addresses = list("addresses").map { a in
            let street = [s(a, "streetAddress"), s(a, "extendedAddress"), s(a, "poBox")]
                .filter { !$0.isEmpty }.joined(separator: "\n")
            return PostalAddress(label: label(a), street: street, city: s(a, "city"), region: s(a, "region"),
                                 postalCode: s(a, "postalCode"), country: s(a, "country"),
                                 countryCode: s(a, "countryCode"))
        }
        func date(_ d: [String: Any]?) -> (Int?, Int, Int)? {
            guard let d, let m = d["month"] as? Int, let day = d["day"] as? Int, m > 0, day > 0 else { return nil }
            let y = d["year"] as? Int
            return (y == 0 ? nil : y, m, day)
        }
        if let b = list("birthdays").lazy.compactMap({ date($0["date"] as? [String: Any]) }).first {
            r.birthday = DateValue(year: b.0, month: b.1, day: b.2)
        }
        r.dates = list("events").compactMap { e in
            date(e["date"] as? [String: Any]).map { DateValue(label: label(e), year: $0.0, month: $0.1, day: $0.2) }
        }
        if includeNotes { r.note = list("biographies").first.map { s($0, "value") } ?? "" }
        return r.normalized()
    }

    static let googleTypeNames: [String: String] = [
        "homefax": "homeFax", "workfax": "workFax", "otherfax": "otherFax", "homepage": "homePage",
        "workmobile": "workMobile", "workpager": "workPager", "googlevoice": "googleVoice",
        "domesticpartner": "domesticPartner", "referredby": "referredBy", "iphone": "iPhone",
        "googletalk": "googleTalk", "netmeeting": "netMeeting", "appinstallpage": "appInstallPage",
    ]

    static func googleType(_ canonical: String) -> String { googleTypeNames[canonical] ?? canonical }

    static func personBody(_ record: ContactRecord, includeNotes: Bool) -> [String: Any] {
        let r = record.normalized()
        var p: [String: Any] = [:]
        func typed(_ d: [String: Any], _ label: String) -> [String: Any] {
            var d = d
            if !label.isEmpty { d["type"] = googleType(label) }
            return d
        }
        let name: [String: Any] = [
            "honorificPrefix": r.namePrefix, "givenName": r.givenName, "middleName": r.middleName,
            "familyName": r.familyName, "honorificSuffix": r.nameSuffix,
            "phoneticGivenName": r.phoneticGivenName, "phoneticMiddleName": r.phoneticMiddleName,
            "phoneticFamilyName": r.phoneticFamilyName,
        ].filter { !($0.value as! String).isEmpty }
        p["names"] = name.isEmpty ? [] : [name]
        p["nicknames"] = r.nickname.isEmpty ? [] : [["value": r.nickname]]
        let orgFields: [String: String] = ["name": r.organization, "department": r.department, "title": r.jobTitle]
        let org = orgFields.filter { !$0.value.isEmpty }
        p["organizations"] = org.isEmpty ? [] : [org]
        p["emailAddresses"] = r.emails.map { typed(["value": $0.value], $0.label) }
        p["phoneNumbers"] = r.phones.map { typed(["value": $0.value], $0.label) }
        p["urls"] = r.urls.map { typed(["value": $0.value], $0.label) }
        p["relations"] = r.relations.map { typed(["person": $0.value], $0.label) }
        p["imClients"] = r.instantMessages.map { im -> [String: Any] in
            var d: [String: Any] = ["username": im.value]
            if !im.label.isEmpty { d["protocol"] = googleType(im.label) }
            return d
        }
        p["addresses"] = r.addresses.map { a -> [String: Any] in
            let fields: [String: String] = ["streetAddress": a.street, "city": a.city, "region": a.region,
                                            "postalCode": a.postalCode, "country": a.country,
                                            "countryCode": a.countryCode.uppercased()]
            return typed(fields.filter { !$0.value.isEmpty }, a.label)
        }
        func date(_ d: DateValue) -> [String: Any] {
            var o: [String: Any] = ["month": d.month, "day": d.day]
            if let y = d.year { o["year"] = y }
            return o
        }
        p["birthdays"] = r.birthday.map { [["date": date($0)]] } ?? []
        p["events"] = r.dates.map { typed(["date": date($0)], $0.label) }
        if includeNotes {
            p["biographies"] = r.note.isEmpty ? [] : [["value": r.note, "contentType": "TEXT_PLAIN"]]
        }
        return p
    }

    static func jpegData(_ data: Data) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let out = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dst, img, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(dst) else { return nil }
        return out as Data
    }
}
