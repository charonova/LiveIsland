import Foundation
import Testing
@testable import LiveIslandCore

/// Output shaped like ccswap 0.42's own (`codex list --json`, `codex usage --json`,
/// `codex auto --json`), with made-up accounts.
private enum Codex {
    static let list = #"{"provider": "codex", "activeAccountNumber": 1, "accounts": [{"number": 1, "email": "Main@example.com", "authMode": "chatgpt", "planType": "prolite", "label": "Codex Pro Lite", "active": true, "disabled": false, "session": {"state": "absent", "capturePending": false, "runCount": 0, "shared": false}}, {"number": 2, "email": "work@example.com", "authMode": "chatgpt", "planType": "plus", "label": "Codex Plus", "active": false, "disabled": true, "session": {"state": "live", "capturePending": true, "runCount": 1, "shared": false}}, {"number": "3", "email": "key@example.com", "authMode": "apikey", "planType": "", "label": "", "active": false, "disabled": false, "session": {"state": "absent", "capturePending": false, "runCount": 0, "shared": false}}]}"#
    static let usage = #"{"provider": "codex", "accounts": [{"number": 1, "email": "Main@example.com", "active": true, "usage": {"five_hour": {"pct": 12.0, "resets_at": "2026-10-28T15:00:00+00:00"}, "weekly": {"pct": 64, "resets_at": "2026-11-02T09:00:00+00:00"}, "reset_credits": {"available": 2}}, "error": null, "status": null}, {"number": 2, "email": "work@example.com", "active": false, "usage": null, "error": "http-401", "status": null}, {"number": 3, "email": "key@example.com", "active": false, "usage": null, "error": null, "status": "API key account"}]}"#
    static let poll = #"{"schemaVersion": 1, "event": "poll", "ts": "2026-10-28T11:01:49Z", "active": {"number": 1, "email": "main@example.com"}, "headroomPct": {"1": 36.0, "2": null, "3": 100.0}, "threshold": 90.0}"#
    static let switched = #"{"schemaVersion": 1, "event": "switch", "ts": "2026-10-28T12:00:00Z", "trigger": "proactive", "from": {"number": 1, "email": "main@example.com"}, "to": {"number": 3, "email": "spare@example.com"}, "warnings": [], "dryRun": false}"#
    static let noSwitch = #"{"schemaVersion": 1, "event": "no-switch", "ts": "2026-10-28T12:00:00Z", "reason": "no-active-account", "detail": "log in and run 'ccswap codex add' first"}"#
    static let switchResult = #"{"switched": true, "from": {"number": 1, "email": ""}, "to": {"number": 2, "email": "work@example.com"}, "reason": "requested"}"#
}

@Suite("ccswap for Codex")
struct CodexSwapTests {
    @Test func readsAccountsWithTheirUsage() throws {
        let readAt = Date(timeIntervalSince1970: 1_800_000_000)
        let accounts = try #require(CodexSwapJSON.accounts(list: Data(Codex.list.utf8), usage: Data(Codex.usage.utf8), readAt: readAt))
        #expect(accounts.map(\.number) == [1, 2, 3])
        let main = accounts[0]
        #expect(main.isActive && main.plan == "Pro Lite" && !main.isDisabled)
        #expect(main.fiveHour?.usedPercent == 12 && main.fiveHour?.windowMinutes == 300)
        #expect(main.fiveHour?.resetsAt == Format.date(iso8601: "2026-10-28T15:00:00Z"))
        #expect(main.weekly?.usedPercent == 64 && main.weekly?.windowMinutes == 10_080)
        #expect(main.bankedResets == 2 && main.usageError == nil && main.usageReadAt == readAt)
        let work = accounts[1]
        #expect(work.isDisabled && work.capturePending && work.needsLogin && work.fiveHour == nil)
        #expect(accounts[2].authMode == "apikey" && accounts[2].usageError == "API key account" && !accounts[2].needsLogin)
    }

    @Test func readsAccountsWithoutUsage() throws {
        let accounts = try #require(CodexSwapJSON.accounts(list: Data(Codex.list.utf8)))
        #expect(accounts.count == 3 && accounts.allSatisfy { $0.fiveHour == nil && $0.usageReadAt == nil })
        #expect(CodexSwapJSON.accounts(list: Data("No managed Codex accounts".utf8)) == nil)
    }

    @Test func readsASwitch() throws {
        let result = try #require(CodexSwapJSON.switched(from: Data(Codex.switchResult.utf8)))
        #expect(result.number == 2 && result.email == "work@example.com")
        #expect(CodexSwapJSON.switched(from: Data(#"{"switched": false}"#.utf8)) == nil)
    }

    @Test func readsAPollFromRoomLeft() throws {
        let parsed = try #require(CodexSwapEvent.parse(Data(Codex.poll.utf8)))
        guard case .poll(let active, let used, let threshold) = parsed.event else { Issue.record("not a poll"); return }
        #expect(active?.number == 1 && threshold == 90)
        #expect(used == [1: 64, 3: 0])
        #expect(parsed.event.summary == "Checked: on main@example.com · #1 64%, #3 0% · switch at 90%")
        #expect(!parsed.event.isNotable && parsed.event.kind == "poll")
    }

    @Test func aSwitchSaysToRestartCodex() throws {
        let event = try #require(CodexSwapEvent.parse(Data(Codex.switched.utf8))?.event)
        #expect(event.kind == "switch" && event.isNotable)
        #expect(event.summary == "Switched from main@example.com to spare@example.com (proactive) · restart Codex to use it")
        let quiet = try #require(CodexSwapEvent.parse(Data(Codex.noSwitch.utf8))?.event)
        #expect(quiet.summary == "No switch: log in and run 'ccswap codex add' first" && !quiet.isNotable)
        #expect(CodexSwapEvent.parse(Data("not json".utf8)) == nil)
    }

    @Test func typedCommandsStayWithCodex() {
        #expect(CodexSwapCommand.arguments("list --json") == ["codex", "list", "--json"])
        #expect(CodexSwapCommand.arguments("ccswap codex switch 2") == ["codex", "switch", "2"])
        #expect(CodexSwapCommand.arguments("codex usage") == ["codex", "usage"])
        // Claude's commands become Codex ones, which ccswap refuses: nothing reaches Claude Code.
        #expect(CodexSwapCommand.arguments("ccswap switch 2") == ["codex", "switch", "2"])
        #expect(CodexSwapCommand.arguments("config set autoswitch.threshold 85") == ["config", "set", "autoswitch.threshold", "85"])
        #expect(CodexSwapCommand.arguments("--version") == ["--version"])
        #expect(CodexSwapCommand.arguments("   ") == [])
        #expect(CodexSwapCommand.arguments("switch \"open") == nil)
    }

    @Test func knowsWhatNeedsATerminal() {
        #expect(CodexSwapCommand.needsTerminal(["codex", "run", "2"]))
        #expect(CodexSwapCommand.needsTerminal(["codex", "auto"]))
        #expect(!CodexSwapCommand.needsTerminal(["codex", "auto", "--once", "--dry-run"]))
        #expect(CodexSwapCommand.needsTerminal(["codex", "remove", "2"]))
        #expect(!CodexSwapCommand.needsTerminal(["codex", "remove", "2", "--yes"]))
        #expect(CodexSwapCommand.needsTerminal(["codex", "redeem-reset", "1"]))
        #expect(!CodexSwapCommand.needsTerminal(["codex", "list", "--json"]))
        #expect(!CodexSwapCommand.needsTerminal(["config", "list"]))
    }

    @Test func readsTheUpdateNotice() {
        #expect(CodexSwapCommand.newerVersion(in: "A newer version of ccswap is available (0.43.0). Run: ccswap upgrade") == "0.43.0")
        #expect(CodexSwapCommand.newerVersion(in: "A newer version of claude-swap is available (0.30.0)") == nil)
    }

    @Test func showsExactlyCcswapsAccounts() throws {
        let now = try #require(Format.date(iso8601: "2026-10-28T12:00:00Z"))
        var book = AccountBook()
        let main = ClaudeAccountIdentity(accountUUID: "user-1", email: "main@example.com", name: "Main", organizationUUID: "ws-1", tier: "pro")
        book.setActive(main, at: now)
        book.setActive(ClaudeAccountIdentity(accountUUID: "user-9", email: "gone@example.com"), at: now)
        book.setActive(main, at: now)
        let swap = try #require(CodexSwapJSON.accounts(list: Data(Codex.list.utf8), usage: Data(Codex.usage.utf8), readAt: now))
        let accounts = CodexAccounts.merge(book: book, ccswap: swap, now: now)
        #expect(accounts.map(\.ccswapNumber) == [1, 2, 3])
        #expect(accounts.allSatisfy { $0.kind == .codex && $0.switcher == .ccswap })
        #expect(accounts[0].identity.name == "Main" && accounts[0].identity.plan == "Pro Lite" && accounts[0].isActive)
        #expect(accounts[0].sevenDay?.usedPercent == 64)
        #expect(accounts[1].needsLogin && accounts[1].identity.email == "work@example.com")
        #expect(!accounts.contains { $0.identity.email == "gone@example.com" })
        // Without ccswap's accounts, the ones Codex used here.
        #expect(CodexAccounts.merge(book: book, ccswap: [], now: now).count == 2)
        #expect(CodexAccounts.merge(book: book, ccswap: nil, now: now).allSatisfy { $0.switcher == nil })
    }

    @Test func aFresherSessionReadingWinsForTheAccountInUse() throws {
        let now = try #require(Format.date(iso8601: "2026-10-28T12:00:00Z"))
        var book = AccountBook()
        let main = ClaudeAccountIdentity(accountUUID: "user-1", email: "main@example.com", organizationUUID: "ws-1")
        book.setActive(main, at: now)
        book.entries[main.key]?.fiveHour = RateLimitWindow(usedPercent: 40, windowMinutes: 300, resetsAt: now.addingTimeInterval(3_600))
        book.entries[main.key]?.limitsObservedAt = now.addingTimeInterval(60)
        let swap = try #require(CodexSwapJSON.accounts(list: Data(Codex.list.utf8), usage: Data(Codex.usage.utf8), readAt: now))
        let active = try #require(CodexAccounts.merge(book: book, ccswap: swap, now: now.addingTimeInterval(90)).first)
        #expect(active.fiveHour?.usedPercent == 40 && active.sevenDay?.usedPercent == 64)
    }
}
