import Foundation

/// Who a Claude Code login belongs to, from the `oauthAccount` object Claude Code keeps in
/// `~/.claude.json`.
public struct ClaudeAccountIdentity: Codable, Equatable, Sendable {
    public var accountUUID: String
    public var email: String
    public var name: String?
    public var organizationUUID: String?
    public var organizationName: String?
    /// "default_claude_max_20x", …
    public var tier: String?

    public init(accountUUID: String, email: String, name: String? = nil, organizationUUID: String? = nil,
                organizationName: String? = nil, tier: String? = nil) {
        self.accountUUID = accountUUID
        self.email = email
        self.name = name
        self.organizationUUID = organizationUUID
        self.organizationName = organizationName
        self.tier = tier
    }

    /// One person can have the same email in a personal and a team organization.
    public var key: String { ClaudeAccountIdentity.key(email: email, organization: organizationUUID) }

    public static func key(email: String, organization: String?) -> String {
        email.lowercased() + "|" + (organization ?? "")
    }

    public var plan: String? { ClaudePlan.label(tier: tier) }

    /// What to call the account: the person's name when Claude has one, else the email.
    public var displayName: String {
        if let name, !name.trimmingCharacters(in: .whitespaces).isEmpty { return name }
        return email
    }

    public static func parse(_ oauthAccount: Data) -> ClaudeAccountIdentity? {
        guard let object = try? JSONSerialization.jsonObject(with: oauthAccount) as? [String: Any],
              let uuid = object["accountUuid"] as? String, let email = object["emailAddress"] as? String
        else { return nil }
        let name = (object["displayName"] as? String) ?? (object["fullName"] as? String)
        return ClaudeAccountIdentity(accountUUID: uuid, email: email, name: name,
                                     organizationUUID: object["organizationUuid"] as? String,
                                     organizationName: object["organizationName"] as? String,
                                     tier: (object["organizationRateLimitTier"] as? String) ?? (object["userRateLimitTier"] as? String))
    }
}

public enum ClaudePlan {
    /// "default_claude_max_20x" → "Max 20x".
    public static func label(tier: String?) -> String? {
        guard let tier = tier?.lowercased() else { return nil }
        if tier.contains("max") {
            if tier.contains("20x") { return "Max 20x" }
            if tier.contains("5x") { return "Max 5x" }
            return "Max"
        }
        if tier.contains("enterprise") { return "Enterprise" }
        if tier.contains("team") { return "Team" }
        if tier.contains("pro") { return "Pro" }
        return nil
    }
}
