import CoreServices
import Foundation
import LiveIslandCore
import os

private let log = Logger(subsystem: "com.aissam.liveisland", category: "agents")

/// Watches Claude Code and Codex sessions through their transcripts. No setup or hooks:
/// macOS file events say which file changed, and only the new bytes are read.
@MainActor
final class AgentMonitor {
    struct Snapshot: Equatable {
        var sessions: [AgentSession] = []
        var usage: UsageSummary?
        var claudeLimit: ClaudeLimitNotice?
        var codexLimits: CodexLimits?
        /// Claude Code's own 5-hour and weekly percentages, when the status line shares them.
        var claudeLimits: ClaudeUsageLimits?
    }

    var onUpdate: ((Snapshot) -> Void)?
    private(set) var snapshot = Snapshot()

    private let worker = Worker()
    private var stream: FSEventStreamRef?
    private var tick: Timer?

    nonisolated static let claudeRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
    nonisolated static let codexRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")

    func start() {
        worker.queue.async { [worker] in
            worker.loadRecent()
            let next = worker.snapshot(now: Date())
            DispatchQueue.main.async { self.publish(next) }
        }
        startWatching()
        // States also change with time alone (working → waiting → idle).
        tick = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh(changed: []) }
        }
    }

    func stop() {
        tick?.invalidate()
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
    }

    private func refresh(changed paths: [String]) {
        worker.queue.async { [worker] in
            worker.ingest(paths)
            let next = worker.snapshot(now: Date())
            DispatchQueue.main.async { self.publish(next) }
        }
    }

    private func publish(_ next: Snapshot) {
        guard next != snapshot else { return }
        snapshot = next
        onUpdate?(next)
    }

    private func startWatching() {
        let roots = [Self.claudeRoot, Self.codexRoot].map(\.path).filter { FileManager.default.fileExists(atPath: $0) }
        guard !roots.isEmpty else { return }
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let monitor = Unmanaged<AgentMonitor>.fromOpaque(info).takeUnretainedValue()
            let changed = (unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []).filter { $0.hasSuffix(".jsonl") }
            guard count > 0, !changed.isEmpty else { return }
            MainActor.assumeIsolated { monitor.refresh(changed: changed) }
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(nil, callback, &context, roots as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, flags) else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }
}

/// Everything that touches the transcripts, on one background queue.
private final class Worker: @unchecked Sendable {
    let queue = DispatchQueue(label: "com.aissam.liveisland.agents", qos: .utility)
    private let ledger = UsageLedger()
    private var ledgerReady = false
    /// Session files seen recently, with what their tails said.
    private var sessions: [String: Session] = [:]
    private var codexLimits: CodexLimits?
    private var lastPrune = Date()

    private struct Session {
        var kind: AgentKind
        var modified: Date
        var claudeTail: ClaudeTranscript.Tail?
        var codexTail: CodexRollout.Tail?
        var codexCwd: String?
    }

    /// How long a quiet session stays listed.
    private static let recent: TimeInterval = 30 * 60
    private static let tailBytes = 256 * 1024

    func loadRecent() {
        let now = Date()
        let claudeFiles = Self.files(under: AgentMonitor.claudeRoot, modifiedSince: now.addingTimeInterval(-UsageLedger.horizon))
        let start = Date()
        ledger.ingest(claudeFiles.map(\.url), now: now, concurrency: 4)
        ledgerReady = true
        log.notice("Read \(claudeFiles.count) Claude transcripts in \(Date().timeIntervalSince(start), format: .fixed(precision: 2))s")

        let codexFiles = Self.files(under: AgentMonitor.codexRoot, modifiedSince: now.addingTimeInterval(-7 * 86_400))
        // The newest Codex file holds the latest limits, even if the session is old.
        if let newest = codexFiles.max(by: { $0.modified < $1.modified }) { readCodex(newest.url, modified: newest.modified) }
        for file in claudeFiles + codexFiles where now.timeIntervalSince(file.modified) < Self.recent {
            update(file.url.path, modified: file.modified)
        }
    }

    func ingest(_ paths: [String]) {
        for path in Set(paths) {
            guard let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date else {
                sessions[path] = nil
                continue
            }
            if path.hasPrefix(AgentMonitor.claudeRoot.path), ledgerReady {
                ledger.ingest(URL(fileURLWithPath: path))
            }
            update(path, modified: modified)
        }
    }

    private var hosts: (claude: [String: SessionHost], codex: [String: SessionHost]) = ([:], [:])
    private var lastHostScan = Date.distantPast

    /// Which app each running agent lives in, keyed the way sessions are filed: Claude Code
    /// by project folder name, Codex by folder. One with a terminal wins over one without.
    private func refreshHosts(now: Date) {
        guard now.timeIntervalSince(lastHostScan) > 5 else { return }
        lastHostScan = now
        var claude: [String: SessionHost] = [:]
        var codex: [String: SessionHost] = [:]
        for found in SessionHosts.scan() {
            func keep(_ existing: SessionHost?) -> Bool { existing == nil || (existing?.tty == nil && found.host.tty != nil) }
            switch found.kind {
            case .claude:
                let key = ClaudeTranscript.projectKey(for: found.host.folder)
                if keep(claude[key]) { claude[key] = found.host }
            case .codex:
                if keep(codex[found.host.folder]) { codex[found.host.folder] = found.host }
            }
        }
        let summary = (claude.values.map(\.bundleIdentifier) + codex.values.map(\.bundleIdentifier)).sorted().joined(separator: ", ")
        if summary != lastHostSummary {
            log.notice("Agents running in: \(summary.isEmpty ? "nothing" : summary, privacy: .public)")
            lastHostSummary = summary
        }
        hosts = (claude, codex)
    }
    private var lastHostSummary = ""

    func snapshot(now: Date) -> AgentMonitor.Snapshot {
        sessions = sessions.filter { now.timeIntervalSince($0.value.modified) < Self.recent }
        refreshHosts(now: now)
        var list: [AgentSession] = []
        for (path, session) in sessions {
            switch session.kind {
            case .claude:
                guard let tail = session.claudeTail else { continue }
                let state = ClaudeTranscript.state(of: tail, modified: session.modified, now: now)
                list.append(AgentSession(
                    id: path, kind: .claude,
                    project: ClaudeTranscript.projectName(cwd: tail.cwd, fallback: Self.claudeProjectFallback(path)),
                    title: tail.title, state: state, lastActivity: tail.lastTimestamp ?? session.modified,
                    workingSince: state == .working || state == .waiting ? tail.turnStartedAt : nil, cwd: tail.cwd,
                    host: hosts.claude[URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent]))
            case .codex:
                guard let tail = session.codexTail else { continue }
                let state = CodexRollout.state(of: tail, modified: session.modified, now: now)
                list.append(AgentSession(
                    id: path, kind: .codex,
                    project: ClaudeTranscript.projectName(cwd: session.codexCwd ?? tail.cwd, fallback: "Codex"),
                    state: state, lastActivity: tail.lastEventAt ?? session.modified,
                    workingSince: tail.working ? tail.turnStartedAt : nil, tokens: tail.tokens ?? 0,
                    cwd: session.codexCwd ?? tail.cwd, host: (session.codexCwd ?? tail.cwd).flatMap { hosts.codex[$0] }))
            }
        }
        list.sort { lhs, rhs in
            let order: [AgentState: Int] = [.waiting: 0, .working: 1, .done: 2, .idle: 3]
            return order[lhs.state]! != order[rhs.state]! ? order[lhs.state]! < order[rhs.state]! : lhs.lastActivity > rhs.lastActivity
        }
        if now.timeIntervalSince(lastPrune) > 600 {
            ledger.prune(now: now)
            lastPrune = now
        }
        return AgentMonitor.Snapshot(
            sessions: list,
            usage: ledgerReady ? ledger.summary(now: now) : nil,
            claudeLimit: ledger.currentLimit(at: now),
            codexLimits: codexLimits,
            claudeLimits: readClaudeLimits()?.current(at: now))
    }

    private var claudeLimitsFile: (modified: Date, limits: ClaudeUsageLimits?)?

    /// Re-reads the status line's file only when it changed.
    private func readClaudeLimits() -> ClaudeUsageLimits? {
        let url = AgentMonitor.claudeRoot.deletingLastPathComponent().appendingPathComponent(ClaudeUsageLimits.fileName)
        guard let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else {
            claudeLimitsFile = nil
            return nil
        }
        if let cached = claudeLimitsFile, cached.modified == modified { return cached.limits }
        let limits = (try? Data(contentsOf: url)).flatMap { ClaudeUsageLimits.parse($0, modified: modified) }
        claudeLimitsFile = (modified, limits)
        return limits
    }

    private func update(_ path: String, modified: Date) {
        if path.hasPrefix(AgentMonitor.claudeRoot.path) {
            // Subagent transcripts live beside their parent; the parent already shows the work.
            let name = URL(fileURLWithPath: path).lastPathComponent
            guard !path.contains("/subagents/"), !name.hasPrefix("agent-") else { return }
            let tail = ClaudeTranscript.tail(of: Self.lastLines(of: path))
            sessions[path] = Session(kind: .claude, modified: modified, claudeTail: tail)
        } else if path.hasPrefix(AgentMonitor.codexRoot.path) {
            readCodex(URL(fileURLWithPath: path), modified: modified)
        }
    }

    private func readCodex(_ url: URL, modified: Date) {
        let lines = Self.lastLines(of: url.path)
        let tail = CodexRollout.tail(of: lines)
        for line in lines.reversed() {
            if var limits = CodexRollout.limits(in: line) {
                limits.session = url.path
                if codexLimits == nil || limits.observedAt >= codexLimits!.observedAt { codexLimits = limits }
                break
            }
        }
        var session = sessions[url.path] ?? Session(kind: .codex, modified: modified)
        session.modified = modified
        session.codexTail = tail
        if session.codexCwd == nil { session.codexCwd = Self.firstLine(of: url.path).flatMap { CodexRollout.tail(of: [$0]).cwd } }
        sessions[url.path] = session
    }

    private static func lastLines(of path: String) -> [Data] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return [] }
        var lines: [Data] = []
        JSONLScanner.forEachLine(in: data) { lines.append($0) }
        // The first line may be cut in half.
        return start > 0 ? Array(lines.dropFirst()) : lines
    }

    private static func firstLine(of path: String) -> Data? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 64 * 1024), let end = data.firstIndex(of: 0x0A) else { return nil }
        return data[data.startIndex..<end]
    }

    private static func files(under root: URL, modifiedSince date: Date) -> [(url: URL, modified: Date)] {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { return [] }
        var files: [(URL, Date)] = []
        while let url = enumerator.nextObject() as? URL {
            guard url.pathExtension == "jsonl",
                  let modified = try? url.resourceValues(forKeys: Set(keys)).contentModificationDate,
                  modified >= date
            else { continue }
            files.append((url, modified))
        }
        return files
    }

    /// "-Users-me-Code-app" → "app", when a transcript has no working directory yet.
    private static func claudeProjectFallback(_ path: String) -> String {
        let folder = URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent
        return folder.split(separator: "-").last.map(String.init) ?? "Claude"
    }
}
