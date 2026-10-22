import CryptoKit
import Foundation
import LiveIslandCore
import os

private let log = Logger(subsystem: "com.aissam.liveisland", category: "accounts")

/// LiveIsland's own account switch. Each account's Claude login is kept in the login
/// Keychain; switching puts another account's login into Claude Code's credential item (only
/// its Claude part: the same item holds the user's MCP logins) and its `oauthAccount` into
/// `~/.claude.json`, while holding Claude Code's own locks. Running sessions pick the new
/// login up within about 30 seconds. Nothing here runs unless the user turned it on.
enum ClaudeLogins {
    enum Failure: LocalizedError {
        case notLoggedIn
        case notSaved(String)
        case unreadableConfig
        case notApplied

        var errorDescription: String? {
            switch self {
            case .notLoggedIn: return "Claude Code isn't logged in on this Mac."
            case .notSaved(let email): return "LiveIsland has no saved login for \(email). Log in to it once with /login in Claude Code."
            case .unreadableConfig: return "Couldn't read Claude Code's settings (~/.claude.json)."
            case .notApplied: return "The switch didn't take; nothing was changed."
            }
        }
    }

    static let claudeService = "Claude Code-credentials"
    static let savedService = "LiveIsland: Claude login"
    /// Claude Code names its item after the macOS user.
    static var claudeAccount: String { ProcessInfo.processInfo.environment["USER"] ?? NSUserName() }
    static var configURL: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json") }

    /// The account Claude Code is logged in to, and its `oauthAccount` exactly as written.
    static func active() -> (identity: ClaudeAccountIdentity, raw: Data)? {
        guard let config = try? Data(contentsOf: configURL),
              let raw = ClaudeConfigFile.value(of: "oauthAccount", in: config),
              let identity = ClaudeAccountIdentity.parse(raw)
        else { return nil }
        return (identity, raw)
    }

    /// Keeps the active account's current login, so LiveIsland can switch back to it later.
    /// Skipped when the config names a different account before and after reading the login:
    /// a /login happened in between, and the two might not match.
    static func saveActive() throws -> (identity: ClaudeAccountIdentity, loginExpires: Date?)? {
        guard let before = active(), let credentials = try SecurityTool.read(service: claudeService, account: claudeAccount),
              let login = ClaudeLogin.extract(from: credentials), let after = active(), after.raw == before.raw
        else { return nil }
        try store(raw: before.raw, login: login, for: before.identity.key)
        return (before.identity, ClaudeLogin.expiry(of: login).login)
    }

    /// Makes `key` the account Claude Code uses. Returns who's logged in afterwards.
    static func switchTo(_ key: String) throws -> ClaudeAccountIdentity {
        try ClaudeCodeLocks.withAll {
            guard let config = try? Data(contentsOf: configURL) else { throw Failure.unreadableConfig }
            guard let credentials = try SecurityTool.read(service: claudeService, account: claudeAccount) else { throw Failure.notLoggedIn }

            // Keep the outgoing account's newest login first: Claude Code replaces the login
            // whenever it refreshes it, and only the newest one keeps working.
            if let raw = ClaudeConfigFile.value(of: "oauthAccount", in: config), let current = ClaudeAccountIdentity.parse(raw),
               let login = ClaudeLogin.extract(from: credentials) {
                if current.key == key { return current }
                try store(raw: raw, login: login, for: current.key)
            }

            guard let saved = try load(key) else { throw Failure.notSaved(key.components(separatedBy: "|").first ?? key) }
            guard let identity = ClaudeAccountIdentity.parse(saved.raw),
                  let newCredentials = ClaudeLogin.replacing(in: credentials, with: saved.login),
                  let newConfig = ClaudeConfigFile.replacingValue(of: "oauthAccount", in: config, with: saved.raw)
            else { throw Failure.notApplied }

            try SecurityTool.write(newCredentials, service: claudeService, account: claudeAccount)
            do {
                try replaceConfig(with: newConfig)
            } catch {
                // Put the old login back, so the login and the config never disagree.
                try? SecurityTool.write(credentials, service: claudeService, account: claudeAccount)
                throw error
            }
            log.notice("Switched Claude Code to another saved account")
            return identity
        }
    }

    static func forget(_ key: String) {
        SecurityTool.delete(service: savedService, account: key)
        savedDigests[key] = nil
    }

    // MARK: - Saved logins

    /// What was last saved per account, so an unchanged login isn't written again.
    private nonisolated(unsafe) static var savedDigests: [String: SHA256.Digest] = [:]

    private static func store(raw: Data, login: [String: Any], for key: String) throws {
        let record: [String: Any] = ["oauthAccount": String(decoding: raw, as: UTF8.self), "claudeAiOauth": login]
        guard let data = ClaudeLogin.asciiJSON(record) else { throw Failure.notApplied }
        let digest = SHA256.hash(data: data)
        guard savedDigests[key] != digest else { return }
        try SecurityTool.write(data, service: savedService, account: key)
        savedDigests[key] = digest
    }

    private static func load(_ key: String) throws -> (raw: Data, login: [String: Any])? {
        guard let data = try SecurityTool.read(service: savedService, account: key),
              let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = record["oauthAccount"] as? String, let login = record["claudeAiOauth"] as? [String: Any]
        else { return nil }
        return (Data(raw.utf8), login)
    }

    /// Writes ~/.claude.json the way an editor would: a private temporary file renamed over
    /// the original, so the file is never half-written or readable by others.
    private static func replaceConfig(with data: Data) throws {
        let directory = configURL.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(".claude.json.liveisland-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw Failure.notApplied
        }
        guard rename(temporary.path, configURL.path) == 0 else {
            try? FileManager.default.removeItem(at: temporary)
            throw Failure.notApplied
        }
    }
}
