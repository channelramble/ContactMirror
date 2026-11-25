import Foundation

public enum ConflictPreference: String, Codable, CaseIterable, Sendable {
    case google, icloud
}

public struct SyncOptions: Sendable {
    /// Which side wins when the same field was edited on both sides between two syncs.
    public var preference: ConflictPreference = .google
    /// Deleting more than max(minimum, fraction * size) contacts from one side pauses the
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

    public var changeCount: Int {
        createdInGoogle + createdInICloud + updatedGoogle + updatedICloud +
            deletedFromGoogle + deletedFromICloud + photosCopied
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
    case massDeletion(google: Int, icloud: Int)

    public var errorDescription: String? {
        switch self {
        case let .massDeletion(g, c):
            return "Paused for safety: this sync would delete \(g) contact(s) from Google and \(c) from iCloud. Review and confirm in the menu."
        }
    }
}

/// Two-way, state-based sync between Google and iCloud. After a successful run both
/// address books contain the same contacts with the same synced fields.
public final class SyncEngine {
    public let google: ContactProvider
    public let icloud: ContactProvider
    public let stateURL: URL
    public var log: (String) -> Void = { _ in }
    /// Called with the untouched contents of both sides before anything is changed.
    public var backup: (([RemoteContact], [RemoteContact]) throws -> Void)?

    public init(google: ContactProvider, icloud: ContactProvider, stateURL: URL) {
        self.google = google
        self.icloud = icloud
        self.stateURL = stateURL
    }

    enum PhotoMove { case none, googleToICloud, icloudToGoogle }

    struct Item {
        var pair: PairState?
        var g: RemoteContact?
        var c: RemoteContact?
        var target: ContactRecord?
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
        try SyncState().save(to: stateURL)
    }

    @discardableResult
    public func sync(options: SyncOptions = SyncOptions()) async throws -> SyncReport {
        var report = SyncReport()
        let state = SyncState.load(from: stateURL)

        log("Fetching contacts from Google…")
        let gList = try await google.fetchAll()
        log("Fetching contacts from iCloud…")
        let cList = try await icloud.fetchAll()
        log("Google: \(gList.count) contacts, iCloud: \(cList.count) contacts")

        let items = plan(state: state, gList: gList, cList: cList, preference: options.preference)

        // Safety valve
        let delG = items.filter(\.deleteG).count
        let delC = items.filter(\.deleteC).count
        func tooMany(_ n: Int, of total: Int) -> Bool {
            n > max(options.massDeletionMinimum, Int(Double(total) * options.massDeletionFraction))
        }
        if !options.allowMassDeletion && (tooMany(delG, of: gList.count) || tooMany(delC, of: cList.count)) {
            throw SyncError.massDeletion(google: delG, icloud: delC)
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
                log("Backup failed, not syncing: \(error.localizedDescription)")
                throw error
            }
        }

        var newPairs: [PairState] = []
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
                let name = (item.target ?? item.g?.record ?? item.c?.record)?.displayName ?? "contact"
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
                var cp = SyncState()
                cp.pairs = newPairs + items[(index + 1)...].compactMap(\.pair)
                try? cp.save(to: stateURL)
            }
        }

        var newState = SyncState()
        newState.pairs = newPairs
        try newState.save(to: stateURL)

        report.googleCount = gList.count + report.createdInGoogle - report.deletedFromGoogle
        report.icloudCount = cList.count + report.createdInICloud - report.deletedFromICloud
        return report
    }

    /// An existing pair whose two sides are already identical: just record fresh fingerprints.
    private func refreshed(_ p: PairState, item: Item) -> PairState {
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

    private func execute(_ item: Item, report: inout SyncReport) async throws -> PairState? {
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

        var pair = PairState(
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

    func plan(state: SyncState, gList: [RemoteContact], cList: [RemoteContact], preference: ConflictPreference) -> [Item] {
        let preferG = preference == .google
        var gByID: [String: RemoteContact] = [:]
        for g in gList { gByID[g.id] = g }
        var cByID: [String: RemoteContact] = [:]
        for c in cList { cByID[c.id] = c }

        var usedG = Set<String>(), usedC = Set<String>()
        var items: [Item] = []
        var unpairedG: [RemoteContact] = []
        var unpairedC: [RemoteContact] = []

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
                if g.record.fingerprint == pair.googleHash && g.photoKey == pair.googlePhotoKey {
                    items.append(Item(pair: pair, g: g, deleteG: true))
                } else {
                    unpairedG.append(g) // edited in Google after being deleted in iCloud: keep it
                }
            case let (nil, c?):
                if c.record.fingerprint == pair.icloudHash && c.photoKey == pair.icloudPhotoKey {
                    items.append(Item(pair: pair, c: c, deleteC: true))
                } else {
                    unpairedC.append(c)
                }
            case let (g?, c?):
                var item = Item(pair: pair, g: g, c: c)
                let gChanged = g.record.fingerprint != pair.googleHash
                let cChanged = c.record.fingerprint != pair.icloudHash
                switch (gChanged, cChanged) {
                case (false, false):
                    // Neither side changed since they were reconciled; any remaining difference is
                    // just how each provider represents the data, so writing would loop forever.
                    break
                case (true, false): item.target = g.record
                case (false, true): item.target = c.record
                case (true, true):
                    item.target = ContactRecord.merge3(base: pair.base, a: g.record, b: c.record, preferA: preferG)
                }
                if let t = item.target {
                    item.writeG = t != g.record
                    item.writeC = t != c.record
                }
                let gp = g.photoKey != pair.googlePhotoKey
                let cp = c.photoKey != pair.icloudPhotoKey
                switch (gp, cp) {
                case (true, false): item.photo = .googleToICloud
                case (false, true): item.photo = .icloudToGoogle
                case (true, true): item.photo = preferG ? .googleToICloud : .icloudToGoogle
                case (false, false): break
                }
                items.append(item)
            }
        }

        unpairedG += gList.filter { !usedG.contains($0.id) }
        unpairedC += cList.filter { !usedC.contains($0.id) }

        // Match contacts that exist on both sides but aren't linked yet (first sync, or after reset).
        var cTaken = Set<Int>()
        var byEmail: [String: [Int]] = [:], byPhone: [String: [Int]] = [:], byName: [String: [Int]] = [:]
        for (i, c) in unpairedC.enumerated() {
            for e in c.record.emails { byEmail[e.value.lowercased(), default: []].append(i) }
            for p in c.record.phones {
                let k = Matching.phoneKey(p.value)
                if k.count >= 6 { byPhone[k, default: []].append(i) }
            }
            if let n = Matching.nameKey(c.record) { byName[n, default: []].append(i) }
        }
        var gNameCounts: [String: Int] = [:], gEmailCounts: [String: Int] = [:], gPhoneCounts: [String: Int] = [:]
        for g in unpairedG {
            if let n = Matching.nameKey(g.record) { gNameCounts[n, default: 0] += 1 }
            for e in Set(g.record.emails.map { $0.value.lowercased() }) { gEmailCounts[e, default: 0] += 1 }
            for k in Set(g.record.phones.map { Matching.phoneKey($0.value) }) { gPhoneCounts[k, default: 0] += 1 }
        }

        // Only link on keys that identify exactly one contact on each side, so two different
        // people sharing e.g. an office number are never merged.
        func unique(_ list: [Int]?) -> Int? {
            guard let list else { return nil }
            let distinct = Array(Set(list))
            return distinct.count == 1 && !cTaken.contains(distinct[0]) ? distinct[0] : nil
        }
        func findMatch(_ g: RemoteContact) -> Int? {
            for e in g.record.emails {
                let k = e.value.lowercased()
                if gEmailCounts[k] == 1, let i = unique(byEmail[k]) { return i }
            }
            for p in g.record.phones {
                let k = Matching.phoneKey(p.value)
                guard k.count >= 6 else { continue }
                if gPhoneCounts[k] == 1, let i = unique(byPhone[k]) { return i }
            }
            if let n = Matching.nameKey(g.record), gNameCounts[n] == 1,
               let list = byName[n], list.count == 1, !cTaken.contains(list[0]) {
                return list[0]
            }
            return nil
        }

        for g in unpairedG {
            if let i = findMatch(g) {
                cTaken.insert(i)
                let c = unpairedC[i]
                let target = preferG
                    ? ContactRecord.union(primary: g.record, secondary: c.record)
                    : ContactRecord.union(primary: c.record, secondary: g.record)
                var item = Item(g: g, c: c, target: target, isNewMatch: true)
                item.writeG = target != g.record
                item.writeC = target != c.record
                if !g.photoKey.isEmpty && c.photoKey.isEmpty { item.photo = .googleToICloud }
                if g.photoKey.isEmpty && !c.photoKey.isEmpty { item.photo = .icloudToGoogle }
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
