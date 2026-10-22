import Foundation
import Testing
@testable import LiveIslandCore

/// Shapes of Claude Code's files, with made-up values.
private enum AccountFixture {
    static func oauthAccount(email: String = "a@example.com", uuid: String = "acct-a", org: String = "org-a",
                             tier: String = "default_claude_max_20x", name: String = "Aïcha") -> String {
        """
        {
            "accountUuid": "\(uuid)",
            "emailAddress": "\(email)",
            "organizationUuid": "\(org)",
            "displayName": "\(name)",
            "organizationRateLimitTier": "\(tier)",
            "organizationName": "\(email)'s Organization"
          }
        """
    }

    static func config(oauth: String) -> String {
        """
        {
          "numStartups": 738,
          "projects": {
            "/Users/me/app": {
              "oauthAccount": {"emailAddress": "nested@example.com"},
              "note": "a } brace and a \\" quote"
            }
          },
          "oauthAccount": \(oauth),
          "tipsHistory": [1, 2, {"x": "]"}]
        }
        """
    }

    static let credentials = #"{"mcpOAuth":{"figma|1":{"serverName":"figma","accessToken":"mcp-token"}},"claudeAiOauth":{"accessToken":"old-access","refreshToken":"old-refresh","expiresAt":1792900000000,"refreshTokenExpiresAt":1800000000000,"scopes":["user:inference"],"subscriptionType":"max"}}"#
}

@Suite("Claude accounts")
struct AccountTests {
    let now = Date(timeIntervalSince1970: 1_792_850_000)

    @Test func readsWhoTheLoginBelongsTo() throws {
        let identity = try #require(ClaudeAccountIdentity.parse(Data(AccountFixture.oauthAccount().utf8)))
        #expect(identity.email == "a@example.com")
        #expect(identity.accountUUID == "acct-a")
        #expect(identity.displayName == "Aïcha")
        #expect(identity.plan == "Max 20x")
        #expect(identity.key == "a@example.com|org-a")
        #expect(ClaudePlan.label(tier: "default_claude_max_5x") == "Max 5x")
        #expect(ClaudePlan.label(tier: "claude_pro") == "Pro")
        #expect(ClaudePlan.label(tier: nil) == nil)
    }

    @Test func findsOnlyTheTopLevelOAuthAccount() throws {
        let config = Data(AccountFixture.config(oauth: AccountFixture.oauthAccount()).utf8)
        let value = try #require(ClaudeConfigFile.value(of: "oauthAccount", in: config))
        #expect(String(decoding: value, as: UTF8.self) == AccountFixture.oauthAccount())
        #expect(ClaudeConfigFile.value(of: "missing", in: config) == nil)
    }

    @Test func swapsTheAccountAndLeavesEveryOtherByteAlone() throws {
        let before = AccountFixture.config(oauth: AccountFixture.oauthAccount())
        let replacement = AccountFixture.oauthAccount(email: "b@example.com", uuid: "acct-b", org: "org-b")
        let after = try #require(ClaudeConfigFile.replacingValue(of: "oauthAccount", in: Data(before.utf8), with: Data(replacement.utf8)))
        #expect(String(decoding: after, as: UTF8.self) == AccountFixture.config(oauth: replacement))
        // Still valid JSON, with the nested look-alike untouched.
        let object = try #require(try JSONSerialization.jsonObject(with: after) as? [String: Any])
        #expect((object["oauthAccount"] as? [String: Any])?["emailAddress"] as? String == "b@example.com")
        let nested = ((object["projects"] as? [String: Any])?["/Users/me/app"] as? [String: Any])?["oauthAccount"] as? [String: Any]
        #expect(nested?["emailAddress"] as? String == "nested@example.com")
    }

    @Test func addsTheAccountWhenLoggedOut() throws {
        let file = Data("{\n  \"numStartups\": 3\n}\n".utf8)
        let after = try #require(ClaudeConfigFile.replacingValue(of: "oauthAccount", in: file, with: Data(#"{"emailAddress":"b@example.com"}"#.utf8)))
        let object = try #require(try JSONSerialization.jsonObject(with: after) as? [String: Any])
        #expect(object["numStartups"] as? Int == 3)
        #expect((object["oauthAccount"] as? [String: Any])?["emailAddress"] as? String == "b@example.com")
        let empty = try #require(ClaudeConfigFile.replacingValue(of: "k", in: Data("{}".utf8), with: Data("1".utf8)))
        #expect((try JSONSerialization.jsonObject(with: empty) as? [String: Any])?["k"] as? Int == 1)
        #expect(ClaudeConfigFile.replacingValue(of: "k", in: Data("[1]".utf8), with: Data("1".utf8)) == nil)
    }

    @Test func replacesOnlyTheClaudeLoginAndKeepsMCPLogins() throws {
        let credentials = Data(AccountFixture.credentials.utf8)
        let login = try #require(ClaudeLogin.extract(from: credentials))
        #expect(login["refreshToken"] as? String == "old-refresh")
        let expiry = ClaudeLogin.expiry(of: login)
        #expect(expiry.access == Date(timeIntervalSince1970: 1_792_900_000))
        #expect(expiry.login == Date(timeIntervalSince1970: 1_800_000_000))

        let next: [String: Any] = ["accessToken": "new-access", "refreshToken": "new-refresh", "note": "café"]
        let merged = try #require(ClaudeLogin.replacing(in: credentials, with: next))
        #expect(merged.allSatisfy { $0 < 0x80 }, "security -w prints only ASCII as text")
        let object = try #require(try JSONSerialization.jsonObject(with: merged) as? [String: Any])
        #expect((object["claudeAiOauth"] as? [String: Any])?["refreshToken"] as? String == "new-refresh")
        #expect((object["claudeAiOauth"] as? [String: Any])?["note"] as? String == "café")
        let mcp = (object["mcpOAuth"] as? [String: Any])?["figma|1"] as? [String: Any]
        #expect(mcp?["accessToken"] as? String == "mcp-token")
    }

    @Test func limitsBelongToTheNewAccountOnlyAfterItAnswered() {
        let switched = now
        // Before any reply on the new login, the status line may still show the old account.
        #expect(!AccountBook.belongsToActive(observedAt: switched.addingTimeInterval(10), activeSince: switched, latestRequestAt: nil))
        #expect(!AccountBook.belongsToActive(observedAt: switched.addingTimeInterval(20), activeSince: switched,
                                             latestRequestAt: switched.addingTimeInterval(15)))
        // A reply after sessions picked up the new login, then a report after it: that's the new account.
        let reply = switched.addingTimeInterval(45)
        #expect(AccountBook.belongsToActive(observedAt: reply.addingTimeInterval(1), activeSince: switched, latestRequestAt: reply))
        #expect(!AccountBook.belongsToActive(observedAt: reply.addingTimeInterval(-1), activeSince: switched, latestRequestAt: reply))
        // Never seen a switch: the report is the active account's.
        #expect(AccountBook.belongsToActive(observedAt: now, activeSince: nil, latestRequestAt: nil))
    }

    @Test func theBookFollowsTheActiveAccount() throws {
        let a = try #require(ClaudeAccountIdentity.parse(Data(AccountFixture.oauthAccount().utf8)))
        let b = try #require(ClaudeAccountIdentity.parse(Data(AccountFixture.oauthAccount(email: "b@example.com", uuid: "acct-b", org: "org-b").utf8)))
        var book = AccountBook()
        book.setActive(a, at: now)
        #expect(book.activeSince == nil, "the first account seen wasn't a switch")
        let limits = ClaudeUsageLimits(fiveHour: RateLimitWindow(usedPercent: 100, windowMinutes: 300, resetsAt: now.addingTimeInterval(3600)),
                                       sevenDay: RateLimitWindow(usedPercent: 40, windowMinutes: 10_080, resetsAt: nil), observedAt: now)
        let recorded = book.record(limits, latestRequestAt: nil)
        #expect(recorded)
        #expect(book.entries[a.key]?.fiveHour?.usedPercent == 100)

        book.setActive(b, at: now.addingTimeInterval(60))
        #expect(book.activeSince == now.addingTimeInterval(60))
        let stale = ClaudeUsageLimits(fiveHour: limits.fiveHour, sevenDay: limits.sevenDay, observedAt: now.addingTimeInterval(70))
        // A session still on A's login reports A's numbers after the switch: they go to A, not B.
        let routed = book.record(stale, latestRequestAt: now.addingTimeInterval(65))
        #expect(routed)
        #expect(book.entries[b.key]?.fiveHour == nil, "A's numbers mustn't land on B")
        #expect(book.entries[a.key]?.limitsObservedAt == now.addingTimeInterval(70))
        // Numbers nobody owns yet wait for a request on B's login.
        let fresh = ClaudeUsageLimits(fiveHour: RateLimitWindow(usedPercent: 3, windowMinutes: 300, resetsAt: now.addingTimeInterval(17_000)),
                                      sevenDay: RateLimitWindow(usedPercent: 20, windowMinutes: 10_080, resetsAt: now.addingTimeInterval(400_000)),
                                      observedAt: now.addingTimeInterval(80))
        let early = book.record(fresh, latestRequestAt: now.addingTimeInterval(75))
        #expect(!early)
        let placed = book.record(fresh, latestRequestAt: now.addingTimeInterval(79))
        #expect(!placed, "a request within 30 s of the switch may still be A's")
        let later = ClaudeUsageLimits(fiveHour: fresh.fiveHour, sevenDay: fresh.sevenDay, observedAt: now.addingTimeInterval(130))
        let recordedB = book.record(later, latestRequestAt: now.addingTimeInterval(120))
        #expect(recordedB)
        #expect(book.entries[b.key]?.fiveHour?.usedPercent == 3)
        #expect(book.entries[a.key]?.fiveHour?.usedPercent == 100)

        book.remove(a.key)
        #expect(book.entries[a.key] == nil)
        book.entries[b.key]?.hasSavedLogin = true
        book.remove(b.key)
        #expect(book.entries[b.key]?.hasSavedLogin == false, "the active account stays, without its saved login")
    }

    @Test func anExhaustedAccountShowsItsLimitFromTheRefusal() throws {
        let a = try #require(ClaudeAccountIdentity.parse(Data(AccountFixture.oauthAccount().utf8)))
        let c = try #require(ClaudeAccountIdentity.parse(Data(AccountFixture.oauthAccount(email: "c@example.com", uuid: "acct-c", org: "org-c").utf8)))
        var book = AccountBook()
        book.setActive(a, at: now)
        book.setActive(c, at: now.addingTimeInterval(10))
        // C never answers: its only news is the refusal, with the weekly reset.
        let resets = now.addingTimeInterval(200_000)
        book.record(ClaudeLimitNotice(status: "rejected", type: "seven_day", resetsAt: resets, observedAt: now.addingTimeInterval(40)))
        #expect(book.entries[c.key]?.sevenDay?.usedPercent == 100)
        #expect(book.entries[c.key]?.sevenDay?.resetsAt == resets)
        #expect(book.entries[c.key]?.fiveHour == nil)
        // A refusal from before the switch isn't C's.
        book.record(ClaudeLimitNotice(status: "rejected", type: "five_hour", resetsAt: now.addingTimeInterval(9000), observedAt: now.addingTimeInterval(5)))
        #expect(book.entries[c.key]?.fiveHour == nil)
    }

    @Test func aRefusalMatchingAnotherAccountsResetIsThatAccounts() throws {
        let a = try #require(ClaudeAccountIdentity.parse(Data(AccountFixture.oauthAccount().utf8)))
        let b = try #require(ClaudeAccountIdentity.parse(Data(AccountFixture.oauthAccount(email: "b@example.com", uuid: "acct-b", org: "org-b").utf8)))
        var book = AccountBook()
        book.setActive(a, at: now)
        let reset = now.addingTimeInterval(3600)
        book.record(ClaudeUsageLimits(fiveHour: RateLimitWindow(usedPercent: 98, windowMinutes: 300, resetsAt: reset), sevenDay: nil, observedAt: now),
                    latestRequestAt: nil)
        // Out of room on A, the user moves to B; a session still on A gets refused.
        book.setActive(b, at: now.addingTimeInterval(60))
        book.record(ClaudeLimitNotice(status: "rejected", type: "five_hour", resetsAt: reset.addingTimeInterval(30), observedAt: now.addingTimeInterval(70)))
        #expect(book.entries[a.key]?.fiveHour?.usedPercent == 100)
        #expect(book.entries[b.key]?.fiveHour == nil)
    }

    @Test func cleansUpNumbersFiledUnderTwoAccounts() throws {
        let a = try #require(ClaudeAccountIdentity.parse(Data(AccountFixture.oauthAccount().utf8)))
        let b = try #require(ClaudeAccountIdentity.parse(Data(AccountFixture.oauthAccount(email: "b@example.com", uuid: "acct-b", org: "org-b").utf8)))
        var book = AccountBook()
        book.setActive(b, at: now)
        book.setActive(a, at: now.addingTimeInterval(10))
        let five = RateLimitWindow(usedPercent: 59, windowMinutes: 300, resetsAt: now.addingTimeInterval(5000))
        let week = RateLimitWindow(usedPercent: 53, windowMinutes: 10_080, resetsAt: now.addingTimeInterval(450_000))
        for (key, seen) in [(a.key, now.addingTimeInterval(300)), (b.key, now.addingTimeInterval(100))] {
            book.entries[key]?.fiveHour = five
            book.entries[key]?.sevenDay = week
            book.entries[key]?.limitsObservedAt = seen
        }
        book.removeDuplicateReadings()
        #expect(book.entries[a.key]?.fiveHour?.usedPercent == 59, "the newest reading stays")
        #expect(book.entries[b.key]?.fiveHour == nil && book.entries[b.key]?.limitsObservedAt == nil)
    }

    @Test func picksTheAccountWithTheMostRoom() {
        func account(_ email: String, active: Bool = false, five: Double?, week: Double?, switcher: ClaudeAccount.Switcher? = .liveIsland,
                     needsLogin: Bool = false) -> ClaudeAccount {
            ClaudeAccount(identity: ClaudeAccountIdentity(accountUUID: email, email: email), isActive: active,
                          fiveHour: five.map { RateLimitWindow(usedPercent: $0, windowMinutes: 300, resetsAt: now.addingTimeInterval(600)) },
                          sevenDay: week.map { RateLimitWindow(usedPercent: $0, windowMinutes: 10_080, resetsAt: now.addingTimeInterval(86_400)) },
                          limitsObservedAt: now, switcher: switcher, needsLogin: needsLogin)
        }
        let accounts = [
            account("active", active: true, five: 100, week: 50),
            account("busy", five: 80, week: 20),
            account("roomy", five: 10, week: 30),
            account("full", five: 5, week: 100),
            account("expired", five: 0, week: 0, needsLogin: true),
            account("unswitchable", five: 0, week: 0, switcher: nil),
            account("unknown", five: nil, week: nil),
        ]
        #expect(ClaudeAccount.best(accounts, at: now)?.identity.email == "roomy")
        #expect(accounts[0].isAtLimit)
        #expect(accounts[0].exhaustedWindow?.windowMinutes == 300)
        // A window that has reset counts from zero.
        let later = now.addingTimeInterval(700)
        #expect(accounts[1].current(at: later).used == 20)
    }

    @Test func readsClaudeSwapsList() throws {
        let json = #"""
        {"schemaVersion":1,"activeAccountNumber":2,"accounts":[
         {"number":1,"email":"a@example.com","organizationName":"","organizationUuid":"","isOrganization":false,"active":false,
          "usageStatus":"ok","usage":{"fiveHour":{"pct":12.5,"resetsAt":"2026-10-22T18:00:00Z","countdown":"2h"},"sevenDay":{"pct":40,"resetsAt":"2026-10-25T08:00:00+00:00"}},
          "usageFetchedAt":"2026-10-22T16:00:00Z"},
         {"number":2,"email":"b@example.com","organizationName":"Team","organizationUuid":"org-b","isOrganization":true,"active":true,"usageStatus":"relogin_required","usage":null},
         {"number":3,"email":"c@example.com","organizationName":"","organizationUuid":"","active":false,"usageStatus":"ok","usage":null,"disabled":true}
        ]}
        """#
        let accounts = try #require(ClaudeSwapJSON.accounts(from: Data(json.utf8)))
        #expect(accounts.count == 3)
        #expect(accounts[0].organizationUUID == nil)
        #expect(accounts[0].fiveHour?.usedPercent == 12.5)
        #expect(accounts[0].fiveHour?.resetsAt == Format.date(iso8601: "2026-10-22T18:00:00Z"))
        #expect(accounts[0].sevenDay?.resetsAt == Format.date(iso8601: "2026-10-25T08:00:00Z"))
        #expect(accounts[0].usageFetchedAt == Format.date(iso8601: "2026-10-22T16:00:00Z"))
        #expect(accounts[1].isActive && accounts[1].needsLogin && accounts[1].fiveHour == nil)
        #expect(accounts[2].isDisabled)
        #expect(ClaudeSwapJSON.accounts(from: Data("nope".utf8)) == nil)
    }

    @Test func readsClaudeSwapsSwitchResult() {
        let ok = #"{"schemaVersion":1,"switched":true,"from":{"number":1,"email":"a@example.com"},"to":{"number":2,"email":"b@example.com"},"strategy":null,"reason":"switched","message":"Switched to Account-2 (b@example.com)","warnings":[]}"#
        #expect(ClaudeSwapJSON.switchResult(from: Data(ok.utf8))?.switched == true)
        #expect(ClaudeSwapJSON.switchResult(from: Data(ok.utf8))?.message == "Switched to Account-2 (b@example.com)")
        let error = #"{"schemaVersion":1,"error":{"type":"SwitchError","message":"Account-9 does not exist"}}"#
        #expect(ClaudeSwapJSON.switchResult(from: Data(error.utf8))?.switched == false)
        #expect(ClaudeSwapJSON.switchResult(from: Data(error.utf8))?.message == "Account-9 does not exist")
    }

    @Test func mergesLiveIslandAndClaudeSwapAccounts() throws {
        let a = try #require(ClaudeAccountIdentity.parse(Data(AccountFixture.oauthAccount().utf8)))
        var book = AccountBook()
        book.setActive(a, at: now)
        book.entries[a.key]?.hasSavedLogin = true
        book.entries[a.key]?.fiveHour = RateLimitWindow(usedPercent: 50, windowMinutes: 300, resetsAt: now.addingTimeInterval(600))
        book.entries[a.key]?.limitsObservedAt = now
        let swap = [
            ClaudeSwapAccount(number: 1, email: "A@example.com", organizationName: nil, organizationUUID: nil, isActive: true, usageStatus: "ok",
                              fiveHour: RateLimitWindow(usedPercent: 10, windowMinutes: 300, resetsAt: now.addingTimeInterval(600)), sevenDay: nil,
                              usageFetchedAt: now.addingTimeInterval(-60), isDisabled: false),
            ClaudeSwapAccount(number: 2, email: "b@example.com", organizationName: nil, organizationUUID: nil, isActive: false, usageStatus: "ok",
                              fiveHour: RateLimitWindow(usedPercent: 5, windowMinutes: 300, resetsAt: now.addingTimeInterval(600)), sevenDay: nil,
                              usageFetchedAt: now, isDisabled: false),
        ]
        let viaSwap = ClaudeAccounts.merge(book: book, claudeSwap: swap, switcher: .claudeSwap, now: now)
        #expect(viaSwap.count == 2, "A matched by email although claude-swap left its organization out")
        #expect(viaSwap[0].isActive && viaSwap[0].identity.email == "a@example.com")
        #expect(viaSwap[0].fiveHour?.usedPercent == 50, "LiveIsland's own reading is newer than claude-swap's")
        #expect(viaSwap[0].switcher == .claudeSwap && viaSwap[0].claudeSwapNumber == 1)
        #expect(viaSwap[1].identity.email == "b@example.com" && viaSwap[1].switcher == .claudeSwap && viaSwap[1].fiveHour?.usedPercent == 5)

        let native = ClaudeAccounts.merge(book: book, claudeSwap: nil, switcher: .liveIsland, now: now)
        #expect(native.count == 1 && native[0].switcher == .liveIsland)
        let off = ClaudeAccounts.merge(book: book, claudeSwap: nil, switcher: nil, now: now)
        #expect(off[0].switcher == nil)
    }

    @Test func theBookSurvivesARestart() throws {
        let a = try #require(ClaudeAccountIdentity.parse(Data(AccountFixture.oauthAccount().utf8)))
        var book = AccountBook()
        book.setActive(a, at: now)
        book.entries[a.key]?.sevenDay = RateLimitWindow(usedPercent: 47, windowMinutes: 10_080, resetsAt: now)
        let decoded = try JSONDecoder().decode(AccountBook.self, from: JSONEncoder().encode(book))
        #expect(decoded == book)
    }
}
