import Foundation
import CryptoKit

/// A single labelled value such as an email address, phone number or URL.
public struct LabeledValue: Codable, Hashable, Sendable {
    public var label: String
    public var value: String
    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }
}

public struct PostalAddress: Codable, Hashable, Sendable {
    public var label: String = ""
    public var street: String = ""
    public var city: String = ""
    public var region: String = ""
    public var postalCode: String = ""
    public var country: String = ""
    public var countryCode: String = ""
    public init(label: String = "", street: String = "", city: String = "", region: String = "",
                postalCode: String = "", country: String = "", countryCode: String = "") {
        self.label = label; self.street = street; self.city = city; self.region = region
        self.postalCode = postalCode; self.country = country; self.countryCode = countryCode
    }
    var isEmpty: Bool {
        street.isEmpty && city.isEmpty && region.isEmpty && postalCode.isEmpty && country.isEmpty && countryCode.isEmpty
    }
}

public struct DateValue: Codable, Hashable, Sendable {
    public var label: String = ""
    public var year: Int?
    public var month: Int
    public var day: Int
    public init(label: String = "", year: Int?, month: Int, day: Int) {
        self.label = label; self.year = year; self.month = month; self.day = day
    }
}

/// The provider-neutral representation of a contact. Everything the app keeps identical
/// between Google and iCloud lives here; anything else on either side is left untouched.
public struct ContactRecord: Codable, Hashable, Sendable {
    public var namePrefix = ""
    public var givenName = ""
    public var middleName = ""
    public var familyName = ""
    public var nameSuffix = ""
    public var nickname = ""
    public var phoneticGivenName = ""
    public var phoneticMiddleName = ""
    public var phoneticFamilyName = ""
    public var organization = ""
    public var department = ""
    public var jobTitle = ""
    public var emails: [LabeledValue] = []
    public var phones: [LabeledValue] = []
    public var urls: [LabeledValue] = []
    public var relations: [LabeledValue] = []
    /// label = service/protocol (e.g. "skype"), value = username
    public var instantMessages: [LabeledValue] = []
    public var addresses: [PostalAddress] = []
    public var birthday: DateValue?
    public var dates: [DateValue] = []
    public var note = ""

    public init() {}

    /// Returns a canonical copy: whitespace trimmed, empty entries dropped, labels canonicalised.
    public func normalized() -> ContactRecord {
        var r = self
        func t(_ s: String) -> String {
            s.replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        r.namePrefix = t(namePrefix); r.givenName = t(givenName); r.middleName = t(middleName)
        r.familyName = t(familyName); r.nameSuffix = t(nameSuffix); r.nickname = t(nickname)
        r.phoneticGivenName = t(phoneticGivenName); r.phoneticMiddleName = t(phoneticMiddleName)
        r.phoneticFamilyName = t(phoneticFamilyName)
        r.organization = t(organization); r.department = t(department); r.jobTitle = t(jobTitle)
        r.note = t(note)
        func lv(_ list: [LabeledValue], lowercaseValue: Bool = false) -> [LabeledValue] {
            list.compactMap { item in
                var v = t(item.value)
                if lowercaseValue { v = v.lowercased() }
                guard !v.isEmpty else { return nil }
                return LabeledValue(label: Labels.canonical(t(item.label)), value: v)
            }
        }
        r.emails = lv(emails)
        r.phones = lv(phones)
        r.urls = lv(urls)
        r.relations = lv(relations)
        r.instantMessages = lv(instantMessages)
        r.addresses = addresses.compactMap { a in
            let n = PostalAddress(label: Labels.canonical(t(a.label)), street: t(a.street), city: t(a.city),
                                  region: t(a.region), postalCode: t(a.postalCode), country: t(a.country),
                                  countryCode: t(a.countryCode).lowercased())
            return n.isEmpty ? nil : n
        }
        func dv(_ d: DateValue) -> DateValue? {
            guard (1...12).contains(d.month), (1...31).contains(d.day) else { return nil }
            let y = (d.year ?? 0) > 0 ? d.year : nil
            return DateValue(label: Labels.canonical(t(d.label)), year: y, month: d.month, day: d.day)
        }
        r.birthday = birthday.flatMap(dv).map { var b = $0; b.label = ""; return b }
        r.dates = dates.compactMap(dv)
        return r
    }

    /// Stable fingerprint of the normalised record.
    public var fingerprint: String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let data = (try? enc.encode(normalized())) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public var displayName: String {
        let n = [namePrefix, givenName, middleName, familyName, nameSuffix]
            .filter { !$0.isEmpty }.joined(separator: " ")
        if !n.isEmpty { return n }
        if !organization.isEmpty { return organization }
        if let e = emails.first?.value { return e }
        if let p = phones.first?.value { return p }
        return "(no name)"
    }

    public var isEmpty: Bool { normalized() == ContactRecord() }
}

// MARK: - Merging

extension ContactRecord {
    /// Used the first time two contacts are matched: nothing is thrown away.
    /// Single fields take `primary` unless it is empty; lists are unioned.
    public static func union(primary p: ContactRecord, secondary s: ContactRecord) -> ContactRecord {
        let p = p.normalized(), s = s.normalized()
        var r = p
        func pick(_ kp: WritableKeyPath<ContactRecord, String>) {
            if r[keyPath: kp].isEmpty { r[keyPath: kp] = s[keyPath: kp] }
        }
        for kp in stringFields { pick(kp) }
        func merge(_ kp: WritableKeyPath<ContactRecord, [LabeledValue]>, key: (String) -> String) {
            var seen = Set(r[keyPath: kp].map { key($0.value) })
            for item in s[keyPath: kp] where !seen.contains(key(item.value)) {
                r[keyPath: kp].append(item)
                seen.insert(key(item.value))
            }
        }
        merge(\.emails) { $0.lowercased() }
        merge(\.phones) { Matching.phoneKey($0) }
        merge(\.urls) { $0.lowercased() }
        merge(\.relations) { $0.lowercased() }
        merge(\.instantMessages) { $0.lowercased() }
        for a in s.addresses where !r.addresses.contains(where: { $0.street.lowercased() == a.street.lowercased() && $0.city.lowercased() == a.city.lowercased() && $0.postalCode == a.postalCode }) {
            r.addresses.append(a)
        }
        if r.birthday == nil { r.birthday = s.birthday }
        for d in s.dates where !r.dates.contains(where: { $0.month == d.month && $0.day == d.day && $0.year == d.year }) {
            r.dates.append(d)
        }
        if r.note.isEmpty { r.note = s.note }
        else if !s.note.isEmpty && s.note != r.note && !r.note.contains(s.note) { r.note += "\n\n" + s.note }
        return r
    }

    /// Three-way merge used when both sides changed since the last sync: every field
    /// takes whichever side changed it; if both changed the same field, `preferA` decides.
    public static func merge3(base: ContactRecord, a: ContactRecord, b: ContactRecord, preferA: Bool) -> ContactRecord {
        let base = base.normalized(), a = a.normalized(), b = b.normalized()
        var r = base
        func m<T: Equatable>(_ kp: WritableKeyPath<ContactRecord, T>) {
            let aChanged = a[keyPath: kp] != base[keyPath: kp]
            let bChanged = b[keyPath: kp] != base[keyPath: kp]
            switch (aChanged, bChanged) {
            case (true, true): r[keyPath: kp] = preferA ? a[keyPath: kp] : b[keyPath: kp]
            case (true, false): r[keyPath: kp] = a[keyPath: kp]
            case (false, true): r[keyPath: kp] = b[keyPath: kp]
            case (false, false): break
            }
        }
        for kp in stringFields { m(kp) }
        m(\.emails); m(\.phones); m(\.urls); m(\.relations); m(\.instantMessages)
        m(\.addresses); m(\.birthday); m(\.dates)
        return r
    }

    static let stringFields: [WritableKeyPath<ContactRecord, String>] = [
        \.namePrefix, \.givenName, \.middleName, \.familyName, \.nameSuffix, \.nickname,
        \.phoneticGivenName, \.phoneticMiddleName, \.phoneticFamilyName,
        \.organization, \.department, \.jobTitle, \.note,
    ]
}

// MARK: - Matching

public enum Matching {
    /// Last 9 digits of a phone number - tolerant of country codes and formatting.
    public static func phoneKey(_ s: String) -> String {
        let digits = s.filter(\.isNumber)
        return String(digits.suffix(9))
    }

    public static func nameKey(_ r: ContactRecord) -> String? {
        let parts = [r.givenName, r.middleName, r.familyName].map { $0.lowercased() }.filter { !$0.isEmpty }
        if !parts.isEmpty { return parts.joined(separator: " ") }
        if !r.organization.isEmpty { return "org:" + r.organization.lowercased() }
        return nil
    }
}

// MARK: - Labels

/// Canonical label vocabulary shared by both providers. Built-in labels are lowercase;
/// custom labels are kept verbatim.
public enum Labels {
    public static let known: Set<String> = [
        "home", "work", "other", "school", "mobile", "iphone", "main", "homefax", "workfax",
        "otherfax", "pager", "workmobile", "workpager", "googlevoice", "homepage", "blog",
        "profile", "ftp", "reservations", "appinstallpage", "anniversary",
        "spouse", "child", "mother", "father", "parent", "brother", "sister", "friend",
        "relative", "domesticpartner", "manager", "assistant", "referredby", "partner",
        "son", "daughter",
        "aim", "msn", "yahoo", "skype", "qq", "googletalk", "icq", "jabber", "netmeeting",
        "facebook", "gadugadu",
    ]

    public static func canonical(_ raw: String) -> String {
        var s = raw
        // Apple built-in labels look like "_$!<Home>!$_"
        if s.hasPrefix("_$!<") && s.hasSuffix(">!$_") {
            s = String(s.dropFirst(4).dropLast(4))
        }
        let lower = s.lowercased()
        if known.contains(lower) { return lower }
        return s
    }
}
