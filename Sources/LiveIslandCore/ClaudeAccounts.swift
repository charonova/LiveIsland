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
