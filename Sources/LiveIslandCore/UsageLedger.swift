import Foundation

/// Counts Claude Code token use from transcripts, reading only what each file gained since
/// the last look. Transcripts can total gigabytes a day, so nothing is ever read twice, and
/// within new data only the lines that matter are examined.
public final class UsageLedger {
    /// How far back records are kept: enough for "today" and the current 5-hour window.
    public static let horizon: TimeInterval = 26 * 3600
    /// Claude's usage limits count in 5-hour windows starting at the first message.
    public static let windowLength: TimeInterval = 5 * 3600
    private static let chunkSize = 8 << 20
    /// The only lines that carry usage or limits.
    private static let markers = [#""type":"assistant""#, #""rate_limit_info""#]

    /// How far each file has been read, and which file it was (a replaced file starts over).
    private var offsets: [String: Position] = [:]
    private var records: [String: (timestamp: Date, tokens: Int)] = [:] { didSet { sortedCache = nil } }
    /// Records in time order, kept until they change: the island asks for a summary every few seconds.
    private var sortedCache: [(timestamp: Date, tokens: Int)]?
    public private(set) var latestLimit: ClaudeLimitNotice?
    /// When Claude last answered: proof that a request went out on the current login.
    public private(set) var latestReplyAt: Date?

    public init() {}

    public var recordCount: Int { records.count }

    /// The latest limit notice, unless Claude has answered since: then the limit was lifted
    /// (it reset early, or extra usage kicked in) and the notice is stale.
    public func currentLimit(at now: Date = Date()) -> ClaudeLimitNotice? {
        guard let notice = latestLimit, notice.isCurrent(at: now) else { return nil }
        let answeredSince = records.values.contains { $0.timestamp > notice.observedAt }
        return answeredSince ? nil : notice
    }

    /// Reads the bytes appended to `url` since the last call. A file that was replaced or
    /// shrank is read again from the start.
    public func ingest(_ url: URL, now: Date = Date()) {
        ingest([url], now: now, concurrency: 1)
    }

    /// Reads many files, `concurrency` at a time, then merges the results.
    public func ingest(_ urls: [URL], now: Date = Date(), concurrency: Int) {
        let earliest = now.addingTimeInterval(-Self.horizon)
        let starts = urls.map { offsets[$0.path] }
        var results = [Scan?](repeating: nil, count: urls.count)
        let lanes = max(1, min(concurrency, urls.count))
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: lanes) { lane in
            for index in stride(from: lane, to: urls.count, by: lanes) {
                let scan = Self.scan(urls[index], from: starts[index], earliest: earliest)
                lock.lock()
                results[index] = scan
                lock.unlock()
            }
        }
        for (url, scan) in zip(urls, results) {
            guard let scan else { continue }
            offsets[url.path] = scan.position
            for record in scan.records where records[record.messageID] == nil {
                records[record.messageID] = (record.timestamp, record.tokens)
                if latestReplyAt == nil || record.timestamp > latestReplyAt! { latestReplyAt = record.timestamp }
            }
            if let notice = scan.latestLimit, latestLimit == nil || notice.observedAt > latestLimit!.observedAt {
                latestLimit = notice
            }
        }
    }

    /// Drops records too old to matter, to keep memory flat.
    public func prune(now: Date = Date()) {
        let earliest = now.addingTimeInterval(-Self.horizon)
        records = records.filter { $0.value.timestamp >= earliest }
    }

    public func summary(now: Date = Date(), calendar: Calendar = .current) -> UsageSummary {
        let sorted = sortedCache ?? records.values.sorted { $0.timestamp < $1.timestamp }
        sortedCache = sorted
        var summary = UsageSummary()

        // Rebuild the 5-hour windows: each starts on the hour of the first message after the
        // previous one ended.
        var windowStart: Date?
        var windowTokens = 0, windowRequests = 0
        for record in sorted {
            if let start = windowStart, record.timestamp < start.addingTimeInterval(Self.windowLength) {
                windowTokens += record.tokens
                windowRequests += 1
            } else {
                windowStart = calendar.dateInterval(of: .hour, for: record.timestamp)?.start ?? record.timestamp
                windowTokens = record.tokens
                windowRequests = 1
            }
        }
        if let start = windowStart, now < start.addingTimeInterval(Self.windowLength) {
            summary.windowStart = start
            summary.windowEnd = start.addingTimeInterval(Self.windowLength)
            summary.windowTokens = windowTokens
            summary.windowRequests = windowRequests
        }

        let today = calendar.startOfDay(for: now)
        for record in sorted where record.timestamp >= today {
            summary.todayTokens += record.tokens
            summary.todayRequests += 1
        }
        return summary
    }

    // MARK: - Scanning

    private struct Position {
        var inode: UInt64
        var offset: UInt64
    }

    private struct Scan {
        var position: Position
        var records: [ClaudeTranscript.UsageRecord] = []
        var latestLimit: ClaudeLimitNotice?
    }

    /// Reads one file from where the last scan stopped. Safe to run on any thread.
    private static func scan(_ url: URL, from previous: Position?, earliest: Date) -> Scan? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let inode = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let size = (try? handle.seekToEnd()) ?? 0
        var offset = previous.map { $0.inode == inode ? $0.offset : 0 } ?? 0
        if size < offset { offset = 0 }
        var scan = Scan(position: Position(inode: inode, offset: offset))
        guard size > offset else { return scan }

        var pending = Data()
        // A response is written once per content block; parse each only once.
        var seen = Set<String>()
        do {
            try handle.seek(toOffset: offset)
            while let chunk = try autoreleasepool(invoking: { try handle.read(upToCount: chunkSize) }), !chunk.isEmpty {
                pending.append(chunk)
                let consumed = autoreleasepool { JSONLScanner.forEachLine(containing: markers, in: pending) { line in
                    if let id = ClaudeTranscript.messageID(in: line), !seen.insert(id).inserted { return }
                    if let record = ClaudeTranscript.usageRecord(in: line) {
                        if record.timestamp >= earliest { scan.records.append(record) }
                    } else if let notice = ClaudeTranscript.limitNotice(in: line),
                              scan.latestLimit == nil || notice.observedAt > scan.latestLimit!.observedAt {
                        scan.latestLimit = notice
                    }
                } }
                offset += UInt64(consumed)
                pending.removeSubrange(pending.startIndex..<pending.startIndex + consumed)
            }
        } catch {
            return nil
        }
        scan.position.offset = offset
        return scan
    }
}
