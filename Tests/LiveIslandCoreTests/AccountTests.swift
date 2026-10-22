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
}
