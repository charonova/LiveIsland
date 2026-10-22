import AppKit
import LiveIslandCore
import SwiftUI

private let tabSpring = Animation.spring(response: 0.36, dampingFraction: 0.82)

/// The open island: tabs and status beside the notch, the chosen page below it.
struct ExpandedIsland: View {
    @EnvironmentObject private var model: IslandModel
    @Namespace private var tabs
    let layout: IslandLayout

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                TabBar(namespace: tabs)
                Spacer(minLength: layout.notch.width + 16)
                StatusStrip()
            }
            .padding(.horizontal, 18)
            .frame(height: max(layout.notch.height, 32))

            ZStack(alignment: .top) {
                switch model.tab {
                case .media: MediaPage().transition(.blurReplace)
                case .agents: AgentsPage().transition(.blurReplace)
                case .activity: ActivityPage().transition(.blurReplace)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .foregroundStyle(.white)
        .background { AmbientGlow() }
        .animation(tabSpring, value: model.tab)
    }
}

// MARK: - Header

private struct TabBar: View {
    @EnvironmentObject private var model: IslandModel
    let namespace: Namespace.ID

    var body: some View {
        HStack(spacing: 2) {
            ForEach(IslandTab.allCases) { tab in
                let selected = model.tab == tab
                Button {
                    withAnimation(tabSpring) { model.tab = tab }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: tab.symbol).font(.system(size: 11, weight: .semibold))
                        if selected {
                            Text(tab.rawValue).font(.system(size: 11, weight: .semibold, design: .rounded)).fixedSize()
                        }
                    }
                    .padding(.horizontal, selected ? 10 : 8)
                    .frame(height: 24)
                    .foregroundStyle(selected ? Color.white : .white.opacity(0.5))
                    .background {
                        if selected {
                            Capsule()
                                .fill(LinearGradient(colors: [.white.opacity(0.24), .white.opacity(0.12)], startPoint: .top, endPoint: .bottom))
                                .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
                                .matchedGeometryEffect(id: "selection", in: namespace)
                        }
                    }
                    .overlay(alignment: .topTrailing) { badge(for: tab) }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(tab.rawValue)
            }
        }
        .padding(3)
        .liquidGlass(in: Capsule())
    }

    /// A dot on Agents when one needs attention or is at work.
    @ViewBuilder private func badge(for tab: IslandTab) -> some View {
        if tab == .agents, model.tab != .agents {
            if model.sessions.contains(where: { $0.state == .waiting }) {
                Circle().fill(.yellow).frame(width: 6, height: 6).offset(x: -2, y: 3)
            } else if model.sessions.contains(where: { $0.state == .working }) {
                Circle().fill(AgentGlyph(kind: .claude).color).frame(width: 6, height: 6).offset(x: -2, y: 3)
            }
        }
    }
}

/// Privacy dots, battery and the time, to the right of the notch.
private struct StatusStrip: View {
    @EnvironmentObject private var model: IslandModel

    var body: some View {
        HStack(spacing: 9) {
            if model.system.cameraOn { Circle().fill(.green).frame(width: 6, height: 6).help("Camera in use") }
            if !model.system.microphoneApps.isEmpty { Circle().fill(.orange).frame(width: 6, height: 6).help("Microphone in use") }
            if let battery = model.system.battery {
                HStack(spacing: 5) {
                    Text("\(battery.percent)%").monospacedDigit()
                    BatteryGlyph(percent: battery.percent, charging: battery.isCharging || battery.onPower)
                }
            }
            TimelineView(.everyMinute) { context in
                Text(context.date, format: .dateTime.hour().minute())
            }
            Button { model.openSettings() } label: {
                Image(systemName: "gearshape.fill").font(.system(size: 11, weight: .semibold))
                    .frame(width: 22, height: 22).contentShape(Circle())
            }
            .buttonStyle(PressableStyle())
            .help("Settings")
        }
        .font(.system(size: 11, weight: .semibold, design: .rounded))
        .foregroundStyle(.white.opacity(0.75))
    }
}

struct BatteryGlyph: View {
    let percent: Int
    let charging: Bool
    var width: CGFloat = 22

    var body: some View {
        let height = width / 2
        HStack(spacing: 1) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: height * 0.3, style: .continuous)
                    .strokeBorder(.white.opacity(0.45), lineWidth: 1)
                RoundedRectangle(cornerRadius: height * 0.18, style: .continuous)
                    .fill(color)
                    .frame(width: max(2, (width - 4) * CGFloat(min(percent, 100)) / 100))
                    .padding(2)
                if charging {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: height * 0.75, weight: .black))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.6), radius: 1)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(width: width, height: height)
            Capsule().fill(.white.opacity(0.45)).frame(width: 1.5, height: height * 0.4)
        }
    }

    private var color: Color {
        charging ? .green : percent <= 20 ? .red : .white
    }
}

/// A soft wash of color behind each page: the artwork on Media, the agents' colors on Agents,
/// the tiles' colors on Activity.
private struct AmbientGlow: View {
    @EnvironmentObject private var model: IslandModel

    var body: some View {
        if model.ambientGlow {
            ZStack {
                switch model.tab {
                case .media: ArtworkGlow()
                case .agents: AgentsGlow()
                case .activity: ActivityGlow()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }
}

/// Radial glows: no blur needed, so they cost next to nothing.
private struct Glows: View {
    let spots: [(color: Color, point: UnitPoint, radius: CGFloat)]

    var body: some View {
        ZStack {
            ForEach(spots.indices, id: \.self) { index in
                RadialGradient(colors: [spots[index].color, .clear], center: spots[index].point,
                               startRadius: 0, endRadius: spots[index].radius)
            }
            LinearGradient(colors: [.black.opacity(0.15), .black.opacity(0.45)], startPoint: .top, endPoint: .bottom)
        }
        .transition(.opacity)
    }
}

private struct AgentsGlow: View {
    @EnvironmentObject private var model: IslandModel

    var body: some View {
        let claude = AgentGlyph(kind: .claude).color
        let codex = AgentGlyph(kind: .codex).color
        let waiting = model.sessions.contains { $0.state == .waiting }
        let working = model.sessions.contains { $0.state == .working }
        Glows(spots: [
            (claude.opacity(working ? 0.42 : 0.3), UnitPoint(x: 0.1, y: 0.75), 320),
            (codex.opacity(0.28), UnitPoint(x: 0.9, y: 0.85), 300),
            (waiting ? Color.yellow.opacity(0.22) : Color.purple.opacity(0.14), UnitPoint(x: 0.45, y: 0.15), 260),
        ])
        .animation(.easeInOut(duration: 0.8), value: waiting)
        .animation(.easeInOut(duration: 0.8), value: working)
    }
}

private struct ActivityGlow: View {
    var body: some View {
        Glows(spots: [
            (Color.orange.opacity(0.28), UnitPoint(x: 0.08, y: 0.35), 260),
            (Color.red.opacity(0.2), UnitPoint(x: 0.5, y: 0.2), 240),
            (Color.green.opacity(0.24), UnitPoint(x: 0.95, y: 0.4), 260),
            (Color.blue.opacity(0.28), UnitPoint(x: 0.2, y: 1), 280),
            (Color.purple.opacity(0.2), UnitPoint(x: 0.8, y: 1), 260),
        ])
    }
}

/// The artwork, blurred into a glow behind the media page.
private struct ArtworkGlow: View {
    @EnvironmentObject private var model: IslandModel

    var body: some View {
        if let look = model.artwork(for: model.nowPlaying) {
            ZStack(alignment: .topLeading) {
                Image(nsImage: look.image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 340, height: 300)
                    .blur(radius: 70)
                    .opacity(0.6)
                    .offset(x: -70, y: 20)
                RadialGradient(colors: [look.accent.opacity(0.28), .clear], center: .bottomLeading, startRadius: 10, endRadius: 420)
                LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .leading, endPoint: .trailing)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clipped()
            .transition(.opacity)
        } else {
            // No cover (a video, a podcast without art, or nothing at all): a warm music glow.
            Glows(spots: [
                (Color.pink.opacity(0.3), UnitPoint(x: 0.1, y: 0.7), 300),
                (Color.purple.opacity(0.26), UnitPoint(x: 0.85, y: 0.9), 300),
            ])
        }
    }
}

// MARK: - Media

private struct MediaPage: View {
    @EnvironmentObject private var model: IslandModel

    var body: some View {
        if let track = model.nowPlaying {
            let accent = model.accent
            VStack(spacing: 12) {
                HStack(alignment: .top, spacing: 16) {
                    CoverArt(track: track, accent: accent)
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(alignment: .top, spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(track.title).font(.system(size: 17, weight: .bold)).lineLimit(1)
                                Text(subtitle(track)).font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "waveform")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(accent)
                                .symbolEffect(.variableColor.iterative.reversing, isActive: track.isPlaying)
                                .opacity(track.isPlaying ? 1 : 0.35)
                        }
                        Spacer(minLength: 8)
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            ScrubBar(track: track, now: context.date, accent: accent)
                        }
                        Spacer(minLength: 6)
                        Controls(track: track, accent: accent)
                    }
                    .frame(height: 116)
                }
                HStack(spacing: 12) {
                    PlayerSwitcher()
                    Spacer(minLength: 0)
                    VolumeRow(accent: accent)
                }
                .frame(height: 26)
                QueueStrip(accent: accent)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        } else {
            EmptyMedia()
        }
    }

    private func subtitle(_ track: NowPlaying) -> String {
        let parts = [track.artist, track.album].filter { !$0.isEmpty }
        return parts.isEmpty ? AppInfo.name(track.bundleIdentifier) ?? " " : parts.joined(separator: " — ")
    }
}

private struct CoverArt: View {
    @EnvironmentObject private var model: IslandModel
    let track: NowPlaying
    let accent: Color

    var body: some View {
        Button { model.openPlayerApp() } label: {
            ZStack(alignment: .bottomTrailing) {
                Artwork(image: model.artwork(for: track)?.image, size: 116, corner: 22)
                    .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
                    .shadow(color: accent.opacity(0.45), radius: 18, y: 6)
                    .scaleEffect(track.isPlaying ? 1 : 0.94)
                    .animation(.spring(response: 0.45, dampingFraction: 0.7), value: track.isPlaying)
                if let icon = AppInfo.icon(track.bundleIdentifier) {
                    Image(nsImage: icon).resizable().frame(width: 28, height: 28)
                        .shadow(color: .black.opacity(0.5), radius: 4, y: 2)
                        .offset(x: 7, y: 7)
                }
            }
        }
        .buttonStyle(PressableStyle())
        .help("Open \(AppInfo.name(track.bundleIdentifier) ?? "the app")")
    }
}

private struct ScrubBar: View {
    @EnvironmentObject private var model: IslandModel
    let track: NowPlaying
    let now: Date
    let accent: Color

    var body: some View {
        let duration = track.duration ?? 0
        let fraction = model.scrubbing ?? track.progress(at: now) ?? 0
        let position = model.scrubbing.map { $0 * duration } ?? track.position(at: now) ?? 0
        VStack(spacing: 4) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.16))
                    Capsule()
                        .fill(LinearGradient(colors: [accent.opacity(0.85), .white], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(6, proxy.size.width * CGFloat(fraction)))
                        .shadow(color: accent.opacity(0.6), radius: 4)
                }
                .frame(height: model.scrubbing == nil ? 5 : 8)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        guard duration > 0 else { return }
                        model.scrubbing = min(max(0, Double(drag.location.x / proxy.size.width)), 1)
                    }
                    .onEnded { drag in
                        guard duration > 0 else { return }
                        model.seek(to: min(max(0, Double(drag.location.x / proxy.size.width)), 1) * duration)
                        model.scrubbing = nil
                    })
                .animation(.spring(response: 0.25, dampingFraction: 0.8), value: model.scrubbing == nil)
            }
            .frame(height: 10)
            HStack {
                Text(Format.clock(position))
                Spacer()
                Text(duration > 0 ? "-" + Format.clock(max(0, duration - position)) : "Live")
            }
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.white.opacity(0.5))
        }
    }
}

private struct Controls: View {
    @EnvironmentObject private var model: IslandModel
    let track: NowPlaying
    let accent: Color

    var body: some View {
        HStack(spacing: 0) {
            control("gobackward.15", size: 15) { model.skip(by: -15) }.help("Back 15 seconds")
            Spacer(minLength: 0)
            control("backward.fill", size: 18) { model.previousTrack() }
            Spacer(minLength: 0)
            Button { model.togglePlayPause() } label: {
                Image(systemName: track.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 20, weight: .bold))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 46, height: 46)
                    .contentShape(Circle())
            }
            .buttonStyle(PressableStyle())
            .liquidGlass(in: Circle(), tint: accent.opacity(0.35), interactive: true)
            Spacer(minLength: 0)
            control("forward.fill", size: 18) { model.nextTrack() }
            Spacer(minLength: 0)
            control("goforward.15", size: 15) { model.skip(by: 15) }.help("Forward 15 seconds")
        }
        .padding(.horizontal, 6)
    }

    private func control(_ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size, weight: .semibold))
                .frame(width: 34, height: 34).contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
    }
}

/// Every player with something loaded (tap to switch), then installed players that are idle
/// (tap to open and play).
private struct PlayerSwitcher: View {
    @EnvironmentObject private var model: IslandModel

    var body: some View {
        HStack(spacing: 6) {
            ForEach(model.players, id: \.bundleIdentifier) { player in
                let selected = player.bundleIdentifier == model.nowPlaying?.bundleIdentifier
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { model.selectedPlayerID = player.bundleIdentifier }
                } label: {
                    chip(player.bundleIdentifier, named: selected, playing: player.isPlaying, selected: selected)
                }
                .buttonStyle(PressableStyle())
                .help(player.title)
            }
            ForEach(model.idlePlayers, id: \.self) { bundle in
                Button { model.launchPlayer(bundle) } label: {
                    chip(bundle, named: false, playing: false, selected: false).opacity(0.55)
                }
                .buttonStyle(PressableStyle())
                .help("Play in \(AppInfo.name(bundle) ?? "the app")")
            }
        }
    }

    private func chip(_ bundle: String?, named: Bool, playing: Bool, selected: Bool) -> some View {
        HStack(spacing: 5) {
            if let icon = AppInfo.icon(bundle) {
                Image(nsImage: icon).resizable().frame(width: 16, height: 16)
            }
            if named {
                Text(AppInfo.name(bundle) ?? "Player").font(.system(size: 11, weight: .semibold)).lineLimit(1)
            }
            if playing {
                Image(systemName: "speaker.wave.2.fill").font(.system(size: 8, weight: .bold)).foregroundStyle(.green)
            }
        }
        .padding(.horizontal, 7)
        .frame(height: 24)
        .background(Capsule().fill(.white.opacity(selected ? 0.16 : 0.06)))
        .overlay(Capsule().strokeBorder(.white.opacity(selected ? 0.2 : 0.06), lineWidth: 0.5))
        .contentShape(Capsule())
    }
}

/// Up Next from Music's playlist, or the tracks played earlier: tap one to play it.
private struct QueueStrip: View {
    @EnvironmentObject private var model: IslandModel
    let accent: Color

    var body: some View {
        let current = model.nowPlaying
        let queue = current?.bundleIdentifier.flatMap { model.upNext[$0] } ?? []
        let history = model.history.filter { $0.trackID != current?.trackID }
        if !queue.isEmpty || !history.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Text(queue.isEmpty ? "RECENTLY PLAYED" : "UP NEXT")
                    .font(.system(size: 9, weight: .bold)).tracking(0.8).foregroundStyle(.white.opacity(0.45))
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        if let bundle = current?.bundleIdentifier, !queue.isEmpty {
                            ForEach(Array(queue.enumerated()), id: \.element.id) { index, item in
                                Button { model.play(item, in: bundle) } label: {
                                    TrackChip(title: item.title, artist: item.artist, image: nil, number: index + 1, accent: accent)
                                }
                                .buttonStyle(PressableStyle())
                            }
                        } else {
                            ForEach(history) { track in
                                Button { model.play(track) } label: {
                                    TrackChip(title: track.title, artist: track.artist, image: track.image, number: nil, accent: accent,
                                              badge: AppInfo.icon(track.bundleIdentifier))
                                }
                                .buttonStyle(PressableStyle())
                                .help("Play \(track.title) in \(AppInfo.name(track.bundleIdentifier) ?? "its app")")
                            }
                        }
                    }
                }
                .scrollIndicators(.never)
            }
            .transition(.opacity)
        }
    }
}

private struct TrackChip: View {
    let title: String
    let artist: String
    let image: NSImage?
    let number: Int?
    let accent: Color
    var badge: NSImage? = nil

    var body: some View {
        HStack(spacing: 7) {
            ZStack {
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    LinearGradient(colors: [accent.opacity(0.55), accent.opacity(0.2)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Text(number.map(String.init) ?? "♪").font(.system(size: 12, weight: .bold, design: .rounded))
                }
            }
            .frame(width: 30, height: 30)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(alignment: .bottomTrailing) {
                if let badge { Image(nsImage: badge).resizable().frame(width: 12, height: 12).offset(x: 3, y: 3) }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                Text(artist).font(.system(size: 10)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
            }
            .frame(maxWidth: 110, alignment: .leading)
        }
        .padding(4)
        .padding(.trailing, 6)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(.white.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(.white.opacity(0.07), lineWidth: 0.5))
        .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
}

private struct VolumeRow: View {
    @EnvironmentObject private var model: IslandModel
    let accent: Color

    var body: some View {
        if let output = model.output {
            HStack(spacing: 8) {
                Button { model.volume.toggleMute() } label: {
                    Image(systemName: symbol(output)).font(.system(size: 12, weight: .semibold))
                        .frame(width: 18).contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(PressableStyle())
                .help(output.muted ? "Unmute" : "Mute")
                if output.canSetVolume {
                    CapsuleSlider(value: output.muted ? 0 : Double(output.volume), tint: .white) { model.volume.setVolume(Float($0)) }
                        .frame(width: 120)
                }
                HStack(spacing: 4) {
                    Image(systemName: deviceSymbol(output)).font(.system(size: 10, weight: .semibold))
                    Text(output.device).lineLimit(1)
                }
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
                .frame(maxWidth: 120, alignment: .leading)
            }
        }
    }

    private func symbol(_ output: OutputVolume.State) -> String {
        if output.muted || output.volume == 0 { return "speaker.slash.fill" }
        return output.volume < 0.34 ? "speaker.wave.1.fill" : output.volume < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
    }

    private func deviceSymbol(_ output: OutputVolume.State) -> String {
        if output.isBluetooth { return HeadphoneSymbol.name(for: output.device) }
        return output.isBuiltIn ? "laptopcomputer" : "hifispeaker.fill"
    }
}

/// A thin slider that thickens while dragged.
struct CapsuleSlider: View {
    let value: Double
    var tint: Color = .white
    let onChange: (Double) -> Void

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.16))
                Capsule().fill(tint).frame(width: max(5, proxy.size.width * CGFloat(min(max(value, 0), 1))))
            }
            .frame(height: 5)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                onChange(min(max(0, Double(drag.location.x / proxy.size.width)), 1))
            })
        }
        .frame(height: 16)
    }
}

private struct EmptyMedia: View {
    var body: some View {
        HStack(spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(LinearGradient(colors: [Color(red: 1, green: 0.3, blue: 0.45), Color(red: 0.55, green: 0.25, blue: 1)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "music.note").font(.system(size: 40, weight: .semibold)).foregroundStyle(.white)
            }
            .frame(width: 110, height: 110)
            .shadow(color: .pink.opacity(0.35), radius: 20, y: 6)
            VStack(alignment: .leading, spacing: 6) {
                Text("Nothing playing").font(.system(size: 18, weight: .bold))
                Text("Music, podcasts and videos from any app show up here, with controls.")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.55)).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    ForEach(["com.apple.Music", "com.spotify.client"], id: \.self) { bundle in
                        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
                            Button {
                                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                            } label: {
                                HStack(spacing: 6) {
                                    if let icon = AppInfo.icon(bundle) { Image(nsImage: icon).resizable().frame(width: 16, height: 16) }
                                    Text("Open \(AppInfo.name(bundle) ?? "")").font(.system(size: 11, weight: .semibold))
                                }
                                .padding(.horizontal, 10)
                                .frame(height: 28)
                                .contentShape(Capsule())
                            }
                            .buttonStyle(PressableStyle())
                            .liquidGlass(in: Capsule(), interactive: true)
                        }
                    }
                }
                .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity)
    }
}

// MARK: - Agents

private struct AgentsPage: View {
    @EnvironmentObject private var model: IslandModel

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                SessionsHeader()
                if model.sessions.isEmpty {
                    VStack(spacing: 8) {
                        HStack(spacing: -6) {
                            AgentAvatar(kind: .claude, state: .idle, size: 34)
                            AgentAvatar(kind: .codex, state: .idle, size: 34)
                        }
                        Text("No agents running").font(.system(size: 13, weight: .semibold))
                        Text("Claude Code and Codex sessions show up here as they work.")
                            .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(spacing: 6) {
                            ForEach(model.sessions.prefix(8)) { session in
                                AgentRow(session: session)
                            }
                        }
                    }
                    .scrollIndicators(.never)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            UsagePanel().frame(width: 214)
        }
    }
}

private struct SessionsHeader: View {
    @EnvironmentObject private var model: IslandModel

    var body: some View {
        let working = model.sessions.filter { $0.state == .working }.count
        let waiting = model.sessions.filter { $0.state == .waiting }.count
        HStack(spacing: 6) {
            Text("Sessions").font(.system(size: 12, weight: .bold))
            if working > 0 { Chip(text: "\(working) working", color: AgentGlyph(kind: .claude).color) }
            if waiting > 0 { Chip(text: "\(waiting) need\(waiting == 1 ? "s" : "") you", color: .yellow) }
            Spacer()
        }
    }
}

private struct Chip: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .frame(height: 18)
            .background(Capsule().fill(color.opacity(0.16)))
    }
}

/// The agent's mark in a tinted square, ringed by a spinner while it works.
struct AgentAvatar: View {
    let kind: AgentKind
    let state: AgentState
    var size: CGFloat = 30

    var body: some View {
        let color = AgentGlyph(kind: kind).color
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                .fill(LinearGradient(colors: [color.opacity(0.35), color.opacity(0.12)], startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: size * 0.3, style: .continuous).strokeBorder(color.opacity(0.35), lineWidth: 0.5))
            Image(systemName: kind == .claude ? "sparkle" : "terminal.fill")
                .font(.system(size: size * 0.45, weight: .bold))
                .foregroundStyle(color)
        }
        .frame(width: size, height: size)
        .overlay(alignment: .bottomTrailing) {
            if state == .working {
                ProgressView().controlSize(.mini).tint(color)
                    .padding(1)
                    .background(Circle().fill(.black))
                    .offset(x: 4, y: 4)
            } else if state == .waiting {
                Circle().fill(.yellow).frame(width: 9, height: 9).overlay(Circle().stroke(.black, lineWidth: 2)).offset(x: 2, y: 2)
            } else if state == .done {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 11)).foregroundStyle(.green)
                    .background(Circle().fill(.black)).offset(x: 3, y: 3)
            }
        }
    }
}

private struct AgentRow: View {
    @EnvironmentObject private var model: IslandModel
    let session: AgentSession

    var body: some View {
        HStack(spacing: 10) {
            AgentAvatar(kind: session.kind, state: session.state)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.project).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(session.title ?? session.kind.displayName)
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
            }
            Spacer(minLength: 6)
            StateChip(session: session)
            HStack(spacing: 3) {
                if session.resumeCommand != nil {
                    rowButton(model.copiedSession == session.id ? "checkmark" : "doc.on.doc",
                              help: "Copy the command that resumes this session") { model.copyResumeCommand(session) }
                }
                if let host = session.host, let icon = AppInfo.icon(host.bundleIdentifier) {
                    Button { model.jump(to: session) } label: {
                        Image(nsImage: icon).resizable().frame(width: 20, height: 20)
                            .frame(width: 26, height: 26)
                            .background(Circle().fill(.white.opacity(0.1)))
                            .contentShape(Circle())
                    }
                    .buttonStyle(PressableStyle())
                    .help("Go to this session in \(AppInfo.name(host.bundleIdentifier) ?? "its app")")
                } else {
                    rowButton("folder", help: "Open the project folder") { model.openSession(session) }
                }
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(session.state == .idle ? 0.04 : 0.07)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.07), lineWidth: 0.5))
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture { model.jump(to: session) }
    }

    private func rowButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                .frame(width: 22, height: 22)
                .background(Circle().fill(.white.opacity(0.08)))
                .contentShape(Circle())
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(PressableStyle())
        .foregroundStyle(.white.opacity(0.7))
        .help(help)
    }
}

private struct StateChip: View {
    let session: AgentSession

    var body: some View {
        Group {
            switch session.state {
            case .working:
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Chip(text: Format.span(context.date.timeIntervalSince(session.workingSince ?? session.lastActivity)),
                         color: AgentGlyph(kind: session.kind).color)
                }
            case .waiting:
                Chip(text: "Needs you", color: .yellow)
            case .done:
                Chip(text: "Done", color: .green)
            case .idle:
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(Format.span(context.date.timeIntervalSince(session.lastActivity)) + " ago")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.35))
                }
            }
        }
        .monospacedDigit()
    }
}

/// Limits as rings: Claude Code on top, Codex below.
private struct UsagePanel: View {
    @EnvironmentObject private var model: IslandModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.showClaude { ClaudeUsage() }
            if model.showClaude && model.showCodex { Divider().overlay(.white.opacity(0.08)) }
            if model.showCodex { CodexUsage() }
        }
        .padding(12)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
    }
}

private struct ProviderTitle: View {
    let kind: AgentKind
    let detail: String?

    var body: some View {
        HStack(spacing: 6) {
            AgentGlyph(kind: kind, size: 9)
                .frame(width: 14, height: 14)
            Text(kind.displayName).font(.system(size: 11, weight: .bold))
            Spacer(minLength: 0)
            if let detail { Text(detail).font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.45)).lineLimit(1) }
        }
    }
}

private struct ClaudeUsage: View {
    @EnvironmentObject private var model: IslandModel

    var body: some View {
        let usage = model.agents.usage
        VStack(alignment: .leading, spacing: 8) {
            ProviderTitle(kind: .claude, detail: usage.map { "Today \(Format.tokens($0.todayTokens))" })
            if let limits = model.agents.claudeLimits {
                HStack(spacing: 0) {
                    ForEach(limits.windows, id: \.windowMinutes) { window in
                        RingGauge(window: window, tint: AgentGlyph(kind: .claude).color).frame(maxWidth: .infinity)
                    }
                }
            } else if let limit = model.agents.claudeLimit {
                HStack(spacing: 10) {
                    Ring(fraction: 1, color: .red, size: 40) { Image(systemName: "hand.raised.fill").font(.system(size: 13)).foregroundStyle(.red) }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(limit.windowLabel) limit reached").font(.system(size: 11, weight: .semibold)).foregroundStyle(.red)
                        Text("Resets \(Format.until(limit.resetsAt))").font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
                    }
                }
            } else if let usage {
                HStack(spacing: 10) {
                    let fraction = usage.windowStart.map { min(1, Date().timeIntervalSince($0) / (5 * 3600)) } ?? 0
                    Ring(fraction: fraction, color: AgentGlyph(kind: .claude).color, size: 40) {
                        Text(Format.tokens(usage.windowTokens)).font(.system(size: 9, weight: .bold, design: .rounded)).minimumScaleFactor(0.6)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(usage.windowStart == nil ? "No use in 5 hours" : "Tokens this window").font(.system(size: 11, weight: .semibold))
                        Text(usage.windowEnd.map { "Window ends \(Format.until($0))" } ?? "\(usage.todayRequests) replies today")
                            .font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
                        Button { model.openSettings(.agents) } label: {
                            Text("Show limits in %").font(.system(size: 10, weight: .semibold)).foregroundStyle(AgentGlyph(kind: .claude).color)
                        }
                        .buttonStyle(PressableStyle())
                    }
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Counting…").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                }
            }
        }
    }
}

private struct CodexUsage: View {
    @EnvironmentObject private var model: IslandModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProviderTitle(kind: .codex, detail: nil)
            if let limits = model.agents.codexLimits, !limits.windows.isEmpty {
                HStack(spacing: 0) {
                    ForEach(limits.windows, id: \.windowMinutes) { window in
                        RingGauge(window: window, tint: AgentGlyph(kind: .codex).color).frame(maxWidth: .infinity)
                    }
                }
            } else {
                Text("No recent sessions").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
            }
        }
    }
}

private struct RingGauge: View {
    let window: RateLimitWindow
    let tint: Color

    var body: some View {
        let used = min(max(window.usedPercent, 0), 100)
        HStack(spacing: 7) {
            Ring(fraction: used / 100, color: color(used), size: 36) {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text("\(Int(used.rounded()))").font(.system(size: 11, weight: .bold, design: .rounded)).monospacedDigit()
                    Text("%").font(.system(size: 7, weight: .bold, design: .rounded))
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(window.windowMinutes == 300 ? "5 hours" : window.label).font(.system(size: 10, weight: .semibold))
                Text(window.resetsAt.map { Format.until($0) } ?? "Fresh").font(.system(size: 9)).foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
            }
        }
    }

    private func color(_ used: Double) -> Color {
        used >= 90 ? .red : used >= 70 ? .orange : tint
    }
}

struct Ring<Label: View>: View {
    let fraction: Double
    let color: Color
    var size: CGFloat = 40
    var lineWidth: CGFloat = 4.5
    @ViewBuilder var label: Label

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.18), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: CGFloat(min(max(fraction, 0), 1)))
                .stroke(AngularGradient(colors: [color.opacity(0.6), color], center: .center, startAngle: .degrees(0),
                                        endAngle: .degrees(360 * max(fraction, 0.01))),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: color.opacity(0.5), radius: 3)
            label
        }
        .frame(width: size, height: size)
        .animation(.spring(response: 0.6, dampingFraction: 0.8), value: fraction)
    }
}

// MARK: - Activity

private struct ActivityPage: View {
    var body: some View {
        Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                TimerTile()
                CalendarTile()
                BatteryTile()
            }
            GridRow {
                HeadphonesTile()
                MicrophoneTile()
                CameraTile()
            }
        }
    }
}

/// A Settings-style colored square with a white symbol.
struct IconBadge: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 20

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(LinearGradient(colors: [tint.opacity(0.95), tint.opacity(0.7)], startPoint: .top, endPoint: .bottom))
            .overlay(Image(systemName: symbol).font(.system(size: size * 0.5, weight: .bold)).foregroundStyle(.white))
            .frame(width: size, height: size)
    }
}

private struct Tile<Accessory: View, Content: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                IconBadge(symbol: symbol, tint: tint)
                Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                Spacer(minLength: 0)
                accessory
            }
            content
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
    }
}

extension Tile where Accessory == EmptyView {
    init(symbol: String, tint: Color, title: String, @ViewBuilder content: () -> Content) {
        self.init(symbol: symbol, tint: tint, title: title, accessory: { EmptyView() }, content: content)
    }
}

private struct TimerTile: View {
    @EnvironmentObject private var model: IslandModel

    var body: some View {
        Tile(symbol: "timer", tint: .orange, title: "Timer") {
            if model.timer != nil {
                HStack(spacing: 4) {
                    small(model.timer?.isPaused == true ? "play.fill" : "pause.fill") { model.toggleTimerPause() }
                    small("xmark") { model.cancelTimer() }
                }
            }
        } content: {
            if let timer = model.timer {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    HStack(spacing: 10) {
                        Ring(fraction: 1 - timer.progress(at: context.date), color: .orange, size: 42, lineWidth: 4) {
                            Image(systemName: timer.isPaused ? "pause.fill" : "hourglass").font(.system(size: 12, weight: .bold)).foregroundStyle(.orange)
                        }
                        Text(Format.clock(timer.remaining(at: context.date)))
                            .font(.system(size: 20, weight: .bold, design: .rounded)).monospacedDigit().foregroundStyle(.orange)
                            .minimumScaleFactor(0.7)
                    }
                }
            } else if model.timerFinished {
                Button { model.dismissTimerAlert() } label: {
                    Label("Time's up", systemImage: "bell.fill").font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(.orange)
                }
                .buttonStyle(PressableStyle())
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 5), GridItem(.flexible(), spacing: 5)], spacing: 5) {
                    ForEach([1.0, 5, 10, 25], id: \.self) { minutes in
                        Button { model.startTimer(minutes: minutes) } label: {
                            Text("\(Int(minutes)) min").font(.system(size: 11, weight: .semibold, design: .rounded))
                                .frame(maxWidth: .infinity, minHeight: 24)
                                .background(Capsule().fill(.orange.opacity(0.16)))
                                .foregroundStyle(.orange)
                                .contentShape(Capsule())
                        }
                        .buttonStyle(PressableStyle())
                    }
                }
            }
        }
    }

    private func small(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 9, weight: .bold))
                .frame(width: 20, height: 20).background(Circle().fill(.white.opacity(0.1))).contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
    }
}

private struct CalendarTile: View {
    @EnvironmentObject private var model: IslandModel

    var body: some View {
        Tile(symbol: "calendar", tint: .red, title: Date().formatted(.dateTime.weekday(.wide).day())) {
            let upcoming = Array(model.events.prefix(2))
            if upcoming.isEmpty {
                Text("No more events").font(.system(size: 13, weight: .semibold))
                Text("Enjoy the free time").font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(upcoming) { event in
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 1.5).fill(event.color.map(Color.init(cgColor:)) ?? .red).frame(width: 3)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(event.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                                TimelineView(.everyMinute) { context in
                                    Text(event.start > context.date
                                         ? "\(event.start.formatted(date: .omitted, time: .shortened)) · \(Format.until(event.start, from: context.date))"
                                         : "Now · until \(event.end.formatted(date: .omitted, time: .shortened))")
                                }
                                .font(.system(size: 10)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                            }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}

private struct BatteryTile: View {
    @EnvironmentObject private var model: IslandModel

    var body: some View {
        let battery = model.system.battery
        Tile(symbol: "bolt.fill", tint: .green, title: "Battery") {
            if let battery {
                HStack(alignment: .center, spacing: 10) {
                    Text("\(battery.percent)%").font(.system(size: 22, weight: .bold, design: .rounded)).monospacedDigit()
                    BatteryGlyph(percent: battery.percent, charging: battery.isCharging || battery.onPower, width: 34)
                }
                Text(detail(battery)).font(.system(size: 10)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
            } else {
                Text("Desktop power").font(.system(size: 13, weight: .semibold))
            }
        }
    }

    private func detail(_ battery: SystemMonitor.Battery) -> String {
        let time = battery.minutesRemaining.map { Format.span(TimeInterval($0 * 60)) }
        if battery.isCharging { return time.map { "Charging · full in \($0)" } ?? "Charging" }
        if battery.onPower { return "On power" }
        return time.map { "\($0) left" } ?? "On battery"
    }
}

private struct HeadphonesTile: View {
    @EnvironmentObject private var model: IslandModel

    var body: some View {
        let headphones = model.system.headphones
        Tile(symbol: headphones.map { HeadphoneSymbol.name(for: $0.name) } ?? "headphones", tint: .blue,
             title: headphones?.connected == true ? headphones!.name : "Headphones") {
            if let headphones, headphones.connected {
                HStack(spacing: 10) {
                    if let left = headphones.left { level("L", left) }
                    if let right = headphones.right { level("R", right) }
                    if let single = headphones.single { level("", single) }
                    if let caseLevel = headphones.caseLevel { level("Case", caseLevel) }
                    if headphones.summary == nil && headphones.caseLevel == nil {
                        Text("Connected").font(.system(size: 13, weight: .semibold))
                    }
                }
            } else {
                Text("Not connected").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.8))
                if let output = model.output {
                    Text("Sound: \(output.device)").font(.system(size: 10)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
                }
            }
        }
    }

    private func level(_ label: String, _ percent: Int) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(percent)%").font(.system(size: 13, weight: .bold, design: .rounded)).monospacedDigit()
                .foregroundStyle(percent <= 20 ? .red : .white)
            Capsule().fill(.white.opacity(0.15)).frame(width: 30, height: 3)
                .overlay(alignment: .leading) {
                    Capsule().fill(percent <= 20 ? Color.red : .green).frame(width: 30 * CGFloat(percent) / 100, height: 3)
                }
            if !label.isEmpty { Text(label).font(.system(size: 9, weight: .medium)).foregroundStyle(.white.opacity(0.45)) }
        }
    }
}

private struct MicrophoneTile: View {
    @EnvironmentObject private var model: IslandModel

    var body: some View {
        let call = model.system.call
        let apps = model.system.microphoneApps
        Tile(symbol: call != nil ? "phone.fill" : "mic.fill", tint: call != nil ? .green : .orange,
             title: call != nil ? "Call" : "Microphone") {
            if let call {
                Text(call.app).font(.system(size: 14, weight: .bold)).lineLimit(1)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(Format.clock(context.date.timeIntervalSince(call.since))).monospacedDigit()
                }
                .font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(.green)
            } else if let app = apps.first {
                HStack(spacing: 6) {
                    Circle().fill(.orange).frame(width: 7, height: 7)
                    Text(app).font(.system(size: 14, weight: .bold)).lineLimit(1)
                }
                Text(apps.count > 1 ? "+\(apps.count - 1) more listening" : "Listening now")
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
            } else {
                Text("Off").font(.system(size: 14, weight: .bold)).foregroundStyle(.white.opacity(0.8))
                Text("No app is listening").font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
            }
        }
    }
}

private struct CameraTile: View {
    @EnvironmentObject private var model: IslandModel

    var body: some View {
        Tile(symbol: "video.fill", tint: model.system.cameraOn ? .green : .gray, title: "Camera") {
            if model.system.cameraOn {
                HStack(spacing: 6) {
                    Circle().fill(.green).frame(width: 7, height: 7)
                    Text("In use").font(.system(size: 14, weight: .bold))
                }
                Text("An app is using the camera").font(.system(size: 10)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
            } else {
                Text("Off").font(.system(size: 14, weight: .bold)).foregroundStyle(.white.opacity(0.8))
                Text("Nothing is watching").font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
            }
        }
    }
}

// MARK: - Shared

/// App icons and names, looked up once.
@MainActor
enum AppInfo {
    private static var icons: [String: NSImage] = [:]
    private static var names: [String: String] = [:]

    static func icon(_ bundleIdentifier: String?) -> NSImage? {
        guard let bundleIdentifier else { return nil }
        if let icon = icons[bundleIdentifier] { return icon }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icons[bundleIdentifier] = icon
        return icon
    }

    static func name(_ bundleIdentifier: String?) -> String? {
        guard let bundleIdentifier else { return nil }
        if let name = names[bundleIdentifier] { return name }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else { return nil }
        let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        names[bundleIdentifier] = name
        return name
    }
}

/// Plain buttons that dip slightly when pressed.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: configuration.isPressed)
    }
}
