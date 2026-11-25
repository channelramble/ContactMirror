import AppKit
import SwiftUI
import ContactMirrorCore

@main
struct ContactMirrorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
                .environmentObject(model)
        } label: {
            Image(systemName: menuIcon)
        }
        .menuBarExtraStyle(.menu)
    }

    private var menuIcon: String {
        if model.isSyncing { return "arrow.triangle.2.circlepath" }
        if model.lastError != nil || model.pendingDeletion != nil { return "person.crop.circle.badge.exclamationmark" }
        return "person.2.circle"
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            AppModel.shared.start()
            // First launch, or nothing configured yet: show settings so the user can set it up.
            if AppModel.shared.setupProblem != nil || AppModel.shared.previewMode {
                SettingsOpener.open()
            }
            if let dir = ProcessInfo.processInfo.environment["CONTACTMIRROR_SNAPSHOT_DIR"] {
                await SettingsOpener.snapshotAllTabs(to: URL(fileURLWithPath: dir))
                NSApp.terminate(nil)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

/// The settings window is managed with AppKit so it can be opened from anywhere
/// (menu, first launch) without SwiftUI auto-opening it on every login.
@MainActor
enum SettingsOpener {
    private static var window: NSWindow?

    static func open(tab: SettingsTab? = nil) {
        if let tab { SettingsTabState.shared.tab = tab }
        if window == nil {
            let host = NSHostingController(rootView: SettingsView()
                .environmentObject(AppModel.shared)
                .environmentObject(SettingsTabState.shared)
                .frame(minWidth: 600, minHeight: 520))
            let w = NSWindow(contentViewController: host)
            w.title = "ContactMirror Settings"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.isReleasedWhenClosed = false
            w.setContentSize(NSSize(width: 640, height: 560))
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Renders each settings tab to a PNG (for README screenshots).
    static func snapshotAllTabs(to dir: URL) async {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tabs: [(SettingsTab, String)] = [(.general, "general"), (.accounts, "accounts"), (.updates, "updates"), (.activity, "activity")]
        for (tab, name) in tabs {
            open(tab: tab)
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard let view = window?.contentView?.superview ?? window?.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
        }
    }
}

struct MenuContent: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Group {
            Text(statusLine)
            if let counts = model.counts {
                Text("Contacts: Google \(counts.google) · iCloud \(counts.icloud)")
            }
            if let err = model.lastError {
                Text("⚠︎ " + err).lineLimit(3)
            }
            Divider()
            Button(model.isSyncing ? "Syncing…" : "Sync Now") { model.syncNow() }
                .disabled(model.isSyncing)
                .keyboardShortcut("s")
            if model.pendingDeletion != nil {
                Button("Review Paused Deletions…") { model.confirmMassDeletion() }
            }
            if let update = model.availableUpdate {
                Button("Install Update \(update.version)") { model.install(update) }
                    .disabled(model.installingUpdate)
            }
            Divider()
            Button("Settings…") { showSettings() }
                .keyboardShortcut(",")
            Button("Check for Updates…") {
                Task { await model.checkForUpdates(userInitiated: true) }
                showSettings(tab: .updates)
            }
            Divider()
            Button("Quit ContactMirror") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
    }

    private var statusLine: String {
        if model.isSyncing { return "Syncing…" }
        if let p = model.setupProblem { return "Setup needed: \(p)" }
        guard let last = model.lastSync else { return "Not synced yet" }
        let f = DateFormatter()
        f.doesRelativeDateFormatting = true
        f.dateStyle = .short
        f.timeStyle = .short
        var s = "Last sync: \(f.string(from: last))"
        if !model.syncEnabled { s += " (paused)" }
        return s
    }

    private func showSettings(tab: SettingsTab? = nil) {
        SettingsOpener.open(tab: tab)
    }
}
