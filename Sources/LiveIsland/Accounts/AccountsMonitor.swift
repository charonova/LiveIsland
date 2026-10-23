import Foundation
import LiveIslandCore
import os

private let log = Logger(subsystem: "com.aissam.liveisland", category: "accounts")

/// Every Claude account the user has used here: which one Claude Code is on, each one's
/// limits, and switching between them, by LiveIsland itself or through claude-swap. It never
/// switches on its own; only `switchTo` does, when the user asks.
@MainActor
final class AccountsMonitor {
    enum Switching: String, CaseIterable, Identifiable {
        case off
        case liveIsland
        case claudeSwap

        var id: String { rawValue }

        var title: String {
            switch self {
            case .off: return "Off"
            case .liveIsland: return "LiveIsland"
            case .claudeSwap: return "claude-swap"
            }
        }

        var switcher: ClaudeAccount.Switcher? {
            switch self {
            case .off: return nil
            case .liveIsland: return .liveIsland
            case .claudeSwap: return .claudeSwap
            }
        }
    }

    struct Snapshot: Equatable {
        var accounts: [ClaudeAccount] = []
        var claudeSwapInstalled = false
        /// The account being switched to right now.
        var switching: String?
        /// The last switch's outcome, for a moment.
        var message: String?
        var messageIsError = false

        var active: ClaudeAccount? { accounts.first(where: \.isActive) }
    }

    var onUpdate: ((Snapshot) -> Void)?
    private(set) var snapshot = Snapshot()
    var mode: Switching = .off {
        didSet { if mode != oldValue { refresh(forceClaudeSwap: true) } }
    }

    private let queue = DispatchQueue(label: "com.aissam.liveisland.accounts", qos: .utility)
    private let worker = Worker()
    private var timer: Timer?
    private var latestLimits: ClaudeUsageLimits?
    private var latestNotice: ClaudeLimitNotice?
    /// Asked for more often while the Accounts page is open.
    var isVisible = false

    func start() {
        refresh(forceClaudeSwap: true)
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
    }

    /// From the agent monitor: the status line's latest limits, and a limit Claude is
    /// refusing requests for right now.
    func observe(limits: ClaudeUsageLimits?, notice: ClaudeLimitNotice?) {
        latestLimits = limits
        latestNotice = notice
    }

    func refresh(forceClaudeSwap: Bool = false) {
        let input = Worker.Input(mode: mode, limits: latestLimits, notice: latestNotice,
                                 claudeSwapInterval: forceClaudeSwap ? 0 : (isVisible ? 60 : 300))
        queue.async { [weak self, worker] in
            let accounts = worker.tick(input, now: Date())
            DispatchQueue.main.async {
                guard let self else { return }
                var next = self.snapshot
                next.accounts = accounts
                next.claudeSwapInstalled = ClaudeSwapCLI.executable != nil
                self.publish(next)
            }
        }
    }

    func switchTo(_ account: ClaudeAccount) {
        guard snapshot.switching == nil, let switcher = account.switcher else { return }
        var next = snapshot
        next.switching = account.id
        next.message = nil
        publish(next)
        let mode = mode
        queue.async { [weak self, worker] in
            let result: Result<String, Error>
            do {
                switch switcher {
                case .liveIsland:
                    let identity = try ClaudeLogins.switchTo(account.id)
                    result = .success("Now on \(identity.displayName)")
                case .claudeSwap:
                    guard let number = account.claudeSwapNumber else { throw ClaudeSwapCLI.Failure.unreadable }
                    _ = try ClaudeSwapCLI.switchTo(number)
                    result = .success("Now on \(account.identity.displayName)")
                }
            } catch {
                log.error("Switch failed: \(error.localizedDescription, privacy: .public)")
                result = .failure(error)
            }
            let accounts = worker.tick(Worker.Input(mode: mode, limits: nil, notice: nil, claudeSwapInterval: 0), now: Date())
            DispatchQueue.main.async {
                guard let self else { return }
                var next = self.snapshot
                next.accounts = accounts
                next.switching = nil
                switch result {
                case .success(let message): (next.message, next.messageIsError) = (message, false)
                case .failure(let error): (next.message, next.messageIsError) = (error.localizedDescription, true)
                }
                self.publish(next)
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                    guard let self, self.snapshot.message == next.message else { return }
                    var cleared = self.snapshot
                    cleared.message = nil
                    self.publish(cleared)
                }
            }
        }
    }

    /// Forgets an account: its saved login and its row. The active account stays listed.
    func forget(_ account: ClaudeAccount) {
        queue.async { [weak self, worker] in
            worker.forget(account.id)
            DispatchQueue.main.async { self?.refresh() }
        }
    }

    private func publish(_ next: Snapshot) {
        guard next != snapshot else { return }
        snapshot = next
        onUpdate?(next)
    }
}

/// The monitor's state, only ever touched on its queue.
private final class Worker: @unchecked Sendable {
    struct Input {
        var mode: AccountsMonitor.Switching
        var limits: ClaudeUsageLimits?
        var notice: ClaudeLimitNotice?
        /// How long claude-swap's list stays fresh; 0 asks again now.
        var claudeSwapInterval: TimeInterval
    }

    private var book: AccountBook
    private var configModified: Date?
    private var loginModified: Date?
    private var lastLoginCheck = Date.distantPast
    private var recordedLimits: Date?
    private var claudeSwap: [ClaudeSwapAccount]?
    private var claudeSwapFetched = Date.distantPast

    private static var bookURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("LiveIsland/claude-accounts.json")
    }

    init() {
        book = (try? Data(contentsOf: Self.bookURL)).flatMap { try? JSONDecoder().decode(AccountBook.self, from: $0) } ?? AccountBook()
        // Earlier versions could file one account's numbers under another after a switch.
        book.migrate(now: Date())
        book.removeDuplicateReadings()
    }

    private var sessionStarts: [String: Date] = [:]

    /// When a session began: its transcript's creation. A session reads Claude Code's login
    /// when it starts, so this says which login it can be using.
    private func started(_ transcript: String?) -> Date? {
        guard let transcript else { return nil }
        if let known = sessionStarts[transcript] { return known }
        let created = (try? URL(fileURLWithPath: transcript).resourceValues(forKeys: [.creationDateKey]))?.creationDate
        if sessionStarts.count > 200 { sessionStarts.removeAll() }
        sessionStarts[transcript] = created
        return created
    }

    func tick(_ input: Input, now: Date) -> [ClaudeAccount] {
        let before = book
        followActiveAccount(now: now)
        if input.mode == .liveIsland { keepActiveLogin(now: now) }
        // A report that can't be placed yet is tried again on every tick: its reset times may
        // become known, or it may be repeated by a newer session.
        if let limits = input.limits, limits.observedAt != recordedLimits,
           book.record(limits, sessionStartedAt: started(limits.session)) {
            recordedLimits = limits.observedAt
        }
        if let notice = input.notice, notice.isLimitReached {
            book.record(notice, sessionStartedAt: started(notice.session))
        }
        if input.mode == .claudeSwap {
            if now.timeIntervalSince(claudeSwapFetched) >= input.claudeSwapInterval, ClaudeSwapCLI.executable != nil {
                claudeSwapFetched = now
                do {
                    claudeSwap = try ClaudeSwapCLI.list()
                } catch {
                    log.error("claude-swap list failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        } else {
            claudeSwap = nil
        }
        if book != before { save() }
        return ClaudeAccounts.merge(book: book, claudeSwap: claudeSwap, switcher: input.mode.switcher, now: now)
    }

    func forget(_ key: String) {
        ClaudeLogins.forget(key)
        book.remove(key)
        save()
    }

    /// Reads ~/.claude.json only when it changed: it's Claude Code's, and it can be large.
    private func followActiveAccount(now: Date) {
        let modified = (try? ClaudeLogins.configURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        guard modified != configModified else { return }
        configModified = modified
        if let active = ClaudeLogins.active() { book.setActive(active.identity, at: now) }
    }

    /// Re-saves the active account's login whenever Claude Code changed it (a refresh, a
    /// /login), once it has settled for a few seconds.
    private func keepActiveLogin(now: Date) {
        guard now.timeIntervalSince(lastLoginCheck) >= 15 else { return }
        lastLoginCheck = now
        guard let modified = SecurityTool.modified(service: ClaudeLogins.claudeService, account: ClaudeLogins.claudeAccount),
              modified != loginModified, now.timeIntervalSince(modified) > 3,
              now.timeIntervalSince(configModified ?? .distantPast) > 3,
              (configModified ?? .distantPast) >= modified.addingTimeInterval(-1) || now.timeIntervalSince(modified) > 60
        else { return }
        do {
            guard let saved = try ClaudeLogins.saveActive() else { return }
            loginModified = modified
            book.setActive(saved.identity, at: now)
            book.entries[saved.identity.key]?.hasSavedLogin = true
            book.entries[saved.identity.key]?.loginExpiresAt = saved.loginExpires
        } catch {
            log.error("Couldn't save the active login: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func save() {
        let url = Self.bookURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(book) { try? data.write(to: url, options: .atomic) }
    }
}
