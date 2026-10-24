import Foundation

/// One line of `claude -p --output-format stream-json --verbose`, reduced to what keeping a task
/// going needs: which session it is, how it's progressing, and how it ended.
public enum RunEvent: Equatable, Sendable {
    case started(session: String)
    /// Claude Code is retrying a failed request: `category` is its error category
    /// ("rate_limit", "overloaded", "authentication_failed"…), `status` the HTTP status, if any.
    case retry(category: String, status: Int?)
    case assistantText(String)
    /// A tool call: `detail` is the file it edits or the command it runs.
    case toolUse(id: String, name: String, detail: String)
    case toolResult(id: String, isError: Bool)
    case result(RunResult)

    /// The events in one line (an assistant message can hold text and several tool calls).
    public static func parse(_ line: Data) -> [RunEvent] {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = object["type"] as? String
        else { return [] }
        switch type {
        case "system":
            switch object["subtype"] as? String {
            case "init":
                return (object["session_id"] as? String).map { [.started(session: $0)] } ?? []
            case "api_retry":
                return [.retry(category: object["error"] as? String ?? "unknown", status: object["error_status"] as? Int)]
            default:
                return []
            }
        case "assistant", "user":
            guard object["parent_tool_use_id"] is NSNull || object["parent_tool_use_id"] == nil,
                  let message = object["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]]
            else { return [] }
            return content.compactMap { block in
                switch block["type"] as? String {
                case "text":
                    guard let text = block["text"] as? String, !text.isEmpty else { return nil }
                    return .assistantText(text)
                case "tool_use":
                    guard let id = block["id"] as? String, let name = block["name"] as? String else { return nil }
                    return .toolUse(id: id, name: name, detail: detail(of: block["input"] as? [String: Any] ?? [:]))
                case "tool_result":
                    guard let id = block["tool_use_id"] as? String else { return nil }
                    return .toolResult(id: id, isError: block["is_error"] as? Bool ?? false)
                default:
                    return nil
                }
            }
        case "result":
            let denials = (object["permission_denials"] as? [[String: Any]] ?? []).map { denial -> String in
                let name = denial["tool_name"] as? String ?? "A tool"
                let input = denial["tool_input"] as? [String: Any] ?? [:]
                let what = detail(of: input)
                return what.isEmpty ? name : "\(name): \(what)"
            }
            return [.result(RunResult(isError: object["is_error"] as? Bool ?? false,
                                      subtype: object["subtype"] as? String ?? "",
                                      terminalReason: object["terminal_reason"] as? String,
                                      text: object["result"] as? String ?? "",
                                      permissionDenials: denials))]
        default:
            return []
        }
    }

    /// The part of a tool's input worth showing: the file it touches or the command it runs.
    static func detail(of input: [String: Any]) -> String {
        for key in ["file_path", "notebook_path", "command", "path", "pattern", "url"] {
            if let value = input[key] as? String, !value.isEmpty { return String(value.prefix(200)) }
        }
        return ""
    }
}

public struct RunResult: Equatable, Sendable {
    public var isError: Bool
    public var subtype: String
    public var terminalReason: String?
    public var text: String
    /// Tool calls that were denied because nobody could approve them.
    public var permissionDenials: [String]

    public init(isError: Bool, subtype: String = "success", terminalReason: String? = nil, text: String,
                permissionDenials: [String] = []) {
        self.isError = isError
        self.subtype = subtype
        self.terminalReason = terminalReason
        self.text = text
        self.permissionDenials = permissionDenials
    }
}

/// Why a run of a task ended, which decides what happens next.
public enum RunOutcome: Equatable, Sendable {
    case completed(String)
    /// The account is out of usage. `window` is "five_hour", "seven_day", "opus"…; `resetsAt` is
    /// nil when Claude Code didn't report when it resets.
    case usageLimit(window: String?, resetsAt: Date?)
    /// Anthropic is busy (overloaded, or a 429 that isn't the plan's quota): try again shortly.
    case throttled
    /// Anthropic couldn't be reached.
    case network
    /// The account can't be used until someone signs in again (not signed in, expired, revoked, on hold).
    case accountUnusable(String)
    /// Something only a person can approve was denied.
    case needsApproval([String])
    /// `--resume` couldn't find the conversation.
    case sessionUnavailable
    /// Stopped on purpose (pause, cancel, a signal).
    case stopped
    case failed(String)

    /// A short explanation for Settings.
    public var summary: String {
        switch self {
        case .completed: return "Finished"
        case .usageLimit(let window, _): return "\(Self.windowName(window)) limit reached"
        case .throttled: return "Anthropic was busy"
        case .network: return "Couldn't reach Anthropic"
        case .accountUnusable(let message): return message
        case .needsApproval(let denials): return "Needs your approval: " + denials.prefix(2).joined(separator: "; ")
        case .sessionUnavailable: return "The conversation couldn't be resumed"
        case .stopped: return "Stopped"
        case .failed(let message): return message
        }
    }

    static func windowName(_ window: String?) -> String {
        switch window {
        case "five_hour", "session": return "5-hour"
        case "seven_day", "weekly": return "Weekly"
        case "opus": return "Opus"
        case "sonnet": return "Sonnet"
        default: return "Usage"
        }
    }
}

/// Decides why a run ended, from the structured signals first and the message text second.
public enum RunClassifier {
    /// - Parameters:
    ///   - events: the run's stream-json events.
    ///   - exitCode: the process's exit status.
    ///   - limitNotice: the usage-limit refusal Claude Code wrote in the transcript during this run, if any.
    ///   - stoppedOnPurpose: LiveIsland (or the person) stopped it.
    public static func classify(events: [RunEvent], exitCode: Int32, limitNotice: ClaudeLimitNotice?,
                                stoppedOnPurpose: Bool) -> RunOutcome {
        if stoppedOnPurpose { return .stopped }
        let result: RunResult? = events.lazy.compactMap { event -> RunResult? in
            if case .result(let result) = event { return result }
            return nil
        }.last
        // The transcript's refusal carries the window and the exact reset time. A run that
        // reported success wasn't refused, whatever an older line says.
        if let limitNotice, limitNotice.isLimitReached, result?.isError ?? true {
            return .usageLimit(window: limitNotice.type, resetsAt: limitNotice.resetsAt)
        }
        let retries: [(category: String, status: Int?)] = events.compactMap {
            if case .retry(let category, let status) = $0 { return (category, status) }
            return nil
        }
        guard let result else {
            if exitCode == 143 || exitCode == 130 || exitCode == 137 { return .failed("Claude Code was stopped from outside (code \(exitCode))") }
            if let last = retries.last { return outcome(ofRetry: last.category, status: last.status) ?? .failed("Claude Code exited (code \(exitCode)) without a result") }
            return .failed("Claude Code exited (code \(exitCode)) without a result")
        }

        let text = result.text.lowercased()
        if let window = usageLimitWindow(in: text) { return .usageLimit(window: window, resetsAt: nil) }
        if authProblems.contains(where: text.contains) { return .accountUnusable(firstLine(of: result.text)) }
        if text.contains("no conversation found") { return .sessionUnavailable }
        if result.isError || result.terminalReason == "api_error" {
            if throttling.contains(where: text.contains) { return .throttled }
            if networkProblems.contains(where: text.contains) { return .network }
            if let last = retries.last, let outcome = outcome(ofRetry: last.category, status: last.status) { return outcome }
            return .failed(firstLine(of: result.text).isEmpty ? "Claude Code reported an error" : firstLine(of: result.text))
        }
        if !result.permissionDenials.isEmpty { return .needsApproval(result.permissionDenials) }
        return .completed(result.text)
    }

    /// "You've hit your session limit · resets 3:45pm" and its siblings.
    static func usageLimitWindow(in text: String) -> String? {
        if text.contains("hit your session limit") { return "five_hour" }
        if text.contains("hit your weekly limit") { return "seven_day" }
        if text.contains("hit your opus limit") { return "opus" }
        if text.contains("hit your sonnet limit") { return "sonnet" }
        if text.contains("usage limit reached") || text.contains("hit your limit") { return "limit" }
        return nil
    }

    static func outcome(ofRetry category: String, status: Int?) -> RunOutcome? {
        switch category {
        case "rate_limit", "overloaded", "server_error": return .throttled
        case "authentication_failed", "oauth_org_not_allowed", "account_on_hold": return .accountUnusable("Claude Code couldn't sign in with this account")
        case "billing_error": return .failed("A billing error stopped the run")
        default: return status == nil ? .network : nil
        }
    }

    static let authProblems = [
        "not logged in", "please run /login", "login expired", "oauth token revoked", "oauth token has expired",
        "authentication required", "invalid authentication credentials", "claude login not accepted",
        "does not have access to claude", "account is on hold",
    ]
    static let throttling = [
        "temporarily limiting requests", "request rejected (429)", "529", "overloaded", "high load",
    ]
    static let networkProblems = [
        "unable to connect", "connection error", "network", "timed out", "econnrefused", "econnreset",
        "fetch failed", "no response from api", "offline",
    ]

    static func firstLine(of text: String) -> String {
        String(text.split(whereSeparator: \.isNewline).first ?? "").trimmingCharacters(in: .whitespaces)
    }
}
