import AppKit
import LiveIslandCore
import os

private let log = Logger(subsystem: "com.aissam.liveisland", category: "tasks")

/// Coding tasks LiveIsland keeps going: each runs as `claude -p` on one of the person's
/// accounts, with its progress saved as it streams. When a run ends, `TaskEngine` decides
/// what's next: done, a pause for the person, a wait for a reset, or another run, on the same
/// account or (if allowed) another one. Only one run per task, and per conversation, at a time.
@MainActor
final class TaskRunner: ObservableObject {
    @Published private(set) var tasks: [AutomationTask] = []

    // The new-task form (SwiftUI's @State needs Xcode, so it lives here).
    @Published var draftFolder = ""
    @Published var draftObjective = ""
    @Published var draftMode = "acceptEdits"
    @Published var draftProfile = ClaudeProfile.mainID
    @Published private(set) var draftProblem: String?

    /// Continue after a limit, at its reset (Settings › AI Agents).
    var keepGoing = false
    /// Continue on another of the person's accounts when the task's own runs out.
    var switching = false

    let profiles: ProfileStore

    private struct Run {
        let process: Process
        let startedAt: Date
        /// The transcript and its size when the run started: only what the run adds counts.
        let transcriptAtStart: (path: String, size: UInt64)?
        var events: [RunEvent] = []
        var buffer = Data()
        var errorTail = Data()
        var stoppedOnPurpose = false
        /// Switch to this account once the run has stopped.
        var switchTo: String?
    }

    private var runs: [String: Run] = [:]
    private var timers: [String: Timer] = [:]
    private var lastSave: [String: Date] = [:]
    private var wakeObserver: NSObjectProtocol?
    private var quitting = false
    private let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("LiveIsland/automation/tasks")

    init(profiles: ProfileStore) {
        self.profiles = profiles
    }

    func start() {
        load()
        Task {
            await ClaudeCLI.loadShellPath()
            await profiles.refreshAll()
        }
        // A task that was running when LiveIsland quit continues once it's open again.
        for task in tasks where task.state == .running {
            mutate(task.id) {
                $0.state = .waiting
                $0.reason = "LiveIsland reopened: continuing"
                $0.nextAttemptAt = Date().addingTimeInterval(5)
            }
        }
        for task in tasks where task.state == .waiting { schedule(task.id, at: task.nextAttemptAt ?? Date()) }
        // Timers don't fire during sleep: catch up on wake.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.catchUp() }
        }
    }

    /// LiveIsland is quitting: end each run's turn (SIGINT), so no conversation runs twice
    /// later, and let it continue when LiveIsland opens again.
    func stop() {
        quitting = true
        for (id, run) in runs {
            runs[id]?.stoppedOnPurpose = true
            run.process.interrupt()
            mutate(id) {
                $0.state = .waiting
                $0.reason = "LiveIsland quit: continues when it opens"
                $0.nextAttemptAt = Date()
            }
        }
        timers.values.forEach { $0.invalidate() }
        timers.removeAll()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
    }

    // MARK: - Person's controls

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "The project the task works in"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url { draftFolder = url.path }
    }

    func createFromDraft() {
        let objective = draftObjective.trimmingCharacters(in: .whitespacesAndNewlines)
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: draftFolder, isDirectory: &isFolder), isFolder.boolValue else {
            draftProblem = "Choose the project folder first."
            return
        }
        guard !objective.isEmpty else {
            draftProblem = "Describe the task first."
            return
        }
        guard ClaudeCLI.executable != nil else {
            draftProblem = "Claude Code isn't installed where LiveIsland looks (~/.local/bin/claude)."
            return
        }
        draftProblem = nil
        let task = AutomationTask(objective: objective, folder: draftFolder, permissionMode: draftMode,
                                  profileID: draftProfile, createdAt: Date())
        tasks.insert(task, at: 0)
        save(task.id, force: true)
        draftObjective = ""
        Task {
            if let data = try? await ProcessRunner.output("/usr/bin/git", ["-C", task.folder, "rev-parse", "--abbrev-ref", "HEAD"]),
               let branch = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !branch.isEmpty {
                mutate(task.id) { $0.gitBranch = branch }
            }
            await launch(task.id, on: task.profileID)
        }
    }

    /// Stops the run (ending its turn) or the wait; nothing restarts it until Resume.
    func pause(_ id: String) {
        cancelTimer(id)
        mutate(id) {
            $0.state = .paused
            $0.reason = "Paused"
            $0.nextAttemptAt = nil
        }
        interrupt(id)
    }

    /// For good: no later run, whatever happens to the accounts.
    func cancel(_ id: String) {
        cancelTimer(id)
        mutate(id) {
            $0.state = .cancelled
            $0.reason = "Cancelled"
            $0.nextAttemptAt = nil
        }
        interrupt(id)
    }

    func resume(_ id: String) {
        guard let task = task(id), task.state != .running, task.state != .done, task.state != .cancelled else { return }
        cancelTimer(id)
        mutate(id) {
            $0.retries = 0
            $0.state = .running
            $0.reason = "Continuing"
        }
        Task {
            await profiles.refresh(task.profileID)
            await launch(id, on: task.profileID)
        }
    }

    /// The person moves the task to another account: the run stops first, then continues there.
    func switchAccount(_ id: String, to profile: String) {
        guard let task = task(id), task.state != .done, task.state != .cancelled else { return }
        cancelTimer(id)
        if runs[id] != nil {
            runs[id]?.switchTo = profile
            mutate(id) { $0.reason = "Switching to \(self.profiles.name(of: profile))" }
            interrupt(id)
        } else {
            mutate(id) {
                $0.profileID = profile
                $0.retries = 0
                $0.state = .running
                $0.reason = "Continuing on \(self.profiles.name(of: profile))"
            }
            Task {
                await profiles.refresh(profile)
                await launch(id, on: profile)
            }
        }
    }

    func remove(_ id: String) {
        guard let task = task(id), [.done, .cancelled].contains(task.state) else { return }
        tasks.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: file(for: id))
    }

    func task(_ id: String) -> AutomationTask? { tasks.first { $0.id == id } }

    func isRunning(_ id: String) -> Bool { runs[id] != nil }

    // MARK: - Runs

    private func launch(_ id: String, on profileID: String) async {
        guard var task = task(id), runs[id] == nil, task.state == .running else { return }
        guard let profile = profiles.profile(profileID), let claude = ClaudeCLI.executable else {
            settle(id, "The account or Claude Code itself is missing")
            return
        }
        if profile.unusable != nil {
            // It just turned out to need signing in: let the engine pick again.
            task.attempts.append(TaskAttempt(profileID: profileID, kind: "check", startedAt: Date()))
            replace(task)
            finish(id, outcome: .accountUnusable(profile.unusable ?? "Not signed in"))
            return
        }
        // One run per conversation: not while LiveIsland, or the person, already runs it.
        if let data = try? await ProcessRunner.output("/bin/ps", ["-axo", "command="]),
           TaskEngine.isRunningElsewhere(task, commandLines: String(decoding: data, as: UTF8.self).components(separatedBy: "\n")) {
            settle(id, "Another Claude Code process is working on this conversation: finish it there, then Resume")
            return
        }
        guard runs[id] == nil, self.task(id)?.state == .running else { return }

        let launch = TaskEngine.launch(for: task, on: profileID)
        let kind: String
        switch launch {
        case .start: kind = "start"
        case .resume: kind = "resume"
        case .handoff: kind = "handoff"
        }
        task.profileID = profileID
        task.attempts.append(TaskAttempt(profileID: profileID, kind: kind, startedAt: Date()))
        if kind == "start" || kind == "handoff" { task.reason = "Working on \(profile.name)" }
        replace(task)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: claude)
        process.arguments = TaskEngine.arguments(for: task, launch: launch)
        process.currentDirectoryURL = URL(fileURLWithPath: task.folder)
        process.environment = ClaudeCLI.environment(for: profile)
        process.standardInput = FileHandle.nullDevice
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { handle.readabilityHandler = nil; return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.receive(id, chunk) } }
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { handle.readabilityHandler = nil; return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.receiveError(id, chunk) } }
        }
        process.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            // Let the last output arrive first.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { MainActor.assumeIsolated { self?.ended(id, status: status) } }
        }
        do {
            try process.run()
            let start = task.transcriptPath.map { path in
                (path: path, size: (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? UInt64) ?? 0)
            }
            runs[id] = Run(process: process, startedAt: Date(), transcriptAtStart: start)
            log.notice("Task \(id, privacy: .public): \(kind, privacy: .public) on \(profile.id, privacy: .public)")
        } catch {
            settle(id, "Claude Code couldn't start: \(error.localizedDescription)")
        }
    }

    private func receive(_ id: String, _ chunk: Data) {
        guard var run = runs[id] else { return }
        run.buffer.append(chunk)
        var newEvents: [RunEvent] = []
        while let newline = run.buffer.firstIndex(of: 0x0A) {
            let line = run.buffer[run.buffer.startIndex..<newline]
            run.buffer.removeSubrange(run.buffer.startIndex...newline)
            newEvents += RunEvent.parse(Data(line))
        }
        run.events += newEvents
        runs[id] = run
        guard !newEvents.isEmpty, var task = task(id) else { return }
        for event in newEvents {
            task.progress.record(event)
            if case .started(let session) = event, task.sessionID != session {
                // A new conversation (the first run, or a handoff): follow it from now on.
                task.sessionID = session
                task.transcriptPath = nil
                task.needsHandoff = false
            }
        }
        if task.transcriptPath == nil, let session = task.sessionID, let profile = profiles.profile(task.profileID) {
            task.transcriptPath = Self.transcript(session, in: profile)?.path
        }
        replace(task)
        save(id)
    }

    private func receiveError(_ id: String, _ chunk: Data) {
        runs[id]?.errorTail.append(chunk)
        if let tail = runs[id]?.errorTail, tail.count > 4096 { runs[id]?.errorTail = tail.suffix(4096) }
    }

    private func ended(_ id: String, status: Int32) {
        guard !quitting, var run = runs.removeValue(forKey: id) else { return }
        if !run.buffer.isEmpty { run.events += RunEvent.parse(run.buffer) }
        guard var task = task(id) else { return }

        // Where this run wrote: on another account, the conversation may now live in its folder.
        if let session = task.sessionID, let profile = profiles.profile(task.profileID),
           let path = Self.transcript(session, in: profile)?.path {
            task.transcriptPath = path
        }
        let notice = task.transcriptPath.flatMap { path in
            Self.limitNotice(in: path, after: run.transcriptAtStart?.path == path ? run.transcriptAtStart!.size : 0)
        }
        var outcome = RunClassifier.classify(events: run.events, exitCode: status, limitNotice: notice,
                                             stoppedOnPurpose: run.stoppedOnPurpose)
        if case .failed(let message) = outcome, message.contains("without a result"),
           let line = String(data: run.errorTail, encoding: .utf8)?.split(whereSeparator: \.isNewline).last {
            outcome = .failed("\(message): \(line)")
        }
        log.notice("Task \(id, privacy: .public) run ended (\(status)): \(outcome.summary, privacy: .public)")
        replace(task)

        if let target = run.switchTo, task.state == .running {
            mutate(id) {
                $0.profileID = target
                $0.retries = 0
                $0.reason = "Continuing on \(self.profiles.name(of: target))"
            }
            Task {
                await profiles.refresh(target)
                await launch(id, on: target)
            }
            return
        }
        finish(id, outcome: outcome)
    }

    /// Hands the outcome to the engine and does what it says.
    private func finish(_ id: String, outcome: RunOutcome) {
        guard var task = task(id) else { return }
        var accounts = profiles.profiles
        let next = TaskEngine.after(outcome, task: &task, profiles: &accounts, keepGoing: keepGoing, switching: switching, now: Date())
        profiles.update(accounts)
        replace(task)
        save(id, force: true)
        perform(next, for: id)
    }

    private func perform(_ next: TaskEngine.Next, for id: String) {
        switch next {
        case .run(let profile):
            Task {
                // Before continuing, make sure the account is still signed in.
                await profiles.refresh(profile)
                await launch(id, on: profile)
            }
        case .wait(let date):
            schedule(id, at: date)
        case .stop:
            break
        }
    }

    // MARK: - Waiting

    private func schedule(_ id: String, at date: Date) {
        cancelTimer(id)
        let timer = Timer(fire: max(date, Date().addingTimeInterval(1)), interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.due(id) }
        }
        RunLoop.main.add(timer, forMode: .common)
        timers[id] = timer
    }

    private func due(_ id: String) {
        timers[id] = nil
        guard var task = task(id), task.state == .waiting else { return }
        let next = TaskEngine.whenDue(task: &task, profiles: profiles.profiles, keepGoing: keepGoing, switching: switching, now: Date())
        replace(task)
        save(id, force: true)
        perform(next, for: id)
    }

    private func catchUp() {
        for task in tasks where task.state == .waiting && (task.nextAttemptAt ?? .distantFuture) <= Date() { due(task.id) }
    }

    private func cancelTimer(_ id: String) {
        timers.removeValue(forKey: id)?.invalidate()
    }

    private func interrupt(_ id: String) {
        guard let run = runs[id] else { return }
        runs[id]?.stoppedOnPurpose = true
        // SIGINT ends the turn cleanly; SIGTERM would leave it half done.
        run.process.interrupt()
    }

    private func settle(_ id: String, _ reason: String) {
        mutate(id) {
            $0.state = .needsYou
            $0.reason = reason
            $0.nextAttemptAt = nil
        }
    }

    // MARK: - Transcripts

    /// The conversation's transcript in this account's folder, if it's there.
    static func transcript(_ session: String, in profile: ClaudeProfile) -> URL? {
        let projects = ClaudeCLI.projectsDirectory(for: profile)
        guard let folders = try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil) else { return nil }
        return folders.lazy.map { $0.appendingPathComponent(session + ".jsonl") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// The usage-limit refusal Claude Code wrote during this run: it carries the limit's window
    /// and its exact reset time. Only the lines added since `offset` (the transcript's size when
    /// the run started) count, so an earlier run's refusal is never read again.
    static func limitNotice(in path: String, after offset: UInt64) -> ClaudeLimitNotice? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        guard size > offset else { return nil }
        try? handle.seek(toOffset: max(offset, size > 262_144 ? size - 262_144 : 0))
        guard let data = try? handle.readToEnd() else { return nil }
        var found: ClaudeLimitNotice?
        for line in data.split(separator: 0x0A) where line.count < 65_536 {
            if let notice = ClaudeTranscript.limitNotice(in: Data(line)) { found = notice }
        }
        return found
    }

    // MARK: - Saving

    private func mutate(_ id: String, _ change: (inout AutomationTask) -> Void) {
        guard var task = task(id) else { return }
        change(&task)
        replace(task)
        save(id, force: true)
    }

    private func replace(_ task: AutomationTask) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        if tasks[index] != task { tasks[index] = task }
    }

    private func file(for id: String) -> URL { folder.appendingPathComponent(id + ".json") }

    /// The checkpoint: written as the run streams (at most every few seconds) and at every change of state.
    private func save(_ id: String, force: Bool = false) {
        guard let task = task(id) else { return }
        let now = Date()
        if !force, let last = lastSave[id], now.timeIntervalSince(last) < 3 { return }
        lastSave[id] = now
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try JSONEncoder().encode(task).write(to: file(for: id), options: .atomic)
        } catch {
            log.error("Couldn't save task \(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func load() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return }
        tasks = files.filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(AutomationTask.self, from: Data(contentsOf: $0)) }
            .sorted { $0.createdAt > $1.createdAt }
    }
}
