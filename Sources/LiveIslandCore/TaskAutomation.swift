import Foundation

/// One of the person's Claude accounts, as a Claude Code configuration directory: Claude Code
/// keeps that account's login (in the Keychain, keyed to the directory), settings and sessions
/// there. LiveIsland stores only this reference and what it has seen, never a credential.
public struct ClaudeProfile: Codable, Equatable, Identifiable, Sendable {
    public static let mainID = "main"

    public var id: String
    public var name: String
    /// nil: Claude Code's default (`~/.claude`), the account plain `claude` uses.
    public var configDir: String?
    /// Allowed to take over a task when another account runs out.
    public var enabled: Bool
    public var email: String?
    public var plan: String?
    /// Out of usage until then (a reset time Claude Code reported).
    public var exhaustedUntil: Date?
    /// Out of usage with no reset time reported: when that was seen.
    public var exhaustedSince: Date?
    /// Why the account can't be used until someone signs in again, if so.
    public var unusable: String?

    public init(id: String, name: String, configDir: String?, enabled: Bool = true, email: String? = nil,
                plan: String? = nil, exhaustedUntil: Date? = nil, exhaustedSince: Date? = nil, unusable: String? = nil) {
        self.id = id
        self.name = name
        self.configDir = configDir
        self.enabled = enabled
        self.email = email
        self.plan = plan
        self.exhaustedUntil = exhaustedUntil
        self.exhaustedSince = exhaustedSince
        self.unusable = unusable
    }
}

/// Which account a task runs on next.
public enum AccountRotation {
    /// How long an account that ran out without a reset time waits before it's tried again.
    public static let unknownResetRetry: TimeInterval = 3600

    public enum Choice: Equatable, Sendable {
        case use(String)
        case wait(until: Date, then: String)
        case blocked(String)
    }

    public static func isAvailable(_ profile: ClaudeProfile, at now: Date) -> Bool {
        guard profile.unusable == nil else { return false }
        if let until = profile.exhaustedUntil, until > now { return false }
        if let since = profile.exhaustedSince, now.timeIntervalSince(since) < unknownResetRetry { return false }
        return true
    }

    /// When an account that ran out can be tried again.
    public static func availableAt(_ profile: ClaudeProfile) -> Date? {
        profile.exhaustedUntil ?? profile.exhaustedSince.map { $0.addingTimeInterval(unknownResetRetry) }
    }

    /// The task's own account while it has room; with switching, otherwise the first available
    /// account in priority order (`profiles` is in that order). Accounts known to be out are
    /// never tried before they reset; when all are out, wait for the earliest reset.
    public static func choose(_ profiles: [ClaudeProfile], current: String, switching: Bool, now: Date) -> Choice {
        let candidates = switching ? profiles.filter { $0.enabled || $0.id == current } : profiles.filter { $0.id == current }
        if let mine = candidates.first(where: { $0.id == current }), isAvailable(mine, at: now) { return .use(mine.id) }
        if switching, let next = candidates.first(where: { $0.enabled && isAvailable($0, at: now) }) { return .use(next.id) }
        let waits = candidates
            .filter { $0.unusable == nil && ($0.enabled || $0.id == current || !switching) }
            .compactMap { profile in availableAt(profile).map { (id: profile.id, at: max($0, now)) } }
        if let earliest = waits.min(by: { $0.at < $1.at }) { return .wait(until: earliest.at, then: earliest.id) }
        if candidates.isEmpty { return .blocked("No account is set up to run this task.") }
        let name = candidates.first(where: { $0.id == current })?.name ?? "This account"
        return .blocked(switching ? "Every account needs you to sign in again." : "\(name) needs you to sign in again.")
    }
}

/// A coding task LiveIsland keeps going, and the checkpoint it keeps while the task runs, so
/// nothing needs another model request once an account is out.
public struct AutomationTask: Codable, Equatable, Identifiable, Sendable {
    public enum State: String, Codable, Sendable {
        case running, waiting, paused, needsYou, done, cancelled
    }

    public var id: String
    public var objective: String
    public var folder: String
    /// Claude Code's permission mode: "default" (Manual), "acceptEdits" or "auto".
    public var permissionMode: String
    public var createdAt: Date
    public var state: State
    /// Why it's in this state, for the person.
    public var reason: String
    /// The account it runs on, or will run on next.
    public var profileID: String
    public var nextAttemptAt: Date?
    public var sessionID: String?
    public var transcriptPath: String?
    public var gitBranch: String?
    public var progress: TaskProgress
    public var attempts: [TaskAttempt]
    /// Throttling or network failures in a row, for backing off.
    public var retries: Int
    /// The conversation can't be resumed: the next run starts fresh from the checkpoint.
    public var needsHandoff: Bool

    public init(id: String = UUID().uuidString, objective: String, folder: String, permissionMode: String,
                profileID: String, createdAt: Date, gitBranch: String? = nil) {
        self.id = id
        self.objective = objective
        self.folder = folder
        self.permissionMode = permissionMode
        self.createdAt = createdAt
        self.profileID = profileID
        self.gitBranch = gitBranch
        state = .running
        reason = "Starting"
        progress = TaskProgress()
        attempts = []
        retries = 0
        needsHandoff = false
    }

    /// Paused, cancelled, finished or waiting on a person: nothing restarts it on its own.
    public var isSettled: Bool { [.paused, .needsYou, .done, .cancelled].contains(state) }
}

/// What a task did so far, kept up to date as its run streams.
public struct TaskProgress: Codable, Equatable, Sendable {
    public var filesTouched: [String] = []
    public var lastMessage: String?
    public var lastCommand: String?
    public var lastCommandFailed: Bool?
    /// A tool call that started but whose result never arrived: it may or may not have happened.
    public var unfinishedAction: String?
    public var toolCalls = 0
    private var openCalls: [String: String] = [:]

    public init() {}

    public mutating func record(_ event: RunEvent) {
        switch event {
        case .assistantText(let text):
            lastMessage = String(text.prefix(600))
        case .toolUse(let id, let name, let detail):
            toolCalls += 1
            let action = detail.isEmpty ? name : "\(name) \(detail)"
            openCalls[id] = action
            unfinishedAction = action
            if ["Edit", "Write", "MultiEdit", "NotebookEdit"].contains(name), !detail.isEmpty, !filesTouched.contains(detail) {
                filesTouched.append(detail)
                if filesTouched.count > 60 { filesTouched.removeFirst() }
            }
            if name == "Bash" { lastCommand = detail; lastCommandFailed = nil }
        case .toolResult(let id, let isError):
            if let action = openCalls.removeValue(forKey: id) {
                if action.hasPrefix("Bash ") { lastCommandFailed = isError }
                if unfinishedAction == action { unfinishedAction = openCalls.values.first }
            }
        case .started, .retry, .result:
            break
        }
    }
}

public struct TaskAttempt: Codable, Equatable, Sendable {
    public var profileID: String
    /// "start", "resume" (same conversation) or "handoff" (a new conversation from the checkpoint).
    public var kind: String
    public var startedAt: Date
    public var endedAt: Date?
    public var outcome: String?

    public init(profileID: String, kind: String, startedAt: Date) {
        self.profileID = profileID
        self.kind = kind
        self.startedAt = startedAt
    }
}

/// What happens to a task after each run, and how the next run is started.
public enum TaskEngine {
    public enum Next: Equatable, Sendable {
        case run(profile: String)
        case wait(until: Date)
        case stop
    }

    /// Waits after throttling or network failures in a row.
    public static let backoff: [TimeInterval] = [60, 120, 300, 600, 900, 1800]

    /// After a run: update the task and the accounts, and say what comes next.
    /// - Parameters:
    ///   - keepGoing: automatic continuation is on.
    ///   - switching: switching to another account when one runs out is on.
    public static func after(_ outcome: RunOutcome, task: inout AutomationTask, profiles: inout [ClaudeProfile],
                             keepGoing: Bool, switching: Bool, now: Date) -> Next {
        if var attempt = task.attempts.popLast() {
            attempt.endedAt = now
            attempt.outcome = outcome.summary
            task.attempts.append(attempt)
        }
        task.nextAttemptAt = nil
        switch outcome {
        case .completed:
            task.retries = 0
            return settle(&task, .done, "Finished")
        case .stopped:
            // Pause and Cancel set the state themselves; anything else stopped it from outside.
            if task.isSettled { return .stop }
            return settle(&task, .paused, "Stopped outside LiveIsland")
        case .needsApproval, .failed:
            return settle(&task, .needsYou, outcome.summary)
        case .sessionUnavailable:
            if task.needsHandoff { return settle(&task, .needsYou, "The task couldn't be continued, even in a new conversation") }
            task.needsHandoff = true
            task.state = .running
            task.reason = "Continuing in a new conversation from the saved progress"
            return .run(profile: task.profileID)
        case .throttled, .network:
            guard task.retries < backoff.count else { return settle(&task, .needsYou, "\(outcome.summary), again and again") }
            let wait = backoff[task.retries]
            task.retries += 1
            return waiting(&task, until: now.addingTimeInterval(wait), "\(outcome.summary): trying again")
        case .accountUnusable(let message):
            if let index = profiles.firstIndex(where: { $0.id == task.profileID }) { profiles[index].unusable = message }
            return choose(&task, profiles: profiles, keepGoing: keepGoing, switching: switching, now: now, why: message)
        case .usageLimit(let window, let resetsAt):
            task.retries = 0
            if let index = profiles.firstIndex(where: { $0.id == task.profileID }) {
                if let resetsAt { profiles[index].exhaustedUntil = resetsAt } else { profiles[index].exhaustedSince = now }
            }
            return choose(&task, profiles: profiles, keepGoing: keepGoing, switching: switching, now: now,
                          why: "\(RunOutcome.windowName(window)) limit reached")
        }
    }

    /// A wait is over: check the accounts again before running.
    public static func whenDue(task: inout AutomationTask, profiles: [ClaudeProfile], keepGoing: Bool, switching: Bool,
                               now: Date) -> Next {
        guard task.state == .waiting else { return .stop }
        task.nextAttemptAt = nil
        // A backoff after throttling keeps the same account.
        if task.retries > 0, profiles.first(where: { $0.id == task.profileID }).map({ AccountRotation.isAvailable($0, at: now) }) == true {
            task.state = .running
            task.reason = "Trying again"
            return .run(profile: task.profileID)
        }
        return choose(&task, profiles: profiles, keepGoing: keepGoing, switching: switching, now: now, why: nil)
    }

    private static func choose(_ task: inout AutomationTask, profiles: [ClaudeProfile], keepGoing: Bool, switching: Bool,
                               now: Date, why: String?) -> Next {
        guard keepGoing else { return settle(&task, .needsYou, why ?? "Waiting for you") }
        let name: (String) -> String = { id in profiles.first(where: { $0.id == id })?.name ?? "the account" }
        switch AccountRotation.choose(profiles, current: task.profileID, switching: switching, now: now) {
        case .use(let id):
            let switched = id != task.profileID
            task.profileID = id
            task.state = .running
            task.reason = switched ? (why.map { "\($0); continuing on \(name(id))" } ?? "Continuing on \(name(id))") : "Continuing"
            return .run(profile: id)
        case .wait(let until, let id):
            task.profileID = id
            let reason = until.timeIntervalSince(now) < 1 ? "Trying \(name(id)) again" : "\(why.map { $0 + ": " } ?? "")waiting for \(name(id))"
            return waiting(&task, until: until, reason)
        case .blocked(let message):
            return settle(&task, .needsYou, message)
        }
    }

    private static func waiting(_ task: inout AutomationTask, until: Date, _ reason: String) -> Next {
        task.state = .waiting
        task.reason = reason
        task.nextAttemptAt = until
        return .wait(until: until)
    }

    private static func settle(_ task: inout AutomationTask, _ state: AutomationTask.State, _ reason: String) -> Next {
        task.state = state
        task.reason = reason
        return .stop
    }

    // MARK: - Starting a run

    public enum Launch: Equatable, Sendable {
        case start
        /// Continue the same conversation: by session ID on the same account, by the
        /// transcript's path on another one (each account keeps its own session list).
        case resume(String)
        /// A new conversation, told what the earlier one did.
        case handoff
    }

    public static func launch(for task: AutomationTask, on profile: String) -> Launch {
        if task.needsHandoff { return .handoff }
        guard let session = task.sessionID else { return task.attempts.isEmpty ? .start : .handoff }
        let lastProfile = task.attempts.last?.profileID
        if lastProfile == profile || task.transcriptPath == nil { return .resume(session) }
        return .resume(task.transcriptPath!)
    }

    /// The `claude` arguments for a run: non-interactive, streaming, in the task's own
    /// permission mode. Nobody is there to approve a new action, so such prompts are denied and
    /// the task pauses for the person instead.
    public static func arguments(for task: AutomationTask, launch: Launch) -> [String] {
        var arguments: [String]
        switch launch {
        case .start: arguments = ["-p", task.objective]
        case .resume(let reference): arguments = ["-p", continuePrompt(task), "--resume", reference]
        case .handoff: arguments = ["-p", handoffPrompt(task)]
        }
        return arguments + ["--output-format", "stream-json", "--verbose",
                            "--permission-mode", task.permissionMode, "--permission-prompts", "none"]
    }

    static func continuePrompt(_ task: AutomationTask) -> String {
        var lines = ["The previous run of this task was interrupted (\(task.attempts.last?.outcome?.lowercased() ?? "it stopped")). Continue the task from where it stopped."]
        if let action = task.progress.unfinishedAction {
            lines.append("Its last action was `\(action)`, and its result wasn't recorded: check whether it already took effect before running it again.")
        }
        lines.append("Before redoing anything, check what is already done (for example git status and the files you changed), and don't repeat work that completed. When the whole task is done, say so.")
        return lines.joined(separator: " ")
    }

    static func handoffPrompt(_ task: AutomationTask) -> String {
        var lines = [
            "You're continuing a coding task that an earlier Claude Code conversation started and that can't be resumed. This is a new conversation: you only know what's below and what's in the folder.",
            "",
            "Task: \(task.objective)",
            "Folder: \(task.folder)",
        ]
        if let branch = task.gitBranch { lines.append("Git branch: \(branch)") }
        if !task.progress.filesTouched.isEmpty {
            lines.append("Files the earlier conversation changed: " + task.progress.filesTouched.suffix(20).joined(separator: ", "))
        }
        if let command = task.progress.lastCommand {
            let result = task.progress.lastCommandFailed.map { $0 ? "it failed" : "it passed" } ?? "its result is unknown"
            lines.append("Its last command: `\(command)` (\(result)).")
        }
        if let action = task.progress.unfinishedAction {
            lines.append("It was interrupted during `\(action)`: check whether that took effect.")
        }
        if let message = task.progress.lastMessage {
            lines.append("Its last message: \(message)")
        }
        lines.append("")
        lines.append("First look at the current state (git status, git diff, the files above), then finish the task without redoing work that's already done. When the whole task is done, say so.")
        return lines.joined(separator: "\n")
    }

    // MARK: - One run at a time

    /// Whether a `claude` process already works on this conversation (LiveIsland's own run, or
    /// one the person started), from the process list's command lines.
    public static func isRunningElsewhere(_ task: AutomationTask, commandLines: [String]) -> Bool {
        let references = [task.sessionID, task.transcriptPath].compactMap { $0 }
        guard !references.isEmpty else { return false }
        return commandLines.contains { line in
            let words = line.split(separator: " ")
            guard let first = words.first, (first as NSString).lastPathComponent == "claude" || line.contains("/claude ") else { return false }
            return references.contains { line.contains($0) }
        }
    }
}
