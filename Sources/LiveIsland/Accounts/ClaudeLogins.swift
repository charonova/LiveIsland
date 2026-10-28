import Foundation
import LiveIslandCore

/// Which account Claude Code is logged in to, read from `~/.claude.json`. Switching between
/// accounts is claude-swap's job; LiveIsland never reads or writes a login.
enum ClaudeLogins {
    static var configURL: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json") }

    /// The account Claude Code is logged in to, and its `oauthAccount` exactly as written.
    static func active() -> (identity: ClaudeAccountIdentity, raw: Data)? {
        guard let config = try? Data(contentsOf: configURL),
              let raw = ClaudeConfigFile.value(of: "oauthAccount", in: config),
              let identity = ClaudeAccountIdentity.parse(raw)
        else { return nil }
        return (identity, raw)
    }

    /// Earlier versions kept a copy of each account's login under this Keychain service.
    static let legacyService = "LiveIsland: Claude login"
}
