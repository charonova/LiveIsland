import AppKit
import LiveIslandCore
import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case general, island, media, agents, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .island: return "Island"
        case .media: return "Media"
        case .agents: return "AI Agents"
        case .about: return "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape.fill"
        case .island: return "capsule.fill"
        case .media: return "music.note"
        case .agents: return "sparkles"
        case .about: return "info"
        }
    }

    var tint: Color {
        switch self {
        case .general: return .gray
        case .island: return .indigo
        case .media: return .pink
        case .agents: return .orange
        case .about: return .blue
        }
    }
}

/// Which page the settings window shows (SwiftUI's @State needs Xcode's plugins here).
final class SettingsNavigation: ObservableObject {
    @Published var section: SettingsSection? = .general
}

/// One settings window, brought forward when asked for again.
@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?
    private let navigation = SettingsNavigation()

    func show(model: IslandModel, section: SettingsSection) {
        navigation.section = section
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 540),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.title = "LiveIsland Settings"
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.toolbarStyle = .unified
            window.isReleasedWhenClosed = false
            window.contentMinSize = NSSize(width: 680, height: 480)
            window.contentView = NSHostingView(rootView: SettingsView().environmentObject(model).environmentObject(navigation))
            window.center()
            window.setFrameAutosaveName("LiveIslandSettings")
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: IslandModel
    @EnvironmentObject private var navigation: SettingsNavigation

    var body: some View {
        NavigationSplitView {
            List(selection: $navigation.section) {
                ForEach(SettingsSection.allCases) { section in
                    Label {
                        Text(section.title)
                    } icon: {
                        IconBadge(symbol: section.symbol, tint: section.tint, size: 22)
                    }
                    .tag(section)
                    .padding(.vertical, 2)
                }
            }
            .safeAreaInset(edge: .top) { SidebarHeader() }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 240)
        } detail: {
            Group {
                switch navigation.section ?? .general {
                case .general: GeneralPage()
                case .island: IslandPage()
                case .media: MediaSettingsPage()
                case .agents: AgentsSettingsPage()
                case .about: AboutPage()
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
        .frame(minWidth: 680, minHeight: 480)
    }
}

private struct SidebarHeader: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 1) {
                Text("LiveIsland").font(.system(size: 15, weight: .bold))
                Text("Your notch, alive").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }
}

/// The big title at the top of each page.
private struct PageHeader: View {
    let section: SettingsSection
    let detail: String

    var body: some View {
        HStack(spacing: 14) {
            IconBadge(symbol: section.symbol, tint: section.tint, size: 44)
                .shadow(color: section.tint.opacity(0.4), radius: 10, y: 4)
            VStack(alignment: .leading, spacing: 3) {
                Text(section.title).font(.system(size: 22, weight: .bold))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
    }
}

/// A toggle row with a colored icon, like System Settings.
private struct ToggleRow: View {
    let symbol: String
    let tint: Color
    let title: String
    var detail: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: 10) {
                IconBadge(symbol: symbol, tint: tint, size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                    if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(.secondary) }
                }
            }
        }
        .toggleStyle(.switch)
    }
}

// MARK: - Pages

private struct GeneralPage: View {
    @EnvironmentObject private var model: IslandModel

    var body: some View {
        Form {
            Section { PageHeader(section: .general, detail: "How the island opens and when LiveIsland starts.") }
            Section("Behavior") {
                ToggleRow(symbol: "cursorarrow.motionlines", tint: .blue, title: "Open on hover",
                          detail: "Point at the notch to open the island. Clicking always works.", isOn: $model.expandOnHover)
                LabeledContent {
                    HStack {
                        Slider(value: $model.hoverDelay, in: 0.05...0.6).frame(width: 180)
                        Text("\(Int(model.hoverDelay * 1000)) ms").monospacedDigit().foregroundStyle(.secondary).frame(width: 52, alignment: .trailing)
                    }
                } label: {
                    HStack(spacing: 10) {
                        IconBadge(symbol: "timer", tint: .teal, size: 26)
                        Text("Hover delay")
                    }
                }
                .disabled(!model.expandOnHover)
                ToggleRow(symbol: "power", tint: .green, title: "Open at login",
                          isOn: Binding(get: { model.launchAtLogin }, set: model.setLaunchAtLogin))
            }
            Section {
                ForEach([("liveisland://open", "Open the island"), ("liveisland://close", "Close it"),
                         ("liveisland://timer/5", "Start a 5-minute timer")], id: \.0) { link, what in
                    LabeledContent(what) {
                        Text(link).font(.system(.body, design: .monospaced)).textSelection(.enabled).foregroundStyle(.secondary)
                    }
                }
                Text("Use these from Shortcuts, Raycast, Alfred or a terminal (`open liveisland://open`).")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } header: {
                Text("Links")
            }
        }
    }
}

private struct IslandPage: View {
    @EnvironmentObject private var model: IslandModel

    var body: some View {
        Form {
            Section {
                PageHeader(section: .island, detail: "Choose what the island shows. The most important thing wins the notch.")
                IslandPreview().frame(maxWidth: .infinity).padding(.vertical, 8)
            }
            Section("Show in the island") {
                ToggleRow(symbol: "music.note", tint: .pink, title: "Now Playing", detail: "Artwork, waveform and controls", isOn: $model.showMedia)
                ToggleRow(symbol: "sparkles", tint: .orange, title: "AI Agents", detail: "Claude Code and Codex at work", isOn: $model.showAgents)
                ToggleRow(symbol: "phone.fill", tint: .green, title: "Calls, Microphone & Camera", detail: "FaceTime, Zoom, Teams and more", isOn: $model.showCalls)
                ToggleRow(symbol: "airpodspro", tint: .blue, title: "AirPods & Charging", detail: "Battery levels when they connect", isOn: $model.showDevices)
                ToggleRow(symbol: "calendar", tint: .red, title: "Calendar", detail: "Events starting within 10 minutes", isOn: $model.showCalendar)
            }
            Section("Look") {
                ToggleRow(symbol: "sun.max.fill", tint: .purple, title: "Background glow",
                          detail: "Color the open island: the cover's colors on Media, the agents' on Agents", isOn: $model.ambientGlow)
            }
        }
    }
}

/// A small, still picture of the island, so the page shows what it changes.
private struct IslandPreview: View {
    var body: some View {
        HStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(LinearGradient(colors: [.pink, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 22, height: 22)
                .overlay(Image(systemName: "music.note").font(.system(size: 10, weight: .bold)).foregroundStyle(.white))
            Spacer()
            HStack(spacing: 6) {
                AgentGlyph(kind: .claude, size: 11)
                Image(systemName: "waveform").font(.system(size: 14, weight: .bold)).foregroundStyle(.pink)
            }
        }
        .padding(.horizontal, 12)
        .frame(width: 300, height: 36)
        .background(IslandShape(bottomRadius: 14, topRadius: 6).fill(.black))
        .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
    }
}

private struct MediaSettingsPage: View {
    @EnvironmentObject private var model: IslandModel

    var body: some View {
        Form {
            Section { PageHeader(section: .media, detail: "Any app that plays audio or video shows up, with controls.") }
            Section {
                ToggleRow(symbol: "play.circle.fill", tint: .green, title: "Spotify and Music, always",
                          detail: "Read them directly, so a paused Spotify stays one tap away while a video plays elsewhere",
                          isOn: $model.controlPlayers)
                Text("macOS asks once for permission to talk to each app. LiveIsland never opens them on its own.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } header: {
                Text("Players")
            }
            Section("Playing now") {
                if model.players.isEmpty {
                    Text("Nothing is playing").foregroundStyle(.secondary)
                }
                ForEach(model.players, id: \.bundleIdentifier) { player in
                    HStack(spacing: 10) {
                        Artwork(image: model.artwork(for: player)?.image, size: 34, corner: 8)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(player.title).lineLimit(1)
                            Text([AppInfo.name(player.bundleIdentifier), player.artist.isEmpty ? nil : player.artist]
                                .compactMap { $0 }.joined(separator: " · "))
                                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Text(player.isPlaying ? "Playing" : "Paused").font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(player.isPlaying ? .green : .secondary)
                    }
                }
            }
            if let output = model.output {
                Section("Sound output") {
                    LabeledContent {
                        HStack {
                            Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                            Slider(value: Binding(get: { Double(output.volume) }, set: { model.volume.setVolume(Float($0)) }))
                                .frame(width: 200)
                                .disabled(!output.canSetVolume)
                            Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                        }
                    } label: {
                        HStack(spacing: 10) {
                            IconBadge(symbol: output.isBluetooth ? HeadphoneSymbol.name(for: output.device) : "hifispeaker.fill", tint: .blue, size: 26)
                            Text(output.device)
                        }
                    }
                }
            }
        }
    }
}

private struct AgentsSettingsPage: View {
    @EnvironmentObject private var model: IslandModel

    var body: some View {
        Form {
            Section { PageHeader(section: .agents, detail: "Follow coding agents from the notch: who's working, who needs you, and how much is left.") }
            Section("Agents") {
                agentToggle(.claude, detail: "Sessions from ~/.claude/projects", isOn: $model.showClaude)
                agentToggle(.codex, detail: "Sessions from ~/.codex/sessions", isOn: $model.showCodex)
                ToggleRow(symbol: "speaker.wave.2.fill", tint: .pink, title: "Play a sound",
                          detail: "When an agent finishes, or stops to ask you something", isOn: $model.agentSounds)
            }
            AccountsSettingsSection()
            Section {
                if let limits = model.agents.claudeLimits {
                    ForEach(limits.windows, id: \.windowMinutes) { window in
                        LabeledContent(window.windowMinutes == 300 ? "5-hour limit" : "Weekly limit") {
                            HStack(spacing: 8) {
                                ProgressView(value: min(window.usedPercent, 100), total: 100).frame(width: 140)
                                Text("\(Int(window.usedPercent.rounded()))%").monospacedDigit().frame(width: 40, alignment: .trailing)
                            }
                        }
                    }
                    LabeledContent("Updated") {
                        Text(limits.observedAt, format: .relative(presentation: .named)).foregroundStyle(.secondary)
                    }
                } else if ClaudeStatusLine.isInstalled {
                    Label("Added to your status line. The numbers appear after Claude Code's next reply.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Claude Code shares its 5-hour and weekly percentages only with its status line. LiveIsland can add three lines to your status line script that pass them on; your script keeps working as before, and a copy of it is saved first.")
                            .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 10) {
                            Button("Add to My Status Line") { model.installStatusLine() }.glassButton(prominent: true)
                            Button("Copy the Lines") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(ClaudeStatusLine.block, forType: .string)
                            }
                            .glassButton()
                        }
                        if let note = model.statusLineNote {
                            Text(note).font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                        }
                        Text("They go inside the status line script, after it reads its input. Typed into a terminal they do nothing: there's no input there.")
                            .font(.system(size: 11)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 4)
                }
                Text("Several accounts? The numbers follow whichever one Claude Code used last.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } header: {
                Text("Claude Code limits")
            }
            if let usage = model.agents.usage {
                Section("Claude Code tokens") {
                    LabeledContent("This 5-hour window", value: "\(Format.tokens(usage.windowTokens)) · \(usage.windowRequests) replies")
                    LabeledContent("Today", value: "\(Format.tokens(usage.todayTokens)) · \(usage.todayRequests) replies")
                }
            }
        }
    }

    private func agentToggle(_ kind: AgentKind, detail: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            HStack(spacing: 10) {
                AgentAvatar(kind: kind, state: .idle, size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(kind.displayName)
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
        .toggleStyle(.switch)
    }
}

private struct AboutPage: View {
    @EnvironmentObject private var model: IslandModel

    var body: some View {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        VStack(spacing: 14) {
            Spacer()
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 128, height: 128)
                .shadow(color: .purple.opacity(0.35), radius: 24, y: 10)
            VStack(spacing: 4) {
                Text("LiveIsland").font(.system(size: 30, weight: .bold))
                Text("Version \(version)").foregroundStyle(.secondary)
            }
            Text("Now playing, AI agents, calls, AirPods, timers and your calendar, living in the notch.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 380)
            HStack(spacing: 10) {
                Button("Open the Island") { model.expand() }.glassButton(prominent: true)
                Button("Island Settings") { model.openSettings(.island) }.glassButton()
            }
            .controlSize(.large)
            Spacer()
            VStack(spacing: 3) {
                Text("© 2026 Aissam Irhir · MIT License")
                Text("Now playing through mediaremote-adapter by ungive (BSD-3-Clause)")
            }
            .font(.system(size: 11)).foregroundStyle(.tertiary)
            .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Claude accounts: how to switch between them, and the ones LiveIsland knows.
private struct AccountsSettingsSection: View {
    @EnvironmentObject private var model: IslandModel

    var body: some View {
        Section {
            LabeledContent {
                Picker("Switch accounts with", selection: $model.accountSwitching) {
                    ForEach(AccountsMonitor.Switching.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 260)
            } label: {
                HStack(spacing: 10) {
                    IconBadge(symbol: "person.2.fill", tint: .indigo, size: 26)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Switch accounts with")
                        Text("Only when you tap Switch, never on its own").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
            Text(explanation).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if model.accountSwitching == .claudeSwap && !model.accountsState.claudeSwapInstalled {
                Label("claude-swap isn't installed. In a terminal: uv tool install claude-swap", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12)).foregroundStyle(.orange).textSelection(.enabled)
            }
            ForEach(model.accounts) { account in
                HStack(spacing: 10) {
                    AccountAvatar(identity: account.identity, size: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(account.identity.displayName)
                            if account.isActive { Text("In use").font(.system(size: 10, weight: .semibold)).foregroundStyle(.green) }
                        }
                        Text([account.identity.email, account.identity.plan].compactMap { $0 }.joined(separator: " · "))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(status(account)).font(.system(size: 11)).foregroundStyle(.secondary)
                    if account.switcher == .liveIsland || !account.isActive {
                        Button("Forget") { model.forgetAccount(account) }
                            .help(account.isActive ? "Delete LiveIsland's saved copy of this login" : "Remove this account and LiveIsland's saved login")
                    }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Label("Add an account: run /login in Claude Code and sign in to it. Don't use /logout: it can cancel the saved login of the account you leave.",
                      systemImage: "person.badge.plus")
                Label("Running sessions move to the new account within about 30 seconds.", systemImage: "clock")
                Label("Use one switcher at a time. Each keeps its own copy of every login, and Claude Code replaces a login when it refreshes it, so the other copy goes stale.",
                      systemImage: "exclamationmark.arrow.triangle.2.circlepath")
            }
            .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("Claude accounts")
        }
    }

    private var explanation: String {
        switch model.accountSwitching {
        case .off:
            return "LiveIsland shows each account you use and its limits, and tells you when the one in use runs out. Switching stays with you."
        case .liveIsland:
            return "LiveIsland keeps each account's Claude login in your login Keychain, and puts it in place when you tap Switch. Your MCP logins stay as they are, and nothing leaves your Mac."
        case .claudeSwap:
            return "LiveIsland asks claude-swap to switch and shows its usage for every account. LiveIsland itself never touches a login. Add accounts with `cswap add` after /login."
        }
    }

    private func status(_ account: ClaudeAccount) -> String {
        if account.needsLogin { return "Sign in again" }
        switch account.switcher {
        case .liveIsland: return "Login saved"
        case .claudeSwap: return "In claude-swap"
        case nil: return model.accountSwitching == .off ? "" : "Not saved yet"
        }
    }
}
