import AppKit
import LiveIslandCore
import os

private let log = Logger(subsystem: "com.aissam.liveisland", category: "profiles")

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

    /// The environment for running Claude Code on `profile`. It names the profile's directory,
    /// and drops every API key or token variable: those outrank the profile's login, and `-p`
    /// uses an API key without asking, which would bill it silently.
    static func environment(for profile: ClaudeProfile) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        for key in ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_PROFILE",
                    "CLAUDE_CONFIG_DIR", "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT"] {
            environment.removeValue(forKey: key)
        }
        environment["PATH"] = shellPath
        if let directory = profile.configDir { environment["CLAUDE_CONFIG_DIR"] = directory }
        return environment
    }

    /// Where Claude Code keeps this profile's conversations.
    static func projectsDirectory(for profile: ClaudeProfile) -> URL {
        let base = profile.configDir.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        return base.appendingPathComponent("projects")
    }
}

/// The person's Claude accounts for tasks, each a Claude Code configuration directory. The
/// first is plain `claude`'s own (`~/.claude`); others live in `~/.claude-accounts/<name>`
/// and sign in through Claude Code's own `claude auth login`. LiveIsland keeps only the list,
/// the email and plan Claude Code reports, and what it saw (out of usage, needs signing in).
@MainActor
final class ProfileStore: ObservableObject {
    @Published private(set) var profiles: [ClaudeProfile] = []
    /// The name typed for a new account (SwiftUI's @State needs Xcode, so it lives here).
    @Published var newName = ""

    static let accountsFolder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude-accounts")
    private var signInWatches: [String: Task<Void, Never>] = [:]
    private var activationObserver: NSObjectProtocol?
    private var lastRefresh = Date.distantPast
    private let file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("LiveIsland/automation/profiles.json")

    init() {
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([ClaudeProfile].self, from: data) {
            profiles = saved
        }
        if !profiles.contains(where: { $0.id == ClaudeProfile.mainID }) {
            profiles.insert(ClaudeProfile(id: ClaudeProfile.mainID, name: "Main", configDir: nil), at: 0)
        }
        // Coming back to LiveIsland (often from Terminal, after signing in): look again.
        activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, Date().timeIntervalSince(self.lastRefresh) > 30 else { return }
                Task { await self.refreshAll() }
            }
        }
    }

    func profile(_ id: String) -> ClaudeProfile? { profiles.first { $0.id == id } }

    func name(of id: String) -> String { profile(id)?.name ?? "an account" }

    /// Replaces what the task engine learned (out of usage, needs signing in).
    func update(_ next: [ClaudeProfile]) {
        guard next != profiles else { return }
        profiles = next
        save()
    }

    func setEnabled(_ id: String, _ enabled: Bool) {
        mutate(id) { $0.enabled = enabled }
    }

    func move(_ id: String, by offset: Int) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles = Ordering.move(profiles, from: index, by: offset)
        save()
    }

    /// A new account: its own Claude Code directory, sharing the person's settings, instructions,
    /// commands, skills and plugins with `~/.claude` so tasks behave the same on every account.
    /// Its login is its own, made in Terminal by Claude Code.
    func add() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        var slug = name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }.reduce("") { $0 + String($1) }
        if slug.isEmpty { slug = "account" }
        while profiles.contains(where: { $0.id == slug }) { slug += "-2" }
        let directory = Self.accountsFolder.appendingPathComponent(slug)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let shared = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
            for item in ["settings.json", "CLAUDE.md", "commands", "agents", "skills", "plugins"] {
                let source = shared.appendingPathComponent(item)
                let link = directory.appendingPathComponent(item)
                guard FileManager.default.fileExists(atPath: source.path),
                      (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == nil,
                      !FileManager.default.fileExists(atPath: link.path)
                else { continue }
                try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
            }
        } catch {
            log.error("Couldn't create the account folder: \(error.localizedDescription, privacy: .public)")
            return
        }
        let profile = ClaudeProfile(id: slug, name: name, configDir: directory.path, unusable: "Not signed in yet")
        profiles.append(profile)
        newName = ""
        save()
        signIn(profile)
    }

    /// Forgets an account (not Main). Its folder and its login stay where Claude Code keeps them.
    func remove(_ id: String) {
        guard id != ClaudeProfile.mainID else { return }
        profiles.removeAll { $0.id == id }
        save()
    }

    /// Opens Terminal on Claude Code's own sign-in for this account's directory.
    func signIn(_ profile: ClaudeProfile) {
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("LiveIsland sign in \(profile.id).command")
        let directory = profile.configDir.map { "export CLAUDE_CONFIG_DIR=\(Self.quoted($0))\n" } ?? "unset CLAUDE_CONFIG_DIR\n"
        let body = """
        #!/bin/zsh -l
        unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN
        \(directory)echo "Sign in to the Claude account for LiveIsland's account “\(profile.name)”."
        claude auth login
        echo
        echo "Done. You can close this window and go back to LiveIsland."

        """
        do {
            try body.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            NSWorkspace.shared.open(script)
            watchSignIn(profile.id)
        } catch {
            log.error("Couldn't open the sign-in: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Asks Claude Code who this account is signed in as (`claude auth status`): no secrets.
    func refresh(_ id: String) async {
        guard let profile = profile(id), let claude = ClaudeCLI.executable else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: claude)
        process.arguments = ["auth", "status", "--json"]
        process.environment = ClaudeCLI.environment(for: profile)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let data: Data? = await withCheckedContinuation { continuation in
            process.terminationHandler = { _ in continuation.resume(returning: pipe.fileHandleForReading.readDataToEndOfFile()) }
            do { try process.run() } catch { continuation.resume(returning: nil) }
        }
        guard let data, let status = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        mutate(id) { profile in
            if status["loggedIn"] as? Bool == true {
                profile.unusable = nil
                profile.email = status["email"] as? String
                profile.plan = (status["subscriptionType"] as? String).map { $0.capitalized }
            } else {
                profile.unusable = "Not signed in"
            }
        }
    }

    func refreshAll() async {
        lastRefresh = Date()
        for profile in profiles { await refresh(profile.id) }
    }

    /// While the person signs in in Terminal, check every few seconds, and stop once Claude Code
    /// reports a new login (or a different account) for this profile, or after five minutes.
    private func watchSignIn(_ id: String) {
        signInWatches[id]?.cancel()
        let before = profile(id).map { ($0.unusable, $0.email) }
        signInWatches[id] = Task { [weak self] in
            for _ in 0..<100 {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self, !Task.isCancelled else { return }
                await self.refresh(id)
                guard let now = self.profile(id) else { return }
                if now.unusable == nil, now.email != nil, before?.0 != nil || before?.1 != now.email {
                    log.notice("\(id, privacy: .public) is signed in")
                    self.signInWatches[id] = nil
                    return
                }
            }
        }
    }

    /// Another account in the list signed in as the same person: it adds nothing.
    func duplicate(of profile: ClaudeProfile) -> ClaudeProfile? {
        guard let email = profile.email else { return nil }
        return profiles.first { $0.id != profile.id && $0.email == email }
    }

    private func mutate(_ id: String, _ change: (inout ClaudeProfile) -> Void) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        change(&profiles[index])
        save()
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(profiles).write(to: file, options: .atomic)
        } catch {
            log.error("Couldn't save the accounts: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
