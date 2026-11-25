import AppKit
import Contacts
import CryptoKit
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

    // MARK: Status

    @Published var isSyncing = false
    @Published var lastSync: Date? { didSet { defaults.set(lastSync, forKey: "lastSync") } }
    @Published var lastSummary: String { didSet { defaults.set(lastSummary, forKey: "lastSummary") } }
    @Published var lastError: String?
    @Published var counts: (google: Int, icloud: Int)?
    @Published var pendingDeletion: (google: Int, icloud: Int)?
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
        ])
        syncEnabled = defaults.bool(forKey: "syncEnabled")
        syncIntervalMinutes = defaults.integer(forKey: "syncIntervalMinutes")
        preference = ConflictPreference(rawValue: defaults.string(forKey: "conflictPreference") ?? "") ?? .google
        containerID = defaults.string(forKey: "icloudContainerID") ?? ""
        autoCheckUpdates = defaults.bool(forKey: "autoCheckUpdates")
        autoInstallUpdates = defaults.bool(forKey: "autoInstallUpdates")
        lastSync = defaults.object(forKey: "lastSync") as? Date
        lastSummary = defaults.string(forKey: "lastSummary") ?? ""
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
            if CNContactStore.authorizationStatus(for: .contacts) == .notDetermined {
                _ = await AppleContactsProvider.requestAccess()
            }
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
        if syncEnabled, isReady, !isSyncing, pendingDeletion == nil {
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

    var isReady: Bool { googleSignedIn && contactsAuthorized && !effectiveContainerID.isEmpty }

    var effectiveContainerID: String {
        if !containerID.isEmpty, containers.contains(where: { $0.id == containerID }) { return containerID }
        return AppleContactsProvider.defaultICloudContainerID() ?? ""
    }

    var setupProblem: String? {
        if !auth.isConfigured { return "Add your Google OAuth client in Settings → Accounts." }
        if !googleSignedIn { return "Sign in to Google in Settings → Accounts." }
        if !contactsAuthorized { return "Allow Contacts access in Settings → Accounts." }
        if effectiveContainerID.isEmpty { return "Turn on iCloud Contacts on this Mac, then pick it in Settings → Accounts." }
        return nil
    }

    func refreshAccountState() {
        googleSignedIn = auth.isSignedIn
        googleEmail = auth.email
        contactsAuthorized = AppleContactsProvider.isAuthorized
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
        pendingDeletion = nil
        let auth = self.auth
        let containerID = effectiveContainerID
        let notes = AppleContactsProvider.notesAccessible()
        let stateURL = self.stateURL(notes: notes)
        let backupsDir = self.backupsDir
        var options = SyncOptions()
        options.preference = preference
        options.allowMassDeletion = allowMassDeletion
        log("Sync started")

        Task.detached(priority: .utility) { [weak self] in
            let google = GoogleContactsProvider(auth: auth, syncNotes: notes)
            let icloud = AppleContactsProvider(containerID: containerID, syncNotes: notes)
            let engine = SyncEngine(google: google, icloud: icloud, stateURL: stateURL)
            engine.log = { line in Task { @MainActor in self?.log(line) } }
            engine.backup = { g, c in try Backups.write(google: g, icloud: c, to: backupsDir) }
            if !notes {
                Task { @MainActor in self?.log("Note: contact notes aren't accessible to apps on this macOS version, so notes are left untouched.") }
            }
            let result: Result<SyncReport, Error>
            do { result = .success(try await engine.sync(options: options)) } catch { result = .failure(error) }
            await MainActor.run { self?.finishSync(result) }
        }
    }

    private func finishSync(_ result: Result<SyncReport, Error>) {
        isSyncing = false
        switch result {
        case .success(let r):
            lastSync = Date()
            lastSummary = r.description
            counts = (r.googleCount, r.icloudCount)
            lastError = r.errors.isEmpty ? nil : "\(r.errors.count) contact(s) failed – see Activity."
            log("Sync finished: \(r.description)")
        case .failure(let e):
            if case let SyncError.massDeletion(g, c) = e {
                pendingDeletion = (g, c)
            }
            lastError = e.localizedDescription
            log("Sync failed: \(e.localizedDescription)")
        }
        if autoInstallUpdates, let u = availableUpdate, !installingUpdate {
            install(u)
        }
    }

    func confirmMassDeletion() {
        guard let p = pendingDeletion else { return }
        let alert = NSAlert()
        alert.messageText = "Allow deleting contacts?"
        alert.informativeText = "This sync will delete \(p.google) contact(s) from Google and \(p.icloud) from iCloud because they were deleted on the other side. A backup of both address books is saved first (Settings → General → Open Backups)."
        alert.addButton(withTitle: "Delete and Sync")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            pendingDeletion = nil
            syncNow(allowMassDeletion: true)
        }
    }

    func resetSyncLinks() {
        try? FileManager.default.removeItem(at: stateURL(notes: true))
        try? FileManager.default.removeItem(at: stateURL(notes: false))
        pendingDeletion = nil
        log("Sync links reset – the next sync will re-match contacts without deleting anything.")
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

enum Backups {
    /// Saves both address books (JSON with every synced field + vCards for easy re-import),
    /// keeping the 15 most recent backups.
    static func write(google: [RemoteContact], icloud: [RemoteContact], to dir: URL) throws {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let folder = dir.appendingPathComponent(f.string(from: Date()), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        struct Entry: Codable { var id: String; var contact: ContactRecord }
        try enc.encode(google.map { Entry(id: $0.id, contact: $0.record) }).write(to: folder.appendingPathComponent("google.json"))
        try enc.encode(icloud.map { Entry(id: $0.id, contact: $0.record) }).write(to: folder.appendingPathComponent("icloud.json"))
        try AppleContactsProvider.vCards(for: google.map(\.record)).write(to: folder.appendingPathComponent("google.vcf"))
        try AppleContactsProvider.vCards(for: icloud.map(\.record)).write(to: folder.appendingPathComponent("icloud.vcf"))

        let all = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let sorted = all.filter { $0.hasDirectoryPath }.sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in sorted.dropFirst(15) { try? FileManager.default.removeItem(at: old) }
    }
}
