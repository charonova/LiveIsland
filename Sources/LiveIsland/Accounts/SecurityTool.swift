import Foundation

/// The system `security` tool, used the way Claude Code itself uses it: items it creates stay
/// readable by it without a Keychain prompt (an in-process Keychain call would tie them to
/// LiveIsland's signature, which changes with every build), and secrets go in hex-encoded on
/// stdin rather than on the command line, where other processes could see them.
enum SecurityTool {
    enum Failure: LocalizedError {
        case failed(Int32, String)
        case timedOut

        var errorDescription: String? {
            switch self {
            case .failed(let status, let message): return "The Keychain refused (\(status)): \(message)"
            case .timedOut: return "The Keychain didn't answer in time"
            }
        }
    }

    private static let path = "/usr/bin/security"
    /// errSecItemNotFound, as `security` reports it.
    private static let notFound: Int32 = 44
    /// `security -i` reads one command per line, into a 4096-byte buffer.
    private static let lineLimit = 4096 - 64

    /// The item's secret, or nil when there's no such item.
    static func read(service: String, account: String) throws -> Data? {
        let result = try run(["find-generic-password", "-a", account, "-s", service, "-w"])
        if result.status == notFound { return nil }
        guard result.status == 0 else { throw Failure.failed(result.status, result.error) }
        var output = result.output
        if output.last == UInt8(ascii: "\n") { output.removeLast() }
        // `-w` prints data that isn't plain text as hex.
        if let decoded = hexDecoded(output), (try? JSONSerialization.jsonObject(with: output)) == nil { return decoded }
        return output
    }

    /// When the item last changed, from its attributes alone: nothing is decrypted.
    static func modified(service: String, account: String) -> Date? {
        guard let result = try? run(["find-generic-password", "-a", account, "-s", service]), result.status == 0 else { return nil }
        let text = String(decoding: result.output, as: UTF8.self)
        guard let range = text.range(of: #""mdat"<timedate>=0x[0-9A-F]+\s+"(\d{14})Z"#, options: .regularExpression) else { return nil }
        let digits = text[range].filter(\.isNumber).suffix(14)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMddHHmmss"
        return formatter.date(from: String(digits))
    }

    /// Creates or updates the item. Small secrets go through stdin; one too long for a
    /// `security -i` line has to go on the command line, as Claude Code does too.
    static func write(_ value: Data, service: String, account: String) throws {
        let hex = value.map { String(format: "%02x", $0) }.joined()
        let line = "add-generic-password -U -a \(quoted(account)) -s \(quoted(service)) -X \(hex)\n"
        let result: (status: Int32, output: Data, error: String)
        if line.utf8.count <= lineLimit {
            result = try run(["-i"], input: Data(line.utf8))
        } else {
            result = try run(["add-generic-password", "-U", "-a", account, "-s", service, "-X", hex])
        }
        guard result.status == 0, result.error.isEmpty || !result.error.contains("error") else {
            throw Failure.failed(result.status, result.error)
        }
        // `security -i` can report success for a command that failed: check what landed.
        guard try read(service: service, account: account) == value else {
            throw Failure.failed(result.status, "the saved value didn't match")
        }
    }

    static func delete(service: String, account: String) {
        _ = try? run(["delete-generic-password", "-a", account, "-s", service])
    }

    // MARK: -

    private static func quoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func hexDecoded(_ data: Data) -> Data? {
        guard !data.isEmpty, data.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(data.count / 2)
        var index = data.startIndex
        while index < data.endIndex {
            guard let byte = UInt8(String(decoding: data[index..<data.index(index, offsetBy: 2)], as: UTF8.self), radix: 16) else { return nil }
            bytes.append(byte)
            index = data.index(index, offsetBy: 2)
        }
        return Data(bytes)
    }

    private static func run(_ arguments: [String], input: Data? = nil, timeout: TimeInterval = 10) throws
        -> (status: Int32, output: Data, error: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let output = Pipe(), error = Pipe(), stdin = Pipe()
        process.standardOutput = output
        process.standardError = error
        process.standardInput = input == nil ? FileHandle.nullDevice : stdin
        try process.run()
        // A watchdog: the reads below only return once the process has exited.
        let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        if let input {
            stdin.fileHandleForWriting.write(input)
            try? stdin.fileHandleForWriting.close()
        }
        // Read while it runs, so a large answer can't fill the pipe and stall it.
        let collected = output.fileHandleForReading.readDataToEndOfFile()
        let message = error.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        deadline.cancel()
        guard process.terminationReason == .exit else { throw Failure.timedOut }
        return (process.terminationStatus, collected, String(decoding: message, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
