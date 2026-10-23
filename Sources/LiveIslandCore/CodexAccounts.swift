import Foundation

/// Who a Codex login belongs to, from `~/.codex/auth.json`: the ChatGPT workspace it uses, and
/// the person, from the claims inside its ID token. The token's signature isn't checked: it
/// only labels a login Codex itself wrote.
public enum CodexLogin {
    public static func identity(in authJSON: Data) -> ClaudeAccountIdentity? {
        guard let object = try? JSONSerialization.jsonObject(with: authJSON) as? [String: Any],
              let tokens = object["tokens"] as? [String: Any],
              let idToken = tokens["id_token"] as? String,
              let claims = claims(of: idToken),
              let email = claims["email"] as? String
        else { return nil }
        let auth = claims["https://api.openai.com/auth"] as? [String: Any] ?? [:]
        let workspace = (tokens["account_id"] as? String) ?? (auth["chatgpt_account_id"] as? String)
        let user = (auth["chatgpt_user_id"] as? String) ?? (auth["user_id"] as? String) ?? (claims["sub"] as? String) ?? email
        return ClaudeAccountIdentity(accountUUID: user, email: email, name: claims["name"] as? String,
                                     organizationUUID: workspace, organizationName: nil,
                                     tier: auth["chatgpt_plan_type"] as? String)
    }

    /// The JSON in the middle of a JWT, base64url-encoded.
    static func claims(of jwt: String) -> [String: Any]? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var base64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

public enum CodexPlan {
    /// ChatGPT plan types: "pro" → "Pro", "plus" → "Plus"…
    public static func label(planType: String?) -> String? {
        guard let plan = planType?.lowercased(), !plan.isEmpty else { return nil }
        switch plan {
        case "free": return "Free"
        case "plus": return "Plus"
        case "pro": return "Pro"
        case "prolite", "pro_lite": return "Pro Lite"
        case "team": return "Team"
        case "business": return "Business"
        case "enterprise", "edu": return plan == "edu" ? "Edu" : "Enterprise"
        default: return plan.capitalized
        }
    }
}

extension CodexLimits {
    /// The same shape as Claude Code's limits, so one account book serves both.
    public var usageLimits: ClaudeUsageLimits {
        let windows = [primary, secondary].compactMap { $0 }
        return ClaudeUsageLimits(fiveHour: windows.first { $0.windowMinutes < 1_440 },
                                 sevenDay: windows.first { $0.windowMinutes >= 1_440 },
                                 observedAt: observedAt, session: session)
    }
}
