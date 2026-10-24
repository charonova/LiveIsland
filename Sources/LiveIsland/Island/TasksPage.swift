import AppKit
import LiveIslandCore
import SwiftUI

/// Tasks in the island: each task's state, why, and what happens next, with its controls; and
/// beside them, the accounts tasks can use. Starting a task and adding accounts happen in
/// Settings › Tasks.
struct TasksPage: View {
    @EnvironmentObject private var model: IslandModel

    var body: some View {
        TasksPageContent(runner: model.taskRunner, profiles: model.profileStore)
    }
}

private struct TasksPageContent: View {
    @EnvironmentObject private var model: IslandModel
    @ObservedObject var runner: TaskRunner
    @ObservedObject var profiles: ProfileStore

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                header
                if runner.tasks.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "checklist").font(.system(size: 26)).foregroundStyle(.green.opacity(0.7))
                        Text("No tasks yet").font(.system(size: 13, weight: .semibold))
                        Text("Start a Claude Code task in Settings and leave: it keeps going after a usage limit.")
                            .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).multilineTextAlignment(.center)
                        Button("New Task") { model.openSettings(.tasks) }.buttonStyle(IslandPillStyle(prominent: true))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(spacing: 6) {
                            ForEach(runner.tasks) { task in
                                IslandTaskRow(runner: runner, profiles: profiles, task: task)
                            }
                        }
                    }
                    .scrollIndicators(.never)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            TaskAccountsPanel(profiles: profiles).frame(width: 200)
        }
    }

    private var header: some View {
        let going = runner.tasks.filter { $0.state == .running || $0.state == .waiting }.count
        let needYou = runner.tasks.filter { $0.state == .needsYou }.count
        return HStack(spacing: 6) {
            Text("Tasks").font(.system(size: 12, weight: .bold))
            if going > 0 { Chip(text: "\(going) going", color: .green) }
            if needYou > 0 { Chip(text: "\(needYou) need\(needYou == 1 ? "s" : "") you", color: .yellow) }
            Spacer()
            if !runner.tasks.isEmpty {
                Button { model.openSettings(.tasks) } label: {
                    Label("New", systemImage: "plus").font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(IslandPillStyle(prominent: false))
                .help("Start a task in Settings")
            }
        }
    }
}

/// A task: its state at a glance, what it does, where it stands, and its controls.
private struct IslandTaskRow: View {
    @ObservedObject var runner: TaskRunner
    @ObservedObject var profiles: ProfileStore
    let task: AutomationTask

    var body: some View {
        HStack(spacing: 9) {
            StateMark(state: task.state)
            VStack(alignment: .leading, spacing: 2) {
                Text(task.objective).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text(place).font(.system(size: 10)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
                Text(status).font(.system(size: 10, weight: .medium)).foregroundStyle(StateMark.color(task.state).opacity(0.9)).lineLimit(1)
            }
            Spacer(minLength: 4)
            controls
        }
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(task.isSettled ? 0.04 : 0.07)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.07), lineWidth: 0.5))
    }

    private var place: String {
        var parts = [(task.folder as NSString).lastPathComponent, profiles.name(of: task.profileID)]
        if task.attempts.count > 1 { parts.append("run \(task.attempts.count)") }
        return parts.joined(separator: " · ")
    }

    private var status: String {
        if task.state == .waiting, let next = task.nextAttemptAt {
            return "\(task.reason) · \(TaskTime.short(next))"
        }
        return task.reason
    }

    @ViewBuilder private var controls: some View {
        HStack(spacing: 4) {
            switch task.state {
            case .running:
                IconButton(symbol: "pause.fill", help: "Pause") { runner.pause(task.id) }
                switchMenu
                IconButton(symbol: "xmark", help: "Cancel") { runner.cancel(task.id) }
            case .waiting:
                IconButton(symbol: "play.fill", help: "Continue now") { runner.resume(task.id) }
                switchMenu
                IconButton(symbol: "xmark", help: "Cancel") { runner.cancel(task.id) }
            case .paused, .needsYou:
                IconButton(symbol: "play.fill", help: "Resume") { runner.resume(task.id) }
                switchMenu
                IconButton(symbol: "xmark", help: "Cancel") { runner.cancel(task.id) }
            case .done, .cancelled:
                IconButton(symbol: "folder", help: "Show the folder") { NSWorkspace.shared.open(URL(fileURLWithPath: task.folder)) }
                IconButton(symbol: "trash", help: "Remove") { runner.remove(task.id) }
            }
        }
    }

    private var switchMenu: some View {
        Menu {
            ForEach(profiles.profiles.filter { $0.id != task.profileID }) { profile in
                Button(profile.name) { runner.switchAccount(task.id, to: profile.id) }
            }
        } label: {
            Image(systemName: "arrow.left.arrow.right").font(.system(size: 10, weight: .bold))
                .frame(width: 24, height: 24).background(Circle().fill(.white.opacity(0.1)))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Switch account")
    }
}

/// The task's state as a small mark: a spinner while it runs.
private struct StateMark: View {
    let state: AutomationTask.State

    static func color(_ state: AutomationTask.State) -> Color {
        switch state {
        case .running: return .green
        case .waiting: return .orange
        case .needsYou: return .yellow
        case .paused, .cancelled: return .white.opacity(0.5)
        case .done: return .green
        }
    }

    var body: some View {
        let color = Self.color(state)
        ZStack {
            Circle().fill(color.opacity(0.16))
            switch state {
            case .running:
                ProgressView().controlSize(.small).tint(color).scaleEffect(0.7)
            case .waiting:
                Image(systemName: "hourglass").font(.system(size: 12, weight: .bold)).foregroundStyle(color)
            case .needsYou:
                Image(systemName: "hand.raised.fill").font(.system(size: 12, weight: .bold)).foregroundStyle(color)
            case .paused:
                Image(systemName: "pause.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(color)
            case .done:
                Image(systemName: "checkmark").font(.system(size: 12, weight: .heavy)).foregroundStyle(color)
            case .cancelled:
                Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(color)
            }
        }
        .frame(width: 30, height: 30)
    }
}

/// The accounts tasks can use, in their order, and the two switches.
private struct TaskAccountsPanel: View {
    @EnvironmentObject private var model: IslandModel
    @ObservedObject var profiles: ProfileStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Accounts").font(.system(size: 12, weight: .bold))
                Spacer()
                Button { model.openSettings(.tasks) } label: {
                    Image(systemName: "slider.horizontal.3").font(.system(size: 10, weight: .semibold))
                        .frame(width: 22, height: 22).background(Circle().fill(.white.opacity(0.08))).contentShape(Circle())
                }
                .buttonStyle(PressableStyle())
                .help("Task settings")
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(profiles.profiles.enumerated()), id: \.element.id) { index, profile in
                    HStack(spacing: 7) {
                        Text("\(index + 1)").font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.5)).frame(width: 15, height: 15)
                            .background(Circle().fill(.white.opacity(0.08)))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(profile.name).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                            Text(state(of: profile)).font(.system(size: 9.5)).foregroundStyle(color(of: profile)).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .opacity(profile.enabled ? 1 : 0.45)
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 4) {
                SwitchLine(on: model.keepTasksGoing, text: "Continue after a limit")
                SwitchLine(on: model.keepTasksGoing && model.switchAccountsForTasks, text: "Use my other accounts")
            }
        }
        .padding(12)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
    }

    private func state(of profile: ClaudeProfile) -> String {
        if !profile.enabled { return "Off for tasks" }
        if profile.unusable != nil { return "Sign in needed" }
        if let until = profile.exhaustedUntil, until > Date() { return "Out until \(TaskTime.short(until))" }
        if !AccountRotation.isAvailable(profile, at: Date()) { return "Out · reset not reported" }
        return "Ready"
    }

    private func color(of profile: ClaudeProfile) -> Color {
        if profile.unusable != nil { return .red }
        if profile.enabled && !AccountRotation.isAvailable(profile, at: Date()) { return .orange }
        return .white.opacity(0.5)
    }
}

private struct SwitchLine: View {
    let on: Bool
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(on ? Color.green : .white.opacity(0.25)).frame(width: 6, height: 6)
            Text(text).font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(on ? 0.8 : 0.45))
        }
    }
}

private struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10, weight: .bold))
                .frame(width: 24, height: 24).background(Circle().fill(.white.opacity(0.1))).contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
        .help(help)
    }
}

/// A small capsule button for the island.
private struct IslandPillStyle: ButtonStyle {
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(Capsule().fill(prominent ? Color.green.opacity(0.35) : .white.opacity(0.1)))
            .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// A dot on the Tasks tab: yellow when a task needs you, green while one is going.
struct TasksTabBadge: View {
    @ObservedObject var runner: TaskRunner

    var body: some View {
        if runner.tasks.contains(where: { $0.state == .needsYou }) {
            Circle().fill(.yellow).frame(width: 6, height: 6).offset(x: -2, y: 3)
        } else if runner.tasks.contains(where: { $0.state == .running || $0.state == .waiting }) {
            Circle().fill(.green).frame(width: 6, height: 6).offset(x: -2, y: 3)
        }
    }
}

/// Green while tasks go, amber when one waits on a reset or on you.
struct TasksGlow: View {
    @ObservedObject var runner: TaskRunner

    var body: some View {
        let held = runner.tasks.contains { $0.state == .waiting || $0.state == .needsYou }
        ZStack {
            RadialGradient(colors: [(held ? Color.orange : .green).opacity(0.28), .clear], center: UnitPoint(x: 0.1, y: 0.8), startRadius: 0, endRadius: 320)
            RadialGradient(colors: [Color.teal.opacity(0.24), .clear], center: UnitPoint(x: 0.9, y: 0.9), startRadius: 0, endRadius: 300)
            RadialGradient(colors: [AgentGlyph(kind: .claude).color.opacity(0.2), .clear], center: UnitPoint(x: 0.5, y: 0.1), startRadius: 0, endRadius: 260)
            LinearGradient(colors: [.black.opacity(0.15), .black.opacity(0.45)], startPoint: .top, endPoint: .bottom)
        }
        .animation(.easeInOut(duration: 0.8), value: held)
    }
}
