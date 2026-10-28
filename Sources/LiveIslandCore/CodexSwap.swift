import Foundation

/// One Codex account in ccswap's `ccswap codex list --json`, with what `ccswap codex usage
/// --json` read for it.
public struct CodexSwapAccount: Equatable, Sendable {
    public var number: Int
    public var email: String
    /// "chatgpt" or "apikey".
    public var authMode: String
    /// ChatGPT's plan type ("pro", "plus"…), empty when unknown.
    public var planType: String
    public var isActive: Bool
    public var isDisabled: Bool
    /// A `ccswap codex run` session still holds its login: ccswap saves it back when it ends.
    public var capturePending: Bool
    public var fiveHour: RateLimitWindow?
    public var weekly: RateLimitWindow?
    /// Why its usage couldn't be read ("http-401"…), or ccswap's note in place of usage
    /// ("API key account"…).
    public var usageError: String?
    /// Banked resets it can redeem with `ccswap codex redeem-reset`.
    public var bankedResets: Int?
    /// When LiveIsland asked ccswap for its usage.
    public var usageReadAt: Date?

    public init(number: Int, email: String, authMode: String = "chatgpt", planType: String = "", isActive: Bool = false,
                isDisabled: Bool = false, capturePending: Bool = false, fiveHour: RateLimitWindow? = nil,
                weekly: RateLimitWindow? = nil, usageError: String? = nil, bankedResets: Int? = nil, usageReadAt: Date? = nil) {
        self.number = number
        self.email = email
        self.authMode = authMode
        self.planType = planType
        self.isActive = isActive
        self.isDisabled = isDisabled
        self.capturePending = capturePending
        self.fiveHour = fiveHour
        self.weekly = weekly
        self.usageError = usageError
        self.bankedResets = bankedResets
        self.usageReadAt = usageReadAt
    }

    /// Its login failed: sign in to it again with codex login, then add it again.
    public var needsLogin: Bool { usageError?.contains("401") == true }
    public var plan: String? { CodexPlan.label(planType: planType) }
}

/// ccswap's Codex JSON.
public enum CodexSwapJSON {
    /// `ccswap codex list --json`, with `ccswap codex usage --json` when there is one.
    public static func accounts(list: Data, usage: Data? = nil, readAt: Date? = nil) -> [CodexSwapAccount]? {
        guard let object = try? JSONSerialization.jsonObject(with: list) as? [String: Any],
              let rows = object["accounts"] as? [[String: Any]]
        else { return nil }
        let usageRows = usage.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["accounts"] as? [[String: Any]] ?? []
        var usageByNumber: [Int: [String: Any]] = [:]
        for row in usageRows { if let number = number(row["number"]) { usageByNumber[number] = row } }
        return rows.compactMap { row in
            guard let number = number(row["number"]), let email = row["email"] as? String else { return nil }
            let session = row["session"] as? [String: Any]
            var account = CodexSwapAccount(number: number, email: email, authMode: row["authMode"] as? String ?? "unknown",
                                           planType: row["planType"] as? String ?? "", isActive: row["active"] as? Bool ?? false,
                                           isDisabled: row["disabled"] as? Bool ?? false,
                                           capturePending: session?["capturePending"] as? Bool ?? false)
            if let reading = usageByNumber[number] {
                account.usageReadAt = readAt
                let windows = reading["usage"] as? [String: Any] ?? [:]
                account.fiveHour = window(windows["five_hour"], minutes: 300)
                account.weekly = window(windows["weekly"] ?? windows["seven_day"], minutes: 10_080)
                account.bankedResets = (windows["reset_credits"] as? [String: Any])?["available"] as? Int
                account.usageError = (reading["status"] as? String) ?? message(reading["error"])
            }
            return account
        }
    }

    /// `ccswap codex switch … --json`: whom it switched to.
    public static func switched(from data: Data) -> (number: Int?, email: String)? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["switched"] as? Bool == true
        else { return nil }
        let to = object["to"] as? [String: Any]
        return (number(to?["number"]), to?["email"] as? String ?? "")
    }

    private static func window(_ value: Any?, minutes: Int) -> RateLimitWindow? {
        guard let value = value as? [String: Any], let used = (value["pct"] as? NSNumber)?.doubleValue else { return nil }
        return RateLimitWindow(usedPercent: used, windowMinutes: minutes,
                               resetsAt: (value["resets_at"] as? String).flatMap(Format.date(iso8601:)))
    }

    private static func message(_ value: Any?) -> String? {
        if let text = value as? String, !text.isEmpty { return text }
        return (value as? [String: Any])?["message"] as? String
    }

    /// ccswap writes account numbers as numbers or as strings.
    static func number(_ value: Any?) -> Int? {
        (value as? Int) ?? (value as? String).flatMap(Int.init)
    }
}

/// One line of `ccswap codex auto --json`. Its events are claude-swap's, except its checks,
/// which give each account's room left rather than its windows.
public enum CodexSwapEvent: Equatable, Sendable {
    /// A check of every account: the one in use, and how full each one is.
    case poll(active: ClaudeSwapEvent.Account?, used: [Int: Double], threshold: Double?)
    case swap(ClaudeSwapEvent)

    public static func parse(_ line: Data) -> (event: CodexSwapEvent, at: Date?)? {
        guard let parsed = ClaudeSwapEvent.parse(line) else { return nil }
        guard case .poll(let active, _, let threshold) = parsed.event,
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
        else { return (.swap(parsed.event), parsed.at) }
        var used: [Int: Double] = [:]
        for (key, value) in object["headroomPct"] as? [String: Any] ?? [:] {
            guard let number = Int(key), let room = (value as? NSNumber)?.doubleValue else { continue }
            used[number] = 100 - room
        }
        return (.poll(active: active, used: used, threshold: threshold), parsed.at)
    }

    public var kind: String {
        switch self {
        case .poll: return "poll"
        case .swap(let event): return event.kind
        }
    }

    public var summary: String {
        switch self {
        case .poll(let active, let used, let threshold):
            let name = active?.email ?? active?.number.map { "account \($0)" } ?? "no account"
            let parts = used.keys.sorted().map { "#\($0) \(Int(used[$0]!.rounded()))%" }
            let line = threshold.map { " · switch at \(Int($0))%" } ?? ""
            return "Checked: on \(name) · \(parts.joined(separator: ", "))\(line)"
        case .swap(let event):
            // Codex reads its login when it starts.
            if case .switched(_, _, _, false) = event { return event.summary + " · restart Codex to use it" }
            return event.summary
        }
    }

    public var isNotable: Bool {
        if case .swap(let event) = self { return event.isNotable }
        return false
    }
}

/// Running `ccswap` for Codex from LiveIsland.
public enum CodexSwapCommand {
    /// "A newer version of ccswap is available (0.43.0)" → "0.43.0".
    public static func newerVersion(in output: String) -> String? {
        guard let range = output.range(of: "newer version of ccswap is available (") else { return nil }
        let rest = output[range.upperBound...]
        guard let end = rest.firstIndex(of: ")") else { return nil }
        let version = String(rest[..<end])
        return AppVersion(version) != nil ? version : nil
    }

    /// A typed command as ccswap's arguments: "list --json" and "ccswap codex list --json" both
    /// become `codex list --json`. Only `config`, `--version` and `--help` stay outside `codex`,
    /// so a Claude command can't be run from here. nil when a quote is left open.
    public static func arguments(_ text: String) -> [String]? {
        guard var arguments = ClaudeSwapCommand.arguments(text) else { return nil }
        if arguments.first == "ccswap" { arguments.removeFirst() }
        if arguments.first == "codex" { arguments.removeFirst() }
        guard let first = arguments.first else { return [] }
        if first == "config" || first == "--version" { return arguments }
        return ["codex"] + arguments
    }

    /// Commands that need a terminal, wait for an answer, or never end.
    public static func needsTerminal(_ arguments: [String]) -> Bool {
        guard arguments.first == "codex" else { return false }
        guard let command = arguments.dropFirst().first else { return false }
        switch command {
        case "run": return true
        // LiveIsland runs the loop itself; a single tick ends.
        case "auto": return !arguments.contains("--once")
        // They ask before acting.
        case "remove", "rm", "redeem-reset": return !arguments.contains("--yes")
        case "add": return arguments.contains("--slot")
        default: return false
        }
    }
}

extension CodexAccounts {
    /// The Codex accounts to show. With ccswap managing accounts, exactly its list, in its
    /// order: it holds the logins and switches them. What LiveIsland saw of an account (who it
    /// is, a fresher reading for the one in use from Codex's own sessions) fills in. Without
    /// ccswap, the accounts Codex has used here, with their limits.
    public static func merge(book: AccountBook, ccswap: [CodexSwapAccount]?, now: Date) -> [ClaudeAccount] {
        guard let ccswap, !ccswap.isEmpty else { return list(book: book, switching: false, now: now) }
        return ccswap.map { swap in
            // ccswap's numbers are its own; the book knows the account by email (and workspace).
            let matches = book.entries.filter { $0.value.identity.email.caseInsensitiveCompare(swap.email) == .orderedSame }
            let known = (swap.isActive ? matches.first { $0.key == book.activeKey }?.value : nil) ?? matches.first?.value
            var identity = known?.identity ?? ClaudeAccountIdentity(accountUUID: "", email: swap.email.lowercased())
            if !swap.planType.isEmpty { identity.tier = swap.planType }
            var account = ClaudeAccount(identity: identity, kind: .codex, isActive: swap.isActive, fiveHour: swap.fiveHour,
                                        sevenDay: swap.weekly, limitsObservedAt: swap.usageReadAt ?? now, switcher: .ccswap,
                                        needsLogin: swap.needsLogin)
            account.ccswapNumber = swap.number
            // Codex's sessions report the account in use as they work; ccswap is asked every few minutes.
            if let known, swap.isActive, let observed = known.limitsObservedAt, observed > (swap.usageReadAt ?? .distantPast),
               known.fiveHour != nil || known.sevenDay != nil {
                account.fiveHour = known.fiveHour ?? account.fiveHour
                account.sevenDay = known.sevenDay ?? account.sevenDay
                account.limitsObservedAt = observed
            }
            return account.current(at: now)
        }
        .sorted { lhs, rhs in lhs.isActive != rhs.isActive ? lhs.isActive : (lhs.ccswapNumber ?? 0) < (rhs.ccswapNumber ?? 0) }
    }
}
