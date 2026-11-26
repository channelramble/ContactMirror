import Foundation
import CoreServices

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

    /// Once the Contacts app couldn't be reached (permission prompt unanswered or denied), skip
    /// further attempts for a while instead of waiting two minutes per contact.
    static var blockedUntil = Date.distantPast
    static let blockLock = NSLock()

    static var promptRequested = false

    /// Asks macOS (without waiting on any dialog) whether we may control Contacts.app.
    static func automationStatus(ask: Bool) -> OSStatus {
        var addr = AEAddressDesc()
        let bundleID = "com.apple.AddressBook"
        let created = bundleID.withCString { ptr in AECreateDesc(typeApplicationBundleID, ptr, strlen(ptr), &addr) }
        guard created == noErr else { return OSStatus(created) }
        defer { AEDisposeDesc(&addr) }
        return AEDeterminePermissionToAutomateTarget(&addr, typeWildCard, typeWildCard, ask)
    }

    /// The status query itself can block while a consent prompt is already on screen, so run
    /// it on its own thread and treat "no answer within 3 s" as "waiting for the user".
    static func automationStatusQuick() -> OSStatus {
        let sem = DispatchSemaphore(value: 0)
        let box = StatusBox()
        Thread.detachNewThread {
            box.value = automationStatus(ask: false)
            sem.signal()
        }
        if sem.wait(timeout: .now() + 3) == .timedOut { return OSStatus(errAEEventWouldRequireUserConsent) }
        return box.value
    }

    final class StatusBox: @unchecked Sendable { var value: OSStatus = noErr }

    static func ensureAutomationAllowed() throws {
        var status = automationStatusQuick()
        if status == OSStatus(procNotFound) {
            // The check needs Contacts.app running; start it hidden in the background.
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = ["-g", "-j", "-b", "com.apple.AddressBook"]
            try? p.run(); p.waitUntilExit()
            for _ in 0..<50 where status == OSStatus(procNotFound) {
                Thread.sleep(forTimeInterval: 0.1)
                status = automationStatusQuick()
            }
        }
        switch status {
        case noErr:
            return
        case OSStatus(errAEEventWouldRequireUserConsent):
            // Show macOS's permission prompt once, in the background, and carry on syncing
            // everything else instead of waiting for someone to answer it.
            let shouldAsk = blockLock.withLock { () -> Bool in
                if promptRequested { return false }
                promptRequested = true
                return true
            }
            if shouldAsk {
                Thread.detachNewThread {
                    _ = automationStatus(ask: true)
                    blockLock.withLock { promptRequested = false; blockedUntil = .distantPast }
                }
            }
            throw NSError(domain: "ContactMirror", code: -1744, userInfo: [NSLocalizedDescriptionKey:
                "Waiting for permission to control the Contacts app (needed for contacts that have notes). Click OK on the macOS prompt, or allow it in System Settings → Privacy & Security → Automation."])
        case OSStatus(errAEEventNotPermitted):
            throw NSError(domain: "ContactMirror", code: -1743, userInfo: [NSLocalizedDescriptionKey:
                "ContactMirror isn't allowed to control the Contacts app, so contacts that have notes can't be updated. Allow it in System Settings → Privacy & Security → Automation → ContactMirror → Contacts."])
        default:
            return // unknown: just try, the script reports real errors
        }
    }

    static func run(_ script: String) throws {
        try ensureAutomationAllowed()
        if blockLock.withLock({ Date() < blockedUntil }) {
            throw NSError(domain: "ContactMirror", code: -1743, userInfo: [NSLocalizedDescriptionKey:
                "Waiting for permission to control the Contacts app (needed for contacts that have notes). Allow it in System Settings → Privacy & Security → Automation."])
        }
        do { try runUnchecked(script) } catch {
            let code = (error as NSError).code
            if code == -1743 || code == -1712 || code == -1744 { blockLock.withLock { blockedUntil = Date().addingTimeInterval(20 * 60) } }
            throw error
        }
    }

    static func runUnchecked(_ script: String) throws {
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
        // If macOS is waiting for the user to allow automation, don't block the sync forever.
        let deadline = Date().addingTimeInterval(120)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        if p.isRunning {
            p.terminate()
            throw NSError(domain: "ContactMirror", code: -1712, userInfo: [NSLocalizedDescriptionKey:
                "Timed out waiting for the Contacts app. If macOS is asking whether ContactMirror may control Contacts, click OK."])
        }
        if p.terminationStatus != 0 {
            let msg = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            if msg.contains("-1712") {
                throw NSError(domain: "ContactMirror", code: -1712, userInfo: [NSLocalizedDescriptionKey:
                    "The Contacts app didn't respond (it may be waiting on a permission prompt)."])
            }
            if msg.contains("-1743") || msg.lowercased().contains("not authorized") {
                throw NSError(domain: "ContactMirror", code: -1743, userInfo: [NSLocalizedDescriptionKey:
                    "This contact has a note, so macOS only lets the Contacts app edit it. Allow ContactMirror to control Contacts in System Settings → Privacy & Security → Automation."])
            }
            throw NSError(domain: "ContactMirror", code: Int(p.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "Contacts app couldn't save the change: \(msg.trimmingCharacters(in: .whitespacesAndNewlines))"])
        }
    }
}
