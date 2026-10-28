import Foundation
import LiveIslandCore
/// Every Claude and Codex account the user has used here: which one each tool is on, and
/// each one's limits. Claude accounts come from claude-swap when it manages them (it switches
/// them too), merged with what the status line reports; Codex accounts come from ccswap the
/// same way, merged with what Codex's sessions report.
@MainActor
final class AccountsMonitor {
    struct Snapshot: Equatable {
        var accounts: [ClaudeAccount] = []
        var codexAccounts: [ClaudeAccount] = []
        var claudeSwapInstalled = false
        var ccswapInstalled = false
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
    /// claude-swap's accounts, from its controller; nil when it isn't installed.
    var claudeSwap: [ClaudeSwapAccount]? {
        didSet { if claudeSwap != oldValue { refresh() } }
    }
    /// ccswap's Codex accounts, from its controller; nil when it isn't installed.
    var ccswap: [CodexSwapAccount]? {
        didSet { if ccswap != oldValue { refresh() } }
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
        refresh()
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

    func refresh() {
        let input = Worker.Input(claudeSwap: claudeSwap, ccswap: ccswap, limits: latestLimits, notice: latestNotice,
                                 codexLimits: latestCodexLimits)
        queue.async { [weak self, worker] in
            let accounts = worker.tick(input, now: Date())
            DispatchQueue.main.async {
                guard let self else { return }
                var next = self.snapshot
                (next.accounts, next.codexAccounts) = accounts
                next.claudeSwapInstalled = self.claudeSwap != nil
                next.ccswapInstalled = self.ccswap != nil
                self.publish(next)
            }
        }
    }

    /// Shows the outcome of a switch by claude-swap or ccswap, for a moment.
    func announce(_ message: String, isError: Bool) {
        var next = snapshot
        (next.message, next.messageIsError) = (message, isError)
        publish(next)
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self, self.snapshot.message == message else { return }
            var cleared = self.snapshot
            cleared.message = nil
            self.publish(cleared)
        }
    }

    /// Forgets an account LiveIsland saw: its row. The active account stays listed.
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
        var claudeSwap: [ClaudeSwapAccount]?
        var ccswap: [CodexSwapAccount]?
        var limits: ClaudeUsageLimits?
        var notice: ClaudeLimitNotice?
        var codexLimits: CodexLimits?
    }

    private var book: AccountBook
    private var codexBook: AccountBook
    private var codexAuthModified: Date?
    private var recordedCodexLimits: Date?
    private var configModified: Date?
    private var recordedLimits: Date?

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
        followCodex(now: now)
        if let limits = input.codexLimits, limits.observedAt != recordedCodexLimits,
           codexBook.record(limits.usageLimits, sessionStartedAt: started(limits.session)) {
            recordedCodexLimits = limits.observedAt
        }
        if codexBook != codexBefore { save(codexBook, as: "codex") }
        followActiveAccount(now: now)
        // A report that can't be placed yet is tried again on every tick: its reset times may
        // become known, or it may be repeated by a newer session.
        if let limits = input.limits, limits.observedAt != recordedLimits,
           book.record(limits, sessionStartedAt: started(limits.session)) {
            recordedLimits = limits.observedAt
        }
        if let notice = input.notice, notice.isLimitReached {
            book.record(notice, sessionStartedAt: started(notice.session))
        }
        if book != before { save(book, as: "claude") }
        let managed = input.claudeSwap.flatMap { $0.isEmpty ? nil : $0 }
        return (ClaudeAccounts.merge(book: book, claudeSwap: managed, switcher: managed == nil ? nil : .claudeSwap, now: now),
                CodexAccounts.merge(book: codexBook, ccswap: input.ccswap, now: now))
    }

    func forget(_ account: ClaudeAccount) {
        let key = account.identity.key
        if account.kind == .codex {
            codexBook.remove(key)
            save(codexBook, as: "codex")
        } else {
            book.remove(key)
            save(book, as: "claude")
        }
    }

    /// Notes the account Codex is logged in to, when its login file changes.
    private func followCodex(now: Date) {
        let modified = (try? CodexLogins.authURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        guard modified != codexAuthModified else { return }
        codexAuthModified = modified
        if let active = CodexLogins.active() { codexBook.setActive(active.identity, at: now) }
    }

    /// Reads ~/.claude.json only when it changed: it's Claude Code's, and it can be large.
    private func followActiveAccount(now: Date) {
        let modified = (try? ClaudeLogins.configURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        guard modified != configModified else { return }
        configModified = modified
        if let active = ClaudeLogins.active() { book.setActive(active.identity, at: now) }
    }

    private func save(_ book: AccountBook, as name: String) {
        let url = Self.bookURL(name)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(book) { try? data.write(to: url, options: .atomic) }
    }
}
