import AppKit
import LiveIslandCore
import os

private let log = Logger(subsystem: "com.aissam.liveisland", category: "media")

/// What's playing in any app (Music, Spotify, YouTube in a browser…), through the bundled
/// open-source mediaremote-adapter. Since macOS 15.4 only Apple-signed processes may read
/// MediaRemote, so the adapter runs inside the system's /usr/bin/perl.
@MainActor
final class NowPlayingProvider {
    enum Command: Int {
        case play = 0
        case pause = 1
        case togglePlayPause = 2
        case nextTrack = 4
        case previousTrack = 5
    }

    var onChange: ((NowPlaying?) -> Void)?
    private(set) var current: NowPlaying?

    private var process: Process?
    private var pending = Data()
    private var restartDelay: TimeInterval = 1
    private var stopped = false

    private var script: URL? { Bundle.main.url(forResource: "mediaremote-adapter", withExtension: "pl") }
    private var framework: URL? { Bundle.main.url(forResource: "MediaRemoteAdapter", withExtension: "framework") }

    func start() {
        stopped = false
        guard let script, let framework else {
            log.error("Media adapter is missing from the app bundle")
            return
        }
        Self.endOrphans(of: script)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [script.path, framework.path, "stream", "--no-diff", "--debounce=60"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            DispatchQueue.main.async { self?.receive(chunk) }
        }
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.adapterExited() }
        }
        do {
            try process.run()
            self.process = process
            log.notice("Media adapter started")
        } catch {
            log.error("Couldn't start the media adapter: \(error.localizedDescription, privacy: .public)")
        }
    }

    func stop() {
        stopped = true
        process?.terminate()
        process = nil
    }

    func send(_ command: Command) {
        run(["send", String(command.rawValue)])
        // Feels instant even before the next update arrives.
        if command == .togglePlayPause, var info = current {
            info.elapsed = info.position(at: Date())
            info.timestamp = Date()
            info.isPlaying.toggle()
            publish(info)
        }
    }

    /// An adapter left behind by an instance that was killed outright keeps running under
    /// launchd; there's only ever one island, so those can go.
    private static func endOrphans(of script: URL) {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-axo", "pid=,ppid=,command="]
        let output = Pipe()
        ps.standardOutput = output
        guard (try? ps.run()) != nil else { return }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") where line.contains(script.path) {
            let fields = line.split(separator: " ", maxSplits: 2)
            guard fields.count == 3, fields[1] == "1", let pid = pid_t(fields[0]) else { continue }
            log.notice("Ending a leftover media adapter (\(pid))")
            kill(pid, SIGTERM)
        }
    }

    func seek(to seconds: Double) {
        run(["seek", String(Int(seconds * 1_000_000))])
    }

    private func run(_ arguments: [String]) {
        guard let script, let framework else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [script.path, framework.path] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    private func receive(_ chunk: Data) {
        pending.append(chunk)
        var latest = current
        let consumed = JSONLScanner.forEachLine(in: pending) { line in
            latest = NowPlaying.applying(line, to: latest)
        }
        pending.removeSubrange(pending.startIndex..<pending.startIndex + consumed)
        restartDelay = 1
        if latest != current { publish(latest) }
    }

    private func publish(_ info: NowPlaying?) {
        current = info
        onChange?(info)
    }

    /// The adapter shouldn't exit; if it does, bring it back with growing delays.
    private func adapterExited() {
        process = nil
        guard !stopped else { return }
        log.error("Media adapter exited; restarting in \(self.restartDelay)s")
        DispatchQueue.main.asyncAfter(deadline: .now() + restartDelay) { [weak self] in
            guard let self, !self.stopped, self.process == nil else { return }
            self.start()
        }
        restartDelay = min(restartDelay * 2, 60)
    }
}
