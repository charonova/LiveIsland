import Foundation

/// Claude Code's own advisory locks, held while LiveIsland changes its login. Claude Code
/// (through the npm `proper-lockfile` package) takes `~/.claude/.oauth_refresh.lock` and
/// `~/.claude.lock` while it refreshes a token, and `~/.claude.json.lock` while it writes its
/// config. Each lock is a directory: creating it is the lock. A holder touches it every few
/// seconds, so one left untouched for long (60 s for credentials, 10 s for the config) belongs
/// to a process that died. Holding them means a refresh in flight finishes before the switch,
/// or sees the new login afterwards; it can't overwrite it.
enum ClaudeCodeLocks {
    enum Failure: LocalizedError {
        case busy(String)

        var errorDescription: String? {
            switch self {
            case .busy(let name): return "Claude Code is busy with its login (\(name)). Try again in a few seconds."
            }
        }
    }

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// In Claude Code's order: its refresh takes the first two in this order too.
    private static var locks: [(url: URL, staleAfter: TimeInterval)] {
        [(home.appendingPathComponent(".claude/.oauth_refresh.lock"), 60),
         (home.appendingPathComponent(".claude.lock"), 60),
         (home.appendingPathComponent(".claude.json.lock"), 10)]
    }

    static func withAll<T>(timeout: TimeInterval = 9, _ body: () throws -> T) throws -> T {
        var held: [URL] = []
        defer { for url in held.reversed() { try? FileManager.default.removeItem(at: url) } }
        let deadline = Date().addingTimeInterval(timeout)
        for lock in locks {
            try acquire(lock.url, staleAfter: lock.staleAfter, deadline: deadline)
            held.append(lock.url)
        }
        return try body()
    }

    private static func acquire(_ url: URL, staleAfter: TimeInterval, deadline: Date) throws {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        while true {
            if mkdir(url.path, 0o755) == 0 { return }
            guard errno == EEXIST else { throw Failure.busy(url.lastPathComponent) }
            // Taken. An abandoned lock goes; a live one is waited for.
            if let touched = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
               Date().timeIntervalSince(touched) > staleAfter {
                rmdir(url.path)
                continue
            }
            guard Date() < deadline else { throw Failure.busy(url.lastPathComponent) }
            Thread.sleep(forTimeInterval: 0.25 + Double.random(in: 0...0.25))
        }
    }
}
