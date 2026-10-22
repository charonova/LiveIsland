import Foundation

/// Reads Codex CLI session logs (~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl).
public enum CodexRollout {
    /// The rate limits Codex reported with its latest token count.
    public static func limits(in line: Data) -> CodexLimits? {
        guard JSONLScanner.contains(line, #""rate_limits""#),
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
        else { return nil }
        let payload = object["payload"] as? [String: Any] ?? object
        guard let limits = payload["rate_limits"] as? [String: Any] else { return nil }
        let observedAt = (object["timestamp"] as? String).flatMap(Format.date(iso8601:)) ?? Date()
        let primary = window(limits["primary"], observedAt: observedAt)
        let secondary = window(limits["secondary"], observedAt: observedAt)
        guard primary != nil || secondary != nil else { return nil }
        return CodexLimits(primary: primary, secondary: secondary, observedAt: observedAt)
    }

    /// The session's running token total.
    public static func totalTokens(in line: Data) -> Int? {
        guard JSONLScanner.contains(line, #""total_token_usage""#),
              let usage = JSONLScanner.object(forKey: "total_token_usage", in: line)
        else { return nil }
        return (usage["total_tokens"] as? NSNumber)?.intValue
    }

    public struct Tail: Equatable, Sendable {
        public var working = false
        public var awaitingApproval = false
        public var lastEventAt: Date?
        public var turnStartedAt: Date?
        public var finishedAt: Date?
        public var cwd: String?
        public var tokens: Int?

        public init() {}
    }

    public static func tail(of lines: [Data]) -> Tail {
        var tail = Tail()
        for line in lines {
            let stamp = JSONLScanner.string(after: #""timestamp":""#, in: line).flatMap(Format.date(iso8601:))
            if tail.cwd == nil, let cwd = JSONLScanner.string(after: #""cwd":""#, in: line) { tail.cwd = cwd }
            if let tokens = totalTokens(in: line) { tail.tokens = tokens }
            if JSONLScanner.contains(line, #""type":"task_started""#) {
                tail.working = true
                tail.awaitingApproval = false
                tail.turnStartedAt = stamp
            } else if JSONLScanner.contains(line, #""type":"task_complete""#) || JSONLScanner.contains(line, #""type":"turn_aborted""#) {
                tail.working = false
                tail.awaitingApproval = false
                tail.finishedAt = stamp
            } else if JSONLScanner.contains(line, #"approval_request""#) {
                tail.awaitingApproval = true
            } else if tail.awaitingApproval, JSONLScanner.contains(line, #""function_call_output""#) {
                tail.awaitingApproval = false
            }
            if let stamp { tail.lastEventAt = stamp }
        }
        return tail
    }

    public static func state(of tail: Tail, modified: Date, now: Date) -> AgentState {
        if tail.working {
            if tail.awaitingApproval { return .waiting }
            return now.timeIntervalSince(modified) < 30 * 60 ? .working : .idle
        }
        if let finished = tail.finishedAt, now.timeIntervalSince(finished) < 20 { return .done }
        return .idle
    }

    private static func window(_ value: Any?, observedAt: Date) -> RateLimitWindow? {
        guard let window = value as? [String: Any], let used = (window["used_percent"] as? NSNumber)?.doubleValue else {
            return nil
        }
        let minutes = (window["window_minutes"] as? NSNumber)?.intValue ?? 0
        var resetsAt: Date?
        if let epoch = (window["resets_at"] as? NSNumber)?.doubleValue {
            resetsAt = Date(timeIntervalSince1970: epoch)
        } else if let seconds = (window["resets_in_seconds"] as? NSNumber)?.doubleValue {
            // Older Codex versions report a countdown from when the line was written.
            resetsAt = observedAt.addingTimeInterval(seconds)
        }
        return RateLimitWindow(usedPercent: used, windowMinutes: minutes, resetsAt: resetsAt)
    }
}
