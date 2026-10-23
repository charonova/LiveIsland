import Foundation

/// Claude Code's own usage percentages, as its status line receives them. Claude Code doesn't
/// write them anywhere else, so LiveIsland reads a small file that the user's status line
/// command can write (opt-in: `scripts/claude-statusline-snippet.sh`).
public struct ClaudeUsageLimits: Equatable, Sendable {
    public var fiveHour: RateLimitWindow?
    public var sevenDay: RateLimitWindow?
    public var observedAt: Date
    /// The transcript of the session that reported them, when the status line says.
    public var session: String?

    public init(fiveHour: RateLimitWindow?, sevenDay: RateLimitWindow?, observedAt: Date, session: String? = nil) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.observedAt = observedAt
        self.session = session
    }

    public var windows: [RateLimitWindow] { [fiveHour, sevenDay].compactMap { $0 } }

    /// The file the status line writes, next to Claude Code's own data.
    public static let fileName = "liveisland-limits.json"

    /// A window that has reset since it was observed starts again from zero.
    public func current(at now: Date) -> ClaudeUsageLimits {
        func fresh(_ window: RateLimitWindow?) -> RateLimitWindow? {
            guard var window else { return nil }
            if let resets = window.resetsAt, resets <= now {
                window.usedPercent = 0
                window.resetsAt = nil
            }
            return window
        }
        return ClaudeUsageLimits(fiveHour: fresh(fiveHour), sevenDay: fresh(sevenDay), observedAt: observedAt, session: session)
    }

    /// Reads either the status line's whole input or `{"observed_at": …, "rate_limits": …}`.
    /// `modified` stands in for `observed_at` when the file doesn't say.
    public static func parse(_ data: Data, modified: Date) -> ClaudeUsageLimits? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let limits = object["rate_limits"] as? [String: Any]
        else { return nil }
        let observed = (object["observed_at"] as? Double).map { Date(timeIntervalSince1970: $0) } ?? modified
        let result = ClaudeUsageLimits(fiveHour: window(limits["five_hour"], minutes: 300),
                                       sevenDay: window(limits["seven_day"], minutes: 10_080),
                                       observedAt: observed,
                                       session: (object["transcript_path"] as? String).flatMap { $0.isEmpty ? nil : $0 })
        return result.windows.isEmpty ? nil : result
    }

    private static func window(_ value: Any?, minutes: Int) -> RateLimitWindow? {
        guard let value = value as? [String: Any], let used = value["used_percentage"] as? Double else { return nil }
        let resets: Date?
        switch value["resets_at"] {
        case let seconds as Double: resets = Date(timeIntervalSince1970: seconds)
        case let text as String: resets = Format.date(iso8601: text)
        default: resets = nil
        }
        return RateLimitWindow(usedPercent: used, windowMinutes: minutes, resetsAt: resets)
    }
}
