import Foundation

public enum AgentKind: String, Codable, CaseIterable, Sendable {
    case claude
    case codex

    public var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        }
    }
}

public enum AgentState: String, Equatable, Sendable {
    /// Writing or thinking right now.
    case working
    /// Stopped in the middle of a turn: running a long tool, or waiting for approval.
    case waiting
    /// Just finished its turn.
    case done
    case idle
}

/// Where a running agent lives: the app around it (VS Code, Cursor, Terminal…), the terminal
/// it's attached to, and the folder it started in.
public struct SessionHost: Equatable, Sendable {
    public var bundleIdentifier: String
    public var processID: Int32
    /// "/dev/ttys005"; nil when the agent runs without a terminal (an editor's chat panel).
    public var tty: String?
    public var folder: String

    public init(bundleIdentifier: String, processID: Int32, tty: String?, folder: String) {
        self.bundleIdentifier = bundleIdentifier
        self.processID = processID
        self.tty = tty
        self.folder = folder
    }

    /// The open editor folder that contains `path`, deepest first: the window to bring forward.
    public static func window(for path: String, among folders: [String]) -> String? {
        folders.filter { path == $0 || path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }.max { $0.count < $1.count }
    }
}

public struct AgentSession: Identifiable, Equatable, Sendable {
    /// The session file's path.
    public let id: String
    public let kind: AgentKind
    public var project: String
    public var title: String?
    public var state: AgentState
    public var lastActivity: Date
    /// When the current stretch of work began, for "working 3m".
    public var workingSince: Date?
    public var tokens: Int
    /// The folder the agent works in.
    public var cwd: String?
    /// The editor or terminal it runs in, when its process is still alive.
    public var host: SessionHost?

    public init(id: String, kind: AgentKind, project: String, title: String? = nil, state: AgentState,
                lastActivity: Date, workingSince: Date? = nil, tokens: Int = 0, cwd: String? = nil, host: SessionHost? = nil) {
        self.id = id
        self.kind = kind
        self.project = project
        self.title = title
        self.state = state
        self.lastActivity = lastActivity
        self.workingSince = workingSince
        self.tokens = tokens
        self.cwd = cwd
        self.host = host
    }

    /// The session's id, from its file name: `<id>.jsonl` for Claude Code,
    /// `rollout-<date>-<id>.jsonl` for Codex.
    public var sessionID: String? {
        let name = URL(fileURLWithPath: id).deletingPathExtension().lastPathComponent
        switch kind {
        case .claude:
            return name.isEmpty ? nil : name
        case .codex:
            // A UUID is 36 characters: the end of the name.
            guard name.count > 36 else { return nil }
            let uuid = String(name.suffix(36))
            return UUID(uuidString: uuid) == nil ? nil : uuid
        }
    }

    /// A shell command that picks the session up again in a terminal.
    public var resumeCommand: String? {
        guard let sessionID else { return nil }
        let resume = kind == .claude ? "claude --resume \(sessionID)" : "codex resume \(sessionID)"
        guard let cwd else { return resume }
        // Claude Code finds sessions by project folder, so start there.
        return "cd '\(cwd.replacingOccurrences(of: "'", with: "'\\''"))' && \(resume)"
    }
}

/// One rate-limit window as Codex reports it.
public struct RateLimitWindow: Codable, Equatable, Sendable {
    public var usedPercent: Double
    public var windowMinutes: Int
    public var resetsAt: Date?

    public init(usedPercent: Double, windowMinutes: Int, resetsAt: Date?) {
        self.usedPercent = usedPercent
        self.windowMinutes = windowMinutes
        self.resetsAt = resetsAt
    }

    /// "5-hour" or "Weekly".
    public var label: String {
        switch windowMinutes {
        case 10_080: return "Weekly"
        case 1_440: return "Daily"
        case let minutes where minutes % 60 == 0: return "\(minutes / 60)-hour"
        default: return "\(windowMinutes)-minute"
        }
    }
}

public struct CodexLimits: Equatable, Sendable {
    public var primary: RateLimitWindow?
    public var secondary: RateLimitWindow?
    public var observedAt: Date

    public init(primary: RateLimitWindow?, secondary: RateLimitWindow?, observedAt: Date) {
        self.primary = primary
        self.secondary = secondary
        self.observedAt = observedAt
    }

    public var windows: [RateLimitWindow] { [primary, secondary].compactMap { $0 } }
}

/// What Claude Code logged when it ran into (or near) a usage limit.
public struct ClaudeLimitNotice: Equatable, Sendable {
    /// "rejected" means the limit was hit; other values are warnings.
    public var status: String
    /// "five_hour", "seven_day", …
    public var type: String
    public var resetsAt: Date
    public var observedAt: Date

    public init(status: String, type: String, resetsAt: Date, observedAt: Date) {
        self.status = status
        self.type = type
        self.resetsAt = resetsAt
        self.observedAt = observedAt
    }

    public var isLimitReached: Bool { status == "rejected" }

    public var windowLabel: String {
        switch type {
        case "five_hour": return "5-hour"
        case "seven_day": return "Weekly"
        case let other: return other.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// Only worth showing until the limit resets.
    public func isCurrent(at now: Date) -> Bool { resetsAt > now }
}

/// Claude Code token use: the current 5-hour window (as Claude's limits count it) and today.
public struct UsageSummary: Equatable, Sendable {
    public var windowStart: Date?
    public var windowEnd: Date?
    public var windowTokens: Int
    public var windowRequests: Int
    public var todayTokens: Int
    public var todayRequests: Int

    public init(windowStart: Date? = nil, windowEnd: Date? = nil, windowTokens: Int = 0, windowRequests: Int = 0,
                todayTokens: Int = 0, todayRequests: Int = 0) {
        self.windowStart = windowStart
        self.windowEnd = windowEnd
        self.windowTokens = windowTokens
        self.windowRequests = windowRequests
        self.todayTokens = todayTokens
        self.todayRequests = todayRequests
    }

    public static let empty = UsageSummary()
}
