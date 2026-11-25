import AppKit
import SwiftUI
import ContactMirrorCore

enum SettingsTab: Hashable { case general, accounts, updates, activity }

final class SettingsTabState: ObservableObject {
    static let shared = SettingsTabState()
    @Published var tab: SettingsTab = .general
}

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var tabState: SettingsTabState

    var body: some View {
        TabView(selection: $tabState.tab) {
            GeneralTab().tabItem { Label("General", systemImage: "gearshape") }.tag(SettingsTab.general)
            AccountsTab().tabItem { Label("Accounts", systemImage: "person.2") }.tag(SettingsTab.accounts)
            UpdatesTab().tabItem { Label("Updates", systemImage: "arrow.down.circle") }.tag(SettingsTab.updates)
            ActivityTab().tabItem { Label("Activity", systemImage: "list.bullet.rectangle") }.tag(SettingsTab.activity)
        }
        .padding()
        .onAppear {
            model.refreshAccountState()
            model.refreshLoginItem()
            if model.setupProblem != nil && tabState.tab == .general { tabState.tab = .accounts }
        }
    }
}

// MARK: - General

struct GeneralTab: View {
    @EnvironmentObject var model: AppModel
    @State private var confirmReset = false

    var body: some View {
        Form {
            Section("Status") {
                LabeledContent("Last sync") {
                    Text(model.lastSync.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Never")
                }
                if !model.lastSummary.isEmpty {
                    LabeledContent("Result") { Text(model.lastSummary).multilineTextAlignment(.trailing).font(.callout) }
                }
                if let next = model.nextSyncDate, !model.isSyncing {
                    LabeledContent("Next sync") { Text(next.formatted(date: .omitted, time: .shortened)) }
                }
                if let err = model.lastError {
                    Text(err).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button(model.isSyncing ? "Syncing…" : "Sync Now") { model.syncNow() }
                        .disabled(model.isSyncing)
                    if model.pendingDeletion != nil {
                        Button("Review Paused Deletions…") { model.confirmMassDeletion() }
                    }
                    if model.isSyncing { ProgressView().controlSize(.small) }
                }
            }

            Section("What to sync") {
                Toggle("Contacts  (Google Contacts ↔ iCloud Contacts)", isOn: $model.syncContacts)
                Toggle("Calendars  (Google Calendar ↔ iCloud Calendar)", isOn: $model.syncCalendars)
                Toggle("Tasks  (Google Tasks ↔ iCloud Reminders)", isOn: $model.syncTasks)
                Text("Calendars and task lists are paired by name (your main Google calendar and task list pair with the default iCloud ones); any that exist on only one side are created on the other. Events are synced from one year back to two years ahead.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Schedule") {
                Toggle("Sync automatically", isOn: $model.syncEnabled)
                HStack {
                    Text("Sync every")
                    TextField("", value: $model.syncIntervalMinutes, format: .number)
                        .frame(width: 60)
                        .multilineTextAlignment(.trailing)
                    Stepper("", value: $model.syncIntervalMinutes, in: 1...1440, step: 5).labelsHidden()
                    Text(model.syncIntervalMinutes == 1 ? "minute" : "minutes")
                    Spacer()
                    Menu("Presets") {
                        ForEach([5, 15, 30, 60, 120, 360, 720, 1440], id: \.self) { m in
                            Button(m < 60 ? "\(m) minutes" : "\(m / 60) hour\(m == 60 ? "" : "s")") {
                                model.syncIntervalMinutes = m
                            }
                        }
                    }
                    .fixedSize()
                }
                Toggle("Open ContactMirror at login", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }))
            }

            Section("Conflicts") {
                Picker("If the same field is edited on both sides", selection: $model.preference) {
                    Text("Google wins").tag(ConflictPreference.google)
                    Text("iCloud wins").tag(ConflictPreference.icloud)
                }
                Text("Edits to different fields are always combined. Deletions on either side are mirrored to the other; large batches of deletions pause for your confirmation.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Safety") {
                HStack {
                    Button("Open Backups Folder") {
                        try? FileManager.default.createDirectory(at: model.backupsDir, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(model.backupsDir)
                    }
                    Button("Reset Sync Links…") { confirmReset = true }
                }
                Text("A backup of both address books (vCard + JSON) is saved before every sync that changes anything. Resetting links makes the next sync re-match contacts by email, phone and name without deleting anything.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Reset sync links?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) { model.resetSyncLinks() }
        } message: {
            Text("ContactMirror will forget which contacts are linked. Nothing is deleted; the next sync matches and merges them again.")
        }
    }
}

// MARK: - Accounts

struct AccountsTab: View {
    @EnvironmentObject var model: AppModel
    @State private var clientID = ""
    @State private var clientSecret = ""
    @State private var saved = false

    var body: some View {
        Form {
            Section {
                if model.auth.isConfigured && !editingClient {
                    LabeledContent("OAuth client") {
                        Text(String(model.auth.clientID.prefix(24)) + "…").foregroundStyle(.secondary)
                    }
                    Button("Change OAuth Client…") { editingClient = true }
                } else {
                    TextField("Client ID", text: $clientID, prompt: Text("1234-abc.apps.googleusercontent.com"))
                    SecureField("Client secret", text: $clientSecret, prompt: Text("GOCSPX-…"))
                    HStack {
                        Button("Save") {
                            model.saveGoogleClient(id: clientID, secret: clientSecret)
                            editingClient = false
                        }
                        .disabled(clientID.isEmpty || clientSecret.isEmpty)
                        Link("How do I get these?", destination: AppModel.setupGuideURL)
                    }
                }
                if model.googleSignedIn {
                    LabeledContent("Signed in as") { Text(model.googleEmail ?? "Google account") }
                    if let p = model.setupProblem, p.contains("Sign in to Google again") {
                        Text(p).foregroundStyle(.orange)
                        Button("Sign in Again") { model.signInToGoogle() }
                    }
                    Button("Sign Out") { model.signOutOfGoogle() }
                } else {
                    HStack {
                        Button(model.signingIn ? "Waiting for browser…" : "Sign in with Google") { model.signInToGoogle() }
                            .disabled(!model.auth.isConfigured || model.signingIn)
                        if model.signingIn { ProgressView().controlSize(.small) }
                    }
                }
            } header: {
                Text("Google Contacts")
            } footer: {
                Text("Google requires every app that edits contacts to have its own OAuth client. The README walks you through creating one in about five minutes; your credentials and tokens stay on this Mac, readable only by your account.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                if model.contactsAuthorized {
                    LabeledContent("Contacts access") { Text("Allowed").foregroundStyle(.green) }
                    if model.containers.isEmpty {
                        Text("No contact accounts found. Turn on Contacts in System Settings → Apple Account → iCloud.")
                            .foregroundStyle(.orange)
                    } else {
                        Picker("Account to sync", selection: $model.containerID) {
                            ForEach(model.containers) { c in Text(c.name).tag(c.id) }
                        }
                    }
                } else {
                    LabeledContent("Contacts access") { Text("Not allowed").foregroundStyle(.red) }
                    Button("Allow Access to Contacts") { model.requestContactsAccess() }
                }
                permissionRow("Calendar access", granted: model.calendarsAuthorized, enabled: model.syncCalendars) {
                    model.requestEventKit(.event)
                }
                permissionRow("Reminders access", granted: model.remindersAuthorized, enabled: model.syncTasks) {
                    model.requestEventKit(.reminder)
                }
            } header: {
                Text("iCloud")
            } footer: {
                Text("ContactMirror edits the iCloud account in this Mac's Contacts, Calendar and Reminders apps, and macOS syncs it to iCloud and your other devices. For contacts, pick the account named “iCloud”.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            clientID = model.auth.clientID
            clientSecret = model.auth.clientSecret
        }
    }

    @State private var editingClient = false

    @ViewBuilder
    func permissionRow(_ title: String, granted: Bool, enabled: Bool, request: @escaping () -> Void) -> some View {
        if enabled {
            if granted {
                LabeledContent(title) { Text("Allowed").foregroundStyle(.green) }
            } else {
                LabeledContent(title) {
                    Button("Allow…", action: request)
                }
            }
        }
    }
}

// MARK: - Updates

struct UpdatesTab: View {
    @EnvironmentObject var model: AppModel
    @State private var checking = false

    var body: some View {
        Form {
            Section("ContactMirror \(Updater.currentVersion)") {
                Toggle("Check for updates automatically", isOn: $model.autoCheckUpdates)
                Toggle("Install updates automatically", isOn: $model.autoInstallUpdates)
                    .disabled(!model.autoCheckUpdates)
                HStack {
                    Button("Check Now") {
                        checking = true
                        Task { await model.checkForUpdates(userInitiated: true); checking = false }
                    }
                    .disabled(checking || model.installingUpdate)
                    if checking || model.installingUpdate { ProgressView().controlSize(.small) }
                    Text(model.updateStatus).foregroundStyle(.secondary)
                }
            }
            if let u = model.availableUpdate {
                Section("Version \(u.version)") {
                    ScrollView {
                        Text(u.notes.isEmpty ? "No release notes." : u.notes)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 160)
                    HStack {
                        Button("Install and Relaunch") { model.install(u) }
                            .disabled(model.installingUpdate)
                        if let page = u.pageURL { Link("View on GitHub", destination: page) }
                    }
                }
            }
            Section {
                Link("Source code and releases on GitHub", destination: URL(string: "https://github.com/\(AppModel.repo)")!)
            } footer: {
                Text("Updates come from this project's GitHub releases and are only installed if they're signed with the same certificate as the app you're running.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Activity

struct ActivityTab: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(model.logLines.enumerated()), id: \.offset) { i, line in
                            Text(line).font(.system(.caption, design: .monospaced)).textSelection(.enabled).id(i)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .onChange(of: model.logLines.count) { n in
                    if n > 0 { proxy.scrollTo(n - 1, anchor: .bottom) }
                }
            }
            HStack {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.logLines.joined(separator: "\n"), forType: .string)
                }
                Button("Open Full Log") { NSWorkspace.shared.open(model.logURL) }
                Spacer()
            }
        }
        .padding()
    }
}
