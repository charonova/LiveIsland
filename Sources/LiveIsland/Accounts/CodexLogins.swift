import Foundation
import LiveIslandCore

/// Who Codex is logged in as. Codex keeps its login in `~/.codex/auth.json`; ccswap holds each
/// account's login and switches them (`CodexSwapController`), so LiveIsland only reads who
/// the login belongs to, never its tokens.
enum CodexLogins {
    static var authURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json")
    }

    /// The account Codex is logged in to.
    static func active() -> (identity: ClaudeAccountIdentity, auth: Data)? {
        guard let auth = try? Data(contentsOf: authURL), let identity = CodexLogin.identity(in: auth) else { return nil }
        return (identity, auth)
    }
}
