import Foundation
import Testing
@testable import LiveIslandCore

@Suite("Usage ledger")
struct UsageLedgerTests {
    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("transcript-\(UUID().uuidString).jsonl")
    }

    private func append(_ text: String, to url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }

    @Test func countsEachResponseOnceAndReadsOnlyNewLines() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let now = Format.date(iso8601: "2026-10-22T12:00:00.000Z")!
        let ledger = UsageLedger()

        // One response written as two lines (two content blocks), plus a partial line.
        try append(Fixture.claudeAssistant(id: "msg_A", at: "2026-10-22T11:00:00.000Z") + "\n", to: url)
        try append(Fixture.claudeAssistant(id: "msg_A", at: "2026-10-22T11:00:01.000Z") + "\n", to: url)
        let partial = Fixture.claudeAssistant(id: "msg_B", at: "2026-10-22T11:30:00.000Z")
        try append(String(partial.prefix(40)), to: url)
        ledger.ingest(url, now: now)
        #expect(ledger.recordCount == 1)

        // The rest of the partial line arrives later.
        try append(String(partial.dropFirst(40)) + "\n", to: url)
        ledger.ingest(url, now: now)
        #expect(ledger.recordCount == 2)
        #expect(ledger.summary(now: now, calendar: utc).windowTokens == 2 * 4_510)
    }

    @Test func windowsStartOnTheHourOfTheFirstMessageAndLastFiveHours() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let lines = [
            Fixture.claudeAssistant(id: "msg_1", at: "2026-10-22T02:10:00.000Z", output: 0, cacheWrite: 0, cacheRead: 90),  // old window
            Fixture.claudeAssistant(id: "msg_2", at: "2026-10-22T09:42:00.000Z", input: 1, output: 0, cacheWrite: 0, cacheRead: 0),
            Fixture.claudeAssistant(id: "msg_3", at: "2026-10-22T11:05:00.000Z", input: 2, output: 0, cacheWrite: 0, cacheRead: 0),
        ]
        try append(lines.joined(separator: "\n") + "\n", to: url)
        let now = Format.date(iso8601: "2026-10-22T12:00:00.000Z")!
        let ledger = UsageLedger()
        ledger.ingest(url, now: now)
        let summary = ledger.summary(now: now, calendar: utc)
        #expect(summary.windowStart == Format.date(iso8601: "2026-10-22T09:00:00.000Z"))
        #expect(summary.windowEnd == Format.date(iso8601: "2026-10-22T14:00:00.000Z"))
        #expect(summary.windowTokens == 3)
        #expect(summary.windowRequests == 2)
        #expect(summary.todayTokens == 100 + 3)
        #expect(summary.todayRequests == 3)

        // After the window ends there's no current window, until the next message.
        let later = Format.date(iso8601: "2026-10-22T14:30:00.000Z")!
        #expect(ledger.summary(now: later, calendar: utc).windowStart == nil)
    }

    @Test func keepsTheLatestLimitNotice() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        try append(Fixture.claudeLimit + "\n", to: url)
        let ledger = UsageLedger()
        ledger.ingest(url, now: Format.date(iso8601: "2026-10-20T09:00:00.000Z")!)
        #expect(ledger.latestLimit?.type == "seven_day")
    }

    @Test func aLimitNoticeIsStaleOnceClaudeAnswersAgain() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let now = Format.date(iso8601: "2026-10-22T12:00:00.000Z")!
        try append(Fixture.claudeLimit + "\n", to: url)  // logged 2026-10-20 08:00, resets 2026-10-24
        let ledger = UsageLedger()
        ledger.ingest(url, now: Format.date(iso8601: "2026-10-20T09:00:00.000Z")!)
        #expect(ledger.currentLimit(at: Format.date(iso8601: "2026-10-20T09:00:00.000Z")!) != nil)
        #expect(ledger.latestLimit?.session == url.path, "a refusal knows which session it was")
        try append(Fixture.claudeAssistant(id: "msg_after", at: "2026-10-22T11:00:00.000Z") + "\n", to: url)
        ledger.ingest(url, now: now)
        #expect(ledger.currentLimit(at: now) == nil, "Claude answered after the notice, so the limit is gone")
    }

    @Test func aReplacedFileIsReadAgain() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let now = Format.date(iso8601: "2026-10-22T12:00:00.000Z")!
        try append(Fixture.claudeAssistant(id: "msg_X", at: "2026-10-22T11:00:00.000Z") + "\n", to: url)
        let ledger = UsageLedger()
        ledger.ingest(url, now: now)
        // Same size, different content, new file.
        let replacement = Fixture.claudeAssistant(id: "msg_Y", at: "2026-10-22T11:10:00.000Z") + "\n"
        try Data(replacement.utf8).write(to: url, options: .atomic)
        ledger.ingest(url, now: now)
        #expect(ledger.recordCount == 2)
    }

    @Test func aFileThatShrankIsReadAgain() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let now = Format.date(iso8601: "2026-10-22T12:00:00.000Z")!
        let first = Fixture.claudeAssistant(id: "msg_P", at: "2026-10-22T11:00:00.000Z")
        try append(first + "\n" + first.replacingOccurrences(of: "msg_P", with: "msg_Q") + "\n", to: url)
        let ledger = UsageLedger()
        ledger.ingest(url, now: now)
        #expect(ledger.recordCount == 2)
        try FileHandle(forWritingTo: url).truncate(atOffset: 0)
        try append(Fixture.claudeAssistant(id: "msg_R", at: "2026-10-22T11:20:00.000Z") + "\n", to: url)
        ledger.ingest(url, now: now)
        #expect(ledger.recordCount == 3)
    }

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }
}

@Suite("Now playing")
struct NowPlayingTests {
    private func line(_ payload: String, diff: Bool = false) -> Data {
        Fixture.data(#"{"type":"data","diff":\#(diff),"payload":\#(payload)}"#)
    }

    @Test func aFullPayloadDescribesTheTrack() throws {
        let artwork = Data([1, 2, 3]).base64EncodedString()
        let info = try #require(NowPlaying.applying(line(
            #"{"title":"HAKAYET","artist":"VEN1","duration":177,"elapsedTime":98.9,"timestamp":"2026-10-22T15:09:10Z","playbackRate":1,"playing":true,"bundleIdentifier":"com.google.Chrome","artworkData":"\#(artwork)"}"#),
            to: nil))
        #expect(info.title == "HAKAYET")
        #expect(info.artist == "VEN1")
        #expect(info.isPlaying)
        #expect(info.artwork == Data([1, 2, 3]))
        #expect(info.bundleIdentifier == "com.google.Chrome")
    }

    @Test func aDiffChangesOnlyItsKeys() throws {
        let start = NowPlaying.applying(line(#"{"title":"A","artist":"X","playing":true}"#), to: nil)
        let paused = try #require(NowPlaying.applying(line(#"{"playing":false}"#, diff: true), to: start))
        #expect(paused.title == "A")
        #expect(paused.artist == "X")
        #expect(!paused.isPlaying)
    }

    @Test func anEmptyPayloadMeansNothingIsPlaying() {
        let start = NowPlaying.applying(line(#"{"title":"A"}"#), to: nil)
        #expect(start != nil)
        #expect(NowPlaying.applying(line("{}"), to: start) == nil)
    }

    @Test func otherLinesLeaveTheStateAlone() {
        let start = NowPlaying(title: "A")
        #expect(NowPlaying.applying(Fixture.data(#"{"type":"log","message":"hi"}"#), to: start) == start)
        #expect(NowPlaying.applying(Fixture.data("not json"), to: start) == start)
    }

    @Test func positionMovesWhilePlayingAndStopsAtTheEnd() {
        let then = Date(timeIntervalSince1970: 1_000)
        var info = NowPlaying(title: "A", duration: 100, elapsed: 40, timestamp: then, playbackRate: 1, isPlaying: true)
        #expect(info.position(at: then.addingTimeInterval(10)) == 50)
        #expect(info.position(at: then.addingTimeInterval(500)) == 100)
        #expect(info.progress(at: then.addingTimeInterval(10)) == 0.5)
        info.isPlaying = false
        #expect(info.position(at: then.addingTimeInterval(10)) == 40)
    }
}

@Suite("Island decisions")
struct IslandTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    @Test func whatNeedsYouBeatsWhatsOngoing() {
        let activities: [IslandActivity] = [
            .nowPlaying(title: "Song", isPlaying: true),
            .agentWorking(.claude, project: "app", since: now),
            .agentNeedsYou(.codex, project: "api"),
        ]
        #expect(IslandActivity.mostImportant(activities) == .agentNeedsYou(.codex, project: "api"))
    }

    @Test func aCallBeatsEverything() {
        let activities: [IslandActivity] = [.timerFinished, .call(app: "FaceTime", since: now), .charging(percent: 80)]
        #expect(IslandActivity.mostImportant(activities) == .call(app: "FaceTime", since: now))
    }

    @Test func pausedMusicStepsBack() {
        let activities: [IslandActivity] = [.nowPlaying(title: "Song", isPlaying: false), .timer(endsAt: now)]
        #expect(IslandActivity.mostImportant(activities) == .timer(endsAt: now))
    }

    @Test func amongEqualsTheFirstWins() {
        let activities: [IslandActivity] = [.agentWorking(.claude, project: "a", since: now), .agentWorking(.codex, project: "b", since: now)]
        #expect(IslandActivity.mostImportant(activities) == .agentWorking(.claude, project: "a", since: now))
        #expect(IslandActivity.mostImportant([]) == nil)
    }

    @Test func timersCountDownPauseAndResume() {
        var timer = CountdownTimer(duration: 300, startedAt: now)
        #expect(timer.remaining(at: now.addingTimeInterval(60)) == 240)
        #expect(timer.progress(at: now.addingTimeInterval(150)) == 0.5)
        timer.pause(at: now.addingTimeInterval(60))
        #expect(timer.remaining(at: now.addingTimeInterval(1000)) == 240)
        #expect(!timer.isFinished(at: now.addingTimeInterval(1000)))
        timer.resume(at: now.addingTimeInterval(1000))
        #expect(timer.remaining(at: now.addingTimeInterval(1100)) == 140)
        #expect(timer.isFinished(at: now.addingTimeInterval(1240)))
    }
}

@Suite("Formatting")
struct FormatTests {
    @Test func tokens() {
        #expect(Format.tokens(950) == "950")
        #expect(Format.tokens(12_400) == "12.4K")
        #expect(Format.tokens(3_000_000) == "3M")
        #expect(Format.tokens(250_000_000) == "250M")
        #expect(Format.tokens(1_100_000_000) == "1.1B")
    }

    @Test func transcriptTimestampsParseFastAndExactly() {
        let samples = ["2026-10-22T13:52:07.633Z", "2026-02-28T23:59:59Z", "2024-02-29T00:00:00.5Z", "1999-12-31T12:00:00.000Z"]
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for sample in samples {
            let reference = formatter.date(from: sample) ?? ISO8601DateFormatter().date(from: sample)
            let fast = Format.utcTimestamp(sample)
            #expect(fast != nil, "\(sample)")
            #expect(abs((fast?.timeIntervalSince1970 ?? 0) - (reference?.timeIntervalSince1970 ?? -1)) < 0.001, "\(sample)")
        }
        #expect(Format.utcTimestamp("2026-10-22T13:52:07+02:00") == nil, "offsets fall back to the formatter")
        #expect(Format.date(iso8601: "2026-10-22T13:52:07+02:00") != nil)
        #expect(Format.utcTimestamp("not a date") == nil)
    }

    @Test func clocksAndSpans() {
        #expect(Format.clock(42) == "0:42")
        #expect(Format.clock(725) == "12:05")
        #expect(Format.clock(3725) == "1:02:05")
        #expect(Format.span(45) == "45s")
        #expect(Format.span(3900) == "1h 5m")
        #expect(Format.span(7200) == "2h")
        #expect(Format.span(2 * 86_400 + 4 * 3600) == "2d 4h")
        let now = Date()
        #expect(Format.until(now.addingTimeInterval(-5), from: now) == "now")
        #expect(Format.until(now.addingTimeInterval(11_520), from: now) == "in 3h 12m")
    }
}
