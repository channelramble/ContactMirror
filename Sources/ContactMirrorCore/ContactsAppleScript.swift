import Foundation

/// Fallback writer that edits contacts through the Contacts app via AppleScript.
///
/// macOS refuses CNSaveRequest updates/deletes (Cocoa error 134092, "permission denied") for
/// any contact that has a note unless the app holds Apple's restricted notes entitlement.
/// Contacts.app has that entitlement, so we ask it to make the change instead. The first time,
/// macOS asks the user to allow ContactMirror to control Contacts.
enum ContactsAppleScript {
    static func isNotesPermissionError(_ error: Error) -> Bool {
        let ns = error as NSError
        return ns.code == 134092 || (ns.userInfo[NSUnderlyingErrorKey] as? NSError)?.code == 134092
    }

    static func q(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static let labels: [String: String] = [
        "homefax": "home fax", "workfax": "work fax", "otherfax": "other fax", "iphone": "iPhone",
        "homepage": "homepage", "workmobile": "work mobile",
    ]

    static func label(_ canonical: String) -> String { labels[canonical] ?? canonical }

    static func updateScript(id: String, record: ContactRecord) -> String {
        let r = record.normalized()
        var lines: [String] = []
        func set(_ prop: String, _ v: String) {
            lines.append("set \(prop) of p to \(q(v))")
        }
        set("title", r.namePrefix); set("first name", r.givenName); set("middle name", r.middleName)
        set("last name", r.familyName); set("suffix", r.nameSuffix); set("nickname", r.nickname)
        set("phonetic first name", r.phoneticGivenName); set("phonetic middle name", r.phoneticMiddleName)
        set("phonetic last name", r.phoneticFamilyName)
        set("organization", r.organization); set("department", r.department); set("job title", r.jobTitle)

        func list(_ element: String, _ plural: String, _ items: [LabeledValue]) {
            lines.append("delete every \(element) of p")
            for i in items {
                lines.append("make new \(element) at end of \(plural) of p with properties {label:\(q(label(i.label))), value:\(q(i.value))}")
            }
        }
        list("email", "emails", r.emails)
        list("phone", "phones", r.phones)
        list("url", "urls", r.urls)
        list("related name", "related names", r.relations)
        lines.append("delete every address of p")
        for a in r.addresses {
            lines.append("make new address at end of addresses of p with properties {label:\(q(label(a.label))), street:\(q(a.street)), city:\(q(a.city)), state:\(q(a.region)), zip:\(q(a.postalCode)), country:\(q(a.country)), country code:\(q(a.countryCode))}")
        }
        if let b = r.birthday, let y = b.year {
            lines.append("set bd to current date")
            lines.append("set day of bd to 1")
            lines.append("set year of bd to \(y)")
            lines.append("set month of bd to \(b.month)")
            lines.append("set day of bd to \(b.day)")
            lines.append("set time of bd to 43200")
            lines.append("set birth date of p to bd")
        } else if r.birthday == nil {
            lines.append("try\nset birth date of p to missing value\nend try")
        }
        return wrap(id: id, body: lines.joined(separator: "\n"))
    }

    static func deleteScript(id: String) -> String {
        wrap(id: id, body: "delete p")
    }

    static func wrap(id: String, body: String) -> String {
        """
        set wasRunning to application "Contacts" is running
        tell application "Contacts"
        set p to person id \(q(id))
        \(body)
        save
        end tell
        if not wasRunning then tell application "Contacts" to quit
        """
    }

    static func run(_ script: String) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-"]
        let input = Pipe(), errPipe = Pipe()
        p.standardInput = input
        p.standardError = errPipe
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        input.fileHandleForWriting.write(Data(script.utf8))
        try input.fileHandleForWriting.close()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            let msg = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            if msg.contains("-1743") || msg.lowercased().contains("not authorized") {
                throw NSError(domain: "ContactMirror", code: -1743, userInfo: [NSLocalizedDescriptionKey:
                    "This contact has a note, so macOS only lets the Contacts app edit it. Allow ContactMirror to control Contacts in System Settings → Privacy & Security → Automation."])
            }
            throw NSError(domain: "ContactMirror", code: Int(p.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "Contacts app couldn't save the change: \(msg.trimmingCharacters(in: .whitespacesAndNewlines))"])
        }
    }
}
