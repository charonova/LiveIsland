import AppKit
import LiveIslandCore
import SwiftUI

/// Settings › Accounts: claude-swap, run from LiveIsland. Installing and updating it, its
/// automatic switching, every account with its controls, and a console with each command's
/// output and every switch as it happens.
struct ClaudeSwapPage: View {
    @EnvironmentObject private var model: IslandModel

    var body: some View {
        ClaudeSwapPageContent(swap: model.claudeSwap)
    }
}

private struct ClaudeSwapPageContent: View {
    @EnvironmentObject private var navigation: SettingsNavigation
    @ObservedObject var swap: ClaudeSwapController

    var body: some View {
        ScrollViewReader { proxy in
            form
                .onAppear { scroll(proxy) }
                .onChange(of: navigation.anchor) { _, _ in scroll(proxy) }
        }
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        guard navigation.anchor == "console" else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            withAnimation { proxy.scrollTo("console", anchor: .top) }
            navigation.anchor = nil
        }
    }

    private var form: some View {
        Form {
            Section { PageHeader(section: .accounts, detail: "Your Claude accounts, switched by claude-swap: by hand, or on its own before one runs out.") }
            InstallSection(swap: swap)
            if swap.executable != nil {
                AutoSection(swap: swap)
                AccountsSection(swap: swap)
                ConsoleSection(swap: swap).id("console")
                if swap.hasLegacyLogins { LegacySection(swap: swap) }
            }
        }
        .onAppear { swap.isVisible = true }
        .onDisappear { swap.isVisible = false }
    }
}

// MARK: - Install

private struct InstallSection: View {
    @ObservedObject var swap: ClaudeSwapController

    var body: some View {
        Section {
            HStack(spacing: 10) {
                IconBadge(symbol: "arrow.left.arrow.right", tint: .purple, size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(swap.executable == nil ? "claude-swap isn't installed" : "claude-swap \(swap.version ?? "")")
                        .font(.system(size: 13, weight: .semibold))
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                if let busy = swap.busy {
                    ProgressView().controlSize(.small)
                    Text(busy).font(.system(size: 11)).foregroundStyle(.secondary)
                } else if swap.executable == nil {
                    Button("Install") { Task { await swap.install() } }.glassButton(prominent: true)
                } else {
                    if let newer = swap.newerVersion {
                        Button("Update to \(newer)") { Task { await swap.upgrade() } }.glassButton(prominent: true)
                    }
                    Button("Dashboard") { swap.openDashboard() }.help("claude-swap's own dashboard, in Terminal")
                }
            }
            if swap.menuBarServiceInstalled {
                Label("claude-swap's menu bar app is set to start at login. If it switches automatically too, turn that off there, so only one of them switches.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("claude-swap")
        } footer: {
            Text("claude-swap (MIT, github.com/realiti4/claude-swap) keeps each account's login and puts the one in use in place. LiveIsland runs it and shows what it says, and never reads a login itself.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private var detail: String {
        guard swap.executable != nil else { return "Install puts it in place with uv (or pipx), as its README recommends." }
        if let accounts = swap.accounts {
            return accounts.isEmpty ? "No accounts yet: add them below." : "\(accounts.count) account\(accounts.count == 1 ? "" : "s") · up to date unless it says otherwise"
        }
        return "Reading its accounts…"
    }
}

// MARK: - Automatic switching

private struct AutoSection: View {
    @ObservedObject var swap: ClaudeSwapController

    var body: some View {
        Section {
            ToggleRow(symbol: "arrow.triangle.2.circlepath", tint: .green, title: "Switch automatically",
                      detail: "claude-swap checks every account each minute and moves Claude Code to the one with the most room before the account in use runs out. Running sessions follow within about 30 seconds.",
                      isOn: $swap.autoSwitch)
            HStack(spacing: 6) {
                Circle().fill(dot).frame(width: 7, height: 7)
                Text(state).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
            }
            SettingField(swap: swap, key: "autoswitch.threshold", title: "Switch at (5 hours)", unit: "%", placeholder: "90")
            SettingField(swap: swap, key: "autoswitch.weeklyThreshold", title: "Switch at (week)", unit: "%", placeholder: "same")
            SettingField(swap: swap, key: "autoswitch.cooldownSeconds", title: "Wait between switches", unit: "s", placeholder: "300")
            LabeledContent("Pick the account with") {
                Picker("", selection: Binding(get: { swap.setting("autoswitch.strategy")?.value ?? "best" },
                                              set: { value in Task { await swap.setSetting("autoswitch.strategy", value) } })) {
                    Text("The most room").tag("best")
                    Text("The soonest weekly reset").tag("consume-first")
                }
                .labelsHidden()
                .frame(width: 220)
            }
            Text("Anthropic's Consumer Terms forbid “bypassing any of our systems or protective measures”, and Claude Code's limits assume “ordinary, individual usage”. Anthropic doesn't say whether switching your own accounts automatically counts; if it decides it does, it could act on these accounts. Accounts that bill an API key stay out unless you change claude-swap's settings.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("Automatic switching")
        }
    }

    private var state: String {
        switch swap.auto {
        case .off: return "Off. Switch accounts below, or turn it on."
        case .running(let since):
            let last = swap.lastEvent.map { " · \($0.summary)" } ?? ""
            return "On since \(since.formatted(date: .omitted, time: .shortened))\(last)"
        case .restarting(let at, let why): return "\(why): starting again at \(at.formatted(date: .omitted, time: .standard))"
        }
    }

    private var dot: Color {
        switch swap.auto {
        case .off: return .gray
        case .running: return .green
        case .restarting: return .orange
        }
    }
}

/// One of claude-swap's settings, applied when the field is submitted.
private struct SettingField: View {
    @ObservedObject var swap: ClaudeSwapController
    let key: String
    let title: String
    let unit: String
    let placeholder: String

    var body: some View {
        let setting = swap.setting(key)
        let value = setting?.value ?? ""
        LabeledContent(title) {
            HStack(spacing: 8) {
                Text(value.isEmpty ? placeholder : value + unit).monospacedDigit()
                    .foregroundStyle(setting?.isSet == true ? .primary : .secondary)
                if setting?.isSet != true { Text("default").font(.system(size: 10)).foregroundStyle(.tertiary) }
                // A small prompt, so a half-typed value never reaches claude-swap.
                Button("Change…") { edit() }.buttonStyle(.borderless)
            }
        }
    }

    private func edit() {
        let current = swap.setting(key)?.value ?? ""
        guard let value = Prompt.text(title: title, message: "Leave it empty for claude-swap's default (\(placeholder)).", value: current) else { return }
        Task { await swap.setSetting(key, value) }
    }
}

// MARK: - Accounts

private struct AccountsSection: View {
    @ObservedObject var swap: ClaudeSwapController

    var body: some View {
        Section {
            if let accounts = swap.accounts {
                if accounts.isEmpty {
                    Text("claude-swap has no accounts yet. Add the one Claude Code uses now, then the others.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                ForEach(accounts, id: \.number) { account in
                    SwapAccountRow(swap: swap, account: account, count: accounts.count)
                }
            } else {
                HStack { ProgressView().controlSize(.small); Text("Asking claude-swap…").foregroundStyle(.secondary) }
            }
            HStack {
                TextField("Name for another account", text: $swap.newAccountName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { swap.addAccount() }
                Button("Add and Sign In") { swap.addAccount() }
                    .disabled(swap.newAccountName.trimmingCharacters(in: .whitespaces).isEmpty || swap.adding != nil)
            }
            if let adding = swap.adding {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text(adding).font(.system(size: 11)).foregroundStyle(.secondary) }
            }
            HStack {
                Button("Add the Account Claude Code Uses Now") { Task { await swap.addCurrent() } }
                Spacer()
                Button("Switch to the Best One") { Task { await swap.switchToBest() } }
                    .disabled((swap.accounts?.count ?? 0) < 2)
                Button { Task { await swap.refresh() } } label: { Image(systemName: "arrow.clockwise") }.help("Ask claude-swap again")
            }
            .buttonStyle(.borderless)
        } header: {
            Text("Accounts")
        } footer: {
            Text("Add and Sign In opens Claude Code's own sign-in for a new account, in a folder of its own, then adds it to claude-swap. The account Claude Code uses now stays as it is. Don't sign those folders out later: claude-swap holds the same logins, and signing out cancels them.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

private struct SwapAccountRow: View {
    @ObservedObject var swap: ClaudeSwapController
    let account: ClaudeSwapAccount
    let count: Int

    var body: some View {
        HStack(spacing: 10) {
            Text("\(account.number)").font(.system(size: 11, weight: .bold, design: .rounded))
                .frame(width: 22, height: 22).background(Circle().fill(account.isActive ? Color.green.opacity(0.3) : .secondary.opacity(0.15)))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(account.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    if account.isActive { Tag(text: "In use", color: .green) }
                    if account.isDisabled { Tag(text: "Out of rotation", color: .gray) }
                    if account.needsLogin { Tag(text: "Sign in again", color: .red) }
                    if let threshold = account.threshold { Tag(text: "switch at \(Int(threshold))%", color: .purple) }
                }
                if account.alias != nil { Text(account.email).font(.system(size: 11)).foregroundStyle(.secondary) }
                HStack(spacing: 14) {
                    Meter(label: "5 hours", window: account.fiveHour)
                    Meter(label: "Week", window: account.sevenDay)
                }
                if let note = note { Text(note).font(.system(size: 10.5)).foregroundStyle(note.hasPrefix("Couldn't") ? .red : .secondary).lineLimit(2) }
            }
            Spacer(minLength: 6)
            if !account.isActive {
                Button("Switch") { Task { await swap.switchTo(account.number) } }
                    .disabled(swap.busy != nil)
            }
            Menu {
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
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton).fixedSize()
        }
        .padding(.vertical, 2)
    }

    private var note: String? {
        if let error = account.usageError { return "Couldn't read its usage: \(error)" }
        if account.willLastToReset == false, let runsOut = account.projectedExhaustionAt, runsOut > Date() {
            return "At this pace its week runs out \(TaskTime.text(runsOut))"
        }
        return nil
    }
}

private struct Meter: View {
    let label: String
    let window: RateLimitWindow?

    var body: some View {
        let used = window?.usedPercent ?? 0
        let color: Color = used >= 90 ? .red : used >= 70 ? .orange : .green
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(window.map { "\(Int($0.usedPercent.rounded()))%" } ?? "–").font(.system(size: 10, weight: .semibold)).monospacedDigit()
            }
            ProgressView(value: min(used, 100), total: 100).tint(color).controlSize(.mini)
            Text(window?.resetsAt.map { "resets \(TaskTime.short($0))" } ?? " ").font(.system(size: 9.5)).foregroundStyle(.secondary)
        }
        .frame(width: 130)
    }
}

private struct Tag: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text).font(.system(size: 9.5, weight: .bold)).foregroundStyle(color)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.15)))
    }
}

// MARK: - Console

/// Every command LiveIsland ran with its output, and every automatic switch, as text.
private struct ConsoleSection: View {
    @ObservedObject var swap: ClaudeSwapController

    var body: some View {
        Section {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if swap.entries.isEmpty {
                            Text("Commands LiveIsland runs, and what claude-swap answers, show up here.")
                                .foregroundStyle(.white.opacity(0.4))
                        }
                        ForEach(swap.entries) { entry in
                            ConsoleLine(entry: entry).id(entry.id)
                        }
                    }
                    .font(.system(size: 11, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .textSelection(.enabled)
                }
                .frame(height: 280)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(white: 0.07)))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.08)))
                .environment(\.colorScheme, .dark)
                .onChange(of: swap.entries.last?.id) { _, id in
                    guard let id else { return }
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .bottom) }
                }
                .onChange(of: swap.entries.last?.output.count) { _, _ in
                    if let id = swap.entries.last?.id { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
            HStack(spacing: 8) {
                Text("cswap").font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(.purple)
                TextField("", text: $swap.consoleInput, prompt: Text("list · status · config list · threshold 2 85 · auto --once --dry-run"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .onSubmit { Task { await swap.runConsole() } }
                Button("Run") { Task { await swap.runConsole() } }
                    .disabled(swap.consoleInput.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            HStack {
                Toggle("Show every check", isOn: $swap.showChecks).toggleStyle(.checkbox).font(.system(size: 11))
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(swap.entries.map(ConsoleLine.plain).joined(separator: "\n"), forType: .string)
                }
                Button("Clear") { swap.clearConsole() }
            }
            .buttonStyle(.borderless)
        } header: {
            Text("Console")
        } footer: {
            Text("Commands run claude-swap directly, never through a shell. The dashboard and the menu bar app need a terminal: use Dashboard above.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

private struct ConsoleLine: View {
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

// MARK: - Earlier versions

private struct LegacySection: View {
    @ObservedObject var swap: ClaudeSwapController

    var body: some View {
        Section {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Old login copies").font(.system(size: 13, weight: .semibold))
                    Text("Earlier versions of LiveIsland kept a copy of each account's login in your Keychain, under “LiveIsland: Claude login”. claude-swap does the switching now, so they're no longer used.")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Delete…") {
                    if Prompt.confirm(title: "Delete LiveIsland's old login copies?",
                                      message: "This removes only the “LiveIsland: Claude login” items from your Keychain. Claude Code's own login and claude-swap's accounts stay as they are.",
                                      button: "Delete") {
                        Task { await swap.deleteLegacyLogins() }
                    }
                }
            }
        } header: {
            Text("Earlier versions")
        }
    }
}

// MARK: - Prompts

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
