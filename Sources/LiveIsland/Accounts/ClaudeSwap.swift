import AppKit
import LiveIslandCore
import os

private let log = Logger(subsystem: "com.aissam.liveisland", category: "claude-swap")

/// claude-swap (`cswap`) inside LiveIsland: installing and updating it, its accounts and
/// settings, every command it has, and its automatic switching, kept running while it's on.
/// claude-swap holds the logins and does the switching; LiveIsland runs it and shows what it
/// says. Every command and its output goes to `entries`, the console in Settings.
@MainActor
final class ClaudeSwapController: ObservableObject {
    struct Entry: Identifiable, Equatable {
        enum Kind: Equatable { case command, event, note }
        let id = UUID()
        let at: Date
        let kind: Kind
        /// "$ cswap list --json", or what an event said.
        var title: String
        var output = ""
        var exitCode: Int32?
        var isError = false
        var isRunning = false
        /// The event's kind ("switch", "poll"…), for events.
        var event: String?
    }

    enum Auto: Equatable {
        case off
        case running(since: Date)
        /// It stopped on its own; LiveIsland starts it again at `at`.
        case restarting(at: Date, why: String)
    }

    @Published private(set) var executable: String?
    @Published private(set) var version: String?
    @Published private(set) var newerVersion: String?
    /// nil until claude-swap has answered (or when it isn't installed).
    @Published private(set) var accounts: [ClaudeSwapAccount]?
    @Published private(set) var settings: [ClaudeSwapSetting] = []
    @Published private(set) var entries: [Entry] = []
    /// What's happening right now ("Installing claude-swap…"), for the buttons to wait on.
    @Published private(set) var busy: String?
    @Published private(set) var auto: Auto = .off
    @Published private(set) var lastEvent: (summary: String, at: Date)?
    /// Signing in a new account and adding it, step by step.
    @Published private(set) var adding: String?
    /// claude-swap's own menu bar service, which can switch too.
    @Published private(set) var menuBarServiceInstalled = false
    @Published private(set) var hasLegacyLogins = false
    @Published var consoleInput = ""
    @Published var newAccountName = ""
    /// Show `poll` and `no-switch` events in the console too.
    @Published var showChecks = false

    /// Automatic switching, by `cswap auto`, while LiveIsland runs. Off until turned on.
    @Published var autoSwitch: Bool {
        didSet {
            guard autoSwitch != oldValue else { return }
            UserDefaults.standard.set(autoSwitch, forKey: Self.autoKey)
            autoSwitch ? startAuto() : stopAuto()
        }
    }

    var onAccounts: (([ClaudeSwapAccount]?) -> Void)?
    var onNotableEvent: ((ClaudeSwapEvent) -> Void)?

    private static let autoKey = "claudeSwapAuto"
    private var autoProcess: Process?
    private var autoBuffer = Data()
    private var autoFailures = 0
    private var restartWork: DispatchWorkItem?
    private var refreshTimer: Timer?
    private var stopping = false
    /// Asked for more often while an accounts page is open.
    var isVisible = false {
        didSet { if isVisible && !oldValue { Task { await refresh() } } }
    }

    init() {
        autoSwitch = UserDefaults.standard.bool(forKey: Self.autoKey)
    }

    func start() {
        locate()
        Task {
            await ClaudeCLI.loadShellPath()
            await refreshVersion()
            await refresh()
            await loadSettings()
            await checkLegacyLogins()
            // Only once it's there: a Mac without it has nothing to start yet.
            if autoSwitch, executable != nil { startAuto() }
        }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // claude-swap asks Anthropic for every account's usage: once a minute while
                // someone looks, every five minutes otherwise.
                self.minutes += 1
                if self.isVisible || self.minutes % 5 == 0 { Task { await self.refresh() } }
            }
        }
    }

    private var minutes = 0

    func stop() {
        refreshTimer?.invalidate()
        stopping = true
        stopAuto()
    }

    // MARK: - Finding and installing

    private func locate() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var candidates = ["\(home)/.local/bin/cswap", "/opt/homebrew/bin/cswap", "/usr/local/bin/cswap"]
        // A stand-in is the only one looked at, so a missing one tests a Mac without cswap.
        if let standIn = ProcessInfo.processInfo.environment["LIVEISLAND_CSWAP"] { candidates = [standIn] }
        executable = candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
        menuBarServiceInstalled = FileManager.default.fileExists(atPath: "\(home)/Library/LaunchAgents/com.cswap.menubar.plist")
    }

    /// Everything a new Mac needs, in one go: uv when neither uv nor pipx is there (its own
    /// installer, or Homebrew's), then claude-swap, then the account Claude Code uses now.
    func install() async {
        guard busy == nil else { return }
        defer { busy = nil }
        var uv = PythonTools.find("uv")
        let pipx = PythonTools.find("pipx")
        if uv == nil, pipx == nil {
            busy = "Installing uv…"
            _ = await run("/bin/sh", ["-c", PythonTools.uvInstall], title: "install uv (docs.astral.sh/uv)", timeout: 300)
            uv = PythonTools.find("uv")
            if uv == nil, let brew = PythonTools.find("brew") {
                _ = await run(brew, ["install", "uv"], title: "brew install uv", timeout: 900)
                uv = PythonTools.find("uv")
            }
        }
        busy = "Installing claude-swap…"
        if let uv {
            _ = await run(uv, ["tool", "install", "claude-swap"], title: "uv tool install claude-swap", timeout: 900)
        } else if let pipx {
            _ = await run(pipx, ["install", "claude-swap"], title: "pipx install claude-swap", timeout: 900)
        } else {
            note("uv couldn't be installed (see above). Check the internet connection and try again, or install uv from docs.astral.sh/uv.", error: true)
            return
        }
        locate()
        guard executable != nil else {
            note("claude-swap didn't install: see the output above.", error: true)
            return
        }
        await refreshVersion()
        await refresh()
        await loadSettings()
        await addCurrentIfNone()
        if autoSwitch { startAuto() }
    }

    /// The last step of setting up: the account Claude Code is signed in to, when claude-swap has none.
    private func addCurrentIfNone() async {
        guard accounts?.isEmpty == true else { return }
        guard let current = ClaudeLogins.active() else {
            note("claude-swap is ready. Sign in to Claude Code (claude, then /login), or add an account below.")
            return
        }
        busy = "Adding \(current.identity.email)…"
        _ = await cswap(["add"])
        await refresh()
        if accounts?.isEmpty == false { note("Set up: claude-swap has \(current.identity.email). Add your other accounts below.") }
    }

    func upgrade() async {
        guard busy == nil, executable != nil else { return }
        busy = "Updating claude-swap…"
        defer { busy = nil }
        let wasRunning = autoProcess != nil
        if wasRunning { stopAuto() }
        let before = version
        let result = await cswap(["upgrade"], timeout: 900)
        newerVersion = nil
        await refreshVersion()
        await refresh()
        // Say plainly whether it worked: the button comes back if claude-swap still offers a newer version.
        if result.status != 0 {
            note("The update didn't finish (exit \(result.status)): see its output above.", error: true)
        } else if version == before {
            note("claude-swap is still \(version ?? "the same version") after the update." + (newerVersion.map { " It still offers \($0): try again later, or run uv tool upgrade claude-swap in Terminal." } ?? ""), error: newerVersion != nil)
        } else {
            note("Updated claude-swap from \(before ?? "?") to \(version ?? "?").")
        }
        if wasRunning && autoSwitch { startAuto() }
    }

    private func refreshVersion() async {
        guard executable != nil else { version = nil; return }
        let result = await cswap(["--version"], quiet: true)
        version = ClaudeSwapCommand.version(from: result.text)
    }

    // MARK: - Accounts and settings

    func refresh() async {
        locate()
        guard executable != nil else {
            accounts = nil
            onAccounts?(nil)
            return
        }
        let result = await cswap(["list", "--json"], quiet: true)
        if let found = ClaudeSwapCommand.newerVersion(in: result.text) { newerVersion = found }
        guard let list = ClaudeSwapJSON.accounts(from: result.output) else {
            if result.status != 0 { log.error("cswap list failed: \(result.text, privacy: .public)") }
            return
        }
        accounts = list
        onAccounts?(list)
    }

    func loadSettings() async {
        guard executable != nil else { return }
        let result = await cswap(["config", "list", "--json"], quiet: true)
        if let parsed = ClaudeSwapSetting.parse(result.output) { settings = parsed }
    }

    func setting(_ key: String) -> ClaudeSwapSetting? { settings.first { $0.key == key } }

    /// `cswap config set KEY VALUE`, or `unset` for an empty value. Auto restarts to pick it up.
    func setSetting(_ key: String, _ value: String) async {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        _ = await cswap(trimmed.isEmpty ? ["config", "unset", key] : ["config", "set", key, trimmed])
        await loadSettings()
        restartAutoIfRunning()
    }

    func switchTo(_ number: Int) async { await act(["switch", String(number), "--json"]) }
    func switchToBest() async { await act(["switch", "--strategy", "best", "--json"]) }
    func setEnabled(_ number: Int, _ enabled: Bool) async { await act([enabled ? "enable" : "disable", String(number)]) }
    func remove(_ number: Int) async { await act(["remove", String(number)]) }
    func move(_ number: Int, to slot: Int) async { await act(["move", String(number), String(slot)]) }
    func addCurrent() async { await act(["add"]) }

    func setThreshold(_ number: Int, _ percent: String) async {
        let value = percent.trimmingCharacters(in: .whitespaces)
        await act(value.isEmpty ? ["threshold", String(number), "--unset"] : ["threshold", String(number), value])
    }

    func setAlias(_ number: Int, _ alias: String) async {
        let value = alias.trimmingCharacters(in: .whitespaces)
        await act(value.isEmpty ? ["alias", String(number), "--unset"] : ["alias", String(number), value])
    }

    private func act(_ arguments: [String]) async {
        guard busy == nil else { return }
        busy = "cswap \(arguments.first ?? "")…"
        _ = await cswap(arguments)
        busy = nil
        await refresh()
    }

    /// A command typed in the console, run without a shell.
    func runConsole() async {
        guard let arguments = ClaudeSwapCommand.arguments(consoleInput) else {
            note("A quote is left open.", error: true)
            return
        }
        guard !arguments.isEmpty else { return }
        if ClaudeSwapCommand.needsTerminal(arguments) {
            note("“cswap \(arguments.joined(separator: " "))” needs a terminal (or runs until stopped). Automatic switching runs from the switch above; the dashboard opens with “Open in Terminal”.", error: true)
            return
        }
        consoleInput = ""
        _ = await cswap(arguments, timeout: 300)
        await refresh()
        if arguments.first == "config" { await loadSettings() }
    }

    /// The full-screen dashboard, in Terminal.
    func openDashboard() {
        guard let executable else { return }
        openInTerminal("\(Self.quoted(executable))", name: "claude-swap dashboard")
    }

    func clearConsole() { entries.removeAll() }

    // MARK: - Adding an account

    /// Signs a new account in with Claude Code's own sign-in, in a folder of its own (so the
    /// account Claude Code uses now stays as it is), then adds it to claude-swap. Don't sign
    /// that folder out afterwards: claude-swap holds the same login, and signing out revokes it.
    func addAccount() {
        let name = newAccountName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, adding == nil else { return }
        var slug = String(name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" })
        if slug.isEmpty { slug = "account" }
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude-accounts")
        var directory = root.appendingPathComponent(slug)
        var suffix = 2
        while FileManager.default.fileExists(atPath: directory.path) {
            directory = root.appendingPathComponent("\(slug)-\(suffix)")
            suffix += 1
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            note("Couldn't create \(directory.path): \(error.localizedDescription)", error: true)
            return
        }
        newAccountName = ""
        adding = "Sign in to “\(name)” in the browser that Terminal opens…"
        note("Signing in a new account in \((directory.path as NSString).abbreviatingWithTildeInPath)")
        openInTerminal("""
        unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN
        export CLAUDE_CONFIG_DIR=\(Self.quoted(directory.path))
        echo "Sign in to the Claude account “\(name)” for LiveIsland and claude-swap."
        claude auth login
        echo
        echo "Done: LiveIsland adds it to claude-swap now. You can close this window."
        """, name: "add \(slug)")
        Task { await waitForSignIn(in: directory.path, name: name) }
    }

    private func waitForSignIn(in directory: String, name: String) async {
        defer { adding = nil }
        for _ in 0..<100 {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let claude = ClaudeCLI.executable else { continue }
            let status = await run(claude, ["auth", "status", "--json"], title: nil, environment: ["CLAUDE_CONFIG_DIR": directory], quiet: true)
            guard let object = try? JSONSerialization.jsonObject(with: status.output) as? [String: Any],
                  object["loggedIn"] as? Bool == true
            else { continue }
            adding = "Adding “\(name)” to claude-swap…"
            _ = await cswap(["add"], environment: ["CLAUDE_CONFIG_DIR": directory])
            await refresh()
            return
        }
        note("“\(name)” wasn't signed in within five minutes. Try Add Account again.", error: true)
    }

    // MARK: - Automatic switching

    private func startAuto() {
        guard autoProcess == nil, let executable else {
            if executable == nil { note("Install claude-swap first.", error: true) }
            return
        }
        restartWork?.cancel()
        stopping = false
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["auto", "--json"]
        process.environment = environment()
        process.standardInput = FileHandle.nullDevice
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { handle.readabilityHandler = nil; return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.receiveAuto(chunk) } }
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { handle.readabilityHandler = nil; return }
            let text = String(decoding: chunk, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // The update notice repeats on every start: the Update button says it once.
                    if let newer = ClaudeSwapCommand.newerVersion(in: text) {
                        self?.newerVersion = newer
                        let rest = text.split(whereSeparator: \.isNewline).filter { !$0.contains("newer version of claude-swap") }
                        guard !rest.isEmpty else { return }
                        self?.note("cswap auto: " + rest.joined(separator: "\n"))
                    } else {
                        self?.note("cswap auto: \(text)")
                    }
                }
            }
        }
        process.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.autoEnded(process, status) } }
        }
        do {
            try process.run()
            autoProcess = process
            auto = .running(since: Date())
            append(Entry(at: Date(), kind: .command, title: "$ cswap auto --json", output: "Automatic switching is on: claude-swap checks every account and switches before one runs out.", isRunning: true))
        } catch {
            note("Couldn't start automatic switching: \(error.localizedDescription)", error: true)
        }
    }

    private func stopAuto() {
        restartWork?.cancel()
        restartWork = nil
        guard let process = autoProcess else { auto = .off; return }
        autoProcess = nil
        process.terminate()
        auto = .off
    }

    private func restartAutoIfRunning() {
        guard autoProcess != nil else { return }
        stopAuto()
        startAuto()
    }

    private func receiveAuto(_ chunk: Data) {
        autoBuffer.append(chunk)
        while let newline = autoBuffer.firstIndex(of: 0x0A) {
            let line = autoBuffer[autoBuffer.startIndex..<newline]
            autoBuffer.removeSubrange(autoBuffer.startIndex...newline)
            guard let parsed = ClaudeSwapEvent.parse(Data(line)) else { continue }
            autoFailures = 0
            let event = parsed.event
            lastEvent = (event.summary, parsed.at ?? Date())
            var isError = false
            if case .error = event { isError = true }
            if case .allExhausted = event { isError = true }
            append(Entry(at: parsed.at ?? Date(), kind: .event, title: event.summary, isError: isError, event: event.kind))
            if case .switched(_, _, _, false) = event { Task { await refresh() } }
            if event.isNotable { onNotableEvent?(event) }
        }
    }

    private func autoEnded(_ process: Process, _ status: Int32) {
        // A switch turned off, LiveIsland quitting, or the loop stopped for a restart isn't a
        // failure. A stopped loop can end after its replacement started: only the one running
        // now counts, or the replacement would be forgotten and keep switching on its own.
        guard process === autoProcess else { return }
        autoProcess = nil
        if let index = entries.lastIndex(where: { $0.title == "$ cswap auto --json" && $0.isRunning }) {
            entries[index].isRunning = false
            entries[index].exitCode = status
        }
        guard autoSwitch, !stopping else { auto = .off; return }
        // It shouldn't stop on its own: start it again, waiting longer each time.
        autoFailures += 1
        let delays: [TimeInterval] = [5, 15, 60, 300]
        let delay = delays[min(autoFailures - 1, delays.count - 1)]
        let why = "cswap auto stopped (code \(status))"
        auto = .restarting(at: Date().addingTimeInterval(delay), why: why)
        note("\(why): starting it again in \(Int(delay)) s", error: true)
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.startAuto() } }
        restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: - Earlier versions' logins

    /// Whether the Keychain still holds the login copies earlier LiveIsland versions made.
    /// Only the item's existence is asked, never its secret.
    func checkLegacyLogins() async {
        let result = await run("/usr/bin/security", ["find-generic-password", "-s", ClaudeLogins.legacyService], title: nil, quiet: true)
        hasLegacyLogins = result.status == 0
    }

    /// Deletes those copies, one item at a time, when the person asks.
    func deleteLegacyLogins() async {
        var deleted = 0
        while deleted < 50 {
            let result = await run("/usr/bin/security", ["delete-generic-password", "-s", ClaudeLogins.legacyService], title: nil, quiet: true)
            guard result.status == 0 else { break }
            deleted += 1
        }
        note("Deleted \(deleted) login cop\(deleted == 1 ? "y" : "ies") that earlier versions of LiveIsland kept in the Keychain.")
        await checkLegacyLogins()
    }

    // MARK: - Running commands

    struct Result {
        var status: Int32
        var output: Data
        /// Everything it printed, stdout and stderr, for people.
        var text: String
    }

    @discardableResult
    func cswap(_ arguments: [String], environment extra: [String: String] = [:], quiet: Bool = false,
               timeout: TimeInterval = 120) async -> Result {
        guard let executable else {
            note("claude-swap isn't installed.", error: true)
            return Result(status: -1, output: Data(), text: "")
        }
        return await run(executable, arguments, title: "cswap " + arguments.map(Self.shown).joined(separator: " "),
                         environment: extra, quiet: quiet, timeout: timeout)
    }

    /// Runs a program (never a shell), streaming its output into a console entry unless quiet;
    /// a quiet run is logged only when it fails.
    private func run(_ executable: String, _ arguments: [String], title: String?, environment extra: [String: String] = [:],
                     quiet: Bool = false, timeout: TimeInterval = 120) async -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment().merging(extra) { $1 }
        process.standardInput = FileHandle.nullDevice
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors

        let entryID = quiet ? nil : append(Entry(at: Date(), kind: .command, title: "$ " + (title ?? executable), isRunning: true))
        let collected = Collected()
        let stream: @Sendable (Data, Bool) -> Void = { [weak self] chunk, isOutput in
            collected.add(chunk, isOutput: isOutput)
            guard let entryID else { return }
            let text = String(decoding: chunk, as: UTF8.self)
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.extend(entryID, with: text) } }
        }
        output.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil } else { stream(chunk, true) }
        }
        errors.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil } else { stream(chunk, false) }
        }
        let status: Int32 = await withCheckedContinuation { continuation in
            process.terminationHandler = { process in
                // Let the last output arrive.
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { continuation.resume(returning: process.terminationStatus) }
            }
            do {
                try process.run()
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if process.isRunning { process.terminate() } }
            } catch {
                collected.add(Data(error.localizedDescription.utf8), isOutput: false)
                continuation.resume(returning: -1)
            }
        }
        let result = Result(status: status, output: collected.output, text: collected.text)
        if let entryID {
            finish(entryID, status: status)
        } else if status != 0, let title {
            append(Entry(at: Date(), kind: .command, title: "$ " + title, output: result.text, exitCode: status, isError: true))
        }
        return result
    }

    /// claude-swap without colors or a pager, unbuffered so `auto` events arrive as they happen.
    private func environment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = ClaudeCLI.shellPath
        environment["NO_COLOR"] = "1"
        environment["TERM"] = "dumb"
        environment["PYTHONUNBUFFERED"] = "1"
        environment["COLUMNS"] = "120"
        environment.removeValue(forKey: "CLAUDE_CONFIG_DIR")
        return environment
    }

    // MARK: - The console

    @discardableResult
    private func append(_ entry: Entry) -> UUID {
        if entry.kind == .event, !showChecks, entry.event == "poll" || entry.event == "no-switch" || entry.event == "sleep" {
            return entry.id
        }
        entries.append(entry)
        if entries.count > 400 { entries.removeFirst(entries.count - 400) }
        return entry.id
    }

    private func extend(_ id: UUID, with text: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].output += text
        if entries[index].output.count > 60_000 { entries[index].output = String(entries[index].output.suffix(60_000)) }
    }

    private func finish(_ id: UUID, status: Int32) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].isRunning = false
        entries[index].exitCode = status
        entries[index].isError = status != 0
    }

    private func note(_ text: String, error: Bool = false) {
        append(Entry(at: Date(), kind: .note, title: text, isError: error))
    }

    private func openInTerminal(_ body: String, name: String) {
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("LiveIsland \(name).command")
        do {
            try ("#!/bin/zsh -l\n" + body + "\n").write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            NSWorkspace.shared.open(script)
        } catch {
            note("Couldn't open Terminal: \(error.localizedDescription)", error: true)
        }
    }

    private static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// How an argument reads in the console: quoted when it has spaces.
    private static func shown(_ argument: String) -> String {
        argument.contains(where: \.isWhitespace) || argument.isEmpty ? "\"\(argument)\"" : argument
    }
}

/// A process's output as it streams in, from the pipes' threads.
private final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var stdout = Data()
    private var all = Data()

    func add(_ chunk: Data, isOutput: Bool) {
        lock.lock()
        if isOutput { stdout.append(chunk) }
        all.append(chunk)
        lock.unlock()
    }

    var output: Data { lock.lock(); defer { lock.unlock() }; return stdout }
    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: all, as: UTF8.self) }
}
