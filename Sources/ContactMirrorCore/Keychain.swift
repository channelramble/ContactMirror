import Foundation

/// Stores the Google client secret and refresh token in a file only the user can read
/// (~/Library/Application Support/ContactMirror/credentials.json, mode 0600).
///
/// The login Keychain isn't used: ContactMirror is signed with a self-signed certificate, so
/// macOS ties Keychain access to each exact build and would ask for the Mac password after
/// every self-update, blocking the always-on app until someone answers.
public enum Keychain {
    static let lock = NSLock()

    public static var fileURL: URL = {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ContactMirror", isDirectory: true)
            .appendingPathComponent("credentials.json")
    }()

    static func load() -> [String: String] {
        guard let d = try? Data(contentsOf: fileURL),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: String] else { return [:] }
        return obj
    }

    static func save(_ dict: [String: String]) {
        let fm = FileManager.default
        let dir = fileURL.deletingLastPathComponent()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let d = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]) else { return }
        let tmp = dir.appendingPathComponent(".credentials-\(UUID().uuidString)")
        fm.createFile(atPath: tmp.path, contents: d, attributes: [.posixPermissions: 0o600])
        _ = try? fm.replaceItemAt(fileURL, withItemAt: tmp)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    public static func set(_ value: String?, for account: String) {
        lock.withLock {
            var d = load()
            if let value, !value.isEmpty { d[account] = value } else { d[account] = nil }
            save(d)
        }
    }

    public static func get(_ account: String) -> String? {
        lock.withLock { load()[account] }
    }
}
