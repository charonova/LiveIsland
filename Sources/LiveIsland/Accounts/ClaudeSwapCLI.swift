import Foundation
import LiveIslandCore

/// claude-swap (`cswap`), when it's installed: LiveIsland shows its accounts and asks it to
/// switch, and never touches a login itself.
enum ClaudeSwapCLI {
    enum Failure: LocalizedError {
        case notInstalled
        case unreadable
        case refused(String)

        var errorDescription: String? {
            switch self {
            case .notInstalled: return "claude-swap isn't installed (uv tool install claude-swap)."
            case .unreadable: return "claude-swap answered something LiveIsland couldn't read."
            case .refused(let message): return message
            }
        }
    }

    /// Where `uv tool install` and `pipx` put it, or Homebrew.
    static var executable: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.local/bin/cswap", "/opt/homebrew/bin/cswap", "/usr/local/bin/cswap"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    static func list() throws -> [ClaudeSwapAccount] {
        guard let accounts = ClaudeSwapJSON.accounts(from: try run(["list", "--json"])) else { throw Failure.unreadable }
        return accounts
    }

    /// Switches to claude-swap's account `number`; returns what it said.
    static func switchTo(_ number: Int) throws -> String {
        guard let result = ClaudeSwapJSON.switchResult(from: try run(["switch", String(number), "--json"])) else { throw Failure.unreadable }
        guard result.switched || !result.message.isEmpty else { throw Failure.unreadable }
        if !result.switched, result.message.localizedCaseInsensitiveContains("already") == false {
            throw Failure.refused(result.message)
        }
        return result.message
    }

    private static func run(_ arguments: [String], timeout: TimeInterval = 60) throws -> Data {
        guard let executable else { throw Failure.notInstalled }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        environment["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        // A watchdog: reading below only returns once the process has exited.
        let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        deadline.cancel()
        guard process.terminationReason == .exit else { throw Failure.refused("claude-swap didn't answer in time.") }
        return data
    }
}
