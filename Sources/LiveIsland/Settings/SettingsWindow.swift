import AppKit
import LiveIslandCore
import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case general, island, media, agents, tasks, updates, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .island: return "Island"
        case .media: return "Media"
        case .agents: return "AI Agents"
        case .tasks: return "Tasks"
        case .updates: return "Software Update"
        case .about: return "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape.fill"
        case .island: return "capsule.fill"
        case .media: return "music.note"
        case .agents: return "sparkles"
        case .tasks: return "checklist"
        case .updates: return "arrow.triangle.2.circlepath"
        case .about: return "info"
        }
    }

    var tint: Color {
        switch self {
        case .general: return .gray
        case .island: return .indigo
        case .media: return .pink
        case .agents: return .orange
        case .tasks: return .green
        case .updates: return .teal
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
                        HStack {
                            Text(section.title)
                            if section == .updates {
                                Spacer()
                                UpdateBadge(updater: model.updater)
                            }
                        }
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
                case .tasks: TasksSettingsPage()
                case .updates: SoftwareUpdatePage(updater: model.updater)
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
            Section {
                ForEach(Array(model.tabOrder.enumerated()), id: \.element) { index, tab in
                    TabOrderRow(tab: tab, index: index, count: model.tabOrder.count)
                }
            } header: {
                Text("Tabs")
            } footer: {
                HStack(alignment: .top) {
                    Text("The island shows its tabs in this order. When nothing's going on, it opens on the first one with something to show; an agent that needs you or a call still opens its own tab.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer(minLength: 12)
                    if model.tabOrder != IslandTab.allCases {
                        Button("Reset") { withAnimation { model.resetTabOrder() } }
                            .controlSize(.small)
                    }
                }
            }
            Section("Look") {
                ToggleRow(symbol: "sun.max.fill", tint: .purple, title: "Background glow",
                          detail: "Color the open island: the cover's colors on Media, the agents' on Agents", isOn: $model.ambientGlow)
            }
        }
    }
}

/// One tab in the order list, with buttons to move it up or down.
private struct TabOrderRow: View {
    @EnvironmentObject private var model: IslandModel
    let tab: IslandTab
    let index: Int
    let count: Int

    var body: some View {
        HStack(spacing: 10) {
            IconBadge(symbol: tab.symbol, tint: tint, size: 26)
            Text(tab.rawValue)
            Spacer()
            Button { withAnimation { model.moveTab(tab, by: -1) } } label: {
                Image(systemName: "chevron.up").frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .disabled(index == 0)
            .help("Move \(tab.rawValue) left")
            Button { withAnimation { model.moveTab(tab, by: 1) } } label: {
                Image(systemName: "chevron.down").frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .disabled(index == count - 1)
            .help("Move \(tab.rawValue) right")
        }
        .buttonStyle(.borderless)
        .font(.system(size: 12, weight: .semibold))
    }

    private var tint: Color {
        switch tab {
        case .media: return .pink
        case .agents: return .orange
        case .activity: return .blue
        case .accounts: return .purple
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
            Section {
                ToggleRow(symbol: "waveform", tint: .pink, title: "Live waveform",
                          detail: "Bars that move with the music you're playing", isOn: $model.liveWaveform)
                Text("macOS asks once for permission to record system audio. LiveIsland only measures how loud each part of the sound is while music plays; it never records or stores it. Without permission, the island shows the animated symbol.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } header: {
                Text("Waveform")
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
            CodexAccountsSettingsSection()
            Section {
                if ClaudeStatusLine.needsUpdate {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Your status line has LiveIsland's lines from an earlier version, which don't say which session reported the limits. Update them so each account gets its own numbers.")
                            .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Button("Update My Status Line") { model.installStatusLine() }.glassButton(prominent: true)
                    }
                }
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
                AboutUpdateLine(updater: model.updater)
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

/// Software Update, like the one in System Settings: the version running, whether a newer
/// one is out and what's in it, and the button that installs it.
private struct SoftwareUpdatePage: View {
    @EnvironmentObject private var model: IslandModel
    @ObservedObject var updater: Updater

    var body: some View {
        Form {
            Section { PageHeader(section: .updates, detail: "New versions of LiveIsland, from its releases on GitHub.") }
            Section {
                status
                if let release = updater.availableRelease {
                    if !release.notes.isEmpty {
                        Text(notes(release.notes)).font(.system(size: 12)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack {
                        Button("Update Now") { Task { await updater.install() } }.glassButton(prominent: true)
                        Link("Release Notes", destination: release.page).font(.system(size: 12))
                        Spacer()
                        if release.size > 0 {
                            Text(ByteCountFormatter.string(fromByteCount: Int64(release.size), countStyle: .file))
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section {
                ToggleRow(symbol: "clock.arrow.circlepath", tint: .teal, title: "Check for updates automatically",
                          detail: "Once a day, LiveIsland asks GitHub whether a newer version is out. It never installs one without you.",
                          isOn: $model.checkForUpdates)
                Text("Updating replaces LiveIsland where it is and opens the new version. Until LiveIsland is notarized by Apple, macOS may ask again for the permissions it uses.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var status: some View {
        HStack(spacing: 12) {
            switch updater.state {
            case .checking:
                ProgressView().controlSize(.small).frame(width: 28)
                Text("Checking for updates…")
            case .downloading(let release):
                ProgressView().controlSize(.small).frame(width: 28)
                Text("Downloading LiveIsland \(release.version.description)…")
            case .installing(let release):
                ProgressView().controlSize(.small).frame(width: 28)
                Text("Installing LiveIsland \(release.version.description). It reopens in a moment.")
            case .available(let release):
                Image(systemName: "arrow.down.circle.fill").font(.system(size: 24)).foregroundStyle(.teal).frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("LiveIsland \(release.version.description) is available").font(.system(size: 13, weight: .semibold))
                    Text("You have version \(updater.currentVersion)").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 22)).foregroundStyle(.orange).frame(width: 28)
                Text(message).fixedSize(horizontal: false, vertical: true)
            case .upToDate, .idle:
                Image(systemName: updater.state == .upToDate ? "checkmark.seal.fill" : "app.badge")
                    .font(.system(size: 22)).foregroundStyle(updater.state == .upToDate ? .green : .secondary).frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(updater.state == .upToDate ? "LiveIsland is up to date" : "LiveIsland \(updater.currentVersion)")
                        .font(.system(size: 13, weight: .semibold))
                    Text(checkedLine).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if updater.availableRelease == nil {
                Button("Check Now") { Task { await updater.check() } }
                    .disabled(updater.isBusy)
            }
        }
    }

    private var checkedLine: String {
        guard let checked = updater.lastChecked else { return "Version \(updater.currentVersion)" }
        let ago = Date().timeIntervalSince(checked) < 60 ? "just now" : RelativeDateTimeFormatter().localizedString(for: checked, relativeTo: Date())
        return "Version \(updater.currentVersion) · checked \(ago)"
    }

    /// The release notes' Markdown, shown with its bold and code; lines stay lines.
    private func notes(_ markdown: String) -> AttributedString {
        (try? AttributedString(markdown: markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(markdown)
    }
}

/// A count in the sidebar, like System Settings' Software Update, when a new version is out.
private struct UpdateBadge: View {
    @ObservedObject var updater: Updater

    var body: some View {
        if updater.availableRelease != nil {
            Text("1").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(Capsule().fill(.red))
        }
    }
}

/// Under the version on About: a way to the update, when there is one.
private struct AboutUpdateLine: View {
    @EnvironmentObject private var model: IslandModel
    @ObservedObject var updater: Updater

    var body: some View {
        if let release = updater.availableRelease {
            Button("Version \(release.version.description) is available") { model.openSettings(.updates) }
                .buttonStyle(.link).font(.system(size: 12))
        }
    }
}

/// Claude Code tasks that keep going after a usage limit.
private struct TasksSettingsPage: View {
    @EnvironmentObject private var model: IslandModel

    var body: some View {
        Form {
            Section { PageHeader(section: .tasks, detail: "Claude Code tasks that keep going on their own: after a usage limit resets, or on another of your accounts.") }
            TaskAutomationSections(runner: model.taskRunner, profiles: model.profileStore)
        }
    }
}

/// Tasks that keep going after a usage limit: the switches, the accounts they may use, a form
/// to start one, and each task's state with its controls.
private struct TaskAutomationSections: View {
    @EnvironmentObject private var model: IslandModel
    @ObservedObject var runner: TaskRunner
    @ObservedObject var profiles: ProfileStore

    var body: some View {
        Group {
            Section {
                ToggleRow(symbol: "arrow.clockwise.circle.fill", tint: .green, title: "Continue tasks after a usage limit",
                          detail: "A task started below picks up again by itself when its account's limit resets, from where it stopped.",
                          isOn: $model.keepTasksGoing)
                ToggleRow(symbol: "person.2.circle.fill", tint: .orange, title: "Use my other accounts",
                          detail: "When the task's account runs out, continue on the next account below that has room, instead of waiting.",
                          isOn: $model.switchAccountsForTasks)
                    .disabled(!model.keepTasksGoing)
                Text("Anthropic's Consumer Terms forbid “bypassing any of our systems or protective measures”, and Claude Code's limits assume “ordinary, individual usage”. Anthropic doesn't say whether switching your own accounts automatically counts; if it decides it does, it could act on these accounts. LiveIsland only uses accounts you signed in to here through Claude Code itself, never touches their logins, and never turns on extra usage or an API key.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Keep tasks going")
            }
            Section {
                ForEach(Array(profiles.profiles.enumerated()), id: \.element.id) { index, profile in
                    ProfileRow(profiles: profiles, profile: profile, index: index)
                }
                HStack {
                    TextField("Name for another account", text: $profiles.newName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { profiles.add() }
                    Button("Add and Sign In") { profiles.add() }
                        .disabled(profiles.newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Accounts for tasks")
            } footer: {
                Text("Each account is its own Claude Code folder (Main is ~/.claude), signed in with `claude auth login` in Terminal. Claude Code keeps the login in your Keychain; LiveIsland only remembers the email and plan it reports. Tasks use them from the top down.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Project") {
                    HStack {
                        Text(runner.draftFolder.isEmpty ? "None" : (runner.draftFolder as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Button("Choose…") { runner.chooseFolder() }
                    }
                }
                TextField("What should Claude Code do?", text: $runner.draftObjective, axis: .vertical)
                    .lineLimit(3...8)
                Picker("Permissions", selection: $runner.draftMode) {
                    Text("Accept edits").tag("acceptEdits")
                    Text("Auto").tag("auto")
                    Text("Ask (pause when something needs approval)").tag("default")
                }
                Picker("Start on", selection: $runner.draftProfile) {
                    ForEach(profiles.profiles) { Text($0.name).tag($0.id) }
                }
                HStack {
                    if let problem = runner.draftProblem {
                        Text(problem).font(.system(size: 11)).foregroundStyle(.red)
                    }
                    Spacer()
                    Button("Start Task") { runner.createFromDraft() }.glassButton(prominent: true)
                }
            } header: {
                Text("New task")
            } footer: {
                Text("The task runs as `claude -p` in that folder, with these permissions. Nobody is there to approve anything new, so a step that needs approval pauses the task for you.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if !runner.tasks.isEmpty {
                Section("Tasks") {
                    ForEach(runner.tasks) { task in
                        TaskRow(runner: runner, profiles: profiles, task: task)
                    }
                }
            }
        }
    }
}

/// An account for tasks: on or off, its place in the order, and what LiveIsland knows of it.
private struct ProfileRow: View {
    @ObservedObject var profiles: ProfileStore
    let profile: ClaudeProfile
    let index: Int

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { profile.enabled }, set: { profiles.setEnabled(profile.id, $0) }))
                .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                .help("Tasks may move to this account")
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(profile.name).font(.system(size: 13, weight: .semibold))
                    if let plan = profile.plan {
                        Text(plan).font(.system(size: 10, weight: .semibold)).padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(.quaternary))
                    }
                }
                Text(status).font(.system(size: 11)).foregroundStyle(statusColor).lineLimit(2)
            }
            Spacer()
            if profile.unusable != nil {
                Button("Sign In") { profiles.signIn(profile) }
            }
            Menu {
                Button("Check Sign-In") { Task { await profiles.refresh(profile.id) } }
                Button("Sign In Again") { profiles.signIn(profile) }
                if profile.id != ClaudeProfile.mainID {
                    Divider()
                    Button("Remove from LiveIsland") { profiles.remove(profile.id) }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton).fixedSize()
            Button { profiles.move(profile.id, by: -1) } label: { Image(systemName: "chevron.up") }
                .disabled(index == 0).help("Use earlier")
            Button { profiles.move(profile.id, by: 1) } label: { Image(systemName: "chevron.down") }
                .disabled(index == profiles.profiles.count - 1).help("Use later")
        }
        .buttonStyle(.borderless)
    }

    private var status: String {
        let now = Date()
        if let reason = profile.unusable { return reason }
        if let other = profiles.duplicate(of: profile) { return "\(profile.email ?? "") · same account as \(other.name)" }
        let who = [profile.email, profile.configDir.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "~/.claude"]
            .compactMap { $0 }.joined(separator: " · ")
        if let until = profile.exhaustedUntil, until > now { return "Out of usage until \(TaskTime.text(until)) · \(who)" }
        if let since = profile.exhaustedSince, now.timeIntervalSince(since) < AccountRotation.unknownResetRetry {
            return "Out of usage, reset time not reported · tried again at \(TaskTime.text(since.addingTimeInterval(AccountRotation.unknownResetRetry)))"
        }
        return "Ready · \(who)"
    }

    private var statusColor: Color {
        if profile.unusable != nil || profiles.duplicate(of: profile) != nil { return .red }
        if AccountRotation.isAvailable(profile, at: Date()) { return .secondary }
        return .orange
    }
}

/// A task: what it does, where it stands and why, what happens next, and the controls.
private struct TaskRow: View {
    @ObservedObject var runner: TaskRunner
    @ObservedObject var profiles: ProfileStore
    let task: AutomationTask

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                badge
                Text(task.objective).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                Spacer()
            }
            Text(details).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(3)
            HStack(spacing: 8) {
                switch task.state {
                case .running:
                    Button("Pause") { runner.pause(task.id) }
                    Button("Cancel") { runner.cancel(task.id) }
                    switchMenu
                case .waiting:
                    Button("Continue Now") { runner.resume(task.id) }
                    Button("Pause") { runner.pause(task.id) }
                    Button("Cancel") { runner.cancel(task.id) }
                    switchMenu
                case .paused, .needsYou:
                    Button("Resume") { runner.resume(task.id) }
                    Button("Cancel") { runner.cancel(task.id) }
                    switchMenu
                case .done, .cancelled:
                    Button("Remove") { runner.remove(task.id) }
                }
                Spacer()
                Button("Show Folder") { NSWorkspace.shared.open(URL(fileURLWithPath: task.folder)) }
            }
            .controlSize(.small)
        }
        .padding(.vertical, 3)
    }

    private var switchMenu: some View {
        Menu("Switch Account") {
            ForEach(profiles.profiles.filter { $0.id != task.profileID }) { profile in
                Button(profile.name) { runner.switchAccount(task.id, to: profile.id) }
            }
        }
        .fixedSize()
    }

    private var badge: some View {
        let (label, color): (String, Color) = {
            switch task.state {
            case .running: return ("Running", .green)
            case .waiting: return ("Waiting", .orange)
            case .paused: return ("Paused", .gray)
            case .needsYou: return ("Needs you", .yellow)
            case .done: return ("Done", .green)
            case .cancelled: return ("Cancelled", .gray)
            }
        }()
        return Text(label).font(.system(size: 10, weight: .bold)).foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.15)))
    }

    private var details: String {
        var parts = [(task.folder as NSString).abbreviatingWithTildeInPath, profiles.name(of: task.profileID)]
        if task.attempts.count > 1 { parts.append("run \(task.attempts.count)") }
        var text = parts.joined(separator: " · ") + "\n" + task.reason
        if task.state == .waiting, let next = task.nextAttemptAt {
            text += " · next: \(TaskTime.text(next)) on \(profiles.name(of: task.profileID))"
        }
        if task.attempts.last?.kind == "handoff" { text += " · new conversation from saved progress" }
        return text
    }
}

/// Times for tasks and accounts, with their time zone, so a reset isn't misread.
enum TaskTime {
    static func text(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm zzz" : "EEE d MMM, HH:mm zzz"
        return formatter.string(from: date)
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
                Label("New Claude Code sessions use the new account. Sessions already running can keep the previous one: restart them (claude --continue picks up where you left off).", systemImage: "clock")
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

/// Codex accounts: whether LiveIsland keeps their logins to switch, and the ones it knows.
private struct CodexAccountsSettingsSection: View {
    @EnvironmentObject private var model: IslandModel

    var body: some View {
        Section {
            Toggle(isOn: $model.codexSwitching) {
                HStack(spacing: 10) {
                    AgentAvatar(kind: .codex, state: .idle, size: 26)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Switch Codex accounts with LiveIsland")
                        Text("Only when you tap Switch, never on its own").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
            .toggleStyle(.switch)
            Text(model.codexSwitching
                 ? "LiveIsland keeps a copy of each Codex login in its own folder, readable only by you, the same way Codex keeps its own in ~/.codex/auth.json, and puts it in place when you tap Switch."
                 : "LiveIsland shows each Codex account you use and its limits. Switching stays with you (codex login).")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(model.codexAccounts) { account in
                HStack(spacing: 10) {
                    AccountAvatar(identity: account.identity, size: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(account.identity.email)
                            if account.isActive { Text("In use").font(.system(size: 10, weight: .semibold)).foregroundStyle(.green) }
                        }
                        Text(account.identity.plan.map { "ChatGPT \($0)" } ?? "ChatGPT").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(account.switcher != nil ? "Login saved" : (model.codexSwitching ? "Not saved yet" : ""))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    if account.switcher != nil || !account.isActive {
                        Button("Forget") { model.forgetAccount(account) }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Label("Add an account: run codex login and sign in to it. Don't use codex logout: it cancels the login.",
                      systemImage: "person.badge.plus")
                Label("New Codex sessions use the new account. Sessions already running keep theirs until you restart them (codex resume picks up where you left off).",
                      systemImage: "clock")
            }
            .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("Codex accounts")
        }
    }
}
