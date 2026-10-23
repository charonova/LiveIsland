import Foundation
import LiveIslandCore
import os

private let log = Logger(subsystem: "com.aissam.liveisland", category: "accounts")

/// LiveIsland's switch for Codex accounts. Codex keeps its login in `~/.codex/auth.json`, a
/// file only the user can read; LiveIsland keeps each account's copy the same way, in its own
/// folder, and puts the chosen one in place. Codex refuses to save a refreshed login over a
/// different account's file, so a running session can't undo a switch; sessions already
/// running keep their account until restarted. Nothing here runs unless the user turned it on.
enum CodexLogins {
    enum Failure: LocalizedError {
        case notLoggedIn
        case notSaved(String)
        case notApplied
        case overwritten

        var errorDescription: String? {
            switch self {
            case .notLoggedIn: return "Codex isn't logged in on this Mac."
            case .notSaved(let email): return "LiveIsland has no saved login for \(email). Log in to it once with codex login."
            case .notApplied: return "The switch didn't take; nothing was changed."
            case .overwritten: return "Codex replaced the login while switching. Try again."
            }
        }
    }

    static var authURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json")
    }

    private static var storeURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LiveIsland/codex-logins", isDirectory: true)
    }

    /// The account Codex is logged in to, and its login exactly as written.
    static func active() -> (identity: ClaudeAccountIdentity, auth: Data)? {
        guard let auth = try? Data(contentsOf: authURL), let identity = CodexLogin.identity(in: auth) else { return nil }
        return (identity, auth)
    }

    /// Keeps the active account's current login, so LiveIsland can switch back to it.
    static func saveActive() throws -> ClaudeAccountIdentity? {
        guard let current = active() else { return nil }
        try store(current.auth, for: current.identity.key)
        return current.identity
    }

    static func switchTo(_ key: String) throws -> ClaudeAccountIdentity {
        guard let current = active() else { throw Failure.notLoggedIn }
        if current.identity.key == key { return current.identity }
        // Codex replaces the login when it refreshes it, and only the newest one keeps working.
        try store(current.auth, for: current.identity.key)
        guard let saved = try? Data(contentsOf: file(for: key)) else {
            throw Failure.notSaved(key.components(separatedBy: "|").first ?? key)
        }
        guard let identity = CodexLogin.identity(in: saved), identity.key == key else { throw Failure.notApplied }
        try write(saved, to: authURL)
        // A refresh that read the old file just before can still write after us: check.
        Thread.sleep(forTimeInterval: 1)
        guard active()?.identity.key == key else { throw Failure.overwritten }
        log.notice("Switched Codex to another saved account")
        return identity
    }

    static func forget(_ key: String) {
        try? FileManager.default.removeItem(at: file(for: key))
    }

    // MARK: -

    private static func file(for key: String) -> URL {
        // Keys hold an email and a workspace id; keep the name to safe characters.
        let name = key.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || "@.-_".unicodeScalars.contains($0) ? String($0) : "_" }.joined()
        return storeURL.appendingPathComponent(name + ".json")
    }

    private static func store(_ auth: Data, for key: String) throws {
        let url = file(for: key)
        if (try? Data(contentsOf: url)) == auth { return }
        try FileManager.default.createDirectory(at: storeURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try write(auth, to: url)
    }

    /// A private temporary file renamed over the target: never half-written, never readable
    /// by anyone else.
    private static func write(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).liveisland-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw Failure.notApplied
        }
        guard rename(temporary.path, url.path) == 0 else {
            try? FileManager.default.removeItem(at: temporary)
            throw Failure.notApplied
        }
    }
}
