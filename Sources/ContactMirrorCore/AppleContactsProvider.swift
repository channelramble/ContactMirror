import Foundation
import Contacts
import CryptoKit
import ObjCSupport

public struct ContactsContainer: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
}

public enum AppleContactsError: Error, LocalizedError {
    case notAuthorized
    case containerMissing
    case notFound

    public var errorDescription: String? {
        switch self {
        case .notAuthorized: return "ContactMirror doesn't have access to Contacts. Allow it in System Settings → Privacy & Security → Contacts."
        case .containerMissing: return "The selected iCloud contacts account was not found. Make sure Contacts is enabled for iCloud in System Settings → Apple Account → iCloud, then pick it in Settings → iCloud."
        case .notFound: return "Contact no longer exists."
        }
    }
}

/// iCloud Contacts through the macOS Contacts framework (the Mac's iCloud account syncs it to iCloud).
public final class AppleContactsProvider: RecordProvider, @unchecked Sendable {
    public typealias Record = ContactRecord
    public let displayName = "iCloud"
    let store: CNContactStore
    public let containerID: String
    public let syncNotes: Bool

    public init(store: CNContactStore = CNContactStore(), containerID: String, syncNotes: Bool) {
        self.store = store
        self.containerID = containerID
        self.syncNotes = syncNotes
    }

    // MARK: Authorization & discovery

    public static var isAuthorized: Bool {
        CNContactStore.authorizationStatus(for: .contacts) == .authorized
    }

    public static var authorizationDenied: Bool {
        let s = CNContactStore.authorizationStatus(for: .contacts)
        return s == .denied || s == .restricted
    }

    public static func requestAccess(store: CNContactStore = CNContactStore()) async -> Bool {
        (try? await store.requestAccess(for: .contacts)) ?? false
    }

    public static func containers(store: CNContactStore = CNContactStore()) -> [ContactsContainer] {
        guard isAuthorized, let list = try? store.containers(matching: nil) else { return [] }
        return list.map { c in
            let kind: String
            switch c.type {
            case .cardDAV: kind = "CardDAV"
            case .exchange: kind = "Exchange"
            case .local: kind = "On My Mac"
            default: kind = "Other"
            }
            let name = c.name.isEmpty ? kind : c.name
            return ContactsContainer(id: c.identifier, name: name == kind ? name : "\(name) (\(kind))")
        }
    }

    /// The iCloud container if there is one.
    public static func defaultICloudContainerID(store: CNContactStore = CNContactStore()) -> String? {
        guard isAuthorized, let list = try? store.containers(matching: nil) else { return nil }
        return list.first(where: { $0.name.lowercased() == "icloud" })?.identifier
            ?? list.first(where: { $0.type == .cardDAV && $0.name.lowercased().contains("icloud") })?.identifier
    }

    /// Contact notes need a special Apple entitlement on some macOS versions; find out if we can read them.
    public static func notesAccessible(store: CNContactStore = CNContactStore()) -> Bool {
        guard isAuthorized else { return false }
        var ok = false
        let exc = CMCatchException {
            let req = CNContactFetchRequest(keysToFetch: [CNContactNoteKey as CNKeyDescriptor])
            do {
                var first: CNContact?
                try store.enumerateContacts(with: req) { c, stop in first = c; stop.pointee = true }
                if let first {
                    _ = first.note // throws an ObjC exception if the key was silently dropped
                }
                ok = true
            } catch {
                ok = false
            }
        }
        return exc == nil && ok
    }

    // MARK: Keys

    var keys: [CNKeyDescriptor] {
        var k: [String] = [
            CNContactIdentifierKey, CNContactNamePrefixKey, CNContactGivenNameKey, CNContactMiddleNameKey,
            CNContactFamilyNameKey, CNContactNameSuffixKey, CNContactNicknameKey,
            CNContactPhoneticGivenNameKey, CNContactPhoneticMiddleNameKey, CNContactPhoneticFamilyNameKey,
            CNContactOrganizationNameKey, CNContactDepartmentNameKey, CNContactJobTitleKey,
            CNContactEmailAddressesKey, CNContactPhoneNumbersKey, CNContactUrlAddressesKey,
            CNContactRelationsKey, CNContactInstantMessageAddressesKey, CNContactPostalAddressesKey,
            CNContactBirthdayKey, CNContactDatesKey, CNContactImageDataKey, CNContactImageDataAvailableKey,
        ]
        if syncNotes { k.append(CNContactNoteKey) }
        return k as [CNKeyDescriptor]
    }

    // MARK: ContactProvider

    public func fetchAll() async throws -> [RemoteContact] {
        guard Self.isAuthorized else { throw AppleContactsError.notAuthorized }
        let store = self.store, keys = self.keys, containerID = self.containerID, notes = syncNotes
        return try await Task.detached(priority: .utility) {
            let containers = try store.containers(matching: CNContainer.predicateForContainers(withIdentifiers: [containerID]))
            guard !containers.isEmpty else { throw AppleContactsError.containerMissing }
            let req = CNContactFetchRequest(keysToFetch: keys)
            req.predicate = CNContact.predicateForContactsInContainer(withIdentifier: containerID)
            req.unifyResults = false
            var out: [RemoteContact] = []
            var thrown: Error?
            let exc = CMCatchException {
                do {
                    try store.enumerateContacts(with: req) { c, _ in
                        out.append(Self.remote(from: c, includeNotes: notes))
                    }
                } catch { thrown = error }
            }
            if let thrown { throw thrown }
            if let exc { throw exc }
            return out
        }.value
    }

    public func create(_ record: ContactRecord) async throws -> RemoteContact {
        let contact = CNMutableContact()
        Self.apply(record, to: contact, includeNotes: syncNotes)
        let req = CNSaveRequest()
        req.add(contact, toContainerWithIdentifier: containerID)
        try execute(req)
        return try fetch(contact.identifier)
    }

    public func update(_ existing: RemoteContact, to record: ContactRecord) async throws -> RemoteContact {
        let current = try fetchContact(existing.id)
        guard let m = current.mutableCopy() as? CNMutableContact else { throw AppleContactsError.notFound }
        Self.apply(record, to: m, includeNotes: syncNotes)
        let req = CNSaveRequest()
        req.update(m)
        try execute(req)
        return try fetch(existing.id)
    }

    public func delete(_ existing: RemoteContact) async throws {
        let current: CNContact
        do { current = try fetchContact(existing.id) } catch AppleContactsError.notFound { return }
        guard let m = current.mutableCopy() as? CNMutableContact else { return }
        let req = CNSaveRequest()
        req.delete(m)
        try execute(req)
    }

    public func photoData(for contact: RemoteContact) async throws -> Data? {
        try fetchContact(contact.id).imageData
    }

    public func setPhoto(_ data: Data?, for contact: RemoteContact) async throws -> RemoteContact {
        let current = try fetchContact(contact.id)
        guard let m = current.mutableCopy() as? CNMutableContact else { throw AppleContactsError.notFound }
        m.imageData = data
        let req = CNSaveRequest()
        req.update(m)
        try execute(req)
        return try fetch(contact.id)
    }

    // MARK: Store helpers

    private func execute(_ req: CNSaveRequest) throws {
        var thrown: Error?
        let exc = CMCatchException {
            do { try self.store.execute(req) } catch { thrown = error }
        }
        if let thrown { throw thrown }
        if let exc { throw exc }
    }

    private func fetchContact(_ id: String) throws -> CNContact {
        let req = CNContactFetchRequest(keysToFetch: keys)
        req.predicate = CNContact.predicateForContacts(withIdentifiers: [id])
        req.unifyResults = false
        var found: CNContact?
        var thrown: Error?
        let exc = CMCatchException {
            do {
                try self.store.enumerateContacts(with: req) { c, stop in
                    if c.identifier == id { found = c; stop.pointee = true }
                }
            } catch { thrown = error }
        }
        if let thrown { throw thrown }
        if let exc { throw exc }
        guard let found else { throw AppleContactsError.notFound }
        return found
    }

    private func fetch(_ id: String) throws -> RemoteContact {
        Self.remote(from: try fetchContact(id), includeNotes: syncNotes)
    }

    // MARK: Mapping

    static func remote(from c: CNContact, includeNotes: Bool) -> RemoteContact {
        var photoKey = ""
        if c.isKeyAvailable(CNContactImageDataKey), let d = c.imageData, !d.isEmpty {
            photoKey = SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
        }
        return RemoteContact(id: c.identifier, record: record(from: c, includeNotes: includeNotes), photoKey: photoKey)
    }

    static func record(from c: CNContact, includeNotes: Bool) -> ContactRecord {
        var r = ContactRecord()
        r.namePrefix = c.namePrefix; r.givenName = c.givenName; r.middleName = c.middleName
        r.familyName = c.familyName; r.nameSuffix = c.nameSuffix; r.nickname = c.nickname
        r.phoneticGivenName = c.phoneticGivenName; r.phoneticMiddleName = c.phoneticMiddleName
        r.phoneticFamilyName = c.phoneticFamilyName
        r.organization = c.organizationName; r.department = c.departmentName; r.jobTitle = c.jobTitle
        r.emails = c.emailAddresses.map { LabeledValue(label: $0.label ?? "", value: $0.value as String) }
        r.phones = c.phoneNumbers.map { LabeledValue(label: $0.label ?? "", value: $0.value.stringValue) }
        r.urls = c.urlAddresses.map { LabeledValue(label: $0.label ?? "", value: $0.value as String) }
        r.relations = c.contactRelations.map { LabeledValue(label: $0.label ?? "", value: $0.value.name) }
        r.instantMessages = c.instantMessageAddresses.map { LabeledValue(label: $0.value.service, value: $0.value.username) }
        r.addresses = c.postalAddresses.map { lv in
            let a = lv.value
            return PostalAddress(label: lv.label ?? "", street: a.street, city: a.city, region: a.state,
                                 postalCode: a.postalCode, country: a.country, countryCode: a.isoCountryCode)
        }
        func valid(_ v: Int?) -> Int? {
            guard let v, v != NSDateComponentUndefined, v > 0 else { return nil }
            return v
        }
        if let b = c.birthday, let m = valid(b.month), let d = valid(b.day) {
            r.birthday = DateValue(year: valid(b.year), month: m, day: d)
        }
        r.dates = c.dates.compactMap { lv in
            let dc = lv.value
            guard let m = valid(dc.month), let d = valid(dc.day) else { return nil }
            return DateValue(label: lv.label ?? "", year: valid(dc.year), month: m, day: d)
        }
        if includeNotes, c.isKeyAvailable(CNContactNoteKey) { r.note = c.note }
        return r.normalized()
    }

    static let cnLabels: [String: String] = [
        "home": CNLabelHome, "work": CNLabelWork, "other": CNLabelOther, "school": CNLabelSchool,
        "mobile": CNLabelPhoneNumberMobile, "iphone": CNLabelPhoneNumberiPhone, "main": CNLabelPhoneNumberMain,
        "homefax": CNLabelPhoneNumberHomeFax, "workfax": CNLabelPhoneNumberWorkFax,
        "otherfax": CNLabelPhoneNumberOtherFax, "pager": CNLabelPhoneNumberPager,
        "homepage": CNLabelURLAddressHomePage, "anniversary": CNLabelDateAnniversary,
        "father": CNLabelContactRelationFather, "mother": CNLabelContactRelationMother,
        "parent": CNLabelContactRelationParent, "brother": CNLabelContactRelationBrother,
        "sister": CNLabelContactRelationSister, "child": CNLabelContactRelationChild,
        "friend": CNLabelContactRelationFriend, "spouse": CNLabelContactRelationSpouse,
        "partner": CNLabelContactRelationPartner, "assistant": CNLabelContactRelationAssistant,
        "manager": CNLabelContactRelationManager, "son": CNLabelContactRelationSon,
        "daughter": CNLabelContactRelationDaughter,
    ]

    static let cnServices: [String: String] = [
        "aim": CNInstantMessageServiceAIM, "facebook": CNInstantMessageServiceFacebook,
        "gadugadu": CNInstantMessageServiceGaduGadu, "googletalk": CNInstantMessageServiceGoogleTalk,
        "icq": CNInstantMessageServiceICQ, "jabber": CNInstantMessageServiceJabber,
        "msn": CNInstantMessageServiceMSN, "qq": CNInstantMessageServiceQQ,
        "skype": CNInstantMessageServiceSkype, "yahoo": CNInstantMessageServiceYahoo,
    ]

    static func cnLabel(_ canonical: String) -> String? {
        if canonical.isEmpty { return nil }
        return cnLabels[canonical] ?? GoogleContactsProvider.googleType(canonical)
    }

    static func apply(_ record: ContactRecord, to c: CNMutableContact, includeNotes: Bool) {
        let r = record.normalized()
        c.namePrefix = r.namePrefix; c.givenName = r.givenName; c.middleName = r.middleName
        c.familyName = r.familyName; c.nameSuffix = r.nameSuffix; c.nickname = r.nickname
        c.phoneticGivenName = r.phoneticGivenName; c.phoneticMiddleName = r.phoneticMiddleName
        c.phoneticFamilyName = r.phoneticFamilyName
        c.organizationName = r.organization; c.departmentName = r.department; c.jobTitle = r.jobTitle
        c.emailAddresses = r.emails.map { CNLabeledValue(label: cnLabel($0.label), value: $0.value as NSString) }
        c.phoneNumbers = r.phones.map { CNLabeledValue(label: cnLabel($0.label), value: CNPhoneNumber(stringValue: $0.value)) }
        c.urlAddresses = r.urls.map { CNLabeledValue(label: cnLabel($0.label), value: $0.value as NSString) }
        c.contactRelations = r.relations.map { CNLabeledValue(label: cnLabel($0.label), value: CNContactRelation(name: $0.value)) }
        c.instantMessageAddresses = r.instantMessages.map {
            let service = cnServices[$0.label] ?? GoogleContactsProvider.googleType($0.label)
            return CNLabeledValue(label: nil, value: CNInstantMessageAddress(username: $0.value, service: service))
        }
        c.postalAddresses = r.addresses.map { a in
            let p = CNMutablePostalAddress()
            p.street = a.street; p.city = a.city; p.state = a.region; p.postalCode = a.postalCode
            p.country = a.country; p.isoCountryCode = a.countryCode
            return CNLabeledValue(label: cnLabel(a.label), value: p.copy() as! CNPostalAddress)
        }
        if let b = r.birthday {
            var dc = DateComponents()
            dc.month = b.month; dc.day = b.day
            if let y = b.year { dc.year = y }
            c.birthday = dc
        } else {
            c.birthday = nil
        }
        c.dates = r.dates.map { d in
            let dc = NSDateComponents()
            dc.month = d.month; dc.day = d.day
            if let y = d.year { dc.year = y }
            return CNLabeledValue(label: cnLabel(d.label), value: dc)
        }
        if includeNotes { c.note = r.note }
    }

    // MARK: vCard export (backups)

    /// vCard data for a list of records (used for backups of either side).
    public static func vCards(for records: [ContactRecord]) -> Data {
        let contacts: [CNContact] = records.map { r in
            let c = CNMutableContact()
            apply(r, to: c, includeNotes: false)
            return c
        }
        var data = Data()
        _ = CMCatchException {
            data = (try? CNContactVCardSerialization.data(with: contacts)) ?? Data()
        }
        return data
    }
}
