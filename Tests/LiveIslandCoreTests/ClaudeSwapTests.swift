import Foundation
import Testing
@testable import LiveIslandCore

/// Lines shaped like claude-swap 0.28's own output, with made-up accounts.
private enum Swap {
    static let poll = #"{"schemaVersion": 1, "event": "poll", "ts": "2026-10-28T11:01:49Z", "active": {"number": 1, "email": "main@example.com"}, "headroomPct": {"1": 33.0, "2": 1.0, "3": 1.0}, "threshold": 90.0, "windowsPct": {"1": {"5h": 15.0, "7d": 67.0}, "2": {"5h": 0.0, "7d": 99.0}, "3": {"5h": 0.0, "7d": 99.0}}}"#
    static let noSwitch = #"{"schemaVersion": 1, "event": "no-switch", "ts": "2026-10-28T11:01:49Z", "reason": "below-threshold", "detail": "7d 67% < 90%"}"#
    static let switched = #"{"schemaVersion": 1, "event": "switch", "ts": "2026-10-28T12:00:00Z", "trigger": "proactive", "from": {"number": "1", "email": "main@example.com"}, "to": {"number": "2", "email": "work@example.com"}, "warnings": [], "dryRun": false}"#
    static let dryRun = #"{"schemaVersion": 1, "event": "switch", "ts": "2026-10-28T12:00:00Z", "trigger": "proactive", "from": {"number": 1}, "to": {"number": 2}, "dryRun": true}"#
    static let exhausted = #"{"schemaVersion": 1, "event": "all-exhausted", "ts": "2026-10-28T12:00:00Z", "earliestResetAt": "2026-10-28T14:30:00Z"}"#
    static let quarantined = #"{"schemaVersion": 1, "event": "account-quarantined", "ts": "2026-10-28T12:00:00Z", "number": "3", "email": "spare@example.com", "reason": "relogin-required"}"#
    static let error = #"{"schemaVersion": 1, "event": "error", "ts": "2026-10-28T12:00:00Z", "message": "usage endpoint unreachable", "transient": true}"#
    static let future = #"{"schemaVersion": 1, "event": "lunar-phase", "ts": "2026-10-28T12:00:00Z", "phase": "full"}"#
    static let list = #"{"schemaVersion": 1, "activeAccountNumber": 1, "accounts": [{"number": 1, "email": "main@example.com", "active": true, "usageStatus": "ok", "alias": "main", "threshold": 85.0, "loginExpiresAt": "2027-01-01T00:00:00Z", "usage": {"fiveHour": {"pct": 15.0, "resetsAt": "2026-10-28T14:30:00.300010+00:00"}, "sevenDay": {"pct": 67.0, "resetsAt": "2026-11-03T01:00:00.300035+00:00", "projectedExhaustionAt": "2026-10-29T03:46:31Z", "willLastToReset": false}}, "usageFetchedAt": "2026-10-28T11:00:00Z"}, {"number": 2, "email": "work@example.com", "active": false, "usageStatus": "relogin_required", "disabled": true, "usageError": "token revoked", "usage": {"fiveHour": {"pct": 0.0}, "sevenDay": {"pct": 99.0}}}]}"#
    static let settings = #"{"schemaVersion": 1, "path": "/Users/me/.claude-swap-backup/settings.json", "settings": [{"key": "autoswitch.threshold", "value": 90.0, "isSet": false}, {"key": "autoswitch.weeklyThreshold", "value": null, "isSet": false}, {"key": "autoswitch.strategy", "value": "best", "isSet": true}, {"key": "updates.check", "value": true, "isSet": false}, {"key": "autoswitch.hysteresisPct", "value": 7.5, "isSet": true}]}"#

    static func event(_ line: String) -> ClaudeSwapEvent? { ClaudeSwapEvent.parse(Data(line.utf8))?.event }
}

@Suite("claude-swap")
struct ClaudeSwapTests {
    @Test func readsAPoll() throws {
        let parsed = try #require(ClaudeSwapEvent.parse(Data(Swap.poll.utf8)))
        #expect(parsed.at == Format.date(iso8601: "2026-10-28T11:01:49Z"))
        guard case .poll(let active, let windows, let threshold) = parsed.event else { Issue.record("not a poll"); return }
        #expect(active?.number == 1 && active?.email == "main@example.com")
        #expect(windows[2]?.week == 99 && windows[1]?.fiveHour == 15)
        #expect(threshold == 90)
        #expect(parsed.event.summary == "Checked: on main@example.com · #1 15%/67%, #2 0%/99%, #3 0%/99% · switch at 90%")
        #expect(!parsed.event.isNotable)
    }

    @Test func readsASwitchEvenWithNumbersAsText() throws {
        let event = try #require(Swap.event(Swap.switched))
        guard case .switched(let trigger, let from, let to, let dryRun) = event else { Issue.record("not a switch"); return }
        #expect(trigger == "proactive" && from?.number == 1 && to?.number == 2 && !dryRun)
        #expect(event.summary == "Switched from main@example.com to work@example.com (proactive)")
        #expect(event.isNotable)
        let rehearsal = try #require(Swap.event(Swap.dryRun))
        #expect(rehearsal.summary == "Would switch from account 1 to account 2 (proactive)")
        #expect(!rehearsal.isNotable, "a dry run changes nothing")
    }

    @Test func readsTheOtherEvents() throws {
        #expect(Swap.event(Swap.noSwitch)?.summary == "No switch: 7d 67% < 90%")
        let exhausted = try #require(Swap.event(Swap.exhausted))
        #expect(exhausted == .allExhausted(earliestReset: Format.date(iso8601: "2026-10-28T14:30:00Z")))
        #expect(exhausted.isNotable)
        #expect(Swap.event(Swap.quarantined)?.summary == "Set aside spare@example.com: relogin-required")
        #expect(Swap.event(Swap.error)?.summary == "Error: usage endpoint unreachable")
        #expect(Swap.event(Swap.error)?.isNotable == false, "a passing error stays in the console")
    }

    @Test func keepsWhatItDoesntKnow() {
        #expect(Swap.event(Swap.future) == .other("lunar-phase"))
        #expect(ClaudeSwapEvent.parse(Data("not json".utf8)) == nil)
        #expect(ClaudeSwapEvent.parse(Data(#"{"schemaVersion":1}"#.utf8)) == nil)
    }

    @Test func readsTheAccountsWithTheirSettings() throws {
        let accounts = try #require(ClaudeSwapJSON.accounts(from: Data(Swap.list.utf8)))
        #expect(accounts.count == 2)
        let main = accounts[0], work = accounts[1]
        #expect(main.isActive && main.name == "main" && main.threshold == 85)
        #expect(main.fiveHour?.usedPercent == 15 && main.sevenDay?.usedPercent == 67)
        #expect(main.projectedExhaustionAt == Format.date(iso8601: "2026-10-29T03:46:31Z") && main.willLastToReset == false)
        #expect(main.loginExpiresAt == Format.date(iso8601: "2027-01-01T00:00:00Z"))
        #expect(work.isDisabled && work.needsLogin && work.usageError == "token revoked" && work.name == "work@example.com")
    }

    @Test func readsTheSettings() throws {
        let settings = try #require(ClaudeSwapSetting.parse(Data(Swap.settings.utf8)))
        let values = Dictionary(uniqueKeysWithValues: settings.map { ($0.key, $0) })
        #expect(values["autoswitch.threshold"]?.value == "90")
        #expect(values["autoswitch.weeklyThreshold"]?.value == "")
        #expect(values["autoswitch.strategy"]?.value == "best" && values["autoswitch.strategy"]?.isSet == true)
        #expect(values["updates.check"]?.value == "true")
        #expect(values["autoswitch.hysteresisPct"]?.value == "7.5")
    }

    @Test func readsVersions() {
        #expect(ClaudeSwapCommand.version(from: "cswap 0.28.0\n") == "0.28.0")
        #expect(ClaudeSwapCommand.version(from: "command not found") == nil)
        #expect(ClaudeSwapCommand.newerVersion(in: "A newer version of claude-swap is available (0.29.0). You are using 0.28.0.") == "0.29.0")
        #expect(ClaudeSwapCommand.newerVersion(in: "Added Account 1") == nil)
    }

    @Test func splitsTypedCommandsWithoutAShell() {
        #expect(ClaudeSwapCommand.arguments("cswap alias 2 \"Work laptop\"") == ["alias", "2", "Work laptop"])
        #expect(ClaudeSwapCommand.arguments("threshold   3 80") == ["threshold", "3", "80"])
        #expect(ClaudeSwapCommand.arguments("alias 2 it\\'s") == ["alias", "2", "it's"])
        #expect(ClaudeSwapCommand.arguments("alias 2 '$(rm -rf ~)'") == ["alias", "2", "$(rm -rf ~)"], "nothing is expanded")
        #expect(ClaudeSwapCommand.arguments("alias 2 \"open") == nil)
        #expect(ClaudeSwapCommand.arguments("") == [])
    }

    @Test func turnsAwayCommandsThatNeedATerminal() {
        #expect(ClaudeSwapCommand.needsTerminal([]))
        #expect(ClaudeSwapCommand.needsTerminal(["tui"]) && ClaudeSwapCommand.needsTerminal(["watch"]))
        #expect(ClaudeSwapCommand.needsTerminal(["auto"]), "LiveIsland runs the loop itself")
        #expect(!ClaudeSwapCommand.needsTerminal(["auto", "--once", "--dry-run", "--json"]))
        #expect(ClaudeSwapCommand.needsTerminal(["menubar"]))
        #expect(!ClaudeSwapCommand.needsTerminal(["menubar", "--install-service"]))
        #expect(ClaudeSwapCommand.needsTerminal(["add-token"]) && ClaudeSwapCommand.needsTerminal(["add-token", "-"]))
        #expect(!ClaudeSwapCommand.needsTerminal(["list", "--json"]))
    }
}
