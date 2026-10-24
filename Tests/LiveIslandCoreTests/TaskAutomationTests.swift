import Foundation
import Testing
@testable import LiveIslandCore

/// stream-json lines shaped like the ones `claude -p --output-format stream-json --verbose` prints.
private enum Stream {
    static let start = #"{"type":"system","subtype":"init","session_id":"s-1","cwd":"/tmp/repo","permissionMode":"acceptEdits"}"#
    static let edit = #"{"type":"assistant","parent_tool_use_id":null,"message":{"content":[{"type":"text","text":"Fixing the parser."},{"type":"tool_use","id":"t1","name":"Edit","input":{"file_path":"/tmp/repo/parser.swift","old_string":"a","new_string":"b"}}]},"session_id":"s-1"}"#
    static let editDone = #"{"type":"user","parent_tool_use_id":null,"message":{"content":[{"type":"tool_result","tool_use_id":"t1","is_error":false,"content":"ok"}]},"session_id":"s-1"}"#
    static let test = #"{"type":"assistant","parent_tool_use_id":null,"message":{"content":[{"type":"tool_use","id":"t2","name":"Bash","input":{"command":"swift test"}}]},"session_id":"s-1"}"#
    static let testFailed = #"{"type":"user","parent_tool_use_id":null,"message":{"content":[{"type":"tool_result","tool_use_id":"t2","is_error":true,"content":"1 failure"}]},"session_id":"s-1"}"#
    static let subagent = #"{"type":"assistant","parent_tool_use_id":"t9","message":{"content":[{"type":"text","text":"inside a subagent"}]}}"#
    static func retry(_ category: String, status: String = "429") -> String {
        #"{"type":"system","subtype":"api_retry","attempt":1,"max_retries":10,"retry_delay_ms":500,"error_status":\#(status),"error":"\#(category)","session_id":"s-1"}"#
    }
    static func result(_ text: String, isError: Bool = false, reason: String = "completed", denials: String = "[]") -> String {
        #"{"type":"result","subtype":"success","is_error":\#(isError),"result":"\#(text)","session_id":"s-1","terminal_reason":"\#(reason)","permission_denials":\#(denials)}"#
    }

    static func events(_ lines: String...) -> [RunEvent] {
        lines.flatMap { RunEvent.parse(Data($0.utf8)) }
    }
}

@Suite("Task automation")
struct TaskAutomationTests {
    let now = Date(timeIntervalSince1970: 1_793_000_000)

    func classify(_ events: [RunEvent], exit: Int32 = 0, notice: ClaudeLimitNotice? = nil, stopped: Bool = false) -> RunOutcome {
        RunClassifier.classify(events: events, exitCode: exit, limitNotice: notice, stoppedOnPurpose: stopped)
    }

    // MARK: Reading runs

    @Test func readsTheStream() {
        let events = Stream.events(Stream.start, Stream.edit, Stream.editDone, Stream.subagent, Stream.result("Done."))
        #expect(events.first == .started(session: "s-1"))
        #expect(events.contains(.toolUse(id: "t1", name: "Edit", detail: "/tmp/repo/parser.swift")))
        #expect(events.contains(.toolResult(id: "t1", isError: false)))
        #expect(!events.contains(.assistantText("inside a subagent")), "subagents' messages aren't the task's own")
    }

    @Test func keepsACheckpointWhileItRuns() {
        var progress = TaskProgress()
        for event in Stream.events(Stream.edit, Stream.editDone, Stream.test) { progress.record(event) }
        #expect(progress.filesTouched == ["/tmp/repo/parser.swift"])
        #expect(progress.lastCommand == "swift test")
        #expect(progress.unfinishedAction == "Bash swift test", "the test started, its result never came")
        for event in Stream.events(Stream.testFailed) { progress.record(event) }
        #expect(progress.lastCommandFailed == true)
        #expect(progress.unfinishedAction == nil)
        #expect(progress.lastMessage == "Fixing the parser.")
    }

    // MARK: Why a run ended

    @Test func usageLimitFromTheTranscriptCarriesItsResetTime() {
        let notice = ClaudeLimitNotice(status: "rejected", type: "five_hour", resetsAt: now.addingTimeInterval(7200), observedAt: now)
        let outcome = classify(Stream.events(Stream.start, Stream.result("You've hit your session limit · resets 3:45pm", isError: true, reason: "api_error")),
                               exit: 1, notice: notice)
        #expect(outcome == .usageLimit(window: "five_hour", resetsAt: now.addingTimeInterval(7200)))
    }

    @Test func usageLimitFromTheMessageAloneHasNoInventedResetTime() {
        #expect(classify(Stream.events(Stream.result("You've hit your weekly limit · resets Mon 12:00am", isError: true)), exit: 1)
            == .usageLimit(window: "seven_day", resetsAt: nil))
        #expect(classify(Stream.events(Stream.result("You've hit your Opus limit · resets 3:45pm", isError: true)), exit: 1)
            == .usageLimit(window: "opus", resetsAt: nil))
    }

    @Test func aSuccessfulRunIgnoresAnOlderRefusal() {
        // Resumed on another account: the transcript still holds the first account's refusal.
        let old = ClaudeLimitNotice(status: "rejected", type: "five_hour", resetsAt: now.addingTimeInterval(7200), observedAt: now)
        #expect(classify(Stream.events(Stream.start, Stream.result("All done.")), notice: old) == .completed("All done."))
    }

    @Test func aWarningIsntALimit() {
        let warning = ClaudeLimitNotice(status: "allowed_warning", type: "seven_day", resetsAt: now.addingTimeInterval(9000), observedAt: now)
        #expect(classify(Stream.events(Stream.result("All done.")), notice: warning) == .completed("All done."))
    }

    @Test func tellsThrottlingAndNetworkFromTheLimit() {
        #expect(classify(Stream.events(Stream.retry("overloaded", status: "529"), Stream.result("API Error: Repeated 529 Overloaded errors.", isError: true, reason: "api_error")), exit: 1) == .throttled)
        #expect(classify(Stream.events(Stream.result("Server is temporarily limiting requests", isError: true)), exit: 1) == .throttled)
        #expect(classify(Stream.events(Stream.retry("unknown", status: "null"), Stream.result("Unable to connect to API", isError: true)), exit: 1) == .network)
        #expect(classify(Stream.events(Stream.retry("unknown", status: "null")), exit: 1) == .network, "no result, the last retry had no response")
    }

    @Test func noticesASignInProblem() {
        // What Claude Code printed here for a profile that was never signed in.
        let outcome = classify(Stream.events(Stream.start, Stream.result("Not logged in · Please run /login", isError: true, reason: "api_error")), exit: 1)
        #expect(outcome == .accountUnusable("Not logged in · Please run /login"))
        #expect(classify(Stream.events(Stream.result("Login expired · Please run /login", isError: true)), exit: 1) == .accountUnusable("Login expired · Please run /login"))
    }

    @Test func pausesForAnApprovalNobodyCouldGive() {
        let denials = #"[{"tool_name":"Bash","tool_use_id":"t3","tool_input":{"command":"rm -rf build"}}]"#
        #expect(classify(Stream.events(Stream.result("I couldn't clean the build folder.", denials: denials))) == .needsApproval(["Bash: rm -rf build"]))
    }

    @Test func finishedStoppedAndUnknownEndings() {
        #expect(classify(Stream.events(Stream.start, Stream.result("All done."))) == .completed("All done."))
        #expect(classify(Stream.events(Stream.start), exit: 143, stopped: true) == .stopped)
        #expect(classify(Stream.events(Stream.start), exit: 143) == .failed("Claude Code was stopped from outside (code 143)"))
        #expect(classify(Stream.events(Stream.result("No conversation found with session ID: s-1", isError: true)), exit: 1) == .sessionUnavailable)
        #expect(classify([], exit: 2) == .failed("Claude Code exited (code 2) without a result"))
    }

    // MARK: Choosing an account

    var accounts: [ClaudeProfile] {
        [ClaudeProfile(id: "main", name: "Main", configDir: nil),
         ClaudeProfile(id: "work", name: "Work", configDir: "/p/work"),
         ClaudeProfile(id: "spare", name: "Spare", configDir: "/p/spare")]
    }

    @Test func keepsTheTasksAccountWhileItHasRoom() {
        #expect(AccountRotation.choose(accounts, current: "work", switching: true, now: now) == .use("work"))
    }

    @Test func movesToTheNextAccountInPriorityOrder() {
        var profiles = accounts
        profiles[0].exhaustedUntil = now.addingTimeInterval(3600)
        #expect(AccountRotation.choose(profiles, current: "main", switching: true, now: now) == .use("work"))
        profiles[1].enabled = false
        #expect(AccountRotation.choose(profiles, current: "main", switching: true, now: now) == .use("spare"), "a turned-off account is skipped")
    }

    @Test func neverCyclesThroughAccountsKnownToBeOut() {
        var profiles = accounts
        profiles[0].exhaustedUntil = now.addingTimeInterval(7200)
        profiles[1].exhaustedUntil = now.addingTimeInterval(1800)
        profiles[2].exhaustedSince = now.addingTimeInterval(-60)   // out, reset time unknown
        #expect(AccountRotation.choose(profiles, current: "main", switching: true, now: now) == .wait(until: now.addingTimeInterval(1800), then: "work"),
                "all out: wait for the earliest reset")
        profiles[2].exhaustedSince = now.addingTimeInterval(-3700)
        #expect(AccountRotation.choose(profiles, current: "main", switching: true, now: now) == .use("spare"), "an unknown reset is tried again after an hour")
    }

    @Test func withoutSwitchingItWaitsForItsOwnAccount() {
        var profiles = accounts
        profiles[0].exhaustedUntil = now.addingTimeInterval(3600)
        #expect(AccountRotation.choose(profiles, current: "main", switching: false, now: now) == .wait(until: now.addingTimeInterval(3600), then: "main"))
    }

    @Test func accountsThatNeedSigningInAreLeftOut() {
        var profiles = accounts
        profiles[0].exhaustedUntil = now.addingTimeInterval(3600)
        profiles[1].unusable = "Login expired"
        profiles[2].unusable = "Not logged in"
        #expect(AccountRotation.choose(profiles, current: "main", switching: true, now: now) == .wait(until: now.addingTimeInterval(3600), then: "main"))
        profiles[0].unusable = "Login expired"
        #expect(AccountRotation.choose(profiles, current: "main", switching: true, now: now) == .blocked("Every account needs you to sign in again."))
    }

    // MARK: What happens next

    func task(on profile: String = "main") -> AutomationTask {
        var task = AutomationTask(objective: "Fix the parser", folder: "/tmp/repo", permissionMode: "acceptEdits", profileID: profile, createdAt: now)
        task.sessionID = "s-1"
        task.transcriptPath = "/Users/me/.claude/projects/-tmp-repo/s-1.jsonl"
        task.attempts = [TaskAttempt(profileID: profile, kind: "start", startedAt: now.addingTimeInterval(-600))]
        return task
    }

    @Test func aLimitSwitchesAccountsAndResumesTheSameConversation() {
        var task = task()
        var profiles = accounts
        let next = TaskEngine.after(.usageLimit(window: "five_hour", resetsAt: now.addingTimeInterval(5400)), task: &task, profiles: &profiles,
                                    keepGoing: true, switching: true, now: now)
        #expect(next == .run(profile: "work"))
        #expect(profiles[0].exhaustedUntil == now.addingTimeInterval(5400))
        #expect(task.reason == "5-hour limit reached; continuing on Work")
        #expect(task.attempts.last?.outcome == "5-hour limit reached")
        // Another account keeps its own session list, so it resumes by the transcript's path.
        #expect(TaskEngine.launch(for: task, on: "work") == .resume("/Users/me/.claude/projects/-tmp-repo/s-1.jsonl"))
        #expect(TaskEngine.launch(for: task, on: "main") == .resume("s-1"))
    }

    @Test func whenEveryAccountIsOutItWaitsThenChecksAgain() {
        var task = task()
        var profiles = accounts
        profiles[1].exhaustedUntil = now.addingTimeInterval(9000)
        profiles[2].exhaustedUntil = now.addingTimeInterval(4000)
        let next = TaskEngine.after(.usageLimit(window: "seven_day", resetsAt: now.addingTimeInterval(20000)), task: &task, profiles: &profiles,
                                    keepGoing: true, switching: true, now: now)
        #expect(next == .wait(until: now.addingTimeInterval(4000)))
        #expect(task.state == .waiting && task.profileID == "spare")
        // At the reset it checks again: Spare is free now.
        #expect(TaskEngine.whenDue(task: &task, profiles: profiles, keepGoing: true, switching: true, now: now.addingTimeInterval(4001)) == .run(profile: "spare"))
        #expect(task.state == .running)
    }

    @Test func aSignInProblemMarksTheAccountAndMovesOn() {
        var task = task()
        var profiles = accounts
        let next = TaskEngine.after(.accountUnusable("Login expired · Please run /login"), task: &task, profiles: &profiles,
                                    keepGoing: true, switching: true, now: now)
        #expect(profiles[0].unusable == "Login expired · Please run /login")
        #expect(next == .run(profile: "work"))
        var alone = self.task()
        var single = [accounts[0]]
        #expect(TaskEngine.after(.accountUnusable("Login expired"), task: &alone, profiles: &single, keepGoing: true, switching: true, now: now) == .stop)
        #expect(alone.state == .needsYou && alone.reason == "Every account needs you to sign in again.")
    }

    @Test func throttlingBacksOffOnTheSameAccount() {
        var task = task()
        var profiles = accounts
        #expect(TaskEngine.after(.throttled, task: &task, profiles: &profiles, keepGoing: true, switching: true, now: now) == .wait(until: now.addingTimeInterval(60)))
        #expect(task.profileID == "main" && profiles.allSatisfy { $0.exhaustedUntil == nil }, "a busy server isn't the account's limit")
        task.attempts.append(TaskAttempt(profileID: "main", kind: "resume", startedAt: now))
        #expect(TaskEngine.after(.network, task: &task, profiles: &profiles, keepGoing: true, switching: true, now: now) == .wait(until: now.addingTimeInterval(120)))
        #expect(TaskEngine.whenDue(task: &task, profiles: profiles, keepGoing: true, switching: true, now: now.addingTimeInterval(121)) == .run(profile: "main"))
    }

    @Test func cancellingPreventsAnyLaterRestart() {
        var task = task()
        var profiles = accounts
        _ = TaskEngine.after(.usageLimit(window: "five_hour", resetsAt: now.addingTimeInterval(3600)), task: &task, profiles: &profiles,
                             keepGoing: true, switching: false, now: now)
        #expect(task.state == .waiting)
        task.state = .cancelled
        #expect(TaskEngine.whenDue(task: &task, profiles: profiles, keepGoing: true, switching: false, now: now.addingTimeInterval(4000)) == .stop)
        #expect(TaskEngine.after(.stopped, task: &task, profiles: &profiles, keepGoing: true, switching: true, now: now) == .stop)
        #expect(task.state == .cancelled)
    }

    @Test func withAutomationOffItWaitsForThePerson() {
        var task = task()
        var profiles = accounts
        #expect(TaskEngine.after(.usageLimit(window: "five_hour", resetsAt: now.addingTimeInterval(3600)), task: &task, profiles: &profiles,
                                 keepGoing: false, switching: true, now: now) == .stop)
        #expect(task.state == .needsYou)
    }

    @Test func approvalsAndFailuresPauseInsteadOfRetrying() {
        var task = task()
        var profiles = accounts
        #expect(TaskEngine.after(.needsApproval(["Bash: rm -rf build"]), task: &task, profiles: &profiles, keepGoing: true, switching: true, now: now) == .stop)
        #expect(task.state == .needsYou && task.reason.contains("rm -rf build"))
    }

    @Test func aConversationThatCantBeResumedContinuesFromTheCheckpoint() throws {
        var task = task()
        task.progress.filesTouched = ["/tmp/repo/parser.swift"]
        task.progress.lastCommand = "swift test"
        task.progress.lastCommandFailed = true
        var profiles = accounts
        #expect(TaskEngine.after(.sessionUnavailable, task: &task, profiles: &profiles, keepGoing: true, switching: true, now: now) == .run(profile: "main"))
        #expect(TaskEngine.launch(for: task, on: "main") == .handoff)
        let arguments = TaskEngine.arguments(for: task, launch: .handoff)
        let prompt = try #require(arguments.dropFirst().first)
        #expect(prompt.contains("Task: Fix the parser") && prompt.contains("parser.swift") && prompt.contains("`swift test` (it failed)"))
        #expect(prompt.contains("new conversation"), "it says plainly that this isn't the original conversation")
        #expect(TaskEngine.after(.sessionUnavailable, task: &task, profiles: &profiles, keepGoing: true, switching: true, now: now) == .stop, "only once")
    }

    @Test func runsKeepTheTasksPermissionsAndAskNobody() {
        let arguments = TaskEngine.arguments(for: task(), launch: .resume("s-1"))
        #expect(arguments.starts(with: ["-p"]))
        #expect(arguments.contains("--resume") && arguments.contains("s-1"))
        #expect(Array(arguments.suffix(7)) == ["--output-format", "stream-json", "--verbose", "--permission-mode", "acceptEdits", "--permission-prompts", "none"])
    }

    @Test func refusesASecondRunOfTheSameConversation() {
        let task = task()
        #expect(TaskEngine.isRunningElsewhere(task, commandLines: ["/Users/me/.local/bin/claude -p continue --resume s-1 --output-format stream-json"]))
        #expect(TaskEngine.isRunningElsewhere(task, commandLines: ["claude --resume /Users/me/.claude/projects/-tmp-repo/s-1.jsonl"]))
        #expect(!TaskEngine.isRunningElsewhere(task, commandLines: ["claude -p hello", "vim s-1.txt"]))
    }

    @Test func tasksAndAccountsSurviveARelaunch() throws {
        var task = task()
        task.progress.record(.toolUse(id: "t1", name: "Write", detail: "/tmp/repo/a.swift"))
        let decoded = try JSONDecoder().decode(AutomationTask.self, from: JSONEncoder().encode(task))
        #expect(decoded == task)
        let profiles = try JSONDecoder().decode([ClaudeProfile].self, from: JSONEncoder().encode(accounts))
        #expect(profiles == accounts)
    }
}
