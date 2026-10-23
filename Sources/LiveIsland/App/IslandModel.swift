import AppKit
import LiveIslandCore
import SwiftUI

enum IslandTab: String, CaseIterable, Identifiable {
    case media = "Media"
    case agents = "Agents"
    case activity = "Activity"
    case accounts = "Accounts"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .media: return "music.note"
        case .agents: return "sparkles"
        case .activity: return "square.grid.2x2.fill"
        case .accounts: return "person.2.fill"
        }
    }
}

/// A track that played earlier, to play again with a tap.
struct PlayedTrack: Identifiable {
    var title: String
    var artist: String
    var bundleIdentifier: String
    var trackID: String
    var image: NSImage?
    var id: String { bundleIdentifier + "|" + trackID }
}

/// A track's artwork, decoded once, with the color the island tints itself with.
struct ArtworkLook {
    let image: NSImage
    let accent: Color
}

/// Everything the island knows, and what it should show right now.
@MainActor
final class IslandModel: ObservableObject {
    // Live data
    /// The app the system's media controls point at (any app: browsers, Music, Spotify, …).
    @Published private(set) var systemPlayer: NowPlaying? {
        didSet { levels.isPlaying = players.contains(where: \.isPlaying) }
    }
    /// Spotify and Music, read directly, so they show even when another app has the controls.
    @Published private(set) var scriptedPlayers: [NowPlaying] = [] {
        didSet { levels.isPlaying = players.contains(where: \.isPlaying) }
    }
    /// The player picked in the island; nil follows whatever is playing.
    @Published var selectedPlayerID: String?
    @Published private(set) var output: OutputVolume.State?
    /// Spotify and Music tracks played since launch, newest first.
    @Published private(set) var history: [PlayedTrack] = []
    /// What Music plays next, per player.
    @Published private(set) var upNext: [String: [ScriptedPlayers.QueueItem]] = [:]
    @Published private(set) var agents = AgentMonitor.Snapshot()
    @Published private(set) var system = SystemMonitor.Snapshot()
    @Published private(set) var events: [CalendarProvider.Event] = []
    @Published private(set) var timer: CountdownTimer?
    @Published private(set) var timerFinished = false
    @Published private(set) var transient: IslandActivity?
    /// Bumped every 30 s so time-based activities ("starts in 8m") stay current.
    @Published private(set) var clock = Date()

    // Island state (lives here: SwiftUI's @State needs Xcode's plugins to build)
    @Published private(set) var isExpanded = false
    @Published private(set) var isHovering = false
    @Published var tab: IslandTab = .media {
        didSet { accountsMonitor.isVisible = isExpanded && tab == .accounts }
    }
    /// Claude and Codex accounts and their limits.
    @Published private(set) var accountsState = AccountsMonitor.Snapshot()
    /// Which accounts the Accounts page lists.
    @Published var accountsKind: AgentKind = .claude
    /// The session row the pointer is over, for its actions.
    @Published var hoveredSession: String?
    /// Where the pointer is dragging the progress bar, 0…1.
    @Published var scrubbing: Double?
    @Published var copiedSession: String?
    /// Why adding the lines to Claude Code's status line didn't work, if it didn't.
    @Published private(set) var statusLineNote: String?

    // Settings
    @Published var showMedia: Bool { didSet { save(showMedia, Key.media) } }
    @Published var showAgents: Bool { didSet { save(showAgents, Key.agents) } }
    @Published var showCalls: Bool { didSet { save(showCalls, Key.calls) } }
    @Published var showDevices: Bool { didSet { save(showDevices, Key.devices) } }
    @Published var showCalendar: Bool { didSet { save(showCalendar, Key.calendar) } }
    @Published var showClaude: Bool { didSet { save(showClaude, Key.claude) } }
    @Published var showCodex: Bool { didSet { save(showCodex, Key.codex) } }
    @Published var expandOnHover: Bool { didSet { save(expandOnHover, Key.hover) } }
    @Published var hoverDelay: Double { didSet { defaults.set(hoverDelay, forKey: Key.hoverDelay) } }
    @Published var ambientGlow: Bool { didSet { save(ambientGlow, Key.glow) } }
    @Published var agentSounds: Bool { didSet { save(agentSounds, Key.sounds) } }
    /// Bars that move with the real sound, instead of the animated symbol.
    @Published var liveWaveform: Bool {
        didSet {
            save(liveWaveform, Key.waveform)
            levels.isEnabled = liveWaveform
        }
    }
    /// How LiveIsland switches Claude accounts, if at all. Off until the user picks one.
    @Published var accountSwitching: AccountsMonitor.Switching {
        didSet {
            defaults.set(accountSwitching.rawValue, forKey: Key.switching)
            accountsMonitor.mode = accountSwitching
        }
    }
    /// Whether LiveIsland keeps Codex logins to switch between them. Off until turned on.
    @Published var codexSwitching: Bool {
        didSet {
            save(codexSwitching, Key.codexSwitching)
            accountsMonitor.codexSwitching = codexSwitching
        }
    }
    @Published var controlPlayers: Bool {
        didSet {
            save(controlPlayers, Key.players)
            if controlPlayers { scripted.start() } else { scripted.stop(); scriptedPlayers = [] }
        }
    }
    @Published private(set) var launchAtLogin = LoginItem.isEnabled

    let media = NowPlayingProvider()
    let volume = OutputVolume()
    let levels = AudioLevelMeter()
    private let accountsMonitor = AccountsMonitor()
    private let scripted = ScriptedPlayers()
    private let agentMonitor = AgentMonitor()
    private let systemMonitor = SystemMonitor()
    private let calendar = CalendarProvider()
    private let defaults = UserDefaults.standard
    private var hoverWork: DispatchWorkItem?
    private var timerWork: DispatchWorkItem?
    private var transientWork: DispatchWorkItem?
    private var clockTimer: Timer?
    private var playerRefresh: Timer?
    private var artworkCache: [String: ArtworkLook] = [:]

    init() {
        defaults.register(defaults: [Key.media: true, Key.agents: true, Key.calls: true, Key.devices: true,
                                     Key.calendar: true, Key.claude: true, Key.codex: true, Key.hover: true,
                                     Key.hoverDelay: 0.12, Key.glow: true, Key.sounds: false, Key.players: true,
                                     Key.waveform: true])
        showMedia = defaults.bool(forKey: Key.media)
        showAgents = defaults.bool(forKey: Key.agents)
        showCalls = defaults.bool(forKey: Key.calls)
        showDevices = defaults.bool(forKey: Key.devices)
        showCalendar = defaults.bool(forKey: Key.calendar)
        showClaude = defaults.bool(forKey: Key.claude)
        showCodex = defaults.bool(forKey: Key.codex)
        expandOnHover = defaults.bool(forKey: Key.hover)
        hoverDelay = defaults.double(forKey: Key.hoverDelay)
        ambientGlow = defaults.bool(forKey: Key.glow)
        agentSounds = defaults.bool(forKey: Key.sounds)
        liveWaveform = defaults.bool(forKey: Key.waveform)
        controlPlayers = defaults.bool(forKey: Key.players)
        accountSwitching = defaults.string(forKey: Key.switching).flatMap(AccountsMonitor.Switching.init(rawValue:)) ?? .off
        codexSwitching = defaults.bool(forKey: Key.codexSwitching)
    }

    func start() {
        media.onChange = { [weak self] in self?.systemPlayer = $0 }
        scripted.onChange = { [weak self] in self?.receivePlayers($0) }
        scripted.onQueue = { [weak self] in self?.upNext = $0 }
        volume.onChange = { [weak self] in self?.output = $0 }
        agentMonitor.onUpdate = { [weak self] in self?.receive($0) }
        systemMonitor.onUpdate = { [weak self] in self?.system = $0 }
        systemMonitor.onEvent = { [weak self] in self?.flash($0) }
        calendar.onUpdate = { [weak self] in self?.events = $0 }
        media.start()
        volume.start()
        levels.isEnabled = liveWaveform
        accountsMonitor.onUpdate = { [weak self] in self?.accountsState = $0 }
        accountsMonitor.mode = accountSwitching
        accountsMonitor.codexSwitching = codexSwitching
        accountsMonitor.start()
        if controlPlayers { scripted.start() }
        agentMonitor.start()
        systemMonitor.start()
        calendar.start()
        clockTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.clock = Date() }
        }
    }

    func stop() {
        media.stop()
        volume.stop()
        levels.stop()
        accountsMonitor.stop()
        scripted.stop()
        agentMonitor.stop()
        systemMonitor.stop()
        calendar.stop()
        clockTimer?.invalidate()
        playerRefresh?.invalidate()
    }

    // MARK: - Players

    /// Every player with something loaded: the system's first, then Spotify and Music.
    var players: [NowPlaying] {
        var list = systemPlayer.map { [$0] } ?? []
        for player in scriptedPlayers where player.bundleIdentifier != systemPlayer?.bundleIdentifier {
            list.append(player)
        }
        return list
    }

    /// The player the island shows: the one picked, else the one playing, else the first.
    var nowPlaying: NowPlaying? {
        let list = players
        if let selectedPlayerID, let picked = list.first(where: { $0.bundleIdentifier == selectedPlayerID }) { return picked }
        return list.first(where: \.isPlaying) ?? list.first
    }

    func artwork(for player: NowPlaying?) -> ArtworkLook? {
        guard let player, let data = player.artwork else { return nil }
        let key = "\(player.bundleIdentifier ?? "")|\(player.title)|\(data.count)"
        if let cached = artworkCache[key] { return cached }
        guard let image = NSImage(data: data) else { return nil }
        let look = ArtworkLook(image: image, accent: Color(nsColor: ArtworkPalette.accent(of: image)))
        if artworkCache.count > 12 { artworkCache.removeAll() }
        artworkCache[key] = look
        return look
    }

    var accent: Color {
        artwork(for: nowPlaying)?.accent ?? Color(nsColor: ArtworkPalette.fallback)
    }

    private func routesThroughScript(_ player: NowPlaying) -> Bool {
        player.bundleIdentifier != systemPlayer?.bundleIdentifier && scripted.handles(player.bundleIdentifier)
    }

    /// Notes the track a player moved on from, for Recently Played.
    private func receivePlayers(_ next: [NowPlaying]) {
        for old in scriptedPlayers {
            guard let bundle = old.bundleIdentifier, let trackID = old.trackID,
                  next.first(where: { $0.bundleIdentifier == bundle })?.trackID != trackID
            else { continue }
            let played = PlayedTrack(title: old.title, artist: old.artist, bundleIdentifier: bundle, trackID: trackID,
                                     image: artwork(for: old)?.image)
            history.removeAll { $0.id == played.id }
            history.insert(played, at: 0)
            if history.count > 12 { history.removeLast() }
        }
        scriptedPlayers = next
    }

    /// Players that are installed but have nothing loaded: one tap opens and plays them.
    var idlePlayers: [String] {
        guard controlPlayers else { return [] }
        let loaded = Set(players.compactMap(\.bundleIdentifier))
        return ScriptedPlayers.all.map(\.bundleIdentifier).filter {
            !loaded.contains($0) && NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil
        }
    }

    func launchPlayer(_ bundleIdentifier: String) {
        selectedPlayerID = bundleIdentifier
        scripted.launchAndPlay(bundleIdentifier)
    }

    func play(_ track: PlayedTrack) {
        selectedPlayerID = track.bundleIdentifier
        scripted.play(trackID: track.trackID, in: track.bundleIdentifier)
    }

    func play(_ item: ScriptedPlayers.QueueItem, in bundleIdentifier: String) {
        selectedPlayerID = bundleIdentifier
        scripted.play(trackID: item.trackID, in: bundleIdentifier)
    }

    func togglePlayPause() { control(.togglePlayPause, .playPause) }
    func nextTrack() { control(.nextTrack, .next) }
    func previousTrack() { control(.previousTrack, .previous) }

    private func control(_ system: NowPlayingProvider.Command, _ script: ScriptedPlayers.Command) {
        guard let player = nowPlaying else { return media.send(system) }
        if routesThroughScript(player), let bundle = player.bundleIdentifier {
            // Keep showing this player even as it starts or stops playing.
            selectedPlayerID = bundle
            scripted.send(script, to: bundle)
        } else {
            media.send(system)
        }
    }

    func seek(to seconds: Double) {
        guard let player = nowPlaying else { return }
        if routesThroughScript(player), let bundle = player.bundleIdentifier {
            scripted.seek(bundle, to: seconds)
        } else {
            media.seek(to: seconds)
        }
    }

    func skip(by seconds: Double) {
        guard let player = nowPlaying, let position = player.position(at: Date()) else { return }
        seek(to: min(max(0, position + seconds), player.duration ?? .greatestFiniteMagnitude))
    }

    func openPlayerApp() {
        guard let bundle = nowPlaying?.bundleIdentifier,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        collapse()
    }

    // MARK: - Agents

    /// Sessions of the agents the user wants to see.
    var sessions: [AgentSession] {
        agents.sessions.filter { $0.kind == .claude ? showClaude : showCodex }
    }

    private func receive(_ next: AgentMonitor.Snapshot) {
        if agentSounds {
            let before = Dictionary(agents.sessions.map { ($0.id, $0.state) }, uniquingKeysWith: { first, _ in first })
            for session in next.sessions where before[session.id] == .working {
                if session.state == .waiting { NSSound(named: "Funk")?.play(); break }
                if session.state == .done { NSSound(named: "Glass")?.play(); break }
            }
        }
        agents = next
        accountsMonitor.observe(limits: next.claudeLimits, notice: next.claudeLimit, codexLimits: next.codexLimits)
    }

    // MARK: - Claude accounts

    var accounts: [ClaudeAccount] { accountsState.accounts }
    var codexAccounts: [ClaudeAccount] { accountsState.codexAccounts }

    /// The account in use, when it ran out: by its own numbers, which include the limit Claude
    /// gave when it refused a request. A refusal still pending from the previous account
    /// doesn't count.
    var exhaustedAccount: ClaudeAccount? {
        guard let active = accountsState.active, active.current(at: clock).isAtLimit else { return nil }
        return active
    }

    /// Where to go next: the account with the most room that can be switched to.
    var bestAccount: ClaudeAccount? { ClaudeAccount.best(accounts, at: clock) }

    var exhaustedCodexAccount: ClaudeAccount? {
        guard let active = accountsState.activeCodex, active.current(at: clock).isAtLimit else { return nil }
        return active
    }

    var bestCodexAccount: ClaudeAccount? { ClaudeAccount.best(codexAccounts, at: clock) }

    func switchAccount(_ account: ClaudeAccount) {
        accountsMonitor.switchTo(account)
    }

    func forgetAccount(_ account: ClaudeAccount) {
        accountsMonitor.forget(account)
    }

    func installStatusLine() {
        do {
            _ = try ClaudeStatusLine.install()
            statusLineNote = nil
        } catch {
            statusLineNote = error.localizedDescription
        }
        objectWillChange.send()
    }

    func copyResumeCommand(_ session: AgentSession) {
        guard let command = session.resumeCommand else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        copiedSession = session.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            if self?.copiedSession == session.id { self?.copiedSession = nil }
        }
    }

    /// Brings forward the editor or terminal the session runs in; the folder when it's gone.
    func jump(to session: AgentSession) {
        guard let host = session.host else { return openSession(session) }
        collapse()
        SessionJump.go(to: host, cwd: session.cwd)
    }

    func openSession(_ session: AgentSession) {
        let folder = session.cwd.map { URL(fileURLWithPath: $0) } ?? URL(fileURLWithPath: session.id).deletingLastPathComponent()
        // The synchronous open can wait a second on a sandbox check; this one doesn't hold up the island.
        NSWorkspace.shared.open([folder], withApplicationAt: URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"),
                                configuration: NSWorkspace.OpenConfiguration())
        collapse()
    }

    // MARK: - What to show

    var activities: [IslandActivity] {
        var list: [IslandActivity] = []
        let now = Date()
        if showCalls, let call = system.call { list.append(.call(app: call.app, since: call.since)) }
        if timerFinished { list.append(.timerFinished) }
        if showAgents {
            for session in sessions {
                switch session.state {
                case .waiting: list.append(.agentNeedsYou(session.kind, project: session.project))
                case .done: list.append(.agentDone(session.kind, project: session.project))
                case .working: list.append(.agentWorking(session.kind, project: session.project, since: session.workingSince ?? session.lastActivity))
                case .idle: break
                }
            }
        }
        if showAgents, let exhausted = exhaustedAccount, let best = bestAccount {
            list.append(.accountLimit(account: exhausted.identity.displayName, switchTo: best.identity.displayName))
        }
        if showAgents, let exhausted = exhaustedCodexAccount, let best = bestCodexAccount {
            list.append(.accountLimit(account: "Codex · " + exhausted.identity.email, switchTo: best.identity.email))
        }
        if let transient { list.append(transient) }
        if showCalendar, let event = upcomingEvent(at: now) { list.append(.eventSoon(title: event.title, startsAt: event.start)) }
        if showCalls {
            if system.cameraOn { list.append(.cameraOn(app: nil)) }
            if let app = system.microphoneApps.first { list.append(.microphoneOn(app: app)) }
        }
        if let timer, !timer.isFinished(at: now) { list.append(.timer(endsAt: timer.endsAt)) }
        if showMedia, let player = players.first(where: \.isPlaying) ?? nowPlaying {
            list.append(.nowPlaying(title: player.title, isPlaying: player.isPlaying))
        }
        return list
    }

    var primary: IslandActivity? {
        guard let activity = IslandActivity.mostImportant(activities) else { return nil }
        // Paused music alone isn't worth widening the notch for.
        if case .nowPlaying(_, false) = activity { return nil }
        return activity
    }

    /// Music playing that the island may show beside another activity.
    var musicPlaying: Bool {
        showMedia && players.contains(where: \.isPlaying)
    }

    /// The track the compact island shows: whichever is playing.
    var compactPlayer: NowPlaying? {
        players.first(where: \.isPlaying) ?? nowPlaying
    }

    /// An event starting within 10 minutes, or that started in the last 2.
    func upcomingEvent(at now: Date) -> CalendarProvider.Event? {
        events.first { $0.start.timeIntervalSince(now) < 600 && now.timeIntervalSince($0.start) < 120 }
    }

    // MARK: - Hover and expansion

    func setHovering(_ hovering: Bool) {
        guard hovering != isHovering else { return }
        isHovering = hovering
        hoverWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if hovering, self.expandOnHover { self.expand() } else if !hovering { self.collapse() }
        }
        hoverWork = work
        // Open quickly, close a little later, so passing the mouse by doesn't flicker it.
        DispatchQueue.main.asyncAfter(deadline: .now() + (hovering ? hoverDelay : 0.35), execute: work)
    }

    func toggleExpanded() {
        isExpanded ? collapse() : expand()
    }

    func expand(on requested: IslandTab? = nil) {
        if isExpanded, let requested { tab = requested }
        guard !isExpanded else { return }
        tab = requested ?? suggestedTab
        isExpanded = true
        accountsMonitor.isVisible = tab == .accounts
        if timerFinished { dismissTimerAlert() }
        // Spotify and Music don't say when someone seeks inside them; check while open.
        if controlPlayers {
            scripted.refreshAll()
            playerRefresh = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.tab == .media else { return }
                    self.scripted.refreshAll()
                }
            }
        }
    }

    func collapse() {
        isExpanded = false
        accountsMonitor.isVisible = false
        hoveredSession = nil
        scrubbing = nil
        selectedPlayerID = nil
        playerRefresh?.invalidate()
        playerRefresh = nil
    }

    /// Opens on whatever the island is showing.
    private var suggestedTab: IslandTab {
        switch primary {
        case .agentNeedsYou, .agentDone, .agentWorking: return .agents
        case .accountLimit(let account, _):
            accountsKind = account.hasPrefix("Codex") ? .codex : .claude
            return .accounts
        case .nowPlaying: return .media
        case .call, .timer, .timerFinished, .headphonesConnected, .charging, .eventSoon, .cameraOn, .microphoneOn: return .activity
        case nil: return nowPlaying != nil ? .media : (sessions.isEmpty ? .activity : .agents)
        }
    }

    // MARK: - Timer

    func startTimer(minutes: Double) {
        timer = CountdownTimer(duration: minutes * 60)
        timerFinished = false
        scheduleTimerEnd()
    }

    func toggleTimerPause() {
        guard var current = timer else { return }
        if current.isPaused {
            current.resume(at: Date())
            timer = current
            scheduleTimerEnd()
        } else {
            current.pause(at: Date())
            timer = current
            timerWork?.cancel()
        }
    }

    func cancelTimer() {
        timer = nil
        timerWork?.cancel()
    }

    func dismissTimerAlert() {
        timerFinished = false
    }

    private func scheduleTimerEnd() {
        timerWork?.cancel()
        guard let timer else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, let timer = self.timer, timer.isFinished(at: Date()) else { return }
            self.timer = nil
            self.timerFinished = true
            NSSound(named: "Glass")?.play()
            DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in self?.timerFinished = false }
        }
        timerWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + timer.remaining(at: Date()), execute: work)
    }

    // MARK: - Other actions

    private func flash(_ activity: IslandActivity) {
        guard showDevices else { return }
        transient = activity
        transientWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.transient = nil }
        transientWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        try? LoginItem.setEnabled(enabled)
        launchAtLogin = LoginItem.isEnabled
    }

    func openSettings(_ section: SettingsSection = .general) {
        collapse()
        SettingsWindowController.shared.show(model: self, section: section)
    }

    private func save(_ value: Bool, _ key: String) {
        defaults.set(value, forKey: key)
    }

    private enum Key {
        static let media = "showMedia"
        static let agents = "showAgents"
        static let calls = "showCalls"
        static let devices = "showDevices"
        static let calendar = "showCalendar"
        static let claude = "showClaude"
        static let codex = "showCodex"
        static let hover = "expandOnHover"
        static let hoverDelay = "hoverDelay"
        static let glow = "ambientGlow"
        static let sounds = "agentSounds"
        static let players = "controlPlayers"
        static let waveform = "liveWaveform"
        static let switching = "accountSwitching"
        static let codexSwitching = "codexSwitching"
    }
}
