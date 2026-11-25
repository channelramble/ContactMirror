import Foundation
import Security

public struct ReleaseInfo: Sendable, Equatable {
    public var version: String
    public var notes: String
    public var downloadURL: URL
    public var pageURL: URL?
}

public enum UpdateError: Error, LocalizedError {
    case noAsset
    case badSignature(String)
    case notWritable(String)
    case unzipFailed

    public var errorDescription: String? {
        switch self {
        case .noAsset: return "The latest release has no downloadable app."
        case .badSignature(let s): return "The downloaded update failed signature verification (\(s)). It was not installed."
        case .notWritable(let p): return "Can't replace the app at \(p). Move ContactMirror to /Applications and try again."
        case .unzipFailed: return "Couldn't unpack the update."
        }
    }
}

/// Self-updater backed by GitHub Releases. Each update must be signed with the same
/// certificate as the running app, otherwise it is refused.
public final class Updater: @unchecked Sendable {
    public let repo: String
    public init(repo: String) { self.repo = repo }

    public static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    public static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.trimmingCharacters(in: CharacterSet(charactersIn: "vV ")).split(separator: ".")
                .map { Int($0.prefix { $0.isNumber }) ?? 0 }
        }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    /// Returns the latest release if it is newer than the running version.
    public func checkForUpdate() async throws -> ReleaseInfo? {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("ContactMirror-Updater", forHTTPHeaderField: "User-Agent")
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { return nil }
        guard status == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String else {
            throw URLError(.badServerResponse)
        }
        guard Self.isNewer(tag, than: Self.currentVersion) else { return nil }
        let assets = json["assets"] as? [[String: Any]] ?? []
        guard let asset = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".zip") == true }),
              let urlString = asset["browser_download_url"] as? String,
              let url = URL(string: urlString) else { throw UpdateError.noAsset }
        let version = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        return ReleaseInfo(version: version, notes: json["body"] as? String ?? "", downloadURL: url,
                           pageURL: (json["html_url"] as? String).flatMap(URL.init(string:)))
    }

    /// Downloads, verifies and stages the update, then launches a helper that swaps the app
    /// bundle once this process quits. The caller should terminate the app right after.
    public func install(_ release: ReleaseInfo) async throws {
        let appURL = Bundle.main.bundleURL
        let parent = appURL.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            throw UpdateError.notWritable(appURL.path)
        }

        let (zipTemp, _) = try await URLSession.shared.download(from: release.downloadURL)
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("ContactMirrorUpdate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let zip = work.appendingPathComponent("update.zip")
        try FileManager.default.moveItem(at: zipTemp, to: zip)

        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", zip.path, work.path]
        try unzip.run()
        unzip.waitUntilExit()
        guard unzip.terminationStatus == 0,
              let newApp = try FileManager.default.contentsOfDirectory(at: work, includingPropertiesForKeys: nil)
                .first(where: { $0.pathExtension == "app" }) else { throw UpdateError.unzipFailed }

        try Self.verifySameSigner(newApp)

        // Stage next to the current app (same volume) so the final swap is a cheap rename.
        let staged = parent.appendingPathComponent(".ContactMirror-update-\(UUID().uuidString).app")
        try FileManager.default.moveItem(at: newApp, to: staged)
        try? FileManager.default.removeItem(at: work)

        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        while kill -0 \(pid) 2>/dev/null; do sleep 0.3; done
        OLD="$1"; NEW="$2"
        rm -rf "$OLD.old"
        if mv "$OLD" "$OLD.old" && mv "$NEW" "$OLD"; then rm -rf "$OLD.old"; else mv "$OLD.old" "$OLD"; rm -rf "$NEW"; fi
        /usr/bin/xattr -dr com.apple.quarantine "$OLD" 2>/dev/null
        /usr/bin/open "$OLD"
        """
        try Self.spawnDetached("/bin/sh", ["-c", script, "contactmirror-updater", appURL.path, staged.path])
    }

    /// Starts a process in its own session so it outlives this app when it quits.
    static func spawnDetached(_ path: String, _ args: [String]) throws {
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))
        let argv: [UnsafeMutablePointer<CChar>?] = ([path] + args).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, path, nil, &attr, argv, environ)
        guard rc == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(rc)) }
    }

    /// The update must satisfy the running app's designated requirement (same bundle ID,
    /// same signing certificate).
    static func verifySameSigner(_ url: URL) throws {
        var selfCode: SecCode?
        guard SecCodeCopySelf([], &selfCode) == errSecSuccess, let selfCode else {
            throw UpdateError.badSignature("can't read own signature")
        }
        var selfStatic: SecStaticCode?
        guard SecCodeCopyStaticCode(selfCode, [], &selfStatic) == errSecSuccess, let selfStatic else {
            throw UpdateError.badSignature("can't read own signature")
        }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(selfStatic, [], &requirement) == errSecSuccess, let requirement else {
            throw UpdateError.badSignature("running app is not signed")
        }
        var newCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &newCode) == errSecSuccess, let newCode else {
            throw UpdateError.badSignature("update is not signed")
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        let status = SecStaticCodeCheckValidity(newCode, flags, requirement)
        guard status == errSecSuccess else {
            throw UpdateError.badSignature("OSStatus \(status)")
        }
    }
}
