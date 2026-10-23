import Foundation
import LiveIslandCore
import os

private let log = Logger(subsystem: "com.aissam.liveisland", category: "accounts")

/// Every Claude and Codex account the user has used here: which one each tool is on, each
/// one's limits, and switching between them (Claude by LiveIsland itself or through
/// claude-swap; Codex by LiveIsland). It never switches on its own; only `switchTo` does,
/// when the user asks.
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
        var codexAccounts: [ClaudeAccount] = []
        var claudeSwapInstalled = false
        /// The account being switched to right now.
        var switching: String?
        /// The last switch's outcome, for a moment.
        var message: String?
        var messageIsError = false

        var active: ClaudeAccount? { accounts.first(where: \.isActive) }
        var activeCodex: ClaudeAccount? { codexAccounts.first(where: \.isActive) }
    }

    var onUpdate: ((Snapshot) -> Void)?
    private(set) var snapshot = Snapshot()
    var mode: Switching = .off {
        didSet { if mode != oldValue { refresh(forceClaudeSwap: true) } }
    }
    /// Whether LiveIsland keeps Codex logins to switch between them.
    var codexSwitching = false {
        didSet { if codexSwitching != oldValue { refresh() } }
    }

    private let queue = DispatchQueue(label: "com.aissam.liveisland.accounts", qos: .utility)
    private let worker = Worker()
    private var timer: Timer?
    private var latestLimits: ClaudeUsageLimits?
    private var latestNotice: ClaudeLimitNotice?
    private var latestCodexLimits: CodexLimits?
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
    func observe(limits: ClaudeUsageLimits?, notice: ClaudeLimitNotice?, codexLimits: CodexLimits?) {
        latestLimits = limits
        latestNotice = notice
        latestCodexLimits = codexLimits
    }

    func refresh(forceClaudeSwap: Bool = false) {
        let input = Worker.Input(mode: mode, codexSwitching: codexSwitching, limits: latestLimits, notice: latestNotice,
                                 codexLimits: latestCodexLimits, claudeSwapInterval: forceClaudeSwap ? 0 : (isVisible ? 60 : 300))
        queue.async { [weak self, worker] in
            let accounts = worker.tick(input, now: Date())
            DispatchQueue.main.async {
                guard let self else { return }
                var next = self.snapshot
                (next.accounts, next.codexAccounts) = accounts
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
        let input = Worker.Input(mode: mode, codexSwitching: codexSwitching, claudeSwapInterval: 0)
        queue.async { [weak self, worker] in
            let result: Result<String, Error>
            do {
                switch switcher {
                case .liveIsland where account.kind == .codex:
                    let identity = try CodexLogins.switchTo(account.identity.key)
                    result = .success("Codex now on \(identity.email)")
                case .liveIsland:
                    let identity = try ClaudeLogins.switchTo(account.identity.key)
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
            let accounts = worker.tick(input, now: Date())
            DispatchQueue.main.async {
                guard let self else { return }
                var next = self.snapshot
                (next.accounts, next.codexAccounts) = accounts
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
            worker.forget(account)
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
        var codexSwitching: Bool
        var limits: ClaudeUsageLimits?
        var notice: ClaudeLimitNotice?
        var codexLimits: CodexLimits?
        /// How long claude-swap's list stays fresh; 0 asks again now.
        var claudeSwapInterval: TimeInterval
    }

    private var book: AccountBook
    private var codexBook: AccountBook
    private var codexAuthModified: Date?
    private var recordedCodexLimits: Date?
    private var wasSavingCodex = false
    private var configModified: Date?
    private var loginModified: Date?
    private var lastLoginCheck = Date.distantPast
    private var recordedLimits: Date?
    private var claudeSwap: [ClaudeSwapAccount]?
    private var claudeSwapFetched = Date.distantPast

    private static func bookURL(_ name: String) -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("LiveIsland/\(name)-accounts.json")
    }

    private static func loadBook(_ name: String) -> AccountBook {
        var book = (try? Data(contentsOf: bookURL(name))).flatMap { try? JSONDecoder().decode(AccountBook.self, from: $0) } ?? AccountBook()
        // Earlier versions could file one account's numbers under another after a switch.
        book.migrate(now: Date())
        book.removeDuplicateReadings()
        return book
    }

    init() {
        book = Self.loadBook("claude")
        codexBook = Self.loadBook("codex")
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

    func tick(_ input: Input, now: Date) -> (claude: [ClaudeAccount], codex: [ClaudeAccount]) {
        let before = book, codexBefore = codexBook
        followCodex(saving: input.codexSwitching, now: now)
        if let limits = input.codexLimits, limits.observedAt != recordedCodexLimits,
           codexBook.record(limits.usageLimits, sessionStartedAt: started(limits.session)) {
            recordedCodexLimits = limits.observedAt
        }
        if codexBook != codexBefore { save(codexBook, as: "codex") }
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
        if book != before { save(book, as: "claude") }
        return (ClaudeAccounts.merge(book: book, claudeSwap: claudeSwap, switcher: input.mode.switcher, now: now),
                CodexAccounts.list(book: codexBook, switching: input.codexSwitching, now: now))
    }

    func forget(_ account: ClaudeAccount) {
        let key = account.identity.key
        if account.kind == .codex {
            CodexLogins.forget(key)
            codexBook.remove(key)
            save(codexBook, as: "codex")
        } else {
            ClaudeLogins.forget(key)
            book.remove(key)
            save(book, as: "claude")
        }
    }

    /// Codex writes its whole login to one file at once, so the account named in it is always
    /// the login's own: it can be saved as soon as it changes.
    private func followCodex(saving: Bool, now: Date) {
        let modified = (try? CodexLogins.authURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        // Turning switching on saves the login already in place, too.
        let justTurnedOn = saving && !wasSavingCodex
        wasSavingCodex = saving
        guard modified != codexAuthModified || justTurnedOn else { return }
        guard let active = CodexLogins.active() else {
            codexAuthModified = modified
            return
        }
        codexBook.setActive(active.identity, at: now)
        guard saving else {
            codexAuthModified = modified
            return
        }
        do {
            _ = try CodexLogins.saveActive()
            codexBook.entries[active.identity.key]?.hasSavedLogin = true
            codexAuthModified = modified
        } catch {
            log.error("Couldn't save the Codex login: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Reads ~/.claude.json only when it changed: it's Claude Code's, and it can be large.
    private func followActiveAccount(now: Date) {
        let modified = (try? ClaudeLogins.configURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        guard modified != configModified else { return }
        configModified = modified
        if let active = ClaudeLogins.active() { book.setActive(active.identity, at: now) }
    }

    /// Re-saves the active account's login whenever Claude Code changed it (a refresh, a
    /// /login). A /login writes the Keychain first and ~/.claude.json a moment later, so the
    /// login is saved under the account the config names only once the config was written
    /// after it, or after a minute without changes (a refresh keeps the same account).
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

    private func save(_ book: AccountBook, as name: String) {
        let url = Self.bookURL(name)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(book) { try? data.write(to: url, options: .atomic) }
    }
}
