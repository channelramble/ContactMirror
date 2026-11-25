import AppKit
import Contacts
import CryptoKit
import EventKit
import ServiceManagement
import SwiftUI
import ContactMirrorCore

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()
    static let repo = "channelramble/ContactMirror"
    static let setupGuideURL = URL(string: "https://github.com/\(repo)#1-create-your-google-oauth-client-one-time-about-5-minutes")!

    let auth = GoogleAuth()
    let updater = Updater(repo: repo)
    private let defaults = UserDefaults.standard

    // MARK: Settings (persisted)

    @Published var syncEnabled: Bool { didSet { defaults.set(syncEnabled, forKey: "syncEnabled") } }
    @Published var syncIntervalMinutes: Int {
        didSet {
            let clamped = min(max(syncIntervalMinutes, 1), 1440)
            if clamped != syncIntervalMinutes { syncIntervalMinutes = clamped; return }
            defaults.set(syncIntervalMinutes, forKey: "syncIntervalMinutes")
        }
    }
    @Published var preference: ConflictPreference { didSet { defaults.set(preference.rawValue, forKey: "conflictPreference") } }
    @Published var containerID: String { didSet { defaults.set(containerID, forKey: "icloudContainerID") } }
    @Published var autoCheckUpdates: Bool { didSet { defaults.set(autoCheckUpdates, forKey: "autoCheckUpdates") } }
    @Published var autoInstallUpdates: Bool { didSet { defaults.set(autoInstallUpdates, forKey: "autoInstallUpdates") } }
    @Published var syncContacts: Bool { didSet { defaults.set(syncContacts, forKey: "syncContacts") } }
    @Published var syncCalendars: Bool { didSet { defaults.set(syncCalendars, forKey: "syncCalendars"); if syncCalendars { requestEventKit(.event) } } }
    @Published var syncTasks: Bool { didSet { defaults.set(syncTasks, forKey: "syncTasks"); if syncTasks { requestEventKit(.reminder) } } }

    // MARK: Status

    @Published var isSyncing = false
    @Published var lastSync: Date? { didSet { defaults.set(lastSync, forKey: "lastSync") } }
    @Published var lastSummary: String { didSet { defaults.set(lastSummary, forKey: "lastSummary") } }
    @Published var lastError: String?
    @Published var counts: (google: Int, icloud: Int)?
    @Published var pausedDeletions: [PausedDeletion] = []
    var pendingDeletion: [PausedDeletion]? { pausedDeletions.isEmpty ? nil : pausedDeletions }
    @Published var calendarsAuthorized = EventKitAccess.isAuthorized(.event)
    @Published var remindersAuthorized = EventKitAccess.isAuthorized(.reminder)
    @Published var logLines: [String] = []
    @Published var contactsAuthorized = AppleContactsProvider.isAuthorized
    @Published var containers: [ContactsContainer] = []
    @Published var googleSignedIn = false
    @Published var googleEmail: String?
    @Published var signingIn = false
    @Published var availableUpdate: ReleaseInfo?
    @Published var updateStatus = ""
    @Published var installingUpdate = false
    @Published var launchAtLogin = false

    private var lastAttempt: Date?
    private var lastUpdateCheck: Date?
    private var timer: Timer?
    private var activity: NSObjectProtocol?
    private var started = false

    let supportDir: URL = {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ContactMirror", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    var backupsDir: URL { supportDir.appendingPathComponent("Backups", isDirectory: true) }
    let logURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/ContactMirror.log")

    private init() {
        defaults.register(defaults: [
            "syncEnabled": true, "syncIntervalMinutes": 30, "conflictPreference": "google",
            "autoCheckUpdates": true, "autoInstallUpdates": true,
            "syncContacts": true, "syncCalendars": true, "syncTasks": true,
        ])
        syncContacts = defaults.bool(forKey: "syncContacts")
        syncCalendars = defaults.bool(forKey: "syncCalendars")
        syncTasks = defaults.bool(forKey: "syncTasks")
        syncEnabled = defaults.bool(forKey: "syncEnabled")
        syncIntervalMinutes = defaults.integer(forKey: "syncIntervalMinutes")
        preference = ConflictPreference(rawValue: defaults.string(forKey: "conflictPreference") ?? "") ?? .google
        containerID = defaults.string(forKey: "icloudContainerID") ?? ""
        autoCheckUpdates = defaults.bool(forKey: "autoCheckUpdates")
        autoInstallUpdates = defaults.bool(forKey: "autoInstallUpdates")
        lastSync = defaults.object(forKey: "lastSync") as? Date
        lastSummary = defaults.string(forKey: "lastSummary") ?? ""
        // Installer hook: an OAuth client secret written to defaults is moved into the Keychain.
        if let secret = defaults.string(forKey: "bootstrapClientSecret"), !secret.isEmpty {
            auth.clientSecret = secret
            defaults.removeObject(forKey: "bootstrapClientSecret")
        }
        refreshAccountState()
    }

    // MARK: Lifecycle

    /// Set CONTACTMIRROR_PREVIEW=1 to launch without registering a login item, prompting for
    /// Contacts access or syncing (used for screenshots / smoke tests).
    let previewMode = ProcessInfo.processInfo.environment["CONTACTMIRROR_PREVIEW"] == "1"

    func start() {
        guard !started else { return }
        started = true
        if previewMode {
            log("Preview mode: syncing disabled")
            // Maintainer test hook: exercise the full self-update path.
            if ProcessInfo.processInfo.environment["CONTACTMIRROR_TEST_UPDATE"] == "1" {
                Task {
                    await checkForUpdates(userInitiated: true)
                    print("update check: \(updateStatus)")
                    if let u = availableUpdate { install(u) } else { NSApp.terminate(nil) }
                }
            }
            return
        }
        // Keep the app responsive in the background (no App Nap) while still letting the Mac sleep.
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "Keeps Google and iCloud contacts in sync")
        log("ContactMirror \(Updater.currentVersion) started")

        if !defaults.bool(forKey: "didRegisterLoginItem") {
            defaults.set(true, forKey: "didRegisterLoginItem")
            setLaunchAtLogin(true)
        }
        refreshLoginItem()

        Task {
            if syncContacts, CNContactStore.authorizationStatus(for: .contacts) == .notDetermined {
                _ = await AppleContactsProvider.requestAccess()
            }
            if syncCalendars, EventKitAccess.isUndetermined(.event) { _ = await EventKitAccess.request(.event) }
            if syncTasks, EventKitAccess.isUndetermined(.reminder) { _ = await EventKitAccess.request(.reminder) }
            refreshAccountState()
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 20_000_000_000) // let the network come back
                self?.tick()
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            tick()
        }
    }

    private func tick() {
        let now = Date()
        if syncEnabled, isReady, !isSyncing {
            let due = lastAttempt.map { now.timeIntervalSince($0) >= Double(syncIntervalMinutes) * 60 } ?? true
            if due { syncNow() }
        }
        if autoCheckUpdates, !installingUpdate,
           lastUpdateCheck.map({ now.timeIntervalSince($0) >= 6 * 3600 }) ?? true {
            Task { await checkForUpdates(userInitiated: false) }
        }
    }

    var nextSyncDate: Date? {
        guard syncEnabled, isReady else { return nil }
        return (lastAttempt ?? Date()).addingTimeInterval(Double(syncIntervalMinutes) * 60)
    }

    // MARK: Accounts

    var isReady: Bool { setupProblem == nil }

    var effectiveContainerID: String {
        if !containerID.isEmpty, containers.contains(where: { $0.id == containerID }) { return containerID }
        return AppleContactsProvider.defaultICloudContainerID() ?? ""
    }

    var setupProblem: String? {
        if !auth.isConfigured { return "Add your Google OAuth client in Settings → Accounts." }
        if !googleSignedIn { return "Sign in to Google in Settings → Accounts." }
        if !(syncContacts || syncCalendars || syncTasks) { return "Choose what to sync in Settings → General." }
        if syncContacts && !contactsAuthorized { return "Allow Contacts access in Settings → Accounts." }
        if syncContacts && effectiveContainerID.isEmpty { return "Turn on iCloud Contacts on this Mac, then pick it in Settings → Accounts." }
        if syncCalendars && !calendarsAuthorized { return "Allow full Calendar access in Settings → Accounts." }
        if syncTasks && !remindersAuthorized { return "Allow full Reminders access in Settings → Accounts." }
        if (syncCalendars && !auth.hasScope(GoogleAuth.calendarScope)) || (syncTasks && !auth.hasScope(GoogleAuth.tasksScope))
            || (syncContacts && !auth.hasScope(GoogleAuth.contactsScope)) {
            return "Sign in to Google again and allow access to Contacts, Calendar and Tasks."
        }
        return nil
    }

    func refreshAccountState() {
        googleSignedIn = auth.isSignedIn
        googleEmail = auth.email
        contactsAuthorized = AppleContactsProvider.isAuthorized
        calendarsAuthorized = EventKitAccess.isAuthorized(.event)
        remindersAuthorized = EventKitAccess.isAuthorized(.reminder)
        containers = AppleContactsProvider.containers()
        if containerID.isEmpty, let id = AppleContactsProvider.defaultICloudContainerID() { containerID = id }
    }

    func requestContactsAccess() {
        Task {
            if AppleContactsProvider.authorizationDenied {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts")!)
            } else {
                _ = await AppleContactsProvider.requestAccess()
            }
            refreshAccountState()
        }
    }

    func requestEventKit(_ type: EKEntityType) {
        Task {
            if EventKitAccess.isDenied(type) {
                let pane = type == .event ? "Privacy_Calendars" : "Privacy_Reminders"
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
            } else if !EventKitAccess.isAuthorized(type) {
                _ = await EventKitAccess.request(type)
            }
            refreshAccountState()
        }
    }

    func saveGoogleClient(id: String, secret: String) {
        auth.clientID = id
        auth.clientSecret = secret
        objectWillChange.send()
    }

    func signInToGoogle() {
        guard !signingIn else { return }
        signingIn = true
        Task {
            defer { signingIn = false }
            do {
                try await auth.signIn { url in NSWorkspace.shared.open(url) }
                NSApp.activate(ignoringOtherApps: true)
                log("Signed in to Google as \(auth.email ?? "unknown account")")
                lastError = nil
            } catch {
                lastError = error.localizedDescription
                log("Google sign-in failed: \(error.localizedDescription)")
            }
            refreshAccountState()
        }
    }

    func signOutOfGoogle() {
        auth.signOut()
        log("Signed out of Google")
        refreshAccountState()
    }

    // MARK: Sync

    /// One state file per Google account + Contacts container, so switching accounts never
    /// looks like "everything was deleted".
    /// Notes are part of the key too: if notes access ever changes, contacts are re-matched
    /// (merging notes) rather than treated as conflicting edits.
    func stateURL(notes: Bool) -> URL {
        let key = "\(googleEmail ?? "google")|\(effectiveContainerID)" + (notes ? "|notes" : "")
        let h = SHA256.hash(data: Data(key.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return supportDir.appendingPathComponent("state-\(h).json")
    }

    func syncNow(allowMassDeletion: Bool = false) {
        guard !isSyncing else { return }
        refreshAccountState()
        if let problem = setupProblem {
            lastError = problem
            return
        }
        isSyncing = true
        lastAttempt = Date()
        pausedDeletions = []
        let auth = self.auth
        let containerID = effectiveContainerID
        let notes = syncContacts && AppleContactsProvider.notesAccessible()
        let contactsState = self.stateURL(notes: notes)
        let supportDir = self.supportDir
        let backupsDir = self.backupsDir
        let accountKey = googleEmail ?? "google"
        let (doContacts, doCalendars, doTasks) = (syncContacts, syncCalendars, syncTasks)
        var options = SyncOptions()
        options.preference = preference
        options.allowMassDeletion = allowMassDeletion
        log("Sync started")

        Task.detached(priority: .utility) { [weak self] in
            let logger: (String) -> Void = { line in Task { @MainActor in self?.log(line) } }
            let backup = BackupWriter(root: backupsDir)
            var parts: [String] = []
            var errors = 0
            var paused: [PausedDeletion] = []
            var contactCounts: (Int, Int)?
            var fatal: String?

            if doContacts {
                let engine = SyncEngine(google: GoogleContactsProvider(auth: auth, syncNotes: notes),
                                        icloud: AppleContactsProvider(containerID: containerID, syncNotes: notes),
                                        stateURL: contactsState, what: "contacts")
                engine.log = logger
                engine.backup = { g, c in
                    try backup.writeJSON("contacts", google: g, icloud: c)
                    try backup.write(AppleContactsProvider.vCards(for: g.map(\.record)), name: "contacts-google.vcf")
                    try backup.write(AppleContactsProvider.vCards(for: c.map(\.record)), name: "contacts-icloud.vcf")
                }
                if !notes { logger("Note: contact notes aren't accessible to apps on this macOS version, so notes are left untouched.") }
                do {
                    let r = try await engine.sync(options: options)
                    parts.append("Contacts: \(r)")
                    errors += r.errors.count
                    contactCounts = (r.googleCount, r.icloudCount)
                } catch let SyncError.massDeletion(what, g, c) {
                    paused.append(PausedDeletion(what: what, google: g, icloud: c))
                } catch {
                    fatal = "Contacts: \(error.localizedDescription)"
                    logger("Contacts sync failed: \(error.localizedDescription)")
                }
            }

            if doCalendars || doTasks {
                let runner = CollectionSyncRunner(api: GoogleAPIClient(auth: auth), store: EKEventStore(),
                                                  stateDir: supportDir, accountKey: accountKey)
                runner.log = logger
                runner.backup = backup
                if doCalendars {
                    do {
                        let r = try await runner.syncCalendars(options: options)
                        parts.append("Calendars: \(r)")
                        errors += r.errors.count
                    } catch {
                        fatal = (fatal.map { $0 + "\n" } ?? "") + "Calendars: \(error.localizedDescription)"
                        logger("Calendar sync failed: \(error.localizedDescription)")
                    }
                }
                if doTasks {
                    do {
                        let r = try await runner.syncTasks(options: options)
                        parts.append("Tasks: \(r)")
                        errors += r.errors.count
                    } catch {
                        fatal = (fatal.map { $0 + "\n" } ?? "") + "Tasks: \(error.localizedDescription)"
                        logger("Task sync failed: \(error.localizedDescription)")
                    }
                }
                paused += runner.paused
            }
            BackupWriter.prune(root: backupsDir)

            let summary = parts.joined(separator: "\n")
            await MainActor.run {
                self?.finishSync(summary: summary, errors: errors, paused: paused, counts: contactCounts, fatal: fatal)
            }
        }
    }

    private func finishSync(summary: String, errors: Int, paused: [PausedDeletion], counts: (Int, Int)?, fatal: String?) {
        isSyncing = false
        if let counts { self.counts = counts }
        pausedDeletions = paused
        if !summary.isEmpty {
            lastSync = Date()
            lastSummary = summary
        }
        if let fatal {
            lastError = fatal
        } else if !paused.isEmpty {
            lastError = "Paused for safety: " + paused.map { "\($0.what) would delete \($0.google) from Google and \($0.icloud) from iCloud" }
                .joined(separator: "; ") + ". Review in the menu."
        } else if errors > 0 {
            lastError = "\(errors) item(s) failed – see Activity."
        } else {
            lastError = nil
        }
        log("Sync finished" + (summary.isEmpty ? "" : ":\n" + summary))
        if autoInstallUpdates, let u = availableUpdate, !installingUpdate {
            install(u)
        }
    }

    func confirmMassDeletion() {
        guard !pausedDeletions.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "Allow these deletions?"
        alert.informativeText = pausedDeletions.map { "• \($0.what): \($0.google) from Google, \($0.icloud) from iCloud" }
            .joined(separator: "\n") + "\n\nThese items were deleted on the other side. A backup is saved first (Settings → General → Open Backups Folder)."
        alert.addButton(withTitle: "Delete and Sync")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            pausedDeletions = []
            syncNow(allowMassDeletion: true)
        }
    }

    func resetSyncLinks() {
        let files = (try? FileManager.default.contentsOfDirectory(at: supportDir, includingPropertiesForKeys: nil)) ?? []
        for f in files where f.lastPathComponent.hasPrefix("state-") { try? FileManager.default.removeItem(at: f) }
        pausedDeletions = []
        log("Sync links reset – the next sync will re-match items without deleting anything.")
    }

    // MARK: Updates

    func checkForUpdates(userInitiated: Bool) async {
        lastUpdateCheck = Date()
        if userInitiated { updateStatus = "Checking…" }
        do {
            if let release = try await updater.checkForUpdate() {
                availableUpdate = release
                updateStatus = "Version \(release.version) is available."
                log("Update available: \(release.version)")
                if autoInstallUpdates && !isSyncing && !userInitiated { install(release) }
            } else {
                availableUpdate = nil
                updateStatus = "You're up to date (\(Updater.currentVersion))."
            }
        } catch {
            updateStatus = "Update check failed: \(error.localizedDescription)"
            if userInitiated { log(updateStatus) }
        }
    }

    func install(_ release: ReleaseInfo) {
        guard !installingUpdate else { return }
        if isSyncing { updateStatus = "Will install after the current sync."; return }
        installingUpdate = true
        updateStatus = "Downloading \(release.version)…"
        log("Installing update \(release.version)")
        Task {
            do {
                try await updater.install(release)
                log("Update staged, relaunching")
                NSApp.terminate(nil)
            } catch {
                installingUpdate = false
                updateStatus = error.localizedDescription
                log("Update failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: Login item

    func refreshLoginItem() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            log("Couldn't change login item: \(error.localizedDescription)")
        }
        refreshLoginItem()
    }

    // MARK: Logging

    func log(_ line: String) {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let entry = "\(f.string(from: Date()))  \(line)"
        logLines.append(entry)
        if logLines.count > 1000 { logLines.removeFirst(logLines.count - 1000) }
        let data = Data((entry + "\n").utf8)
        if let h = try? FileHandle(forWritingTo: logURL) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? data.write(to: logURL)
        }
    }
}
