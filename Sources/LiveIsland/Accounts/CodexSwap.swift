import AppKit
import LiveIslandCore
import os

private let log = Logger(subsystem: "com.aissam.liveisland", category: "ccswap")

/// ccswap (`ccswap codex …`) inside LiveIsland, for Codex accounts only: installing and
/// updating it, its accounts and settings, its Codex commands, and its automatic switching,
/// kept running while it's on. ccswap holds the Codex logins and switches them; LiveIsland
/// runs it and shows what it says. Every command and its output goes to `entries`.
///
/// ccswap is a fork of claude-swap and keeps its data where claude-swap does
/// (`~/.claude-swap-backup` on a Mac). LiveIsland runs it with a home of its own, so its data
/// lives in LiveIsland's folder and claude-swap's stays as it is; `CODEX_HOME` still points
/// at Codex's real folder, where ccswap puts the login in use.
@MainActor
final class CodexSwapController: ObservableObject {
    typealias Entry = ClaudeSwapController.Entry
    typealias Auto = ClaudeSwapController.Auto

    @Published private(set) var executable: String?
    @Published private(set) var version: String?
    @Published private(set) var newerVersion: String?
    /// nil until ccswap has answered (or when it isn't installed).
    @Published private(set) var accounts: [CodexSwapAccount]?
    @Published private(set) var settings: [ClaudeSwapSetting] = []
    @Published private(set) var entries: [Entry] = []
    /// What's happening right now ("Installing ccswap…"), for the buttons to wait on.
    @Published private(set) var busy: String?
    @Published private(set) var auto: Auto = .off
    @Published private(set) var lastEvent: (summary: String, at: Date)?
    /// Signing in a new account and adding it, step by step.
    @Published private(set) var adding: String?
    /// Logins earlier versions of LiveIsland kept to switch Codex themselves.
    @Published private(set) var legacyLogins = 0
    @Published var consoleInput = ""
    @Published var newAccountName = ""
    /// Show `poll` and `no-switch` events in the console too.
    @Published var showChecks = false

    /// Automatic switching, by `ccswap codex auto`, while LiveIsland runs. Off until turned on.
    @Published var autoSwitch: Bool {
        didSet {
            guard autoSwitch != oldValue else { return }
            UserDefaults.standard.set(autoSwitch, forKey: Self.autoKey)
            autoSwitch ? startAuto() : stopAuto()
        }
    }

    var onAccounts: (([CodexSwapAccount]?) -> Void)?
    var onNotableEvent: ((CodexSwapEvent) -> Void)?

    private static let autoKey = "codexSwapAuto"
    private static let autoTitle = "$ ccswap codex auto --json"
    private var autoProcess: Process?
    private var autoBuffer = Data()
    private var autoFailures = 0
    private var restartWork: DispatchWorkItem?
    private var refreshTimer: Timer?
    private var stopping = false
    private var minutes = 0
    /// Asked for more often while an accounts page is open.
    var isVisible = false {
        didSet { if isVisible && !oldValue { Task { await refresh() } } }
    }

    init() {
        autoSwitch = UserDefaults.standard.bool(forKey: Self.autoKey)
    }

    /// ccswap's home: its data goes in `.claude-swap-backup` here, never in the real one.
    static var home: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LiveIsland/ccswap", isDirectory: true)
    }

    /// Codex's own folder, where the login in use lives.
    static var codexHome: String {
        ProcessInfo.processInfo.environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path
    }

    func start() {
        locate()
        Task {
            await ClaudeCLI.loadShellPath()
            await refreshVersion()
            await refresh()
            await loadSettings()
            countLegacyLogins()
            await endOrphanedLoops()
            // Only once it's there: a Mac without it has nothing to start yet.
            if autoSwitch, executable != nil { startAuto() }
        }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // ccswap asks OpenAI for every account's usage: once a minute while someone
                // looks, every five minutes otherwise.
                self.minutes += 1
                if self.isVisible || self.minutes % 5 == 0 { Task { await self.refresh() } }
            }
        }
    }

    func stop() {
        refreshTimer?.invalidate()
        stopping = true
        stopAuto()
    }

    // MARK: - Finding and installing

    private func locate() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var candidates = ["\(home)/.local/bin/ccswap", "/opt/homebrew/bin/ccswap", "/usr/local/bin/ccswap"]
        // A stand-in is the only one looked at, so a missing one tests a Mac without ccswap.
        if let standIn = ProcessInfo.processInfo.environment["LIVEISLAND_CCSWAP"] { candidates = [standIn] }
        executable = candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func tool(_ names: [String]) -> String? {
        names.lazy.compactMap(PythonTools.find).first
    }

    /// Everything a new Mac needs, in one go: uv when neither uv nor pipx is there (its own
    /// installer, or Homebrew's), then ccswap next to claude-swap, then the account Codex uses now.
    func install() async {
        guard busy == nil else { return }
        defer { busy = nil }
        var uv = Self.tool(["uv"])
        let pipx = Self.tool(["pipx"])
        if uv == nil, pipx == nil {
            busy = "Installing uv…"
            _ = await run("/bin/sh", ["-c", PythonTools.uvInstall], title: "install uv (docs.astral.sh/uv)", environment: installEnvironment(), timeout: 300)
            uv = Self.tool(["uv"])
            if uv == nil, let brew = Self.tool(["brew"]) {
                _ = await run(brew, ["install", "uv"], title: "brew install uv", environment: installEnvironment(), timeout: 900)
                uv = Self.tool(["uv"])
            }
        }
        busy = "Installing ccswap…"
        if let uv {
            _ = await run(uv, ["tool", "install", "ccswap"], title: "uv tool install ccswap", environment: installEnvironment(), timeout: 900)
        } else if let pipx {
            _ = await run(pipx, ["install", "ccswap"], title: "pipx install ccswap", environment: installEnvironment(), timeout: 900)
        } else {
            note("uv couldn't be installed (see above). Check the internet connection and try again, or install uv from docs.astral.sh/uv.", error: true)
            return
        }
        locate()
        guard executable != nil else {
            note("ccswap didn't install: see the output above.", error: true)
            return
        }
        await refreshVersion()
        await refresh()
        await loadSettings()
        await addCurrentIfNone()
        if autoSwitch { startAuto() }
    }

    /// The last step of setting up: the account Codex is signed in to, when ccswap has none.
    private func addCurrentIfNone() async {
        guard accounts?.isEmpty == true else { return }
        guard let current = CodexLogins.active() else {
            note("ccswap is ready. Sign in to Codex (codex login), or add an account below.")
            return
        }
        busy = "Adding \(current.identity.email)…"
        _ = await ccswap(["codex", "add"])
        await refresh()
        if accounts?.isEmpty == false { note("Set up: ccswap has \(current.identity.email). Add your other accounts below.") }
    }

    /// With the tool that installed it, not `ccswap upgrade`: that would run ccswap with the
    /// real home.
    func upgrade() async {
        guard busy == nil, executable != nil else { return }
        busy = "Updating ccswap…"
        defer { busy = nil }
        let wasRunning = autoProcess != nil
        if wasRunning { stopAuto() }
        let before = version
        let result: Result
        if let uv = Self.tool(["uv"]) {
            result = await run(uv, ["tool", "upgrade", "ccswap"], title: "uv tool upgrade ccswap", environment: installEnvironment(), timeout: 900)
        } else if let pipx = Self.tool(["pipx"]) {
            result = await run(pipx, ["upgrade", "ccswap"], title: "pipx upgrade ccswap", environment: installEnvironment(), timeout: 900)
        } else {
            note("Neither uv nor pipx is installed, so LiveIsland can't update ccswap.", error: true)
            return
        }
        newerVersion = nil
        await refreshVersion()
        await refresh()
        if result.status != 0 {
            note("The update didn't finish (exit \(result.status)): see its output above.", error: true)
        } else if version == before {
            note("ccswap is still \(version ?? "the same version") after the update." + (newerVersion.map { " It still offers \($0): try again later." } ?? ""), error: newerVersion != nil)
        } else {
            note("Updated ccswap from \(before ?? "?") to \(version ?? "?").")
        }
        if wasRunning && autoSwitch { startAuto() }
    }

    private func refreshVersion() async {
        guard executable != nil else { version = nil; return }
        let result = await ccswap(["--version"], quiet: true)
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
        let list = await ccswap(["codex", "list", "--json"], quiet: true)
        if let found = CodexSwapCommand.newerVersion(in: list.text) { newerVersion = found }
        guard CodexSwapJSON.accounts(list: list.output) != nil else {
            if list.status != 0 { log.error("ccswap codex list failed: \(list.text, privacy: .public)") }
            return
        }
        // Usage asks OpenAI, one request per account: skip it when there are none.
        let hasAccounts = CodexSwapJSON.accounts(list: list.output)?.isEmpty == false
        let usage = hasAccounts ? await ccswap(["codex", "usage", "--json"], quiet: true, timeout: 90) : nil
        let parsed = CodexSwapJSON.accounts(list: list.output, usage: usage?.status == 0 ? usage?.output : nil, readAt: Date())
        // Keep the last readings when OpenAI didn't answer this time.
        accounts = parsed.map { fresh in
            fresh.map { account in
                guard account.usageReadAt == nil, let old = accounts?.first(where: { $0.number == account.number && $0.email == account.email })
                else { return account }
                var kept = account
                (kept.fiveHour, kept.weekly, kept.usageReadAt, kept.bankedResets) = (old.fiveHour, old.weekly, old.usageReadAt, old.bankedResets)
                return kept
            }
        }
        onAccounts?(accounts)
    }

    func loadSettings() async {
        guard executable != nil else { return }
        let result = await ccswap(["config", "list", "--json"], quiet: true)
        if let parsed = ClaudeSwapSetting.parse(result.output) { settings = parsed }
    }

    func setting(_ key: String) -> ClaudeSwapSetting? { settings.first { $0.key == key } }

    /// `ccswap config set KEY VALUE` in LiveIsland's ccswap home, or `unset` for an empty
    /// value. Auto restarts to pick it up.
    func setSetting(_ key: String, _ value: String) async {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        _ = await ccswap(trimmed.isEmpty ? ["config", "unset", key] : ["config", "set", key, trimmed])
        await loadSettings()
        restartAutoIfRunning()
    }

    /// Whether the switch happened, for the notch.
    @discardableResult
    func switchTo(_ number: Int) async -> Bool { await act(["codex", "switch", String(number), "--json"]) }
    func switchToBest() async { await act(["codex", "switch", "--strategy", "best", "--json"]) }
    func remove(_ number: Int) async { await act(["codex", "remove", String(number), "--yes"]) }
    func addCurrent() async { await act(["codex", "add"]) }
    func redeemReset(_ number: Int) async { await act(["codex", "redeem-reset", String(number), "--yes", "--json"]) }

    @discardableResult
    private func act(_ arguments: [String]) async -> Bool {
        guard busy == nil else { return false }
        busy = "ccswap \(arguments.dropFirst().first ?? arguments.first ?? "")…"
        let result = await ccswap(arguments)
        busy = nil
        await refresh()
        return result.status == 0
    }

    /// A command typed in the console, run without a shell, always as a Codex command.
    func runConsole() async {
        guard let arguments = CodexSwapCommand.arguments(consoleInput) else {
            note("A quote is left open.", error: true)
            return
        }
        guard !arguments.isEmpty else { return }
        if CodexSwapCommand.needsTerminal(arguments) {
            note("“ccswap \(arguments.joined(separator: " "))” needs a terminal, asks before acting, or runs until stopped. Automatic switching runs from the switch above; add --yes to remove or redeem-reset.", error: true)
            return
        }
        consoleInput = ""
        _ = await ccswap(arguments, timeout: 300)
        await refresh()
        if arguments.first == "config" { await loadSettings() }
    }

    func clearConsole() { entries.removeAll() }

    // MARK: - Adding an account

    /// Signs a new account in with Codex's own sign-in, in a folder of its own (so the account
    /// Codex uses now stays as it is), adds it to ccswap, then deletes that folder: ccswap
    /// keeps the login.
    func addAccount() {
        let name = newAccountName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, adding == nil else { return }
        let directory = Self.home.appendingPathComponent("sign-in-\(UUID().uuidString.prefix(8))", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            note("Couldn't create a folder to sign in: \(error.localizedDescription)", error: true)
            return
        }
        newAccountName = ""
        adding = "Sign in to “\(name)” in the browser that Terminal opens…"
        note("Signing in a new Codex account")
        openInTerminal("""
        unset OPENAI_API_KEY
        export CODEX_HOME=\(Self.quoted(directory.path))
        echo "Sign in to the ChatGPT account “\(name)” for LiveIsland and ccswap."
        codex login
        echo
        echo "Done: LiveIsland adds it to ccswap now. You can close this window."
        """, name: "add codex account")
        Task { await waitForSignIn(in: directory, name: name) }
    }

    private func waitForSignIn(in directory: URL, name: String) async {
        defer {
            adding = nil
            try? FileManager.default.removeItem(at: directory)
        }
        let auth = directory.appendingPathComponent("auth.json")
        for _ in 0..<100 {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let data = try? Data(contentsOf: auth), CodexLogin.identity(in: data) != nil else { continue }
            adding = "Adding “\(name)” to ccswap…"
            _ = await ccswap(["codex", "add"], environment: ["CODEX_HOME": directory.path])
            await refresh()
            return
        }
        note("“\(name)” wasn't signed in within five minutes. Try Add Account again.", error: true)
    }

    // MARK: - Earlier versions' logins

    private static var legacyFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LiveIsland/codex-logins", isDirectory: true)
    }

    private static func legacyFiles() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: legacyFolder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasPrefix(".") }
    }

    func countLegacyLogins() {
        legacyLogins = Self.legacyFiles().count
    }

    /// Adds each login earlier versions kept to ccswap, one at a time, through a private
    /// folder that's deleted right after. The one Codex uses now is added as it is.
    func importLegacyLogins() async {
        guard busy == nil, executable != nil else { return }
        busy = "Adding saved logins to ccswap…"
        defer { busy = nil }
        let active = (try? Data(contentsOf: URL(fileURLWithPath: Self.codexHome).appendingPathComponent("auth.json")))
            .flatMap(CodexLogin.identity(in:))?.key
        var added = 0
        for file in Self.legacyFiles() {
            guard let data = try? Data(contentsOf: file), let identity = CodexLogin.identity(in: data) else { continue }
            if identity.key == active {
                if await ccswap(["codex", "add"]).status == 0 { added += 1 }
                continue
            }
            let directory = Self.home.appendingPathComponent("import-\(UUID().uuidString.prefix(8))", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            guard (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])) != nil,
                  FileManager.default.createFile(atPath: directory.appendingPathComponent("auth.json").path, contents: data, attributes: [.posixPermissions: 0o600])
            else { continue }
            if await ccswap(["codex", "add"], environment: ["CODEX_HOME": directory.path]).status == 0 { added += 1 }
        }
        note("Added \(added) saved login\(added == 1 ? "" : "s") to ccswap. A login Codex refreshed since it was saved may need codex login once more.")
        await refresh()
    }

    func deleteLegacyLogins() {
        try? FileManager.default.removeItem(at: Self.legacyFolder)
        note("Deleted the Codex logins earlier versions of LiveIsland kept.")
        countLegacyLogins()
    }

    // MARK: - Automatic switching

    private func startAuto() {
        guard autoProcess == nil, let executable else {
            if executable == nil { note("Install ccswap first.", error: true) }
            return
        }
        restartWork?.cancel()
        stopping = false
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["codex", "auto", "--json"]
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
                    if let newer = CodexSwapCommand.newerVersion(in: text) {
                        self?.newerVersion = newer
                        let rest = text.split(whereSeparator: \.isNewline).filter { !$0.contains("newer version of ccswap") }
                        guard !rest.isEmpty else { return }
                        self?.note("ccswap codex auto: " + rest.joined(separator: "\n"))
                    } else {
                        self?.note("ccswap codex auto: \(text)")
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
            append(Entry(at: Date(), kind: .command, title: Self.autoTitle, output: "Automatic switching is on: ccswap checks every Codex account and switches before one runs out. Codex sessions pick up the new account when restarted.", isRunning: true))
        } catch {
            note("Couldn't start automatic switching: \(error.localizedDescription)", error: true)
        }
    }

    /// A loop left by a LiveIsland that crashed would keep switching on its own: end it.
    private func endOrphanedLoops() async {
        let found = await run("/usr/bin/pgrep", ["-P", "1", "-f", "ccswap codex auto --json"], title: nil, environment: installEnvironment(), quiet: true)
        for pid in found.text.split(whereSeparator: \.isNewline).compactMap({ Int32($0) }) {
            kill(pid, SIGTERM)
            log.notice("Ended a ccswap codex auto loop left from an earlier run")
        }
    }

    private func stopAuto() {
        restartWork?.cancel()
        restartWork = nil
        guard let process = autoProcess else { auto = .off; return }
        autoProcess = nil
        process.terminate()
        auto = .off
        if let index = entries.lastIndex(where: { $0.title == Self.autoTitle && $0.isRunning }) { entries[index].isRunning = false }
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
            guard let parsed = CodexSwapEvent.parse(Data(line)) else { continue }
            autoFailures = 0
            let event = parsed.event
            lastEvent = (event.summary, parsed.at ?? Date())
            var isError = false
            if case .swap(.error) = event { isError = true }
            if case .swap(.allExhausted) = event { isError = true }
            append(Entry(at: parsed.at ?? Date(), kind: .event, title: event.summary, isError: isError, event: event.kind))
            if case .swap(.switched(_, _, _, false)) = event { Task { await refresh() } }
            if event.isNotable { onNotableEvent?(event) }
        }
    }

    private func autoEnded(_ process: Process, _ status: Int32) {
        // A switch turned off, LiveIsland quitting, or the loop stopped for a restart isn't a
        // failure. A stopped loop can end after its replacement started: only the one running
        // now counts, or the replacement would be forgotten and keep running.
        guard process === autoProcess else { return }
        autoProcess = nil
        if let index = entries.lastIndex(where: { $0.title == Self.autoTitle && $0.isRunning }) {
            entries[index].isRunning = false
            entries[index].exitCode = status
        }
        guard autoSwitch, !stopping else { auto = .off; return }
        // It shouldn't stop on its own: start it again, waiting longer each time.
        autoFailures += 1
        let delays: [TimeInterval] = [5, 15, 60, 300]
        let delay = delays[min(autoFailures - 1, delays.count - 1)]
        let why = "ccswap codex auto stopped (code \(status))"
        auto = .restarting(at: Date().addingTimeInterval(delay), why: why)
        note("\(why): starting it again in \(Int(delay)) s", error: true)
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.startAuto() } }
        restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: - Running commands

    struct Result {
        var status: Int32
        var output: Data
        /// Everything it printed, stdout and stderr, for people.
        var text: String
    }

    @discardableResult
    func ccswap(_ arguments: [String], environment extra: [String: String] = [:], quiet: Bool = false,
                timeout: TimeInterval = 120) async -> Result {
        guard let executable else {
            note("ccswap isn't installed.", error: true)
            return Result(status: -1, output: Data(), text: "")
        }
        return await run(executable, arguments, title: "ccswap " + arguments.map(Self.shown).joined(separator: " "),
                         environment: environment().merging(extra) { $1 }, quiet: quiet, timeout: timeout)
    }

    /// Runs a program (never a shell) with exactly `environment`, streaming its output into a
    /// console entry unless quiet; a quiet run is logged only when it fails.
    private func run(_ executable: String, _ arguments: [String], title: String?, environment: [String: String],
                     quiet: Bool = false, timeout: TimeInterval = 120) async -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors

        let entryID = quiet ? nil : append(Entry(at: Date(), kind: .command, title: "$ " + (title ?? executable), isRunning: true))
        let collected = CollectedOutput()
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

    /// ccswap in LiveIsland's home (see the type's note), without colors or a pager,
    /// unbuffered so `auto` events arrive as they happen.
    private func environment() -> [String: String] {
        try? FileManager.default.createDirectory(at: Self.home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var environment = installEnvironment()
        environment["HOME"] = Self.home.path
        environment["CODEX_HOME"] = Self.codexHome
        environment["NO_COLOR"] = "1"
        environment["TERM"] = "dumb"
        environment["PYTHONUNBUFFERED"] = "1"
        environment["COLUMNS"] = "120"
        environment.removeValue(forKey: "XDG_DATA_HOME")
        return environment
    }

    /// For uv, pipx and Homebrew: the real home, where they keep their tools.
    private func installEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = ClaudeCLI.shellPath
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
private final class CollectedOutput: @unchecked Sendable {
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
