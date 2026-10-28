import Foundation

/// One line of `cswap auto --json`: claude-swap's automatic switching, as it happens. Unknown
/// kinds and fields are kept as `other`, as claude-swap asks scripts to do.
public enum ClaudeSwapEvent: Equatable, Sendable {
    public struct Account: Equatable, Sendable {
        public var number: Int?
        public var email: String?
    }

    /// A check of every account: the one in use and each account's 5-hour and weekly use.
    case poll(active: Account?, windows: [Int: (fiveHour: Double?, week: Double?)], threshold: Double?)
    /// It switched (`trigger`: "proactive", "at-limit", "failover", "consume-first").
    case switched(trigger: String, from: Account?, to: Account?, dryRun: Bool)
    case noSwitch(reason: String, detail: String)
    /// An account was set aside (bad login…), or came back.
    case quarantined(number: Int?, email: String, reason: String)
    case unquarantined(number: Int?, email: String)
    /// Every account is out; the earliest reset, if known.
    case allExhausted(earliestReset: Date?)
    case sleep(until: Date?)
    case error(message: String, transient: Bool)
    case configWarning(String)
    case other(String)

    public static func == (lhs: ClaudeSwapEvent, rhs: ClaudeSwapEvent) -> Bool {
        lhs.summary == rhs.summary && lhs.kind == rhs.kind
    }

    public static func parse(_ line: Data) -> (event: ClaudeSwapEvent, at: Date?)? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let kind = object["event"] as? String
        else { return nil }
        let at = (object["ts"] as? String).flatMap(Format.date(iso8601:))
        func account(_ value: Any?) -> Account? {
            guard let value = value as? [String: Any] else { return nil }
            return Account(number: number(value["number"]), email: value["email"] as? String)
        }
        let event: ClaudeSwapEvent
        switch kind {
        case "poll":
            var windows: [Int: (Double?, Double?)] = [:]
            for (key, value) in object["windowsPct"] as? [String: Any] ?? [:] {
                guard let number = Int(key), let window = value as? [String: Any] else { continue }
                windows[number] = (window["5h"] as? Double, window["7d"] as? Double)
            }
            event = .poll(active: account(object["active"]), windows: windows, threshold: object["threshold"] as? Double)
        case "switch":
            event = .switched(trigger: object["trigger"] as? String ?? "", from: account(object["from"]),
                              to: account(object["to"]), dryRun: object["dryRun"] as? Bool ?? false)
        case "no-switch":
            event = .noSwitch(reason: object["reason"] as? String ?? "", detail: object["detail"] as? String ?? "")
        case "account-quarantined":
            event = .quarantined(number: number(object["number"]), email: object["email"] as? String ?? "",
                                 reason: object["reason"] as? String ?? "")
        case "account-unquarantined":
            event = .unquarantined(number: number(object["number"]), email: object["email"] as? String ?? "")
        case "all-exhausted":
            event = .allExhausted(earliestReset: (object["earliestResetAt"] as? String).flatMap(Format.date(iso8601:)))
        case "sleep":
            event = .sleep(until: (object["until"] as? String).flatMap(Format.date(iso8601:)))
        case "error":
            event = .error(message: object["message"] as? String ?? "claude-swap reported an error",
                           transient: object["transient"] as? Bool ?? true)
        case "config-warning":
            event = .configWarning(object["message"] as? String ?? "")
        default:
            event = .other(kind)
        }
        return (event, at)
    }

    /// claude-swap writes account numbers as numbers or as strings.
    private static func number(_ value: Any?) -> Int? {
        (value as? Int) ?? (value as? String).flatMap(Int.init)
    }

    public var kind: String {
        switch self {
        case .poll: return "poll"
        case .switched: return "switch"
        case .noSwitch: return "no-switch"
        case .quarantined: return "account-quarantined"
        case .unquarantined: return "account-unquarantined"
        case .allExhausted: return "all-exhausted"
        case .sleep: return "sleep"
        case .error: return "error"
        case .configWarning: return "config-warning"
        case .other(let kind): return kind
        }
    }

    /// One line for the console and the notch.
    public var summary: String {
        func name(_ account: Account?) -> String { account?.email ?? account?.number.map { "account \($0)" } ?? "an account" }
        switch self {
        case .poll(let active, let windows, let threshold):
            let parts = windows.keys.sorted().map { number -> String in
                let window = windows[number]!
                let five = window.fiveHour.map { "\(Int($0.rounded()))%" } ?? "–"
                let week = window.week.map { "\(Int($0.rounded()))%" } ?? "–"
                return "#\(number) \(five)/\(week)"
            }
            let line = threshold.map { " · switch at \(Int($0))%" } ?? ""
            return "Checked: on \(name(active)) · \(parts.joined(separator: ", "))\(line)"
        case .switched(let trigger, let from, let to, let dryRun):
            return "\(dryRun ? "Would switch" : "Switched") from \(name(from)) to \(name(to))\(trigger.isEmpty ? "" : " (\(trigger))")"
        case .noSwitch(let reason, let detail):
            return "No switch: \(detail.isEmpty ? reason : detail)"
        case .quarantined(_, let email, let reason):
            return "Set aside \(email): \(reason)"
        case .unquarantined(_, let email):
            return "\(email) is back in rotation"
        case .allExhausted(let reset):
            return "Every account is out" + (reset.map { " until \(Self.clock($0))" } ?? "")
        case .sleep(let until):
            return "Waiting" + (until.map { " until \(Self.clock($0))" } ?? "")
        case .error(let message, _):
            return "Error: \(message)"
        case .configWarning(let message):
            return "Settings: \(message)"
        case .other(let kind):
            return kind
        }
    }

    /// "14:30", or "Thu 03:00" on another day, in the Mac's time zone.
    static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "EEE HH:mm"
        return formatter.string(from: date)
    }

    /// Worth a moment in the notch.
    public var isNotable: Bool {
        switch self {
        case .switched(_, _, _, let dryRun): return !dryRun
        case .allExhausted, .quarantined: return true
        case .error(_, let transient): return !transient
        default: return false
        }
    }
}

/// `cswap config list --json`: each setting's value, and whether the person set it.
public struct ClaudeSwapSetting: Equatable, Sendable {
    public var key: String
    /// As claude-swap prints it ("90", "best", "" for none).
    public var value: String
    public var isSet: Bool

    public static func parse(_ data: Data) -> [ClaudeSwapSetting]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = object["settings"] as? [[String: Any]]
        else { return nil }
        return rows.compactMap { row in
            guard let key = row["key"] as? String else { return nil }
            let value: String
            // JSON's true and false arrive as numbers too: check for them first.
            if let flag = row["value"] as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID() {
                return ClaudeSwapSetting(key: key, value: flag.boolValue ? "true" : "false", isSet: row["isSet"] as? Bool ?? false)
            }
            switch row["value"] {
            case let number as Double: value = number == number.rounded() ? String(Int(number)) : String(number)
            case let number as Int: value = String(number)
            case let text as String: value = text
            default: value = ""
            }
            return ClaudeSwapSetting(key: key, value: value, isSet: row["isSet"] as? Bool ?? false)
        }
    }
}

/// Running `cswap` from LiveIsland: its version, and commands typed in the console.
public enum ClaudeSwapCommand {
    /// "cswap 0.28.0" → "0.28.0".
    public static func version(from output: String) -> String? {
        output.split(whereSeparator: \.isWhitespace).last.map(String.init).flatMap { AppVersion($0) != nil ? $0 : nil }
    }

    /// "A newer version of claude-swap is available (0.29.0)" → "0.29.0".
    public static func newerVersion(in output: String) -> String? {
        guard let range = output.range(of: "newer version of claude-swap is available (") else { return nil }
        let rest = output[range.upperBound...]
        guard let end = rest.firstIndex(of: ")") else { return nil }
        let version = String(rest[..<end])
        return AppVersion(version) != nil ? version : nil
    }

    /// Splits a typed command into arguments, honoring quotes and backslashes, without a
    /// shell: nothing is expanded or substituted. A leading "cswap" is dropped. nil when a
    /// quote is left open.
    public static func arguments(_ text: String) -> [String]? {
        var arguments: [String] = []
        var current = ""
        var inWord = false
        var quote: Character?
        var escaped = false
        for character in text {
            if escaped {
                current.append(character)
                escaped = false
                inWord = true
            } else if character == "\\" && quote != "'" {
                escaped = true
            } else if let open = quote {
                if character == open { quote = nil } else { current.append(character) }
            } else if character == "\"" || character == "'" {
                quote = character
                inWord = true
            } else if character.isWhitespace {
                if inWord { arguments.append(current); current = ""; inWord = false }
            } else {
                current.append(character)
                inWord = true
            }
        }
        guard quote == nil, !escaped else { return nil }
        if inWord { arguments.append(current) }
        if arguments.first == "cswap" { arguments.removeFirst() }
        return arguments
    }

    /// Commands that need a terminal or never end: the console can't host them.
    public static func needsTerminal(_ arguments: [String]) -> Bool {
        // Bare `cswap` opens the dashboard.
        guard let command = arguments.first else { return true }
        switch command {
        case "tui", "watch", "run": return true
        // The menu bar app runs until quit; only installing or removing its service ends.
        case "menubar": return !arguments.contains { $0.hasSuffix("-service") }
        // LiveIsland runs the loop itself; a single tick ends.
        case "auto": return !arguments.contains("--once")
        // Without a token on the command line it waits for one to be typed.
        case "add-token": return arguments.count < 2 || arguments[1] == "-"
        default: return false
        }
    }
}
