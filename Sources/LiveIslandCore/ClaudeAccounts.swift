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

/// `~/.claude.json` edits that leave every byte outside the edited value as it was:
/// Claude Code owns the file, so LiveIsland only ever swaps its `oauthAccount` object.
public enum ClaudeConfigFile {
    /// The raw JSON text of a top-level key's value.
    public static func value(of key: String, in data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard let range = topLevelValueRange(of: key, in: bytes) else { return nil }
        return Data(bytes[range])
    }

    /// The file with a top-level key's value replaced by `value` (raw JSON text), or the key
    /// added at the end when it's missing. Nil when the file isn't a JSON object.
    public static func replacingValue(of key: String, in data: Data, with value: Data) -> Data? {
        let bytes = [UInt8](data)
        if let range = topLevelValueRange(of: key, in: bytes) {
            return Data(bytes[..<range.lowerBound]) + value + Data(bytes[range.upperBound...])
        }
        // Missing (logged out): add it before the closing brace.
        guard let close = bytes.lastIndex(where: { !isWhitespace($0) }), bytes[close] == UInt8(ascii: "}"),
              let open = bytes.firstIndex(where: { !isWhitespace($0) }), bytes[open] == UInt8(ascii: "{")
        else { return nil }
        let isEmpty = bytes[(open + 1)..<close].allSatisfy(isWhitespace)
        var end = close
        while end > open + 1, isWhitespace(bytes[end - 1]) { end -= 1 }
        let entry = Data((isEmpty ? "\n  " : ",\n  ").utf8) + Data("\"\(key)\": ".utf8) + value + Data("\n".utf8)
        return Data(bytes[..<end]) + entry + Data(bytes[close...])
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09
    }

    /// Walks only the top level of the object, skipping nested values whole, so a key of the
    /// same name inside another object never matches.
    static func topLevelValueRange(of key: String, in bytes: [UInt8]) -> Range<Int>? {
        var index = 0
        func skipWhitespace() { while index < bytes.count, isWhitespace(bytes[index]) { index += 1 } }
        skipWhitespace()
        guard index < bytes.count, bytes[index] == UInt8(ascii: "{") else { return nil }
        index += 1
        let wanted = Array(key.utf8)
        while true {
            skipWhitespace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: "\""), let keyEnd = endOfString(bytes, from: index) else { return nil }
            let name = bytes[(index + 1)..<keyEnd]
            index = keyEnd + 1
            skipWhitespace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { return nil }
            index += 1
            skipWhitespace()
            let start = index
            guard let end = endOfValue(bytes, from: index) else { return nil }
            if name.elementsEqual(wanted) { return start..<end }
            index = end
            skipWhitespace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: ",") else { return nil }
            index += 1
        }
    }

    /// The index of the closing quote of the string starting at `start`.
    private static func endOfString(_ bytes: [UInt8], from start: Int) -> Int? {
        var index = start + 1
        while index < bytes.count {
            switch bytes[index] {
            case UInt8(ascii: "\\"): index += 2
            case UInt8(ascii: "\""): return index
            default: index += 1
            }
        }
        return nil
    }

    /// One past the end of the value starting at `start`.
    private static func endOfValue(_ bytes: [UInt8], from start: Int) -> Int? {
        guard start < bytes.count else { return nil }
        switch bytes[start] {
        case UInt8(ascii: "\""):
            return endOfString(bytes, from: start).map { $0 + 1 }
        case UInt8(ascii: "{"), UInt8(ascii: "["):
            var depth = 0
            var index = start
            while index < bytes.count {
                switch bytes[index] {
                case UInt8(ascii: "\""):
                    guard let end = endOfString(bytes, from: index) else { return nil }
                    index = end
                case UInt8(ascii: "{"), UInt8(ascii: "["):
                    depth += 1
                case UInt8(ascii: "}"), UInt8(ascii: "]"):
                    depth -= 1
                    if depth == 0 { return index + 1 }
                default:
                    break
                }
                index += 1
            }
            return nil
        default:
            var index = start
            while index < bytes.count, !isWhitespace(bytes[index]),
                  bytes[index] != UInt8(ascii: ","), bytes[index] != UInt8(ascii: "}"), bytes[index] != UInt8(ascii: "]") {
                index += 1
            }
            return index
        }
    }
}

/// The Claude account part of Claude Code's credential item. The same item also holds the
/// logins of the user's MCP servers, which must survive an account switch untouched.
public enum ClaudeLogin {
    public static let key = "claudeAiOauth"

    public static func extract(from credentials: Data) -> [String: Any]? {
        guard let object = try? JSONSerialization.jsonObject(with: credentials) as? [String: Any] else { return nil }
        return object[key] as? [String: Any]
    }

    /// The credential item with only the Claude login replaced. ASCII-only, as Claude Code
    /// reads the item back with `security -w`, which hex-encodes anything else.
    public static func replacing(in credentials: Data, with login: [String: Any]) -> Data? {
        guard var object = try? JSONSerialization.jsonObject(with: credentials) as? [String: Any] else { return nil }
        object[key] = login
        return asciiJSON(object)
    }

    /// When the access token and the login itself expire. Claude Code stores milliseconds.
    public static func expiry(of login: [String: Any]) -> (access: Date?, login: Date?) {
        func date(_ value: Any?) -> Date? {
            guard let number = value as? Double, number > 0 else { return nil }
            return Date(timeIntervalSince1970: number > 1e11 ? number / 1000 : number)
        }
        return (date(login["expiresAt"]), date(login["refreshTokenExpiresAt"]))
    }

    /// JSON with every non-ASCII character escaped, so `security -w` prints it as text.
    public static func asciiJSON(_ object: Any) -> Data? {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        var escaped = ""
        escaped.reserveCapacity(text.utf8.count)
        for unit in text.utf16 {
            if unit < 0x80 {
                escaped.unicodeScalars.append(Unicode.Scalar(unit)!)
            } else {
                escaped += String(format: "\\u%04x", unit)
            }
        }
        return Data(escaped.utf8)
    }
}

/// What LiveIsland remembers about each account: no secrets (those stay in the Keychain),
/// just who it is and its limits when last seen.
public struct AccountBook: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var identity: ClaudeAccountIdentity
        public var fiveHour: RateLimitWindow?
        public var sevenDay: RateLimitWindow?
        public var limitsObservedAt: Date?
        /// LiveIsland keeps a copy of this account's login, so it can switch to it.
        public var hasSavedLogin: Bool
        /// When the saved login stops working and needs a fresh /login.
        public var loginExpiresAt: Date?

        public init(identity: ClaudeAccountIdentity, hasSavedLogin: Bool = false) {
            self.identity = identity
            self.hasSavedLogin = hasSavedLogin
        }
    }

    public var entries: [String: Entry] = [:]
    public var activeKey: String?
    /// When the active account last changed; nil when LiveIsland never saw it change.
    public var activeSince: Date?

    public init() {}

    /// Notes the account Claude Code is logged in to now.
    public mutating func setActive(_ identity: ClaudeAccountIdentity, at now: Date) {
        if entries[identity.key] == nil {
            entries[identity.key] = Entry(identity: identity)
        } else {
            entries[identity.key]!.identity = identity
        }
        guard activeKey != identity.key else { return }
        if activeKey != nil { activeSince = now }
        activeKey = identity.key
    }

    /// Files the status line's limits under the account they belong to. Every account's
    /// windows reset at their own times, so a report whose reset times match an account's is
    /// that account's, whichever is active: a session still on the previous login reports its
    /// numbers. Anything else goes to the active account, once a request was made on it.
    /// Returns false when the report can't be placed yet.
    @discardableResult
    public mutating func record(_ limits: ClaudeUsageLimits, latestRequestAt: Date?) -> Bool {
        if let owner = entries.first(where: { Self.sameWindows($0.value, limits) })?.key {
            store(limits, in: owner)
            return true
        }
        guard let key = activeKey, entries[key] != nil,
              Self.belongsToActive(observedAt: limits.observedAt, activeSince: activeSince, latestRequestAt: latestRequestAt)
        else { return false }
        store(limits, in: key)
        return true
    }

    /// A request Claude refused for a limit: the account in use is out of room until the
    /// notice's reset time. That's the only news an exhausted account ever gives, as it never
    /// answers. A notice matching another account's reset time is that account's.
    public mutating func record(_ notice: ClaudeLimitNotice) {
        let window = RateLimitWindow(usedPercent: 100, windowMinutes: notice.type == "seven_day" ? 10_080 : 300, resetsAt: notice.resetsAt)
        let owner = entries.first { entry in
            let known = window.windowMinutes == 300 ? entry.value.fiveHour : entry.value.sevenDay
            return Self.sameReset(known?.resetsAt, notice.resetsAt)
        }?.key
        guard let key = owner ?? activeKey, entries[key] != nil else { return }
        // Only a refusal after the switch can be the new account's.
        if owner == nil, let activeSince, notice.observedAt < activeSince { return }
        if let seen = entries[key]!.limitsObservedAt, seen > notice.observedAt { return }
        if window.windowMinutes == 300 { entries[key]!.fiveHour = window } else { entries[key]!.sevenDay = window }
        entries[key]!.limitsObservedAt = notice.observedAt
    }

    private mutating func store(_ limits: ClaudeUsageLimits, in key: String) {
        if let seen = entries[key]!.limitsObservedAt, seen > limits.observedAt { return }
        entries[key]!.fiveHour = limits.fiveHour
        entries[key]!.sevenDay = limits.sevenDay
        entries[key]!.limitsObservedAt = limits.observedAt
    }

    /// After a switch, sessions keep showing the previous account's numbers until they make a
    /// request on the new one (they pick up a new login within about 30 seconds). So only a
    /// report made after a request that came after that counts.
    public static func belongsToActive(observedAt: Date, activeSince: Date?, latestRequestAt: Date?) -> Bool {
        guard let activeSince else { return true }
        guard let request = latestRequestAt, request > activeSince.addingTimeInterval(30) else { return false }
        return observedAt >= request
    }

    /// Same reset times for every window both sides know: the same account. Reset times move
    /// only when a window starts over, and two accounts sharing both is vanishingly unlikely.
    static func sameWindows(_ entry: Entry, _ limits: ClaudeUsageLimits) -> Bool {
        let pairs = [(entry.fiveHour?.resetsAt, limits.fiveHour?.resetsAt), (entry.sevenDay?.resetsAt, limits.sevenDay?.resetsAt)]
            .filter { $0.0 != nil && $0.1 != nil }
        return !pairs.isEmpty && pairs.count == [limits.fiveHour?.resetsAt, limits.sevenDay?.resetsAt].compactMap { $0 }.count
            && pairs.allSatisfy { sameReset($0.0, $0.1) }
    }

    static func sameReset(_ lhs: Date?, _ rhs: Date?) -> Bool {
        guard let lhs, let rhs else { return false }
        return abs(lhs.timeIntervalSince(rhs)) <= 90
    }

    /// Readings that ended up under two accounts: keep the newest, clear the others.
    public mutating func removeDuplicateReadings() {
        let read = entries.filter { $0.value.limitsObservedAt != nil }
        for (key, entry) in read {
            let limits = ClaudeUsageLimits(fiveHour: entry.fiveHour, sevenDay: entry.sevenDay, observedAt: entry.limitsObservedAt!)
            let newer = read.contains { other in
                other.key != key && Self.sameWindows(other.value, limits)
                    && (other.value.limitsObservedAt! > entry.limitsObservedAt! || (other.value.limitsObservedAt! == entry.limitsObservedAt! && other.key == activeKey))
            }
            if newer {
                entries[key]!.fiveHour = nil
                entries[key]!.sevenDay = nil
                entries[key]!.limitsObservedAt = nil
            }
        }
    }

    public mutating func remove(_ key: String) {
        guard key != activeKey else {
            entries[key]?.hasSavedLogin = false
            return
        }
        entries[key] = nil
    }
}

/// An account as the island shows it, whatever it came from.
public struct ClaudeAccount: Identifiable, Equatable, Sendable {
    public enum Switcher: String, Codable, Sendable {
        case liveIsland
        case claudeSwap
    }

    public var identity: ClaudeAccountIdentity
    public var isActive: Bool
    public var fiveHour: RateLimitWindow?
    public var sevenDay: RateLimitWindow?
    public var limitsObservedAt: Date?
    /// How to switch to it; nil when it can't be switched to from here.
    public var switcher: Switcher?
    /// Its saved login expired: sign in to it again with /login.
    public var needsLogin: Bool
    public var claudeSwapNumber: Int?

    public var id: String { identity.key }

    public init(identity: ClaudeAccountIdentity, isActive: Bool = false, fiveHour: RateLimitWindow? = nil,
                sevenDay: RateLimitWindow? = nil, limitsObservedAt: Date? = nil, switcher: Switcher? = nil,
                needsLogin: Bool = false, claudeSwapNumber: Int? = nil) {
        self.identity = identity
        self.isActive = isActive
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.limitsObservedAt = limitsObservedAt
        self.switcher = switcher
        self.needsLogin = needsLogin
        self.claudeSwapNumber = claudeSwapNumber
    }

    /// Windows that reset since they were seen count from zero again.
    public func current(at now: Date) -> ClaudeAccount {
        var account = self
        let limits = ClaudeUsageLimits(fiveHour: fiveHour, sevenDay: sevenDay, observedAt: limitsObservedAt ?? now).current(at: now)
        account.fiveHour = limits.fiveHour
        account.sevenDay = limits.sevenDay
        return account
    }

    /// The fuller of the two windows: what decides whether it can take more work.
    public var used: Double? {
        let values = [fiveHour?.usedPercent, sevenDay?.usedPercent].compactMap { $0 }
        return values.max()
    }

    public var isAtLimit: Bool { (used ?? 0) >= 100 }

    /// The window that ran out first, for "5-hour limit reached".
    public var exhaustedWindow: RateLimitWindow? {
        [fiveHour, sevenDay].compactMap { $0 }.first { $0.usedPercent >= 100 }
    }

    /// The account to move to next: one that can be switched to, with the most room left.
    /// Accounts never measured come last.
    public static func best(_ accounts: [ClaudeAccount], at now: Date) -> ClaudeAccount? {
        accounts
            .filter { !$0.isActive && $0.switcher != nil && !$0.needsLogin }
            .map { $0.current(at: now) }
            .filter { !$0.isAtLimit }
            .min { ($0.used ?? 99.5) < ($1.used ?? 99.5) }
    }
}

/// One account in claude-swap's `cswap list --json`.
public struct ClaudeSwapAccount: Equatable, Sendable {
    public var number: Int
    public var email: String
    public var organizationName: String?
    public var organizationUUID: String?
    public var isActive: Bool
    /// "ok", "relogin_required", "token_expired", …
    public var usageStatus: String
    public var fiveHour: RateLimitWindow?
    public var sevenDay: RateLimitWindow?
    public var usageFetchedAt: Date?
    public var isDisabled: Bool

    public var needsLogin: Bool { usageStatus == "relogin_required" }
}

/// claude-swap's JSON (schema version 1).
public enum ClaudeSwapJSON {
    public static func accounts(from data: Data) -> [ClaudeSwapAccount]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = object["accounts"] as? [[String: Any]]
        else { return nil }
        return rows.compactMap { row in
            guard let number = row["number"] as? Int, let email = row["email"] as? String else { return nil }
            let usage = row["usage"] as? [String: Any]
            return ClaudeSwapAccount(
                number: number, email: email,
                organizationName: (row["organizationName"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                organizationUUID: (row["organizationUuid"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                isActive: row["active"] as? Bool ?? false,
                usageStatus: row["usageStatus"] as? String ?? "unavailable",
                fiveHour: window(usage?["fiveHour"], minutes: 300),
                sevenDay: window(usage?["sevenDay"], minutes: 10_080),
                usageFetchedAt: (row["usageFetchedAt"] as? String).flatMap(Format.date(iso8601:)),
                isDisabled: row["disabled"] as? Bool ?? false)
        }
    }

    private static func window(_ value: Any?, minutes: Int) -> RateLimitWindow? {
        guard let value = value as? [String: Any], let used = value["pct"] as? Double else { return nil }
        return RateLimitWindow(usedPercent: used, windowMinutes: minutes,
                               resetsAt: (value["resetsAt"] as? String).flatMap(Format.date(iso8601:)))
    }

    /// `cswap switch … --json`: whether it switched, and what it said (or the error).
    public static func switchResult(from data: Data) -> (switched: Bool, message: String)? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let error = object["error"] as? [String: Any] {
            return (false, error["message"] as? String ?? "claude-swap couldn't switch")
        }
        guard let switched = object["switched"] as? Bool else { return nil }
        return (switched, object["message"] as? String ?? "")
    }
}
