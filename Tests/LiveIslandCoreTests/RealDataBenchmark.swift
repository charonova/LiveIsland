import Foundation
import Testing
@testable import LiveIslandCore

/// Reads this Mac's real Claude Code transcripts, to check speed and totals on real data.
/// Opt-in, since it depends on the machine: LIVEISLAND_REAL_DATA=1 ./scripts/test.sh -c release --filter RealData
@Suite("Real data", .enabled(if: ProcessInfo.processInfo.environment["LIVEISLAND_REAL_DATA"] == "1"))
struct RealDataBenchmark {
    @Test func ledgerReadsTodaysTranscriptsQuickly() throws {
        let projects = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        let since = Date().addingTimeInterval(-UsageLedger.horizon)
        let enumerator = FileManager.default.enumerator(at: projects, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])
        var files: [URL] = []
        var bytes = 0
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "jsonl",
                  let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let modified = values.contentModificationDate, modified >= since
            else { continue }
            files.append(url)
            bytes += values.fileSize ?? 0
        }

        let ledger = UsageLedger()
        let clock = ContinuousClock()
        let first = clock.measure { ledger.ingest(files, concurrency: 4) }
        let again = clock.measure { ledger.ingest(files, concurrency: 4) }
        let summary = ledger.summary()
        print("""
            Files: \(files.count), \(bytes / 1_048_576) MB
            First read: \(first), re-check with nothing new: \(again)
            Responses: \(ledger.recordCount); today \(Format.tokens(summary.todayTokens)) tokens in \(summary.todayRequests) requests
            Current 5-hour window: \(summary.windowStart.map { "\($0)" } ?? "none"), \(Format.tokens(summary.windowTokens)) tokens
            Latest limit notice: \(ledger.latestLimit.map { "\($0.windowLabel) \($0.status), resets \($0.resetsAt)" } ?? "none")
            """)
        #expect(again < .milliseconds(500), "re-checking unchanged files must be nearly free")
    }
}
