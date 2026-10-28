import Foundation

/// Running Claude Code the way the person would from Terminal.
enum ClaudeCLI {
    /// `claude`, wherever its installer put it. `LIVEISLAND_CLAUDE` points at a stand-in, for
    /// testing tasks without spending real usage.
    static var executable: String? {
        if let standIn = ProcessInfo.processInfo.environment["LIVEISLAND_CLAUDE"], FileManager.default.isExecutableFile(atPath: standIn) {
            return standIn
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The PATH of the person's login shell, so a task finds the same tools (git, swift, node…)
    /// it would in Terminal. An app opened from the Dock only gets the system's.
    private(set) static var shellPath = "\(FileManager.default.homeDirectoryForCurrentUser.path)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    static func loadShellPath() async {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard let data = try? await ProcessRunner.output(shell, ["-l", "-c", "printf %s \"$PATH\""]),
              let path = String(data: data, encoding: .utf8), path.contains("/usr/bin")
        else { return }
        shellPath = path
    }

    /// The environment for running Claude Code: the account it uses now (claude-swap moves it),
    /// and no API key or token variable, since those outrank the login and `-p` uses an API key
    /// without asking, which would bill it silently.
    static func environment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        for key in ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_PROFILE",
                    "CLAUDE_CONFIG_DIR", "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT"] {
            environment.removeValue(forKey: key)
        }
        environment["PATH"] = shellPath
        return environment
    }

    /// Where Claude Code keeps conversations.
    static var projectsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
    }
}
