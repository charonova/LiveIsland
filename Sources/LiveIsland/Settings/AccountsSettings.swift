import AppKit
import LiveIslandCore
import SwiftUI

/// Settings › Accounts: every Claude Code and Codex account in one place. A switch picks the
/// tool; claude-swap runs the Claude accounts and ccswap the Codex ones. Each has the same
/// three tabs: its accounts as cards, its automatic switching, and a console with every
/// command's output and every switch as it happens.
struct AccountsSettingsPage: View {
    @EnvironmentObject private var model: IslandModel
    @EnvironmentObject private var navigation: SettingsNavigation

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                IconBadge(symbol: SettingsSection.accounts.symbol, tint: SettingsSection.accounts.tint, size: 40)
                    .shadow(color: SettingsSection.accounts.tint.opacity(0.4), radius: 10, y: 4)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Accounts").font(.system(size: 22, weight: .bold))
                    Text("Switched by hand, or before one runs out").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                ProviderSwitch(selection: $navigation.accountsKind,
                               counts: [.claude: model.claudeSwap.accounts?.count ?? model.accounts.count,
                                        .codex: model.codexSwap.accounts?.count ?? model.codexAccounts.count])
            }
            switch navigation.accountsKind {
            case .codex:
                SwapToolPage(tool: model.codexSwap, kind: .codex) {
                    CodexBanners(swap: model.codexSwap)
                } accounts: {
                    CodexCards(swap: model.codexSwap)
                } consoleActions: {
                    EmptyView()
                }
            default:
                SwapToolPage(tool: model.claudeSwap, kind: .claude) {
                    ClaudeBanners(swap: model.claudeSwap)
                } accounts: {
                    ClaudeCards(swap: model.claudeSwap)
                } consoleActions: {
                    Button("Dashboard") { model.claudeSwap.openDashboard() }.help("claude-swap's own dashboard, in Terminal")
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

enum AccountsTab: String, CaseIterable {
    case accounts, automatic, console

    var title: String { rawValue.capitalized }

    var symbol: String {
        switch self {
        case .accounts: return "person.2"
        case .automatic: return "arrow.triangle.2.circlepath"
        case .console: return "terminal"
        }
    }
}

// MARK: - The two tools

/// What the page needs from claude-swap's and ccswap's controllers.
@MainActor
protocol SwapTool: ObservableObject {
    var executable: String? { get }
    var version: String? { get }
    var newerVersion: String? { get }
    var busy: String? { get }
    var auto: ClaudeSwapController.Auto { get }
    var lastEvent: (summary: String, at: Date)? { get }
    var entries: [ClaudeSwapController.Entry] { get }
    var adding: String? { get }
    var autoSwitch: Bool { get set }
    var consoleInput: String { get set }
    var newAccountName: String { get set }
    var showChecks: Bool { get set }
    var isVisible: Bool { get set }
    var accountCount: Int? { get }
    var activeName: String? { get }
    var info: SwapToolInfo { get }
    func install() async
    func upgrade() async
    func refresh() async
    func switchToBest() async
    func addCurrent() async
    func addAccount()
    func runConsole() async
    func clearConsole()
    func setting(_ key: String) -> ClaudeSwapSetting?
    func setSetting(_ key: String, _ value: String) async
}

/// How a tool introduces itself on the page.
struct SwapToolInfo {
    struct Field {
        enum Kind { case number(unit: String, placeholder: String), choice([(value: String, label: String)], fallback: String) }
        let key: String
        let title: String
        let kind: Kind
    }

    let name: String
    let prompt: String
    let tint: Color
    let repository: String
    let pitch: String
    let consoleHint: String
    let autoDetail: String
    let fields: [Field]
    let terms: String
    let addCurrentTitle: String
    let signInHelp: String
}

extension ClaudeSwapController: SwapTool {
    var accountCount: Int? { accounts?.count }
    var activeName: String? { accounts?.first(where: \.isActive)?.name }
    var info: SwapToolInfo {
        SwapToolInfo(
            name: "claude-swap", prompt: "cswap", tint: .purple, repository: "https://github.com/realiti4/claude-swap",
            pitch: "claude-swap keeps each Claude account's login and puts the one in use in place. LiveIsland installs it, runs it and shows what it says; it never reads a login itself.",
            consoleHint: "list · status · config list · threshold 2 85",
            autoDetail: "Every minute, claude-swap checks each account and moves Claude Code to the one with the most room before the one in use runs out. Running sessions follow within about 30 seconds.",
            fields: [
                .init(key: "autoswitch.threshold", title: "Switch at (5 hours)", kind: .number(unit: "%", placeholder: "90")),
                .init(key: "autoswitch.weeklyThreshold", title: "Switch at (week)", kind: .number(unit: "%", placeholder: "same")),
                .init(key: "autoswitch.cooldownSeconds", title: "Wait between switches", kind: .number(unit: "s", placeholder: "300")),
                .init(key: "autoswitch.strategy", title: "Pick the account with",
                      kind: .choice([("best", "The most room"), ("consume-first", "The soonest weekly reset")], fallback: "best")),
            ],
            terms: "Anthropic's Consumer Terms forbid “bypassing any of our systems or protective measures”, and Claude Code's limits assume “ordinary, individual usage”. Anthropic doesn't say whether switching your own accounts automatically counts; if it decides it does, it could act on these accounts. Accounts that bill an API key stay out unless you change claude-swap's settings.",
            addCurrentTitle: "Add the account Claude Code uses now",
            signInHelp: "Opens Claude Code's sign-in in a folder of its own; the account in use stays as it is. Don't sign those folders out later: that cancels claude-swap's login too.")
    }
}

extension CodexSwapController: SwapTool {
    var accountCount: Int? { accounts?.count }
    var activeName: String? { accounts?.first(where: \.isActive)?.email }
    var info: SwapToolInfo {
        SwapToolInfo(
            name: "ccswap", prompt: "ccswap codex", tint: .cyan, repository: "https://github.com/errhythm/ccswap",
            pitch: "ccswap keeps each Codex account's login and puts the one in use in ~/.codex/auth.json. LiveIsland runs only its Codex commands, with its data in LiveIsland's own folder, so claude-swap and your Claude accounts stay as they are.",
            consoleHint: "list · status · usage · switch 2 · auto --once --dry-run",
            autoDetail: "Every minute, ccswap checks each Codex account and moves Codex to the one with the most room before the one in use runs out. Codex reads its login when it starts: restart a running session (codex resume) to use the new account.",
            fields: [
                .init(key: "autoswitch.threshold", title: "Switch at", kind: .number(unit: "%", placeholder: "90")),
                .init(key: "autoswitch.intervalSeconds", title: "Check every", kind: .number(unit: "s", placeholder: "60")),
                .init(key: "autoswitch.cooldownSeconds", title: "Wait between switches", kind: .number(unit: "s", placeholder: "300")),
            ],
            terms: "OpenAI's terms don't say whether switching your own accounts automatically is allowed; if OpenAI decides it isn't, it could act on these accounts. These settings are ccswap's own, apart from claude-swap's.",
            addCurrentTitle: "Add the account Codex uses now",
            signInHelp: "Opens codex login in a folder of its own, adds the account to ccswap, then deletes the folder; the account in use stays as it is. Avoid codex logout on these accounts: it cancels the login.")
    }
}

// MARK: - One tool's page

private struct SwapToolPage<Tool: SwapTool, Banners: View, Accounts: View, ConsoleActions: View>: View {
    @EnvironmentObject private var navigation: SettingsNavigation
    @ObservedObject var tool: Tool
    let kind: AgentKind
    @ViewBuilder var banners: Banners
    @ViewBuilder var accounts: Accounts
    @ViewBuilder var consoleActions: ConsoleActions

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            StatusCard(tool: tool, kind: kind)
            if tool.executable != nil {
                TabStrip(selection: $navigation.accountsTab, tint: tool.info.tint, running: isRunning)
                switch navigation.accountsTab {
                case .accounts:
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            banners
                            // One column in a normal window, more when it's wide.
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 400), spacing: 10, alignment: .top)], spacing: 10) {
                                accounts
                                AddAccountCard(tool: tool)
                            }
                        }
                        .padding(.bottom, 8)
                    }
                    .scrollIndicators(.automatic)

                case .automatic:
                    AutomaticTab(tool: tool)
                case .console:
                    ConsoleTab(tool: tool) { consoleActions }
                }
            } else {
                SetUpCard(tool: tool, kind: kind)
                Spacer(minLength: 0)
            }
        }
        .onAppear { tool.isVisible = true }
        .onDisappear { tool.isVisible = false }
    }

    private var isRunning: Bool {
        if case .running = tool.auto { return true }
        return false
    }
}

/// The tool, its version and its automatic switching, at a glance.
private struct StatusCard<Tool: SwapTool>: View {
    @EnvironmentObject private var navigation: SettingsNavigation
    @ObservedObject var tool: Tool
    let kind: AgentKind

    var body: some View {
        let info = tool.info
        HStack(spacing: 14) {
            AgentAvatar(kind: kind, state: .idle, size: 42)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(info.name).font(.system(size: 15, weight: .bold))
                    if let version = tool.version { Tag(text: version, color: .secondary) }
                    if let newer = tool.newerVersion, tool.busy == nil { Tag(text: "\(newer) available", color: .orange) }
                }
                Text(summary).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 10)
            if let busy = tool.busy {
                ProgressView().controlSize(.small)
                Text(busy).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            } else if tool.executable == nil {
                Button("Install") { Task { await tool.install() } }.glassButton(prominent: true)
            } else {
                if let newer = tool.newerVersion {
                    Button("Update to \(newer)") { Task { await tool.upgrade() } }.glassButton()
                }
                AutoPill(tool: tool)
                SwiftUI.Menu {
                    // Runs the update whether or not a newer version was announced: it says
                    // in the console what it found.
                    Button("Check for Updates") {
                        navigation.accountsTab = .console
                        Task { await tool.upgrade() }
                    }
                    if let url = URL(string: tool.info.repository) {
                        Button("\(tool.info.name) on GitHub") { NSWorkspace.shared.open(url) }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.system(size: 15))
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Update \(tool.info.name), or open its page")
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(LinearGradient(colors: [info.tint.opacity(0.22), info.tint.opacity(0.05)], startPoint: .topLeading, endPoint: .bottomTrailing))
        )
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(info.tint.opacity(0.25)))
    }

    private var summary: String {
        guard tool.executable != nil else { return "Not installed yet" }
        let count = tool.accountCount.map { "\($0) account\($0 == 1 ? "" : "s")" } ?? "Reading accounts…"
        let active = tool.activeName.map { " · on \($0)" } ?? ""
        let auto: String
        switch tool.auto {
        case .off: auto = ""
        case .running: auto = tool.lastEvent.map { "\n\($0.summary)" } ?? "\nAutomatic switching is on"
        case .restarting(let at, let why): auto = "\n\(why), again at \(at.formatted(date: .omitted, time: .shortened))"
        }
        return count + active + auto
    }
}

/// Automatic switching, on or off, with a live dot.
private struct AutoPill<Tool: SwapTool>: View {
    @ObservedObject var tool: Tool

    var body: some View {
        Button { tool.autoSwitch.toggle() } label: {
            HStack(spacing: 6) {
                Circle().fill(dot).frame(width: 7, height: 7)
                    .shadow(color: dot.opacity(0.8), radius: tool.autoSwitch ? 3 : 0)
                Text(tool.autoSwitch ? "Auto on" : "Auto off").font(.system(size: 11.5, weight: .semibold))
            }
            .padding(.horizontal, 11).frame(height: 26)
            .background(Capsule().fill((tool.autoSwitch ? Color.green : .primary).opacity(tool.autoSwitch ? 0.16 : 0.07)))
            .overlay(Capsule().strokeBorder((tool.autoSwitch ? Color.green : .primary).opacity(0.2)))
            .foregroundStyle(tool.autoSwitch ? Color.green : .secondary)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(tool.autoSwitch ? "\(tool.info.name) switches before an account runs out. Click to turn off." : "Let \(tool.info.name) switch before an account runs out")
    }

    private var dot: Color {
        switch tool.auto {
        case .off: return .gray
        case .running: return .green
        case .restarting: return .orange
        }
    }
}

/// Before the tool is installed: what it is, and one button.
private struct SetUpCard<Tool: SwapTool>: View {
    @ObservedObject var tool: Tool
    let kind: AgentKind

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.left.arrow.right.circle.fill").font(.system(size: 40)).foregroundStyle(tool.info.tint)
            Text("Switch \(kind.displayName) accounts with \(tool.info.name)").font(.system(size: 15, weight: .semibold))
            Text(tool.info.pitch).font(.system(size: 12)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 420).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button("Install \(tool.info.name)") { Task { await tool.install() } }.glassButton(prominent: true).disabled(tool.busy != nil)
                if let url = URL(string: tool.info.repository) { Link("About it", destination: url).font(.system(size: 12)) }
            }
            Text("Installs with uv (or pipx), as its README recommends. MIT license.").font(.system(size: 10.5)).foregroundStyle(.tertiary)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .modifier(Card())
    }
}

/// Accounts · Automatic · Console.
private struct TabStrip: View {
    @Binding var selection: AccountsTab
    let tint: Color
    let running: Bool

    var body: some View {
        HStack(spacing: 2) {
            ForEach(AccountsTab.allCases, id: \.self) { tab in
                let selected = selection == tab
                Button { selection = tab } label: {
                    HStack(spacing: 6) {
                        Image(systemName: tab.symbol).font(.system(size: 11, weight: .semibold))
                        Text(tab.title).font(.system(size: 12, weight: .semibold))
                        if tab == .automatic && running { Circle().fill(.green).frame(width: 6, height: 6) }
                    }
                    .padding(.horizontal, 12).frame(height: 28)
                    .frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? tint.opacity(0.22) : .clear))
                    .foregroundStyle(selected ? Color.primary : .secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.06)))
    }
}

/// Claude Code | Codex, each with how many accounts it has.
private struct ProviderSwitch: View {
    @Binding var selection: AgentKind
    let counts: [AgentKind: Int]

    var body: some View {
        HStack(spacing: 2) {
            ForEach([AgentKind.claude, .codex], id: \.self) { kind in
                let selected = selection == kind
                Button { selection = kind } label: {
                    HStack(spacing: 6) {
                        AgentGlyph(kind: kind, size: 9).frame(width: 14, height: 14)
                        Text(kind.displayName).font(.system(size: 12, weight: .semibold)).lineLimit(1).fixedSize()
                        Text("\(counts[kind] ?? 0)").font(.system(size: 10.5, weight: .bold, design: .rounded))
                            .padding(.horizontal, 5).frame(height: 16)
                            .background(Capsule().fill(Color.primary.opacity(selected ? 0.12 : 0.06)))
                    }
                    .padding(.horizontal, 10).frame(height: 30)
                    .background(Capsule().fill(selected ? Color(nsColor: .controlBackgroundColor) : .clear)
                        .shadow(color: .black.opacity(selected ? 0.15 : 0), radius: 3, y: 1))
                    .foregroundStyle(selected ? Color.primary : .secondary)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Capsule().fill(Color.primary.opacity(0.07)))
        .fixedSize()
    }
}

// MARK: - Accounts tab

/// One account as a card: who, its two limits, and what can be done with it.
private struct AccountCard<Menu: View>: View {
    let number: Int
    let identity: ClaudeAccountIdentity
    let subtitle: String?
    let tags: [(String, Color)]
    let fiveHour: RateLimitWindow?
    let week: RateLimitWindow?
    let note: (text: String, isProblem: Bool)?
    let isActive: Bool
    let isBest: Bool
    let busy: Bool
    let tint: Color
    let onSwitch: () -> Void
    @ViewBuilder var menu: Menu

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 11) {
                AccountAvatar(identity: identity, size: 36)
                    .overlay(alignment: .bottomTrailing) {
                        Text("\(number)").font(.system(size: 9, weight: .heavy, design: .rounded)).foregroundStyle(.white)
                            .frame(width: 16, height: 16).background(Circle().fill(isActive ? Color.green : .gray))
                            .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                            .offset(x: 4, y: 4)
                    }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(identity.displayName).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        ForEach(Array(tags.enumerated()), id: \.offset) { _, tag in Tag(text: tag.0, color: tag.1) }
                    }
                    if let subtitle { Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer(minLength: 8)
                if isActive {
                    Label("In use", systemImage: "checkmark.circle.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(.green)
                } else {
                    Button(isBest ? "Switch ★" : "Switch", action: onSwitch)
                        .glassButton(prominent: isBest)
                        .disabled(busy)
                        .help(isBest ? "The account with the most room" : "Use this account")
                }
                SwiftUI.Menu { menu } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .frame(width: 22)
            }
            HStack(spacing: 18) {
                UsageBar(label: "5 hours", window: fiveHour)
                UsageBar(label: "Week", window: week)
            }
            if let note {
                Label(note.text, systemImage: note.isProblem ? "exclamationmark.triangle.fill" : "info.circle")
                    .font(.system(size: 10.5)).foregroundStyle(note.isProblem ? Color.orange : .secondary).lineLimit(2)
            }
        }
        .padding(14)
        .modifier(Card(highlight: isActive ? .green : isBest ? .orange : nil))
    }
}

/// A limit as a bar that takes the room it's given.
struct UsageBar: View {
    let label: String
    let window: RateLimitWindow?

    var body: some View {
        let used = window.map { min(max($0.usedPercent, 0), 100) }
        let color: Color = (used ?? 0) >= 90 ? .red : (used ?? 0) >= 70 ? .orange : .green
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
                Spacer(minLength: 6)
                Text(used.map { "\(Int($0.rounded()))%" } ?? "–").font(.system(size: 11, weight: .bold, design: .rounded)).monospacedDigit()
            }
            Capsule().fill(Color.primary.opacity(0.09)).frame(height: 5)
                .overlay(alignment: .leading) {
                    GeometryReader { proxy in
                        Capsule().fill(color.gradient).frame(width: proxy.size.width * CGFloat((used ?? 0) / 100))
                    }
                }
            Text(window?.resetsAt.map { "resets \(TaskTime.short($0))" } ?? (used == nil ? "not read yet" : " "))
                .font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct AddAccountCard<Tool: SwapTool>: View {
    @ObservedObject var tool: Tool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Add an account", systemImage: "person.crop.circle.badge.plus").font(.system(size: 13, weight: .semibold))
            HStack(spacing: 8) {
                TextField("", text: $tool.newAccountName, prompt: Text("A name for it, like Work"))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { tool.addAccount() }
                Button("Sign In…") { tool.addAccount() }
                    .glassButton(prominent: true)
                    .disabled(tool.newAccountName.trimmingCharacters(in: .whitespaces).isEmpty || tool.adding != nil)
            }
            if let adding = tool.adding {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text(adding).font(.system(size: 11)).foregroundStyle(.secondary) }
            }
            Text(tool.info.signInHelp).font(.system(size: 10.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(tool.info.addCurrentTitle) { Task { await tool.addCurrent() } }.buttonStyle(.link).font(.system(size: 11.5))
                Spacer()
                Button { Task { await tool.switchToBest() } } label: { Label("Switch to the best one", systemImage: "star") }
                    .buttonStyle(.borderless).font(.system(size: 11.5))
                    .disabled((tool.accountCount ?? 0) < 2 || tool.busy != nil)
                Button { Task { await tool.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Ask \(tool.info.name) again")
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.14), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
    }
}

/// A heads-up above the accounts, with its buttons.
private struct Banner<Actions: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    let text: String
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).font(.system(size: 15)).foregroundStyle(tint).frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(text).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) { actions }.controlSize(.small)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(tint.opacity(0.1)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(tint.opacity(0.25)))
    }
}

private struct ClaudeBanners: View {
    @ObservedObject var swap: ClaudeSwapController

    var body: some View {
        if swap.menuBarServiceInstalled {
            Banner(symbol: "exclamationmark.triangle.fill", tint: .orange, title: "claude-swap's menu bar app starts at login",
                   text: "If it switches automatically too, turn that off there, so only one of them switches.") { EmptyView() }
        }
        // A stand-in claude-swap (LIVEISLAND_CSWAP) is a test: this Mac's old copies aren't its business.
        if swap.hasLegacyLogins, ProcessInfo.processInfo.environment["LIVEISLAND_CSWAP"] == nil {
            Banner(symbol: "key.fill", tint: .blue, title: "Old login copies in your Keychain",
                   text: "Earlier versions kept a copy of each Claude login under “LiveIsland: Claude login”. claude-swap does the switching now.") {
                Button("Delete…") {
                    if Prompt.confirm(title: "Delete LiveIsland's old login copies?",
                                      message: "This removes only the “LiveIsland: Claude login” items from your Keychain. Claude Code's own login and claude-swap's accounts stay as they are.",
                                      button: "Delete") {
                        Task { await swap.deleteLegacyLogins() }
                    }
                }
            }
        }
    }
}

private struct CodexBanners: View {
    @ObservedObject var swap: CodexSwapController

    var body: some View {
        if swap.legacyLogins > 0, ProcessInfo.processInfo.environment["LIVEISLAND_CCSWAP"] == nil {
            Banner(symbol: "key.fill", tint: .blue, title: "\(swap.legacyLogins) saved Codex login\(swap.legacyLogins == 1 ? "" : "s") from an earlier version",
                   text: "ccswap does the switching now: add them to it, then delete LiveIsland's copies.") {
                Button("Add to ccswap") { Task { await swap.importLegacyLogins() } }.disabled(swap.busy != nil)
                Button("Delete…") {
                    if Prompt.confirm(title: "Delete LiveIsland's saved Codex logins?",
                                      message: "This removes only LiveIsland's own copies. Codex's login and ccswap's accounts stay as they are.",
                                      button: "Delete") {
                        swap.deleteLegacyLogins()
                    }
                }
            }
        }
    }
}

private struct ClaudeCards: View {
    @EnvironmentObject private var model: IslandModel
    @ObservedObject var swap: ClaudeSwapController

    var body: some View {
        if let accounts = swap.accounts {
            if accounts.isEmpty { EmptyAccounts(text: "claude-swap has no accounts yet. Add the one Claude Code uses now, then the others.") }
            ForEach(accounts, id: \.number) { account in
                AccountCard(number: account.number,
                            identity: ClaudeAccountIdentity(accountUUID: "", email: account.email, name: account.alias),
                            subtitle: account.alias != nil ? account.email : account.organizationName,
                            tags: tags(account), fiveHour: account.fiveHour, week: account.sevenDay, note: note(account),
                            isActive: account.isActive, isBest: model.bestAccount?.claudeSwapNumber == account.number,
                            busy: swap.busy != nil, tint: .purple,
                            onSwitch: { Task { await swap.switchTo(account.number) } }) {
                    menu(account, count: accounts.count)
                }
            }
        } else {
            Loading(text: "Asking claude-swap…")
        }
    }

    private func tags(_ account: ClaudeSwapAccount) -> [(String, Color)] {
        var tags: [(String, Color)] = []
        if account.isDisabled { tags.append(("Out of rotation", .gray)) }
        if account.needsLogin { tags.append(("Sign in again", .red)) }
        if let threshold = account.threshold { tags.append(("at \(Int(threshold))%", .purple)) }
        return tags
    }

    private func note(_ account: ClaudeSwapAccount) -> (String, Bool)? {
        if let error = account.usageError { return ("Couldn't read its usage: \(error)", true) }
        if account.willLastToReset == false, let runsOut = account.projectedExhaustionAt, runsOut > Date() {
            return ("At this pace its week runs out \(TaskTime.text(runsOut))", true)
        }
        return nil
    }

    @ViewBuilder private func menu(_ account: ClaudeSwapAccount, count: Int) -> some View {
        Button(account.isDisabled ? "Back in Automatic Rotation" : "Keep Out of Automatic Rotation") {
            Task { await swap.setEnabled(account.number, account.isDisabled) }
        }
        Button("Rename…") {
            if let name = Prompt.text(title: "Name for account \(account.number)", message: "A short name; leave it empty to show the email.", value: account.alias ?? "") {
                Task { await swap.setAlias(account.number, name) }
            }
        }
        Button("Switch Point…") {
            if let value = Prompt.text(title: "Switch away from account \(account.number) at", message: "Percent of its limit (50–99.9). Empty uses the default.", value: account.threshold.map { String(Int($0)) } ?? "") {
                Task { await swap.setThreshold(account.number, value) }
            }
        }
        Divider()
        Button("Move Up") { Task { await swap.move(account.number, to: account.number - 1) } }.disabled(account.number <= 1)
        Button("Move Down") { Task { await swap.move(account.number, to: account.number + 1) } }.disabled(account.number >= count)
        Divider()
        Button("Remove from claude-swap…", role: .destructive) {
            if Prompt.confirm(title: "Remove account \(account.number) (\(account.email)) from claude-swap?",
                              message: "claude-swap forgets its saved login. You can add it again later.", button: "Remove") {
                Task { await swap.remove(account.number) }
            }
        }
    }
}

private struct CodexCards: View {
    @EnvironmentObject private var model: IslandModel
    @ObservedObject var swap: CodexSwapController

    var body: some View {
        if let accounts = swap.accounts {
            if accounts.isEmpty { EmptyAccounts(text: "ccswap has no Codex accounts yet. Add the one Codex uses now, then the others.") }
            ForEach(accounts, id: \.number) { account in
                let known = model.codexAccounts.first { $0.ccswapNumber == account.number }
                AccountCard(number: account.number,
                            identity: known?.identity ?? ClaudeAccountIdentity(accountUUID: "", email: account.email),
                            subtitle: known?.identity.name != nil ? account.email : nil,
                            tags: tags(account), fiveHour: known?.fiveHour ?? account.fiveHour, week: known?.sevenDay ?? account.weekly,
                            note: note(account), isActive: account.isActive,
                            isBest: model.bestCodexAccount?.ccswapNumber == account.number,
                            busy: swap.busy != nil, tint: .cyan,
                            onSwitch: { Task { await swap.switchTo(account.number) } }) {
                    if let banked = account.bankedResets, banked > 0 {
                        Button("Redeem a Banked Reset (\(banked) left)…") {
                            if Prompt.confirm(title: "Redeem one of \(account.email)'s banked resets?",
                                              message: "OpenAI resets this account's limits now and uses up one of its \(banked) banked resets.", button: "Redeem") {
                                Task { await swap.redeemReset(account.number) }
                            }
                        }
                        Divider()
                    }
                    Button("Remove from ccswap…", role: .destructive) {
                        if Prompt.confirm(title: "Remove Codex account \(account.number) (\(account.email)) from ccswap?",
                                          message: "ccswap forgets its saved login. You can add it again later.", button: "Remove") {
                            Task { await swap.remove(account.number) }
                        }
                    }
                }
            }
        } else {
            Loading(text: "Asking ccswap…")
        }
    }

    private func tags(_ account: CodexSwapAccount) -> [(String, Color)] {
        var tags: [(String, Color)] = []
        if let plan = account.plan { tags.append((plan, .cyan)) }
        if account.authMode == "apikey" { tags.append(("API key", .gray)) }
        if account.isDisabled { tags.append(("Out of rotation", .gray)) }
        if account.needsLogin { tags.append(("Sign in again", .red)) }
        if account.capturePending { tags.append(("Session running", .orange)) }
        return tags
    }

    private func note(_ account: CodexSwapAccount) -> (String, Bool)? {
        if account.needsLogin { return ("Its login stopped working: sign in to it again, then add it.", true) }
        if let error = account.usageError { return ("Couldn't read its usage: \(error)", true) }
        if let banked = account.bankedResets, banked > 0 { return ("\(banked) banked reset\(banked == 1 ? "" : "s") to redeem, from its menu", false) }
        return nil
    }
}

private struct EmptyAccounts: View {
    let text: String

    var body: some View {
        Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity).padding(20).modifier(Card())
    }
}

private struct Loading: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) { ProgressView().controlSize(.small); Text(text).foregroundStyle(.secondary) }
            .frame(maxWidth: .infinity).padding(20).modifier(Card())
    }
}

// MARK: - Automatic tab

private struct AutomaticTab<Tool: SwapTool>: View {
    @ObservedObject var tool: Tool

    var body: some View {
        let info = tool.info
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle(isOn: $tool.autoSwitch) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Switch automatically").font(.system(size: 13, weight: .semibold))
                            Text(info.autoDetail).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .toggleStyle(.switch)
                    HStack(spacing: 6) {
                        Circle().fill(dot).frame(width: 7, height: 7)
                        Text(state).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .modifier(Card(highlight: tool.autoSwitch ? .green : nil))

                VStack(spacing: 0) {
                    ForEach(Array(info.fields.enumerated()), id: \.offset) { index, field in
                        if index > 0 { Divider().padding(.leading, 14) }
                        FieldRow(tool: tool, field: field)
                    }
                }
                .modifier(Card())

                Label(info.terms, systemImage: "hand.raised")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(.bottom, 8)
        }
    }

    private var state: String {
        switch tool.auto {
        case .off: return "Off. Switch accounts on the Accounts tab, or turn it on."
        case .running(let since):
            return "On since \(since.formatted(date: .omitted, time: .shortened))" + (tool.lastEvent.map { " · \($0.summary)" } ?? "")
        case .restarting(let at, let why): return "\(why): starting again at \(at.formatted(date: .omitted, time: .standard))"
        }
    }

    private var dot: Color {
        switch tool.auto {
        case .off: return .gray
        case .running: return .green
        case .restarting: return .orange
        }
    }
}

/// One of the tool's settings, applied when the prompt is confirmed or the choice is made.
private struct FieldRow<Tool: SwapTool>: View {
    @ObservedObject var tool: Tool
    let field: SwapToolInfo.Field

    var body: some View {
        let setting = tool.setting(field.key)
        HStack {
            Text(field.title).font(.system(size: 12.5))
            Spacer()
            switch field.kind {
            case .number(let unit, let placeholder):
                let value = setting?.value ?? ""
                Text(value.isEmpty ? placeholder : value + unit).monospacedDigit()
                    .foregroundStyle(setting?.isSet == true ? .primary : .secondary)
                if setting?.isSet != true { Text("default").font(.system(size: 10)).foregroundStyle(.tertiary) }
                // A small prompt, so a half-typed value never reaches the tool.
                Button("Change…") {
                    let current = tool.setting(field.key)?.value ?? ""
                    if let value = Prompt.text(title: field.title, message: "Leave it empty for \(tool.info.name)'s default (\(placeholder)).", value: current) {
                        Task { await tool.setSetting(field.key, value) }
                    }
                }
                .buttonStyle(.borderless)
            case .choice(let options, let fallback):
                Picker("", selection: Binding(get: { setting?.value ?? fallback },
                                              set: { value in Task { await tool.setSetting(field.key, value) } })) {
                    ForEach(options, id: \.value) { Text($0.label).tag($0.value) }
                }
                .labelsHidden()
                .fixedSize()
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 40)
    }
}

// MARK: - Console tab

/// Every command LiveIsland ran with its output, and every automatic switch, as text.
private struct ConsoleTab<Tool: SwapTool, Actions: View>: View {
    @ObservedObject var tool: Tool
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Toggle("Show every check", isOn: $tool.showChecks).toggleStyle(.checkbox)
                Spacer()
                actions
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(tool.entries.map(ConsoleLine.plain).joined(separator: "\n"), forType: .string)
                }
                Button("Clear") { tool.clearConsole() }
            }
            .buttonStyle(.borderless)
            .font(.system(size: 11.5))
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            if tool.entries.isEmpty {
                                Text("Commands LiveIsland runs, and what \(tool.info.name) answers, show up here.")
                                    .foregroundStyle(.white.opacity(0.4))
                            }
                            ForEach(tool.entries) { entry in
                                ConsoleLine(entry: entry).id(entry.id)
                            }
                        }
                        .font(.system(size: 11, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .textSelection(.enabled)
                    }
                    .onAppear { if let id = tool.entries.last?.id { proxy.scrollTo(id, anchor: .bottom) } }
                    .onChange(of: tool.entries.last?.id) { _, id in
                        guard let id else { return }
                        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .bottom) }
                    }
                    .onChange(of: tool.entries.last?.output.count) { _, _ in
                        if let id = tool.entries.last?.id { proxy.scrollTo(id, anchor: .bottom) }
                    }
                }
                Divider().overlay(Color.white.opacity(0.06))
                HStack(spacing: 8) {
                    Text(tool.info.prompt).font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(tool.info.tint)
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(.white.opacity(0.35))
                    TextField("", text: $tool.consoleInput, prompt: Text(tool.info.consoleHint).foregroundStyle(.white.opacity(0.3)))
                        .labelsHidden()
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.white)
                        .onSubmit { Task { await tool.runConsole() } }
                    Button("Run") { Task { await tool.runConsole() } }
                        .controlSize(.small)
                        .disabled(tool.consoleInput.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.horizontal, 12)
                .frame(height: 38)
            }
            .frame(maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(white: 0.07)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.08)))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .environment(\.colorScheme, .dark)
            Text("Runs \(tool.info.name) directly, never through a shell.")
                .font(.system(size: 10.5)).foregroundStyle(.tertiary).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct ConsoleLine: View {
    let entry: ClaudeSwapController.Entry

    static func plain(_ entry: ClaudeSwapController.Entry) -> String {
        let time = entry.at.formatted(date: .omitted, time: .standard)
        var text = "[\(time)] \(entry.title)"
        if !entry.output.isEmpty { text += "\n" + entry.output.trimmingCharacters(in: .newlines) }
        if let code = entry.exitCode { text += "\n(exit \(code))" }
        return text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(entry.at.formatted(date: .omitted, time: .standard)).foregroundStyle(.white.opacity(0.35))
                Text(entry.title).foregroundStyle(titleColor).fontWeight(entry.kind == .command ? .semibold : .regular)
                Spacer(minLength: 4)
                if entry.isRunning {
                    ProgressView().controlSize(.mini)
                } else if let code = entry.exitCode {
                    Text(code == 0 ? "ok" : "exit \(code)")
                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(code == 0 ? .green : .red)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill((code == 0 ? Color.green : .red).opacity(0.15)))
                }
            }
            if !entry.output.isEmpty {
                Text(entry.output.trimmingCharacters(in: .newlines))
                    .foregroundStyle(.white.opacity(0.78))
                    .padding(.leading, 66)
            }
        }
    }

    private var titleColor: Color {
        if entry.isError { return .red }
        switch entry.kind {
        case .command: return .purple
        case .event: return entry.event == "switch" ? .green : .white.opacity(0.85)
        case .note: return .orange
        }
    }
}

// MARK: - Small pieces

/// A rounded card, outlined in a color when it stands out.
struct Card: ViewModifier {
    var highlight: Color?

    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(nsColor: .controlBackgroundColor).opacity(0.7)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(highlight.map { $0.opacity(0.45) } ?? Color.primary.opacity(0.08), lineWidth: highlight == nil ? 0.5 : 1))
    }
}

struct Tag: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text).font(.system(size: 9.5, weight: .bold)).foregroundStyle(color)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.15)))
    }
}

/// Small native prompts: SwiftUI's own state needs Xcode's plugins here.
enum Prompt {
    static func text(title: String, message: String, value: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = value
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }

    static func confirm(title: String, message: String, button: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
