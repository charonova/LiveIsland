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
