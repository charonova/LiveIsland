import Foundation

/// Reads Claude Code session transcripts (~/.claude/projects/<project>/<session>.jsonl).
public enum ClaudeTranscript {
    public struct UsageRecord: Equatable, Sendable {
        public let messageID: String
        public let timestamp: Date
        public let tokens: Int
        public let model: String?
    }

    /// The token use of one assistant response. A response is written as several lines (one
    /// per content block) that share a message ID, so callers count each ID once.
    public static func usageRecord(in line: Data) -> UsageRecord? {
        guard JSONLScanner.contains(line, #""type":"assistant""#),
              // message.usage follows the content, which may itself contain a "usage" key: take the last.
              let usage = JSONLScanner.object(forKey: "usage", in: line, last: true),
              let idSuffix = JSONLScanner.string(after: #""id":"msg_"#, in: line),
              let stamp = JSONLScanner.string(after: #""timestamp":""#, in: line, last: true),
              let timestamp = Format.date(iso8601: stamp)
        else { return nil }
        let keys = ["input_tokens", "output_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"]
        let tokens = keys.reduce(0) { $0 + ((usage[$1] as? NSNumber)?.intValue ?? 0) }
        return UsageRecord(messageID: "msg_" + idSuffix, timestamp: timestamp, tokens: tokens,
                           model: JSONLScanner.string(after: #""model":""#, in: line))
    }

    /// The response's message ID, cheap to read, so repeated lines can be skipped early.
    public static func messageID(in line: Data) -> String? {
        JSONLScanner.string(after: #""id":"msg_"#, in: line).map { "msg_" + $0 }
    }

    /// A usage-limit notice, logged when Claude Code hits (or nears) a limit.
    public static func limitNotice(in line: Data) -> ClaudeLimitNotice? {
        guard JSONLScanner.contains(line, #""rate_limit_info""#),
              let info = JSONLScanner.object(forKey: "rate_limit_info", in: line),
              let status = info["status"] as? String,
              let resets = (info["resetsAt"] as? NSNumber)?.doubleValue
        else { return nil }
        let stamp = JSONLScanner.string(after: #""timestamp":""#, in: line, last: true).flatMap(Format.date(iso8601:))
        return ClaudeLimitNotice(
            status: status, type: info["rateLimitType"] as? String ?? "limit",
            resetsAt: Date(timeIntervalSince1970: resets), observedAt: stamp ?? Date(timeIntervalSince1970: resets))
    }

    /// What the end of a transcript says about the session.
    public struct Tail: Equatable, Sendable {
        public enum Step: Equatable, Sendable {
            /// The model finished its turn.
            case finished
            /// The model asked to run a tool.
            case calledTool
            /// A prompt, tool result or API request is waiting on the model.
            case awaitingModel
        }

        public var lastStep: Step?
        public var lastTimestamp: Date?
        /// When the latest prompt was sent, for "working 3m".
        public var turnStartedAt: Date?
        public var title: String?
        public var cwd: String?

        public init() {}
    }

    /// Reads the meaningful steps from the last lines of a transcript.
    public static func tail(of lines: [Data]) -> Tail {
        var tail = Tail()
        for line in lines {
            if let title = JSONLScanner.string(after: #""aiTitle":""#, in: line) { tail.title = title }
            if tail.cwd == nil, let cwd = JSONLScanner.string(after: #""cwd":""#, in: line) { tail.cwd = cwd }
            let stamp = JSONLScanner.string(after: #""timestamp":""#, in: line, last: true).flatMap(Format.date(iso8601:))

            let step: Tail.Step?
            if JSONLScanner.contains(line, #""type":"assistant""#) {
                let reason = JSONLScanner.string(after: #""stop_reason":""#, in: line, last: true)
                step = reason == "end_turn" ? .finished : reason == "tool_use" ? .calledTool : .awaitingModel
            } else if JSONLScanner.contains(line, #""type":"user""#) {
                step = .awaitingModel
                // A typed prompt (not a tool result) starts a new turn.
                if !JSONLScanner.contains(line, #""tool_result""#) { tail.turnStartedAt = stamp ?? tail.turnStartedAt }
            } else if JSONLScanner.contains(line, #""type":"api-request""#) {
                step = .awaitingModel
            } else {
                step = nil
            }
            if let step {
                tail.lastStep = step
                if let stamp { tail.lastTimestamp = stamp }
            }
        }
        return tail
    }

    /// The session's state, from its tail and how long the file has been quiet.
    public static func state(of tail: Tail, modified: Date, now: Date) -> AgentState {
        let quiet = now.timeIntervalSince(modified)
        switch tail.lastStep {
        case .finished:
            return quiet < 20 ? .done : .idle
        case .calledTool:
            // Fresh writes mean the tool just ran; a long pause means a slow tool or an approval prompt.
            if quiet < 8 { return .working }
            return quiet < 30 * 60 ? .waiting : .idle
        case .awaitingModel:
            // Thinking can go a while without writing anything.
            return quiet < 10 * 60 ? .working : .idle
        case nil:
            return .idle
        }
    }

    /// The project's folder name, from the session's working directory.
    /// The folder name Claude Code files a project's transcripts under: the path with every
    /// character other than a letter or digit turned into "-".
    public static func projectKey(for folder: String) -> String {
        String(folder.unicodeScalars.map { scalar -> Character in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar)) ? Character(scalar) : "-"
        })
    }

    public static func projectName(cwd: String?, fallback: String) -> String {
        guard let cwd, !cwd.isEmpty else { return fallback }
        return URL(fileURLWithPath: cwd).lastPathComponent
    }
}
