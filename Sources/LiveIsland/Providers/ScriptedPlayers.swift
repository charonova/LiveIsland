import AppKit
import LiveIslandCore
import os

private let log = Logger(subsystem: "com.aissam.liveisland", category: "players")

/// Spotify and Music, read and controlled directly. The system's now-playing info only names
/// one app at a time; these two say when their track or state changes, and answer AppleScript,
/// so a paused Spotify stays one tap away while a video plays in the browser.
@MainActor
final class ScriptedPlayers {
    struct Player: Sendable {
        let bundleIdentifier: String
        let notification: String
        let query: String
        let commands: (playPause: String, next: String, previous: String)
    }

    nonisolated static let spotify = Player(
        bundleIdentifier: "com.spotify.client",
        notification: "com.spotify.client.PlaybackStateChanged",
        query: """
        tell application id "com.spotify.client"
            set t to current track
            return {player state as string, name of t, artist of t, album of t, duration of t, player position, artwork url of t, id of t}
        end tell
        """,
        commands: ("playpause", "next track", "previous track"))

    nonisolated static let music = Player(
        bundleIdentifier: "com.apple.Music",
        notification: "com.apple.Music.playerInfo",
        query: """
        tell application id "com.apple.Music"
            set s to player state as string
            if s is "stopped" then return {s}
            set t to current track
            return {s, name of t, artist of t, album of t, duration of t, player position, "", persistent ID of t}
        end tell
        """,
        commands: ("playpause", "next track", "previous track"))

    nonisolated static let all = [spotify, music]

    /// A track coming up, as Music lists it.
    struct QueueItem: Equatable, Identifiable, Sendable {
        var title: String
        var artist: String
        var trackID: String
        var id: String { trackID }
    }

    var onChange: (([NowPlaying]) -> Void)?
    /// What plays next, per player. Only Music says; Spotify keeps its queue to itself.
    var onQueue: (([String: [QueueItem]]) -> Void)?
    private(set) var players: [String: NowPlaying] = [:]
    private var queues: [String: [QueueItem]] = [:]

    private let queue = DispatchQueue(label: "com.aissam.liveisland.players", qos: .userInitiated)
    /// Compiled once: compiling is most of what an AppleScript query costs.
    private let scripts = ScriptCache()
    private var observers: [NSObjectProtocol] = []
    /// The last artwork per player, by track, so it's fetched once per track.
    private var artwork: [String: (track: String, data: Data?)] = [:]
    private var running = false

    func start() {
        guard !running else { return }
        running = true
        let center = DistributedNotificationCenter.default()
        for player in Self.all {
            observers.append(center.addObserver(forName: Notification.Name(player.notification), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh(player) }
            })
        }
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let bundle = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated {
                guard let self, let bundle, self.players[bundle] != nil else { return }
                self.players[bundle] = nil
                self.publish()
            }
        })
        refreshAll()
    }

    func stop() {
        running = false
        observers.forEach { DistributedNotificationCenter.default().removeObserver($0); NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers = []
        players = [:]
    }

    /// Positions drift when someone seeks inside the app, which sends no notice; the island
    /// calls this while it's open.
    func refreshAll() {
        for player in Self.all { refresh(player) }
    }

    func handles(_ bundleIdentifier: String?) -> Bool {
        Self.all.contains { $0.bundleIdentifier == bundleIdentifier }
    }

    enum Command { case playPause, next, previous }

    func send(_ command: Command, to bundleIdentifier: String) {
        guard let player = Self.all.first(where: { $0.bundleIdentifier == bundleIdentifier }) else { return }
        let verb: String
        switch command {
        case .playPause: verb = player.commands.playPause
        case .next: verb = player.commands.next
        case .previous: verb = player.commands.previous
        }
        if command == .playPause, var info = players[bundleIdentifier] {
            info.elapsed = info.position(at: Date())
            info.timestamp = Date()
            info.isPlaying.toggle()
            players[bundleIdentifier] = info
            publish()
        }
        perform("tell application id \"\(bundleIdentifier)\" to \(verb)", then: player)
    }

    /// Plays a track the player named before: from history, or from Music's queue.
    func play(trackID: String, in bundleIdentifier: String) {
        guard let player = Self.all.first(where: { $0.bundleIdentifier == bundleIdentifier }),
              trackID.allSatisfy({ $0.isLetter || $0.isNumber || $0 == ":" })
        else { return }
        let source: String
        if bundleIdentifier == Self.spotify.bundleIdentifier {
            source = "tell application id \"com.spotify.client\" to play track \"\(trackID)\""
        } else {
            source = """
            tell application id "com.apple.Music"
                try
                    play (first track of current playlist whose persistent ID is "\(trackID)")
                on error
                    play (first track of library playlist 1 whose persistent ID is "\(trackID)")
                end try
            end tell
            """
        }
        perform(source, then: player)
    }

    /// Opens a player that isn't running and starts it playing: what tapping its icon means.
    func launchAndPlay(_ bundleIdentifier: String) {
        guard let player = Self.all.first(where: { $0.bundleIdentifier == bundleIdentifier }) else { return }
        queue.async { [weak self] in
            var error: NSDictionary?
            NSAppleScript(source: "tell application id \"\(bundleIdentifier)\" to play")?.executeAndReturnError(&error)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self?.refresh(player) }
        }
    }

    func seek(_ bundleIdentifier: String, to seconds: Double) {
        guard let player = Self.all.first(where: { $0.bundleIdentifier == bundleIdentifier }) else { return }
        perform("tell application id \"\(bundleIdentifier)\" to set player position to \(Int(seconds.rounded()))", then: player)
    }

    // MARK: - Reading

    private func perform(_ source: String, then player: Player) {
        guard isRunning(player) else { return }
        queue.async { [weak self] in
            var error: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&error)
            if let error { log.error("\(player.bundleIdentifier, privacy: .public): \(error, privacy: .public)") }
            DispatchQueue.main.async { self?.refresh(player) }
        }
    }

    private func isRunning(_ player: Player) -> Bool {
        // Never script an app that isn't open: AppleScript would launch it.
        !NSRunningApplication.runningApplications(withBundleIdentifier: player.bundleIdentifier).isEmpty
    }

    private func refresh(_ player: Player) {
        guard running else { return }
        guard isRunning(player) else {
            if players.removeValue(forKey: player.bundleIdentifier) != nil { publish() }
            return
        }
        let known = artwork[player.bundleIdentifier]
        let scripts = scripts
        queue.async { [weak self] in
            var error: NSDictionary?
            let result = scripts.script(player.query)?.executeAndReturnError(&error)
            if let error, let code = error[NSAppleScript.errorNumber] as? Int, code != -1728 {
                // -1728 is "no current track", which is normal.
                log.error("Reading \(player.bundleIdentifier, privacy: .public) failed: \(code) \(error[NSAppleScript.errorMessage] as? String ?? "", privacy: .public)")
            }
            var info = result.flatMap { Self.parse($0, player: player) }
            var fetched: (track: String, data: Data?)?
            var upNext: [QueueItem]?
            if var current = info, let track = current.trackID {
                if let known, known.track == track {
                    current.info.artwork = known.data
                } else {
                    let data = Self.artwork(for: player, url: current.artworkURL)
                    current.info.artwork = data
                    fetched = (track, data)
                    // A new track: what follows it changed too.
                    if player.bundleIdentifier == Self.music.bundleIdentifier { upNext = Self.musicUpNext() }
                }
                info = current
            }
            DispatchQueue.main.async {
                guard let self, self.running else { return }
                if let fetched { self.artwork[player.bundleIdentifier] = fetched }
                if info == nil, self.queues[player.bundleIdentifier] != nil { upNext = [] }
                if let upNext, self.queues[player.bundleIdentifier] ?? [] != upNext {
                    self.queues[player.bundleIdentifier] = upNext.isEmpty ? nil : upNext
                    self.onQueue?(self.queues)
                }
                let next = info?.info
                guard self.players[player.bundleIdentifier] != next else { return }
                self.players[player.bundleIdentifier] = next
                self.publish()
            }
        }
    }

    private func publish() {
        onChange?(players.values.sorted { $0.bundleIdentifier ?? "" < $1.bundleIdentifier ?? "" })
    }

    private nonisolated static func parse(_ result: NSAppleEventDescriptor, player: Player)
        -> (info: NowPlaying, trackID: String?, artworkURL: String?)? {
        func item(_ index: Int) -> NSAppleEventDescriptor? {
            index <= result.numberOfItems ? result.atIndex(index) : nil
        }
        guard let state = item(1)?.stringValue, state != "stopped",
              let title = item(2)?.stringValue, !title.isEmpty
        else { return nil }
        var duration = item(5)?.doubleValue ?? 0
        // Spotify counts in milliseconds, Music in seconds.
        if player.bundleIdentifier == spotify.bundleIdentifier { duration /= 1000 }
        let info = NowPlaying(
            title: title, artist: item(3)?.stringValue ?? "", album: item(4)?.stringValue ?? "",
            bundleIdentifier: player.bundleIdentifier, duration: duration > 0 ? duration : nil,
            elapsed: item(6)?.doubleValue, timestamp: Date(), playbackRate: 1, isPlaying: state == "playing",
            trackID: item(8)?.stringValue)
        let url = item(7)?.stringValue
        return (info, item(8)?.stringValue ?? title, url?.isEmpty == false ? url : nil)
    }

    /// The tracks after the current one in Music's playlist. With shuffle on, the order is
    /// Music's secret, so there's nothing to show.
    private nonisolated static func musicUpNext() -> [QueueItem] {
        let source = """
        tell application id "com.apple.Music"
            if shuffle enabled then return {}
            set p to current playlist
            set i to index of current track
            set n to count of tracks of p
            set out to {}
            repeat with k from (i + 1) to (i + 8)
                if k > n then exit repeat
                set t to track k of p
                set end of out to {name of t, artist of t, persistent ID of t}
            end repeat
            return out
        end tell
        """
        var error: NSDictionary?
        guard let list = NSAppleScript(source: source)?.executeAndReturnError(&error), list.numberOfItems > 0 else { return [] }
        return (1...list.numberOfItems).compactMap { index in
            guard let entry = list.atIndex(index), entry.numberOfItems >= 3,
                  let title = entry.atIndex(1)?.stringValue, let id = entry.atIndex(3)?.stringValue
            else { return nil }
            return QueueItem(title: title, artist: entry.atIndex(2)?.stringValue ?? "", trackID: id)
        }
    }

    /// Spotify gives a link to the cover; Music hands over the image itself.
    private nonisolated static func artwork(for player: Player, url: String?) -> Data? {
        if let url, let link = URL(string: url), link.scheme == "https" {
            return try? Data(contentsOf: link)
        }
        guard player.bundleIdentifier == music.bundleIdentifier else { return nil }
        var error: NSDictionary?
        let source = "tell application id \"com.apple.Music\" to get raw data of artwork 1 of current track"
        return NSAppleScript(source: source)?.executeAndReturnError(&error).data
    }
}

/// Compiled AppleScripts by source. Used only on the players queue.
private final class ScriptCache: @unchecked Sendable {
    private var compiled: [String: NSAppleScript] = [:]

    func script(_ source: String) -> NSAppleScript? {
        if let script = compiled[source] { return script }
        guard let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        script.compileAndReturnError(&error)
        compiled[source] = script
        return script
    }
}
