import Foundation
import Testing
@testable import LiveIslandCore

@Suite("JSON-lines scanning")
struct ScannerTests {
    @Test func linesSplitAndAPartialLineWaits() {
        let data = Fixture.data("one\ntwo\nthr")
        var lines: [String] = []
        let consumed = JSONLScanner.forEachLine(in: data) { lines.append(String(decoding: $0, as: UTF8.self)) }
        #expect(lines == ["one", "two"])
        #expect(consumed == 8, "the unfinished line stays unread")
    }

    @Test func stringsDecodeEscapes() {
        let line = Fixture.data(Fixture.claudeTitle)
        #expect(JSONLScanner.string(after: #""aiTitle":""#, in: line) == #"Fix the "login" bug"#)
    }

    @Test func objectsBalanceBracesEvenInsideStrings() throws {
        let line = Fixture.data(#"{"a":{"text":"} not the end {","n":{"x":1}},"b":2}"#)
        let object = try #require(JSONLScanner.object(forKey: "a", in: line))
        #expect(object["text"] as? String == "} not the end {")
        #expect((object["n"] as? [String: Any])?["x"] as? Int == 1)
    }

    @Test func lastOccurrenceIsFoundWhenAsked() {
        let line = Fixture.data(#"{"k":"first","x":{"k":"second"}}"#)
        #expect(JSONLScanner.string(after: #""k":""#, in: line) == "first")
        #expect(JSONLScanner.string(after: #""k":""#, in: line, last: true) == "second")
    }
}

@Suite("Claude Code transcripts")
struct ClaudeTranscriptTests {
    @Test func readsTokenUseFromAnAssistantResponse() throws {
        let record = try #require(ClaudeTranscript.usageRecord(in: Fixture.data(Fixture.claudeAssistant())))
        #expect(record.messageID == "msg_01ABC")
        #expect(record.tokens == 10 + 200 + 300 + 4_000)
        #expect(record.model == "claude-opus-5-5")
        #expect(record.timestamp == Format.date(iso8601: "2026-10-22T10:15:00.000Z"))
    }

    @Test func aToolInputWithItsOwnUsageKeyDoesNotConfuseIt() throws {
        let content = #"[{"type":"tool_use","id":"toolu_9","name":"Write","input":{"usage":{"input_tokens":999999}}}]"#
        let record = try #require(ClaudeTranscript.usageRecord(in: Fixture.data(Fixture.claudeAssistant(content: content))))
        #expect(record.tokens == 4_510)
    }

    @Test func otherLinesHaveNoUsage() {
        #expect(ClaudeTranscript.usageRecord(in: Fixture.data(Fixture.claudePrompt())) == nil)
        #expect(ClaudeTranscript.usageRecord(in: Fixture.data(Fixture.claudeTitle)) == nil)
    }

    @Test func readsUsageLimitNotices() throws {
        let notice = try #require(ClaudeTranscript.limitNotice(in: Fixture.data(Fixture.claudeLimit)))
        #expect(notice.isLimitReached)
        #expect(notice.windowLabel == "Weekly")
        #expect(notice.resetsAt == Date(timeIntervalSince1970: 1_792_818_000))
        #expect(notice.isCurrent(at: Date(timeIntervalSince1970: 1_792_000_000)))
        #expect(!notice.isCurrent(at: Date(timeIntervalSince1970: 1_793_000_000)))
    }

    @Test func tailFindsTitleProjectAndTurnStart() {
        let lines = [Fixture.claudePrompt(), Fixture.claudeTitle, Fixture.claudeAssistant(stop: "end_turn")].map(Fixture.data)
        let tail = ClaudeTranscript.tail(of: lines)
        #expect(tail.title == #"Fix the "login" bug"#)
        #expect(ClaudeTranscript.projectName(cwd: tail.cwd, fallback: "?") == "app")
        #expect(tail.lastStep == .finished)
        #expect(tail.turnStartedAt == Format.date(iso8601: "2026-10-22T10:14:00.000Z"))
    }

    @Test func toolResultsDoNotStartANewTurn() {
        let lines = [Fixture.claudePrompt(), Fixture.claudeAssistant(), Fixture.claudeToolResult()].map(Fixture.data)
        let tail = ClaudeTranscript.tail(of: lines)
        #expect(tail.lastStep == .awaitingModel)
        #expect(tail.turnStartedAt == Format.date(iso8601: "2026-10-22T10:14:00.000Z"))
    }

    @Test func stateFollowsTheLastStepAndHowLongItsBeenQuiet() {
        let now = Date()
        var tail = ClaudeTranscript.Tail()

        tail.lastStep = .finished
        #expect(ClaudeTranscript.state(of: tail, modified: now.addingTimeInterval(-5), now: now) == .done)
        #expect(ClaudeTranscript.state(of: tail, modified: now.addingTimeInterval(-60), now: now) == .idle)

        tail.lastStep = .calledTool
        #expect(ClaudeTranscript.state(of: tail, modified: now.addingTimeInterval(-2), now: now) == .working)
        #expect(ClaudeTranscript.state(of: tail, modified: now.addingTimeInterval(-40), now: now) == .waiting)
        #expect(ClaudeTranscript.state(of: tail, modified: now.addingTimeInterval(-3600), now: now) == .idle)

        tail.lastStep = .awaitingModel
        #expect(ClaudeTranscript.state(of: tail, modified: now.addingTimeInterval(-120), now: now) == .working,
                "long thinking writes nothing for a while")
        #expect(ClaudeTranscript.state(of: ClaudeTranscript.Tail(), modified: now, now: now) == .idle)
    }
}

@Suite("Codex sessions")
struct CodexRolloutTests {
    @Test func readsRateLimitsWithResetTimes() throws {
        let limits = try #require(CodexRollout.limits(in: Fixture.data(Fixture.codexTokenCount())))
        let primary = try #require(limits.primary)
        #expect(primary.usedPercent == 12.5)
        #expect(primary.label == "5-hour")
        #expect(primary.resetsAt == Date(timeIntervalSince1970: 1_792_837_722))
        #expect(limits.secondary?.label == "Weekly")
        #expect(limits.windows.count == 2)
    }

    @Test func olderCountdownStyleResetsAreConverted() throws {
        let line = Fixture.codexTokenCount(resets: #""resets_in_seconds":600"#)
        let limits = try #require(CodexRollout.limits(in: Fixture.data(line)))
        let expected = Format.date(iso8601: "2026-10-16T15:20:00.000Z")!.addingTimeInterval(600)
        #expect(limits.primary?.resetsAt == expected)
    }

    @Test func readsTheSessionTokenTotal() {
        #expect(CodexRollout.totalTokens(in: Fixture.data(Fixture.codexTokenCount(total: 52_000))) == 52_000)
    }

    @Test func tailTracksTurnsAndApprovals() {
        let now = Format.date(iso8601: "2026-10-16T15:30:10.000Z")!
        var lines = [Fixture.codexMeta, Fixture.codexEvent("task_started", at: "2026-10-16T15:30:00.000Z")]
        var tail = CodexRollout.tail(of: lines.map(Fixture.data))
        #expect(tail.cwd == "/Users/me/Code/api")
        #expect(CodexRollout.state(of: tail, modified: now, now: now) == .working)

        lines.append(Fixture.codexEvent("exec_approval_request", at: "2026-10-16T15:30:05.000Z"))
        tail = CodexRollout.tail(of: lines.map(Fixture.data))
        #expect(CodexRollout.state(of: tail, modified: now, now: now) == .waiting)

        lines.append(Fixture.codexEvent("task_complete", at: "2026-10-16T15:30:09.000Z"))
        tail = CodexRollout.tail(of: lines.map(Fixture.data))
        #expect(CodexRollout.state(of: tail, modified: now, now: now) == .done)
        #expect(CodexRollout.state(of: tail, modified: now, now: now.addingTimeInterval(60)) == .idle)
    }
}
