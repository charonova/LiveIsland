import Foundation
import Testing
@testable import LiveIslandCore

/// Codex's auth.json shape, with a made-up, unsigned ID token.
private enum CodexFixture {
    static func base64URL(_ text: String) -> String {
        Data(text.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func idToken(email: String = "dev@example.com", plan: String = "pro", user: String = "user-1", workspace: String = "ws-1") -> String {
        let claims = #"{"email":"\#(email)","name":"Dev","https://api.openai.com/auth":{"chatgpt_plan_type":"\#(plan)","chatgpt_user_id":"\#(user)","chatgpt_account_id":"\#(workspace)"}}"#
        return base64URL(#"{"alg":"none"}"#) + "." + base64URL(claims) + ".signature"
    }

    static func auth(idToken: String = idToken(), accountID: String = "ws-1") -> Data {
        Data(#"{"auth_mode":"chatgpt","OPENAI_API_KEY":null,"tokens":{"id_token":"\#(idToken)","access_token":"made-up-access","refresh_token":"made-up-refresh","account_id":"\#(accountID)"},"last_refresh":"2026-10-23T08:00:00Z"}"#.utf8)
    }
}

@Suite("Codex accounts")
struct CodexAccountTests {
    let now = Date(timeIntervalSince1970: 1_792_850_000)

    @Test func readsWhoTheLoginBelongsTo() throws {
        let identity = try #require(CodexLogin.identity(in: CodexFixture.auth()))
        #expect(identity.email == "dev@example.com")
        #expect(identity.name == "Dev")
        #expect(identity.accountUUID == "user-1")
        #expect(identity.organizationUUID == "ws-1")
        #expect(identity.plan == "Pro")
        #expect(identity.key == "dev@example.com|ws-1")
    }

    @Test func twoPeopleInOneWorkspaceAreTwoAccounts() throws {
        let a = try #require(CodexLogin.identity(in: CodexFixture.auth(idToken: CodexFixture.idToken(email: "a@example.com", user: "u-a"))))
        let b = try #require(CodexLogin.identity(in: CodexFixture.auth(idToken: CodexFixture.idToken(email: "b@example.com", user: "u-b"))))
        #expect(a.key != b.key)
    }

    @Test func ignoresLoginsItCantRead() {
        #expect(CodexLogin.identity(in: Data(#"{"OPENAI_API_KEY":"made-up-key","tokens":null}"#.utf8)) == nil)
        #expect(CodexLogin.identity(in: CodexFixture.auth(idToken: "not-a-jwt")) == nil)
        #expect(CodexLogin.identity(in: Data("nope".utf8)) == nil)
    }

    @Test func namesChatGPTPlans() {
        #expect(CodexPlan.label(planType: "plus") == "Plus")
        #expect(CodexPlan.label(planType: "team") == "Team")
        #expect(CodexPlan.label(planType: "edu") == "Edu")
        #expect(ClaudeAccountIdentity(accountUUID: "u", email: "e", tier: "prolite").plan == "Pro Lite")
        #expect(ClaudeAccountIdentity(accountUUID: "u", email: "e", tier: "pro").plan == "Pro")
        #expect(CodexPlan.label(planType: "") == nil)
        #expect(ClaudeAccountIdentity(accountUUID: "u", email: "e", tier: "plus").plan == "Plus")
        #expect(ClaudeAccountIdentity(accountUUID: "u", email: "e", tier: "default_claude_max_20x").plan == "Max 20x")
    }

    @Test func codexLimitsFitTheAccountBook() {
        let limits = CodexLimits(primary: RateLimitWindow(usedPercent: 12, windowMinutes: 300, resetsAt: now),
                                 secondary: RateLimitWindow(usedPercent: 40, windowMinutes: 10_080, resetsAt: now.addingTimeInterval(9000)),
                                 observedAt: now, session: "/Users/me/.codex/sessions/rollout-x.jsonl").usageLimits
        #expect(limits.fiveHour?.usedPercent == 12)
        #expect(limits.sevenDay?.usedPercent == 40)
        #expect(limits.session == "/Users/me/.codex/sessions/rollout-x.jsonl")
    }

    @Test func listsCodexAccountsActiveFirst() throws {
        let a = try #require(CodexLogin.identity(in: CodexFixture.auth(idToken: CodexFixture.idToken(email: "a@example.com", user: "u-a"))))
        let b = try #require(CodexLogin.identity(in: CodexFixture.auth(idToken: CodexFixture.idToken(email: "b@example.com", user: "u-b"))))
        var book = AccountBook()
        book.setActive(a, at: now)
        book.setActive(b, at: now.addingTimeInterval(10))
        book.entries[a.key]?.hasSavedLogin = true
        let list = CodexAccounts.list(book: book, switching: true, now: now)
        #expect(list.map(\.identity.email) == ["b@example.com", "a@example.com"])
        #expect(list.allSatisfy { $0.kind == .codex })
        #expect(list[1].switcher == .liveIsland && list[0].switcher == nil, "only saved logins can be switched to")
        #expect(CodexAccounts.list(book: book, switching: false, now: now).allSatisfy { $0.switcher == nil })
        // The same email in Claude Code and Codex are two different rows.
        #expect(list[1].id != ClaudeAccount(identity: a).id)
    }
}
