import LiveIslandCore
import SwiftUI

private let islandSpring = Animation.spring(response: 0.42, dampingFraction: 0.8)

/// The island: a black shape growing out of the notch, with compact wings beside it or the
/// full panel below it.
struct IslandView: View {
    @EnvironmentObject private var model: IslandModel
    let layout: IslandLayout

    var body: some View {
        let primary = model.primary
        let size = layout.size(expanded: model.isExpanded, active: primary != nil)
        let shape = IslandShape(bottomRadius: model.isExpanded ? 32 : (primary != nil ? 14 : 10),
                                topRadius: model.isExpanded ? 12 : 6)
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                shape.fill(Color.black)
                Group {
                    if model.isExpanded {
                        ExpandedIsland(layout: layout)
                            .transition(.blurReplace.combined(with: .opacity))
                    } else if let primary {
                        CompactIsland(activity: primary, layout: layout)
                            .id(CompactIsland.identity(of: primary))
                            .transition(.blurReplace.combined(with: .opacity))
                    }
                }
                .frame(width: size.width, height: size.height, alignment: .top)
            }
            .frame(width: size.width, height: size.height)
            .clipShape(shape)
            .contentShape(shape)
            .onTapGesture { if !model.isExpanded { model.expand() } }
            .shadow(color: .black.opacity(model.isExpanded ? 0.5 : 0), radius: 22, y: 12)
            Spacer(minLength: 0)
        }
        .frame(width: IslandLayout.canvas.width, height: IslandLayout.canvas.height, alignment: .top)
        .animation(islandSpring, value: model.isExpanded)
        .animation(islandSpring, value: primary.map(CompactIsland.identity(of:)))
        .environment(\.colorScheme, .dark)
    }
}

/// Top corners curve outward into the menu bar, like the notch itself; bottom corners round in.
struct IslandShape: Shape {
    var bottomRadius: CGFloat
    var topRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(bottomRadius, topRadius) }
        set { (bottomRadius, topRadius) = (newValue.first, newValue.second) }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard rect.height > 0, rect.width > 0 else { return path }
        let top = min(topRadius, rect.width / 4, rect.height / 2)
        let bottom = min(bottomRadius, (rect.width - 2 * top) / 2, rect.height - top)
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.minX + top, y: rect.minY + top), control: CGPoint(x: rect.minX + top, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + top, y: rect.maxY - bottom))
        path.addQuadCurve(to: CGPoint(x: rect.minX + top + bottom, y: rect.maxY), control: CGPoint(x: rect.minX + top, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - top - bottom, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - top, y: rect.maxY - bottom), control: CGPoint(x: rect.maxX - top, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - top, y: rect.minY + top))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.maxX - top, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

// MARK: - Compact

/// Two small wings beside the notch: an icon on the left, a detail on the right.
struct CompactIsland: View {
    @EnvironmentObject private var model: IslandModel
    let activity: IslandActivity
    let layout: IslandLayout

    var body: some View {
        let split = sharesWithMusic
        HStack(spacing: 0) {
            Group {
                if split {
                    HStack(spacing: 7) {
                        leading
                        status.minimumScaleFactor(0.7)
                    }
                    .transition(.blurReplace.combined(with: .opacity))
                } else {
                    leading
                }
            }
            .frame(width: IslandLayout.wingWidth - 14, height: layout.notch.height, alignment: .leading)
            .padding(.leading, 14)
            Spacer(minLength: layout.notch.width)
            Group {
                if split {
                    Waveform(meter: model.levels, style: .compact,
                             color: model.artwork(for: model.compactPlayer)?.accent ?? .pink, playing: true)
                        .transition(.blurReplace.combined(with: .opacity))
                } else {
                    trailing
                }
            }
            .frame(width: IslandLayout.wingWidth - 14, height: layout.notch.height, alignment: .trailing)
            .padding(.trailing, 14)
        }
        .font(.system(size: 12, weight: .semibold, design: .rounded))
        .lineLimit(1)
        .animation(.spring(response: 0.42, dampingFraction: 0.8), value: split)
    }

    /// Music playing behind an agent or a timer: like the iPhone's island with two things going
    /// on, the activity takes the left wing and the music's waveform the right one.
    private var sharesWithMusic: Bool {
        guard model.musicPlaying else { return false }
        switch activity {
        case .agentWorking, .agentDone, .agentNeedsYou, .timer: return true
        default: return false
        }
    }

    /// The activity's detail, short enough to sit beside its icon in the left wing.
    @ViewBuilder private var status: some View {
        switch activity {
        case .agentDone:
            Image(systemName: "checkmark").font(.system(size: 12, weight: .heavy)).foregroundStyle(.green)
        case .agentNeedsYou:
            Image(systemName: "hand.raised.fill").foregroundStyle(.yellow).symbolEffect(.pulse)
        default:
            trailing
        }
    }

    /// Changes in detail (a clock ticking) keep the identity; a different activity animates in.
    static func identity(of activity: IslandActivity) -> String {
        switch activity {
        case .call: return "call"
        case .timerFinished: return "timerFinished"
        case .timer: return "timer"
        case .agentNeedsYou(let kind, let project): return "needs-\(kind)-\(project)"
        case .agentDone(let kind, let project): return "done-\(kind)-\(project)"
        case .accountLimit(let account, _): return "limit-\(account)"
        case .agentWorking(let kind, let project, _): return "working-\(kind)-\(project)"
        case .headphonesConnected: return "headphones"
        case .charging: return "charging"
        case .eventSoon(let title, _): return "event-\(title)"
        case .cameraOn: return "camera"
        case .microphoneOn: return "microphone"
        case .nowPlaying(let title, let playing): return "media-\(title)-\(playing)"
        }
    }

    @ViewBuilder private var leading: some View {
        switch activity {
        case .call:
            Image(systemName: "phone.fill").foregroundStyle(.green).symbolEffect(.pulse)
        case .timerFinished:
            Image(systemName: "bell.fill").foregroundStyle(.orange).symbolEffect(.pulse)
        case .timer:
            TimerRing(size: 18)
        case .agentNeedsYou(let kind, _), .agentDone(let kind, _):
            AgentGlyph(kind: kind, size: 15)
        case .accountLimit:
            Image(systemName: "person.crop.circle.badge.exclamationmark.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .orange)
        case .agentWorking(let kind, _, _):
            AgentGlyph(kind: kind, size: 15, spinning: true)
        case .headphonesConnected(let name, _):
            Image(systemName: HeadphoneSymbol.name(for: name)).foregroundStyle(.white)
        case .charging:
            Image(systemName: "bolt.fill").foregroundStyle(.green).symbolEffect(.pulse)
        case .eventSoon:
            Image(systemName: "calendar").foregroundStyle(.red)
        case .cameraOn:
            Image(systemName: "video.fill").foregroundStyle(.green)
        case .microphoneOn:
            Image(systemName: "mic.fill").foregroundStyle(.orange)
        case .nowPlaying:
            Artwork(image: model.artwork(for: model.compactPlayer)?.image, size: layout.notch.height - 10, corner: 7)
        }
    }

    @ViewBuilder private var trailing: some View {
        switch activity {
        case .call(_, let since):
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(Format.clock(context.date.timeIntervalSince(since))).foregroundStyle(.green).monospacedDigit()
            }
        case .timerFinished:
            Text("Done").foregroundStyle(.orange)
        case .timer(let endsAt):
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(Format.clock(model.timer?.remaining(at: context.date) ?? endsAt.timeIntervalSince(context.date)))
                    .foregroundStyle(.orange).monospacedDigit()
            }
        case .agentNeedsYou:
            Text("Needs you").foregroundStyle(.yellow)
        case .accountLimit:
            Text("Switch").foregroundStyle(.orange)
        case .agentDone:
            Label("Done", systemImage: "checkmark").labelStyle(.titleAndIcon).foregroundStyle(.green)
        case .agentWorking(_, _, let since):
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(Format.span(context.date.timeIntervalSince(since))).foregroundStyle(.white.opacity(0.8)).monospacedDigit()
            }
        case .headphonesConnected(_, let battery):
            if let battery {
                BatteryBadge(percent: battery)
            } else {
                Text("Connected").foregroundStyle(.white.opacity(0.8))
            }
        case .charging(let percent):
            Text("\(percent)%").foregroundStyle(.green).monospacedDigit()
        case .eventSoon(_, let startsAt):
            TimelineView(.periodic(from: .now, by: 15)) { context in
                Text(Format.until(startsAt, from: context.date)).foregroundStyle(.red)
            }
        case .cameraOn:
            Circle().fill(.green).frame(width: 7, height: 7)
        case .microphoneOn(let app):
            Text(app).foregroundStyle(.orange)
        case .nowPlaying(_, let playing):
            Waveform(meter: model.levels, style: .compact,
                     color: model.artwork(for: model.compactPlayer)?.accent ?? .pink, playing: playing)
        }
    }
}

// MARK: - Shared pieces

struct AgentGlyph: View {
    let kind: AgentKind
    var size: CGFloat = 14
    var spinning = false

    var body: some View {
        ZStack {
            Image(systemName: kind == .claude ? "sparkle" : "terminal.fill")
                .font(.system(size: size, weight: .bold))
                .foregroundStyle(color)
            if spinning {
                // A system spinner is drawn by Core Animation: smooth, and nearly free on the CPU.
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                    .tint(color)
                    .scaleEffect((size + 12) / 20)
                    .opacity(0.9)
            }
        }
        .frame(width: size + 10, height: size + 10)
    }

    var color: Color {
        kind == .claude ? Color(red: 0.85, green: 0.47, blue: 0.34) : Color(red: 0.45, green: 0.8, blue: 1)
    }
}

struct Artwork: View {
    let image: NSImage?
    let size: CGFloat
    let corner: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    LinearGradient(colors: [.pink, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "music.note").font(.system(size: size * 0.45, weight: .semibold)).foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }
}

struct BatteryBadge: View {
    let percent: Int

    var body: some View {
        HStack(spacing: 4) {
            ZStack {
                Circle().stroke(.white.opacity(0.2), lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: CGFloat(percent) / 100)
                    .stroke(percent <= 20 ? Color.red : .green, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 14, height: 14)
            Text("\(percent)%").monospacedDigit()
        }
        .foregroundStyle(.white)
    }
}

struct TimerRing: View {
    @EnvironmentObject private var model: IslandModel
    let size: CGFloat

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            ZStack {
                Circle().stroke(.orange.opacity(0.25), lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: 1 - (model.timer?.progress(at: context.date) ?? 1))
                    .stroke(.orange, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: size, height: size)
        }
    }
}

enum HeadphoneSymbol {
    static func name(for device: String) -> String {
        let name = device.lowercased()
        if name.contains("max") { return "airpodsmax" }
        if name.contains("pro") { return "airpodspro" }
        if name.contains("airpods") { return "airpods" }
        if name.contains("beats") { return "beats.headphones" }
        return "headphones"
    }
}
