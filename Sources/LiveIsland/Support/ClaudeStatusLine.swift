import Foundation
import LiveIslandCore

/// Claude Code hands its usage percentages only to the status line command. This adds three
/// lines to the user's status line script that save them where the island reads them.
enum ClaudeStatusLine {
    static let block = """
    # LiveIsland: share Claude Code's usage limits with the island (delete these lines to stop).
    if limits=$(printf '%s' "$input" | jq -c 'select(.rate_limits != null) | {observed_at: now, transcript_path, rate_limits}' 2>/dev/null) && [ -n "$limits" ]; then
      printf '%s\\n' "$limits" > "$HOME/.claude/\(ClaudeUsageLimits.fileName).tmp" && mv -f "$HOME/.claude/\(ClaudeUsageLimits.fileName).tmp" "$HOME/.claude/\(ClaudeUsageLimits.fileName)"
    fi
    """

    enum Failure: LocalizedError {
        case noStatusLine
        case notAScript(String)
        case noInputLine(String)

        var errorDescription: String? {
            switch self {
            case .noStatusLine: return "Claude Code has no status line set up. Add one with /statusline in Claude Code first."
            case .notAScript(let command): return "Your status line runs “\(command)”, which isn't a script file LiveIsland can edit."
            case .noInputLine(let path): return "\((path as NSString).abbreviatingWithTildeInPath) doesn't read its input with input=$(cat); add the lines yourself after it reads stdin."
            }
        }
    }

    private static let claudeFolder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")

    /// The script file the status line command runs, from Claude Code's settings.
    static func script() throws -> URL {
        let settings = claudeFolder.appendingPathComponent("settings.json")
        guard let data = try? Data(contentsOf: settings),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let statusLine = object["statusLine"] as? [String: Any],
              let command = statusLine["command"] as? String
        else { throw Failure.noStatusLine }
        let file = command.split(separator: " ").map(String.init).last { $0.hasSuffix(".sh") }
        guard let file else { throw Failure.notAScript(command) }
        let path = (file.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) as NSString).expandingTildeInPath
            .replacingOccurrences(of: "$HOME", with: FileManager.default.homeDirectoryForCurrentUser.path)
        guard FileManager.default.isWritableFile(atPath: path) else { throw Failure.notAScript(command) }
        return URL(fileURLWithPath: path)
    }

    static var isInstalled: Bool {
        guard let url = try? script(), let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        return text.contains(ClaudeUsageLimits.fileName)
    }

    /// Lines added by an earlier version, which didn't say which session reported the limits:
    /// without that, accounts can't be told apart after a switch.
    static var needsUpdate: Bool {
        guard let url = try? script(), let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        return text.contains(ClaudeUsageLimits.fileName) && !text.contains("transcript_path, rate_limits")
    }

    /// Adds the lines right after the script reads its input, keeping a copy of the original
    /// next to it.
    static func install() throws -> URL {
        let url = try script()
        var text = try String(contentsOf: url, encoding: .utf8)
        var lines = text.components(separatedBy: "\n")
        // An earlier version's lines: replace them in place.
        if let start = lines.firstIndex(where: { $0.hasPrefix("# LiveIsland: share") }),
           let end = lines[start...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "fi" }) {
            guard needsUpdate else { return url }
            try backUp(url)
            lines.replaceSubrange(start...end, with: block.components(separatedBy: "\n"))
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            return url
        }
        guard !text.contains(ClaudeUsageLimits.fileName) else { return url }
        guard let index = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("input=$(cat") }) else {
            throw Failure.noInputLine(url.path)
        }
        try backUp(url)
        lines.insert(contentsOf: ["", block], at: index + 1)
        text = lines.joined(separator: "\n")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static func backUp(_ url: URL) throws {
        let backup = url.appendingPathExtension("liveisland-backup")
        try? FileManager.default.removeItem(at: backup)
        try FileManager.default.copyItem(at: url, to: backup)
    }
}
