import Foundation
import Testing
@testable import LiveIslandCore

/// Some plans have no 5-hour limit: only the week, and maybe a model's own week. Shapes of the
/// status line's file and of claude-swap 0.29's output, with made-up accounts and numbers.
private enum Shape {
    static let statusLineWithFiveHour = #"{"observed_at":1792850000,"transcript_path":"/Users/me/.claude/projects/x/s1.jsonl","rate_limits":{"five_hour":{"used_percentage":30,"resets_at":1792860000},"seven_day":{"used_percentage":47,"resets_at":1793400000}}}"#
    static let statusLineWeekOnly = #"{"observed_at":1792850000,"transcript_path":"/Users/me/.claude/projects/x/s2.jsonl","rate_limits":{"seven_day":{"used_percentage":64,"resets_at":1793400000}}}"#
    static let statusLineNullFiveHour = #"{"observed_at":1792850000,"rate_limits":{"five_hour":null,"seven_day":{"used_percentage":64,"resets_at":1793400000}}}"#

    /// #1 has a 5-hour limit; #2 has only weekly ones, one of them Fable's; #3 was never read.
    static let list = #"""
    {"schemaVersion":1,"activeAccountNumber":2,"accounts":[
     {"number":1,"email":"five@example.com","active":false,"usageStatus":"ok",
      "usage":{"fiveHour":{"pct":20.0,"resetsAt":"2026-10-22T18:00:00Z"},"sevenDay":{"pct":40.0,"resetsAt":"2026-10-25T08:00:00Z"}},
      "usageFetchedAt":"2026-10-22T16:00:00Z"},
     {"number":2,"email":"weekly@example.com","active":true,"usageStatus":"ok",
      "usage":{"sevenDay":{"pct":64.0,"resetsAt":"2026-11-04T18:00:00Z","willLastToReset":true},
               "scoped":[{"name":"Fable","pct":0.0,"resetsAt":"2026-11-04T18:00:00Z","willLastToReset":true}]},
      "usageFetchedAt":"2026-10-22T16:00:00Z"},
     {"number":3,"email":"new@example.com","active":false,"usageStatus":"unavailable","usage":null}
    ]}
    """#

    static let pollWeekOnly = #"{"schemaVersion":1,"event":"poll","ts":"2026-10-28T11:01:49Z","active":{"number":2,"email":"weekly@example.com"},"threshold":90.0,"windowsPct":{"1":{"5h":20.0,"7d":40.0},"2":{"7d":64.0,"Fable":0.0}}}"#
}

@Suite("Limits with and without 5 hours")
struct LimitShapeTests {
    let now = Date(timeIntervalSince1970: 1_792_850_000)

    @Test func theStatusLineMaySendOnlyTheWeek() throws {
        let both = try #require(ClaudeUsageLimits.parse(Fixture.data(Shape.statusLineWithFiveHour), modified: now))
        #expect(both.fiveHour?.usedPercent == 30 && both.sevenDay?.usedPercent == 47)
        #expect(both.windows.map(\.shortLabel) == ["5 hours", "Week"])

        for json in [Shape.statusLineWeekOnly, Shape.statusLineNullFiveHour] {
            let week = try #require(ClaudeUsageLimits.parse(Fixture.data(json), modified: now))
            #expect(week.fiveHour == nil, "no 5-hour limit, not a 0% one")
            #expect(week.sevenDay?.usedPercent == 64)
            #expect(week.windows.map(\.shortLabel) == ["Week"])
            #expect(week.current(at: now.addingTimeInterval(600_000)).fiveHour == nil, "a reset doesn't bring one back")
        }
    }

    @Test func readsEachAccountsOwnLimits() throws {
        let accounts = try #require(ClaudeSwapJSON.accounts(from: Data(Shape.list.utf8)))
        #expect(accounts.map(\.windows.count) == [2, 2, 0])
        #expect(accounts[0].fiveHour?.usedPercent == 20 && accounts[0].models.isEmpty)
        #expect(accounts[1].fiveHour == nil)
        #expect(accounts[1].sevenDay?.usedPercent == 64)
        #expect(accounts[1].models.map(\.model) == ["Fable"])
        #expect(accounts[1].models.first?.windowMinutes == 10_080)
        #expect(accounts[1].models.first?.resetsAt == Format.date(iso8601: "2026-11-04T18:00:00Z"))
        #expect(accounts[1].windows.map(\.shortLabel) == ["Week", "Fable week"])

        #expect(ClaudeSwapAccount.anyHasFiveHourLimit(accounts) == true)
        #expect(ClaudeSwapAccount.anyHasFiveHourLimit([accounts[1], accounts[2]]) == false, "read, and none has one")
        #expect(ClaudeSwapAccount.anyHasFiveHourLimit([accounts[2]]) == nil, "nothing read yet")
        #expect(ClaudeSwapAccount.anyHasFiveHourLimit([]) == nil)
    }

    @Test func theAccountsShownKeepTheirOwnShape() throws {
        let swap = try #require(ClaudeSwapJSON.accounts(from: Data(Shape.list.utf8)))
        let fetched = try #require(Format.date(iso8601: "2026-10-22T16:00:00Z"))
        let accounts = ClaudeAccounts.merge(book: AccountBook(), claudeSwap: swap, switcher: .claudeSwap, now: fetched)
        let weekly = try #require(accounts.first { $0.claudeSwapNumber == 2 })
        let five = try #require(accounts.first { $0.claudeSwapNumber == 1 })
        let unread = try #require(accounts.first { $0.claudeSwapNumber == 3 })
        #expect(weekly.windows.map(\.shortLabel) == ["Week", "Fable week"])
        #expect(five.windows.map(\.shortLabel) == ["5 hours", "Week"])
        #expect(unread.windows.isEmpty)
        #expect(Set(weekly.windows.map(\.id)).count == 2, "the model's week and the week are told apart")
    }

    @Test func aNewerWeekOnlyReadingDropsAnOlder5HourOne() throws {
        let identity = ClaudeAccountIdentity(accountUUID: "acct-w", email: "weekly@example.com")
        var book = AccountBook()
        book.setActive(identity, at: now)
        let reset = now.addingTimeInterval(400_000)
        let placed = book.record(ClaudeUsageLimits(fiveHour: nil, sevenDay: RateLimitWindow(usedPercent: 65, windowMinutes: 10_080, resetsAt: reset),
                                                   observedAt: now.addingTimeInterval(60)), sessionStartedAt: now)
        #expect(placed)
        // claude-swap's older reading still had a 5-hour limit.
        let swap = ClaudeSwapAccount(number: 2, email: "weekly@example.com", organizationName: nil, organizationUUID: nil, isActive: true,
                                     usageStatus: "ok", fiveHour: RateLimitWindow(usedPercent: 12, windowMinutes: 300, resetsAt: now.addingTimeInterval(3600)),
                                     sevenDay: RateLimitWindow(usedPercent: 60, windowMinutes: 10_080, resetsAt: reset), usageFetchedAt: now, isDisabled: false)
        let account = try #require(ClaudeAccounts.merge(book: book, claudeSwap: [swap], switcher: .claudeSwap, now: now).first)
        #expect(account.fiveHour == nil, "no stale 5-hour number")
        #expect(account.sevenDay?.usedPercent == 65)
    }

    @Test func decisionsFallBackToTheWeek() {
        func account(_ email: String, five: Double?, week: Double?, fable: Double? = nil, active: Bool = false) -> ClaudeAccount {
            var account = ClaudeAccount(identity: ClaudeAccountIdentity(accountUUID: email, email: email), isActive: active,
                                        fiveHour: five.map { RateLimitWindow(usedPercent: $0, windowMinutes: 300, resetsAt: now.addingTimeInterval(600)) },
                                        sevenDay: week.map { RateLimitWindow(usedPercent: $0, windowMinutes: 10_080, resetsAt: now.addingTimeInterval(86_400)) },
                                        limitsObservedAt: now, switcher: .claudeSwap)
            account.models = fable.map { [RateLimitWindow(usedPercent: $0, windowMinutes: 10_080, resetsAt: now.addingTimeInterval(86_400), model: "Fable")] } ?? []
            return account
        }
        let out = account("out", five: nil, week: 100, active: true)
        #expect(out.used == 100 && out.isAtLimit)
        #expect(out.exhaustedWindow?.windowMinutes == 10_080)
        #expect(account("fable", five: nil, week: 30, fable: 100).isAtLimit == false, "a model's own limit leaves the other models working")
        let accounts = [out, account("busy", five: 10, week: 70), account("roomy", five: nil, week: 25, fable: 90)]
        #expect(ClaudeAccount.best(accounts, at: now)?.identity.email == "roomy")
        // A model's week resets like any other.
        let later = account("fable", five: nil, week: 30, fable: 80).current(at: now.addingTimeInterval(90_000))
        #expect(later.models.first?.usedPercent == 0 && later.models.first?.resetsAt == nil)
    }

    @Test func aModelsRefusalDoesNotInventA5HourLimit() throws {
        let identity = ClaudeAccountIdentity(accountUUID: "acct-w", email: "weekly@example.com")
        var book = AccountBook()
        book.setActive(identity, at: now)
        let notice = ClaudeLimitNotice(status: "rejected", type: "seven_day_opus", resetsAt: now.addingTimeInterval(9000), observedAt: now)
        book.record(notice, sessionStartedAt: now)
        #expect(book.entries[identity.key]?.fiveHour == nil && book.entries[identity.key]?.sevenDay == nil)
        #expect(notice.windowLabel == "Opus weekly")
        book.record(ClaudeLimitNotice(status: "rejected", type: "seven_day", resetsAt: now.addingTimeInterval(9000), observedAt: now), sessionStartedAt: now)
        #expect(book.entries[identity.key]?.sevenDay?.usedPercent == 100 && book.entries[identity.key]?.fiveHour == nil)
    }

    @Test func aPollShowsOnlyTheLimitsEachAccountHas() throws {
        let event = try #require(ClaudeSwapEvent.parse(Data(Shape.pollWeekOnly.utf8))?.event)
        guard case .poll(_, let windows, _) = event else { Issue.record("not a poll"); return }
        #expect(windows[2]?.fiveHour == nil && windows[2]?.week == 64 && windows[2]?.models == ["Fable": 0])
        #expect(windows[1]?.models.isEmpty == true)
        #expect(event.summary == "Checked: on weekly@example.com · #1 20%/40%, #2 week 64% Fable 0% · switch at 90%")
    }

    @Test func windowsSavedBeforeModelsStillLoad() throws {
        let old = #"{"usedPercent":47,"windowMinutes":10080,"resetsAt":0}"#
        let window = try JSONDecoder().decode(RateLimitWindow.self, from: Data(old.utf8))
        #expect(window.model == nil && window.shortLabel == "Week")
        let fable = RateLimitWindow(usedPercent: 1, windowMinutes: 10_080, resetsAt: nil, model: "Fable")
        #expect(try JSONDecoder().decode(RateLimitWindow.self, from: JSONEncoder().encode(fable)) == fable)
    }
}
