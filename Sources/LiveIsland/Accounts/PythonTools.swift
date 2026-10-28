import Foundation

/// The tools that install claude-swap and ccswap: uv (their own advice), pipx, and Homebrew.
enum PythonTools {
    static func find(_ name: String) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.local/bin/\(name)", "/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// What will install a tool, for the set-up card: "uv", "pipx", or nil when uv comes first.
    static var installer: String? { find("uv") != nil ? "uv" : find("pipx") != nil ? "pipx" : nil }

    /// uv's own installer (docs.astral.sh/uv): uv goes in ~/.local/bin, and the shell's profile
    /// stays as it is (LiveIsland finds uv there by itself).
    static let uvInstall = "curl -LsSf https://astral.sh/uv/install.sh | env UV_NO_MODIFY_PATH=1 sh"
}
