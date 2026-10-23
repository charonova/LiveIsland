import AppKit
import LiveIslandCore
import SwiftUI

/// The menu bar icon: the island, with a little waveform in it.
enum MenuBarIcon {
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 22, height: 16), flipped: false) { _ in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: NSRect(x: 1, y: 4, width: 20, height: 9), xRadius: 4.5, yRadius: 4.5).fill()
            // Cut the waveform and the camera dot out of the pill.
            NSGraphicsContext.current?.compositingOperation = .clear
            for (index, height) in [3.0, 5.0, 2.5].enumerated() {
                let x = 5.0 + Double(index) * 2.4
                NSBezierPath(roundedRect: NSRect(x: x, y: 8.5 - height / 2, width: 1.4, height: height), xRadius: 0.7, yRadius: 0.7).fill()
            }
            NSBezierPath(ovalIn: NSRect(x: 14.5, y: 6.75, width: 3.5, height: 3.5)).fill()
            return true
        }
        image.isTemplate = true
        return image
    }()
}

/// The panel under the menu bar icon: what's playing, quick switches, a timer, settings.
/// Its size never changes: a menu bar window that shrinks leaves a gap under the menu bar.
struct MenuBarPanel: View {
    @EnvironmentObject private var model: IslandModel

    var body: some View {
        VStack(spacing: 12) {
            header
            MiniPlayer()
            AccountStrip()
            QuickToggles()
            TimerRow()
            footer
        }
        .padding(14)
        .frame(width: 330, height: 480, alignment: .top)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text("LiveIsland").font(.system(size: 14, weight: .bold))
                Text(status).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Button { model.openSettings() } label: {
                Image(systemName: "gearshape.fill").font(.system(size: 13, weight: .semibold)).frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .liquidGlass(in: Circle(), interactive: true)
            .help("Settings")
        }
    }

    private var status: String {
        let working = model.sessions.filter { $0.state == .working }.count
        let waiting = model.sessions.filter { $0.state == .waiting }.count
        var parts: [String] = []
        if waiting > 0 { parts.append("\(waiting) agent\(waiting == 1 ? "" : "s") need\(waiting == 1 ? "s" : "") you") }
        if working > 0 { parts.append("\(working) working") }
        if let player = model.players.first(where: \.isPlaying) { parts.append("\(AppInfo.name(player.bundleIdentifier) ?? "Music") playing") }
        return parts.isEmpty ? "All quiet" : parts.joined(separator: " · ")
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button { model.expand() } label: {
                Label("Open Island", systemImage: "capsule.portrait.fill").frame(maxWidth: .infinity)
            }
            .glassButton(prominent: true)
            Button { NSApp.terminate(nil) } label: {
                Label("Quit", systemImage: "power")
            }
            .glassButton()
            .keyboardShortcut("q")
        }
        .controlSize(.large)
    }
}

private struct MiniPlayer: View {
    @EnvironmentObject private var model: IslandModel

    var body: some View {
        HStack(spacing: 10) {
            if let track = model.nowPlaying {
                Artwork(image: model.artwork(for: track)?.image, size: 44, corner: 10)
                    .overlay(alignment: .bottomTrailing) {
                        if let icon = AppInfo.icon(track.bundleIdentifier) {
                            Image(nsImage: icon).resizable().frame(width: 16, height: 16).offset(x: 4, y: 4)
                        }
                    }
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(track.artist.isEmpty ? AppInfo.name(track.bundleIdentifier) ?? "" : track.artist)
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Button { model.togglePlayPause() } label: {
                    Image(systemName: track.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 15, weight: .bold))
                        .frame(width: 30, height: 30).contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                Button { model.nextTrack() } label: {
                    Image(systemName: "forward.fill").font(.system(size: 13, weight: .bold)).frame(width: 26, height: 30)
                }
                .buttonStyle(.plain)
            } else {
                IconBadge(symbol: "music.note", tint: .pink, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Nothing playing").font(.system(size: 13, weight: .semibold))
                    Text("Play something in any app").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(10)
        .frame(height: 64)
        .liquidGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct QuickToggles: View {
    @EnvironmentObject private var model: IslandModel
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            QuickToggle(symbol: "music.note", tint: .pink, title: "Media", isOn: $model.showMedia)
            QuickToggle(symbol: "sparkles", tint: .orange, title: "Agents", isOn: $model.showAgents)
            QuickToggle(symbol: "phone.fill", tint: .green, title: "Calls", isOn: $model.showCalls)
            QuickToggle(symbol: "airpodspro", tint: .blue, title: "Devices", isOn: $model.showDevices)
            QuickToggle(symbol: "calendar", tint: .red, title: "Calendar", isOn: $model.showCalendar)
            QuickToggle(symbol: "cursorarrow.motionlines", tint: .indigo, title: "Hover", isOn: $model.expandOnHover)
        }
    }
}

private struct QuickToggle: View {
    let symbol: String
    let tint: Color
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { isOn.toggle() }
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    Circle().fill(isOn ? tint : Color.primary.opacity(0.1))
                    Image(systemName: symbol).font(.system(size: 13, weight: .bold))
                        .foregroundStyle(isOn ? Color.white : .secondary)
                }
                .frame(width: 32, height: 32)
                Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(isOn ? .primary : .secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 66)
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(PressableStyle())
        .liquidGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous), tint: isOn ? tint.opacity(0.18) : nil)
        .help(isOn ? "Hide \(title.lowercased()) in the island" : "Show \(title.lowercased()) in the island")
    }
}

private struct TimerRow: View {
    @EnvironmentObject private var model: IslandModel

    var body: some View {
        HStack(spacing: 8) {
            IconBadge(symbol: "timer", tint: .orange, size: 26)
            if let timer = model.timer {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(Format.clock(timer.remaining(at: context.date))).font(.system(size: 15, weight: .bold, design: .rounded))
                        .monospacedDigit().foregroundStyle(.orange)
                }
                Spacer()
                Button(timer.isPaused ? "Resume" : "Pause") { model.toggleTimerPause() }.glassButton()
                Button("Cancel") { model.cancelTimer() }.glassButton()
            } else {
                Text("Timer").font(.system(size: 12, weight: .semibold))
                Spacer()
                ForEach([1.0, 5, 10, 25], id: \.self) { minutes in
                    Button("\(Int(minutes))m") { model.startTimer(minutes: minutes) }.glassButton()
                }
            }
        }
        .controlSize(.small)
    }
}

/// The Claude account in use, its limits, and a menu to switch.
private struct AccountStrip: View {
    @EnvironmentObject private var model: IslandModel

    var body: some View {
        HStack(spacing: 10) {
            if let active = model.accountsState.active {
                AccountAvatar(identity: active.identity, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(active.identity.displayName).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Text(limits(active)).font(.system(size: 10)).foregroundStyle(active.isAtLimit ? Color.orange : .secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                let others = model.accounts.filter { !$0.isActive && $0.switcher != nil && !$0.needsLogin }
                let codex = model.codexAccounts.filter { !$0.isActive && $0.switcher != nil }
                if model.accountsState.switching != nil {
                    ProgressView().controlSize(.small)
                } else if !others.isEmpty || !codex.isEmpty {
                    Menu("Switch") {
                        if !others.isEmpty {
                            Section("Claude Code") {
                                ForEach(others) { account in
                                    Button("\(account.identity.displayName) — \(usage(account))") { model.switchAccount(account) }
                                }
                            }
                        }
                        if !codex.isEmpty {
                            Section("Codex") {
                                ForEach(codex) { account in
                                    Button("\(account.identity.email) — \(usage(account))") { model.switchAccount(account) }
                                }
                            }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            } else {
                IconBadge(symbol: "person.2.fill", tint: .indigo, size: 30)
                Text("Claude accounts appear once Claude Code is used").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
        .padding(10)
        .frame(height: 50)
        .liquidGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func usage(_ account: ClaudeAccount) -> String {
        account.used.map { "\(Int($0.rounded()))% used" } ?? "not seen yet"
    }

    private func limits(_ account: ClaudeAccount) -> String {
        func percent(_ window: RateLimitWindow?) -> String { window.map { "\(Int($0.usedPercent.rounded()))%" } ?? "—" }
        return "5 hours \(percent(account.fiveHour)) · Week \(percent(account.sevenDay))"
    }
}
