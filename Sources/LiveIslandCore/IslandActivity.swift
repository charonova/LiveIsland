import Foundation

/// Something the collapsed island can show beside the notch. When several happen at once,
/// the most important wins; the rest stay one hover away.
public enum IslandActivity: Equatable, Sendable {
    case call(app: String, since: Date)
    case timerFinished
    case timer(endsAt: Date)
    case agentNeedsYou(AgentKind, project: String)
    /// The Claude account in use ran out, and another one has room.
    case accountLimit(account: String, switchTo: String)
    /// claude-swap just moved Claude Code to another account.
    case accountSwitched(to: String)
    case agentDone(AgentKind, project: String)
    case headphonesConnected(name: String, battery: Int?)
    case charging(percent: Int)
    case eventSoon(title: String, startsAt: Date)
    case cameraOn(app: String?)
    case microphoneOn(app: String)
    case agentWorking(AgentKind, project: String, since: Date)
    case nowPlaying(title: String, isPlaying: Bool)

    /// Higher wins. Things that need the user, or just happened, beat things that are merely ongoing.
    public var priority: Int {
        switch self {
        case .call: return 100
        case .timerFinished: return 95
        case .agentNeedsYou: return 90
        case .accountLimit: return 88
        case .accountSwitched: return 87
        case .headphonesConnected: return 85
        case .charging: return 84
        case .agentDone: return 80
        case .eventSoon: return 75
        case .cameraOn: return 70
        case .microphoneOn: return 65
        case .timer: return 60
        case .agentWorking: return 50
        case .nowPlaying(_, let isPlaying): return isPlaying ? 40 : 10
        }
    }

    public static func mostImportant(_ activities: [IslandActivity]) -> IslandActivity? {
        // Stable: among equals, the earlier one in the list wins.
        activities.enumerated().max { lhs, rhs in
            lhs.element.priority != rhs.element.priority
                ? lhs.element.priority < rhs.element.priority
                : lhs.offset > rhs.offset
        }?.element
    }
}

/// A countdown that can pause.
public struct CountdownTimer: Equatable, Sendable {
    public let duration: TimeInterval
    public private(set) var endsAt: Date
    /// Set while paused.
    public private(set) var pausedRemaining: TimeInterval?

    public init(duration: TimeInterval, startedAt: Date = Date()) {
        self.duration = duration
        endsAt = startedAt.addingTimeInterval(duration)
    }

    public var isPaused: Bool { pausedRemaining != nil }

    public func remaining(at now: Date) -> TimeInterval {
        pausedRemaining ?? max(0, endsAt.timeIntervalSince(now))
    }

    public func isFinished(at now: Date) -> Bool { !isPaused && remaining(at: now) <= 0 }

    /// 0 at the start, 1 when done.
    public func progress(at now: Date) -> Double {
        guard duration > 0 else { return 1 }
        return min(1, max(0, 1 - remaining(at: now) / duration))
    }

    public mutating func pause(at now: Date) {
        guard !isPaused else { return }
        pausedRemaining = remaining(at: now)
    }

    public mutating func resume(at now: Date) {
        guard let remaining = pausedRemaining else { return }
        endsAt = now.addingTimeInterval(remaining)
        pausedRemaining = nil
    }
}
