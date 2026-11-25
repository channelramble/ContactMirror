import Foundation

public enum ConflictPreference: String, Codable, CaseIterable, Sendable {
    case google, icloud
}

public struct SyncOptions: Sendable {
    /// Which side wins when the same field was edited on both sides between two syncs.
    public var preference: ConflictPreference = .google
    /// Deleting more than max(minimum, fraction * size) items from one side pauses the
    /// sync until the user confirms - protects against an account returning an empty list.
    public var allowMassDeletion = false
    public var massDeletionMinimum = 10
    public var massDeletionFraction = 0.2
    public var dryRun = false
    public init() {}
}

public struct SyncReport: Sendable, CustomStringConvertible {
    public var googleCount = 0
    public var icloudCount = 0
    public var createdInGoogle = 0
    public var createdInICloud = 0
    public var updatedGoogle = 0
    public var updatedICloud = 0
    public var deletedFromGoogle = 0
    public var deletedFromICloud = 0
    public var photosCopied = 0
    public var matched = 0
    public var errors: [String] = []

    public init() {}

    public var changeCount: Int {
        createdInGoogle + createdInICloud + updatedGoogle + updatedICloud +
            deletedFromGoogle + deletedFromICloud + photosCopied
    }

    public static func + (a: SyncReport, b: SyncReport) -> SyncReport {
        var r = a
        r.googleCount += b.googleCount; r.icloudCount += b.icloudCount
        r.createdInGoogle += b.createdInGoogle; r.createdInICloud += b.createdInICloud
        r.updatedGoogle += b.updatedGoogle; r.updatedICloud += b.updatedICloud
        r.deletedFromGoogle += b.deletedFromGoogle; r.deletedFromICloud += b.deletedFromICloud
        r.photosCopied += b.photosCopied; r.matched += b.matched
        r.errors += b.errors
        return r
    }

    public var description: String {
        var parts: [String] = []
        func add(_ n: Int, _ s: String) { if n > 0 { parts.append("\(n) \(s)") } }
        add(createdInGoogle, "added to Google")
        add(createdInICloud, "added to iCloud")
        add(updatedGoogle, "updated in Google")
        add(updatedICloud, "updated in iCloud")
        add(deletedFromGoogle, "deleted from Google")
        add(deletedFromICloud, "deleted from iCloud")
        add(photosCopied, "photos copied")
        add(matched, "newly matched")
        if parts.isEmpty { parts.append("no changes") }
        if !errors.isEmpty { parts.append("\(errors.count) errors") }
        return parts.joined(separator: ", ")
    }
}

public enum SyncError: Error, LocalizedError {
    case massDeletion(what: String, google: Int, icloud: Int)

    public var errorDescription: String? {
        switch self {
        case let .massDeletion(what, g, c):
            return "Paused for safety: syncing \(what) would delete \(g) item(s) from Google and \(c) from iCloud. Review and confirm in the menu."
        }
    }
}

/// Two-way, state-based sync of one collection (an address book, a calendar, a task list)
/// between Google and iCloud. After a successful run both sides hold the same items.
public final class SyncEngine<R: SyncableRecord> {
    public let google: any RecordProvider<R>
    public let icloud: any RecordProvider<R>
    public let stateURL: URL
    /// Human-readable name of what is being synced, e.g. "contacts" or "calendar “Work”".
    public var what: String
    public var log: (String) -> Void = { _ in }
    /// Called with the untouched contents of both sides before anything is changed.
    public var backup: (([RemoteItem<R>], [RemoteItem<R>]) throws -> Void)?

    public init(google: any RecordProvider<R>, icloud: any RecordProvider<R>, stateURL: URL, what: String = "contacts") {
        self.google = google
        self.icloud = icloud
        self.stateURL = stateURL
        self.what = what
    }

    enum PhotoMove { case none, googleToICloud, icloudToGoogle }

    struct Item {
        var pair: PairState<R>?
        var g: RemoteItem<R>?
        var c: RemoteItem<R>?
        var target: R?
        var writeG = false
        var writeC = false
        var deleteG = false
        var deleteC = false
        var photo: PhotoMove = .none
        var isNewMatch = false
        /// Leave the pair exactly as it is this round.
        var hold = false

        var hasWork: Bool {
            if hold { return false }
            return pair == nil || deleteG || deleteC || writeG || writeC || photo != .none || g == nil || c == nil
        }
    }

    public func resetState() throws {
        try SyncState<R>().save(to: stateURL)
    }

    @discardableResult
    public func sync(options: SyncOptions = SyncOptions()) async throws -> SyncReport {
        var report = SyncReport()
        let state = SyncState<R>.load(from: stateURL)

        let gList = try await google.fetchAll()
        let cList = try await icloud.fetchAll()
        log("\(what.prefix(1).uppercased() + what.dropFirst()): Google \(gList.count), iCloud \(cList.count)")

        let items = plan(state: state, gList: gList, cList: cList, preference: options.preference)

        // Safety valve
        let delG = items.filter(\.deleteG).count
        let delC = items.filter(\.deleteC).count
        func tooMany(_ n: Int, of total: Int) -> Bool {
            n > max(options.massDeletionMinimum, Int(Double(total) * options.massDeletionFraction))
        }
        if !options.allowMassDeletion && (tooMany(delG, of: gList.count) || tooMany(delC, of: cList.count)) {
            throw SyncError.massDeletion(what: what, google: delG, icloud: delC)
        }

        let work = items.filter(\.hasWork)
        if options.dryRun {
            for item in work { tally(item, into: &report) }
            report.googleCount = gList.count + report.createdInGoogle - report.deletedFromGoogle
            report.icloudCount = cList.count + report.createdInICloud - report.deletedFromICloud
            return report
        }

        if !work.isEmpty, let backup {
            do { try backup(gList, cList) } catch {
                log("Backup failed, not syncing \(what): \(error.localizedDescription)")
                throw error
            }
        }

        var newPairs: [PairState<R>] = []
        var consecutiveErrors = 0
        var aborted = false

        for (index, item) in items.enumerated() {
            if aborted {
                // Not attempted: keep the old link untouched so pending changes are retried.
                if let p = item.pair { newPairs.append(p) }
                continue
            }
            if !item.hasWork {
                if let p = item.pair { newPairs.append(refreshed(p, item: item)) }
                continue
            }
            do {
                if let result = try await execute(item, report: &report) {
                    newPairs.append(result)
                }
                consecutiveErrors = 0
            } catch {
                let name = (item.target ?? item.g?.record ?? item.c?.record)?.displayName ?? "item"
                let msg = "\(name): \(error.localizedDescription)"
                log("Error – \(msg)")
                report.errors.append(msg)
                if let p = item.pair { newPairs.append(p) }
                consecutiveErrors += 1
                if consecutiveErrors >= 15 {
                    log("Too many consecutive errors, stopping this sync early.")
                    aborted = true
                }
            }
            if index % 25 == 24 {
                // Checkpoint so a crash mid-way never loses track of what was created.
                var cp = SyncState<R>()
                cp.pairs = newPairs + items[(index + 1)...].compactMap(\.pair)
                try? cp.save(to: stateURL)
            }
        }

        var newState = SyncState<R>()
        newState.pairs = newPairs
        try newState.save(to: stateURL)

        report.googleCount = gList.count + report.createdInGoogle - report.deletedFromGoogle
        report.icloudCount = cList.count + report.createdInICloud - report.deletedFromICloud
        return report
    }

    /// An existing pair with nothing to do: just record fresh fingerprints.
    private func refreshed(_ p: PairState<R>, item: Item) -> PairState<R> {
        guard let g = item.g, let c = item.c else { return p }
        var p = p
        p.googleHash = g.record.fingerprint
        p.icloudHash = c.record.fingerprint
        p.googlePhotoKey = g.photoKey
        p.icloudPhotoKey = c.photoKey
        if let t = item.target { p.base = t }
        return p
    }

    private func tally(_ item: Item, into r: inout SyncReport) {
        if item.deleteG { r.deletedFromGoogle += 1; return }
        if item.deleteC { r.deletedFromICloud += 1; return }
        if item.g == nil { r.createdInGoogle += 1 } else if item.writeG { r.updatedGoogle += 1 }
        if item.c == nil { r.createdInICloud += 1 } else if item.writeC { r.updatedICloud += 1 }
        if item.photo != .none { r.photosCopied += 1 }
        if item.isNewMatch { r.matched += 1 }
    }

    private func execute(_ item: Item, report: inout SyncReport) async throws -> PairState<R>? {
        if item.deleteG, let g = item.g {
            log("Deleting \"\(g.record.displayName)\" from Google (deleted in iCloud)")
            try await google.delete(g)
            report.deletedFromGoogle += 1
            return nil
        }
        if item.deleteC, let c = item.c {
            log("Deleting \"\(c.record.displayName)\" from iCloud (deleted in Google)")
            try await icloud.delete(c)
            report.deletedFromICloud += 1
            return nil
        }
        guard let target = item.target ?? item.g?.record ?? item.c?.record else { return item.pair }

        var g = item.g
        var c = item.c
        if let existing = g {
            if item.writeG {
                log("Updating \"\(target.displayName)\" in Google")
                g = try await google.update(existing, to: target)
                report.updatedGoogle += 1
            }
        } else {
            log("Adding \"\(target.displayName)\" to Google")
            g = try await google.create(target)
            report.createdInGoogle += 1
        }
        if let existing = c {
            if item.writeC {
                log("Updating \"\(target.displayName)\" in iCloud")
                c = try await icloud.update(existing, to: target)
                report.updatedICloud += 1
            }
        } else {
            log("Adding \"\(target.displayName)\" to iCloud")
            c = try await icloud.create(target)
            report.createdInICloud += 1
        }
        guard var g, var c else { return item.pair }
        if item.isNewMatch { report.matched += 1 }

        var pair = PairState<R>(
            googleID: g.id, icloudID: c.id,
            googleHash: g.record.fingerprint, icloudHash: c.record.fingerprint,
            googlePhotoKey: g.photoKey, icloudPhotoKey: c.photoKey,
            base: target.normalized(),
            lastSynced: Date()
        )

        switch item.photo {
        case .none:
            break
        case .googleToICloud:
            do {
                let data = g.photoKey.isEmpty ? nil : try await google.photoData(for: g)
                c = try await icloud.setPhoto(data, for: c)
                report.photosCopied += 1
            } catch {
                // Leave photo keys at their old values so the copy is retried next time.
                pair.googlePhotoKey = item.pair?.googlePhotoKey ?? ""
                pair.icloudPhotoKey = item.pair?.icloudPhotoKey ?? c.photoKey
                report.errors.append("\(target.displayName) photo: \(error.localizedDescription)")
                log("Photo copy failed for \"\(target.displayName)\": \(error.localizedDescription)")
                return pair
            }
        case .icloudToGoogle:
            do {
                let data = c.photoKey.isEmpty ? nil : try await icloud.photoData(for: c)
                g = try await google.setPhoto(data, for: g)
                report.photosCopied += 1
            } catch {
                pair.googlePhotoKey = item.pair?.googlePhotoKey ?? g.photoKey
                pair.icloudPhotoKey = item.pair?.icloudPhotoKey ?? ""
                report.errors.append("\(target.displayName) photo: \(error.localizedDescription)")
                log("Photo copy failed for \"\(target.displayName)\": \(error.localizedDescription)")
                return pair
            }
        }
        pair.googlePhotoKey = g.photoKey
        pair.icloudPhotoKey = c.photoKey
        pair.googleHash = g.record.fingerprint
        pair.icloudHash = c.record.fingerprint
        return pair
    }

    // MARK: Planning

    func plan(state: SyncState<R>, gList: [RemoteItem<R>], cList: [RemoteItem<R>], preference: ConflictPreference) -> [Item] {
        let preferG = preference == .google
        var gByID: [String: RemoteItem<R>] = [:]
        for g in gList { gByID[g.id] = g }
        var cByID: [String: RemoteItem<R>] = [:]
        for c in cList { cByID[c.id] = c }

        var usedG = Set<String>(), usedC = Set<String>()
        var items: [Item] = []
        var unpairedG: [RemoteItem<R>] = []
        var unpairedC: [RemoteItem<R>] = []

        for pair in state.pairs {
            guard !usedG.contains(pair.googleID), !usedC.contains(pair.icloudID) else { continue }
            let g = gByID[pair.googleID]
            let c = cByID[pair.icloudID]
            if g != nil { usedG.insert(pair.googleID) }
            if c != nil { usedC.insert(pair.icloudID) }

            let recentlyWritten = pair.lastSynced.map { Date().timeIntervalSince($0) < 15 * 60 } ?? false
            if (g == nil) != (c == nil) && recentlyWritten {
                items.append(Item(pair: pair, g: g, c: c, hold: true))
                continue
            }

            switch (g, c) {
            case (nil, nil):
                continue
            case let (g?, nil):
                let unchanged = g.record.fingerprint == pair.googleHash && g.photoKey == pair.googlePhotoKey
                if !google.isSafeToDelete(g) {
                    items.append(Item(pair: pair, g: g, hold: true))
                } else if unchanged && !g.readOnly {
                    items.append(Item(pair: pair, g: g, deleteG: true))
                } else {
                    unpairedG.append(g) // edited after being deleted in iCloud (or can't be deleted): keep it
                }
            case let (nil, c?):
                let unchanged = c.record.fingerprint == pair.icloudHash && c.photoKey == pair.icloudPhotoKey
                if !icloud.isSafeToDelete(c) {
                    items.append(Item(pair: pair, c: c, hold: true))
                } else if unchanged && !c.readOnly {
                    items.append(Item(pair: pair, c: c, deleteC: true))
                } else {
                    unpairedC.append(c)
                }
            case let (g?, c?):
                var item = Item(pair: pair, g: g, c: c)
                let gChanged = g.record.fingerprint != pair.googleHash
                let cChanged = c.record.fingerprint != pair.icloudHash
                if g.readOnly || c.readOnly {
                    // One side can't be edited: keep the other side equal to it.
                    if gChanged || cChanged {
                        item.target = g.readOnly ? g.record : c.record
                    }
                } else {
                    switch (gChanged, cChanged) {
                    case (false, false):
                        // Neither side changed since they were reconciled; any remaining difference is
                        // just how each provider represents the data, so writing would loop forever.
                        break
                    case (true, false): item.target = g.record
                    case (false, true): item.target = c.record
                    case (true, true):
                        item.target = R.merge3(base: pair.base, a: g.record, b: c.record, preferA: preferG)
                    }
                }
                if let t = item.target {
                    item.writeG = !g.readOnly && t != g.record
                    item.writeC = !c.readOnly && t != c.record
                }
                let gp = g.photoKey != pair.googlePhotoKey
                let cp = c.photoKey != pair.icloudPhotoKey
                switch (gp, cp) {
                case (true, false): item.photo = .googleToICloud
                case (false, true): item.photo = .icloudToGoogle
                case (true, true): item.photo = preferG ? .googleToICloud : .icloudToGoogle
                case (false, false): break
                }
                if g.readOnly && item.photo == .icloudToGoogle { item.photo = .googleToICloud }
                items.append(item)
            }
        }

        unpairedG += gList.filter { !usedG.contains($0.id) }
        unpairedC += cList.filter { !usedC.contains($0.id) }

        // Link items that exist on both sides but aren't linked yet (first sync, or after reset).
        // A key only links when it identifies exactly one unlinked item on each side.
        var cTaken = Set<Int>()
        let gKeys = unpairedG.map(\.record.matchKeys)
        let cKeys = unpairedC.map(\.record.matchKeys)
        let tiers = max(gKeys.map(\.count).max() ?? 0, cKeys.map(\.count).max() ?? 0)
        var cIndex: [[String: [Int]]] = Array(repeating: [:], count: tiers)
        var gCount: [[String: Int]] = Array(repeating: [:], count: tiers)
        for (i, keys) in cKeys.enumerated() {
            for (t, tier) in keys.enumerated() { for k in Set(tier) { cIndex[t][k, default: []].append(i) } }
        }
        for keys in gKeys {
            for (t, tier) in keys.enumerated() { for k in Set(tier) { gCount[t][k, default: 0] += 1 } }
        }
        func findMatch(_ gi: Int) -> Int? {
            for (t, tier) in gKeys[gi].enumerated() {
                for k in tier where gCount[t][k] == 1 {
                    if let list = cIndex[t][k], list.count == 1, !cTaken.contains(list[0]) { return list[0] }
                }
            }
            return nil
        }

        for (gi, g) in unpairedG.enumerated() {
            if let i = findMatch(gi) {
                cTaken.insert(i)
                let c = unpairedC[i]
                let target: R
                if g.readOnly { target = g.record }
                else if preferG { target = R.union(primary: g.record, secondary: c.record) }
                else { target = R.union(primary: c.record, secondary: g.record) }
                var item = Item(g: g, c: c, target: target, isNewMatch: true)
                item.writeG = !g.readOnly && target != g.record
                item.writeC = target != c.record
                if !g.photoKey.isEmpty && c.photoKey.isEmpty { item.photo = .googleToICloud }
                if g.photoKey.isEmpty && !c.photoKey.isEmpty && !g.readOnly { item.photo = .icloudToGoogle }
                items.append(item)
            } else {
                items.append(Item(g: g, target: g.record, photo: g.photoKey.isEmpty ? .none : .googleToICloud))
            }
        }
        for (i, c) in unpairedC.enumerated() where !cTaken.contains(i) {
            items.append(Item(c: c, target: c.record, photo: c.photoKey.isEmpty ? .none : .icloudToGoogle))
        }
        return items
    }
}
