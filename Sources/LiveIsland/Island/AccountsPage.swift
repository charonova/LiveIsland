import LiveIslandCore
import SwiftUI

/// Every Claude and Codex account used on this Mac, with its 5-hour and weekly limits, and a
/// Switch button when switching is set up.
struct AccountsPage: View {
    @EnvironmentObject private var model: IslandModel

    var body: some View {
        let state = model.accountsState
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                KindPicker()
                Spacer(minLength: 6)
                if let message = state.message {
                    Label(message, systemImage: state.messageIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(state.messageIsError ? Color.orange : .green)
                        .lineLimit(1)
                        .transition(.opacity)
                }
                Button { model.openSettings(model.accountsKind == .claude ? .accounts : .agents) } label: {
                    Image(systemName: "slider.horizontal.3").font(.system(size: 11, weight: .semibold))
                        .frame(width: 24, height: 24).background(Circle().fill(.white.opacity(0.08))).contentShape(Circle())
                }
                .buttonStyle(PressableStyle())
                .help("Account settings")
            }
            if state.accounts.isEmpty && state.codexAccounts.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "person.2.fill").font(.system(size: 26)).foregroundStyle(.white.opacity(0.35))
                    Text("No accounts yet").font(.system(size: 13, weight: .semibold))
                    Text("Use Claude Code or Codex once and the account shows up here. Log in to more with /login or codex login.")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let codex = model.accountsKind == .codex
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        if codex {
                            SectionHeader(kind: .codex, detail: model.codexSwitching ? "Switch with LiveIsland" : "Switching off",
                                          on: model.codexSwitching)
                            if state.codexAccounts.isEmpty {
                                Text("Use Codex once and its account shows up here. Log in to more with codex login.")
                                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).padding(.top, 8)
                            }
                            ForEach(state.codexAccounts) { account in
                                AccountRow(account: account, isBest: account.id == model.bestCodexAccount?.id)
                            }
                        } else {
                            ClaudeSwapHeader(swap: model.claudeSwap)
                            ForEach(state.accounts) { account in
                                AccountRow(account: account, isBest: account.id == model.bestAccount?.id)
                            }
                        }
                    }
                }
                .scrollIndicators(.never)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: state.message)
    }
}

/// Claude Code or Codex, with how many accounts each has.
private struct KindPicker: View {
    @EnvironmentObject private var model: IslandModel

    var body: some View {
        HStack(spacing: 2) {
            ForEach([AgentKind.claude, .codex], id: \.self) { kind in
                let selected = model.accountsKind == kind
                let count = kind == .claude ? model.accounts.count : model.codexAccounts.count
                Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { model.accountsKind = kind } } label: {
                    HStack(spacing: 5) {
                        AgentGlyph(kind: kind, size: 8).frame(width: 12, height: 12)
                        Text(kind.displayName).font(.system(size: 11, weight: .semibold))
                        Text("\(count)").font(.system(size: 10, weight: .bold, design: .rounded)).foregroundStyle(.white.opacity(0.5))
                    }
                    .padding(.horizontal, 9)
                    .frame(height: 24)
                    .background(Capsule().fill(.white.opacity(selected ? 0.16 : 0)))
                    .foregroundStyle(selected ? Color.white : .white.opacity(0.55))
                    .contentShape(Capsule())
                }
                .buttonStyle(PressableStyle())
            }
        }
        .padding(2)
        .background(Capsule().fill(.white.opacity(0.06)))
    }
}

/// Claude accounts are switched by claude-swap: whether it's there, and its automatic
/// switching, one tap away.
private struct ClaudeSwapHeader: View {
    @EnvironmentObject private var model: IslandModel
    @ObservedObject var swap: ClaudeSwapController

    var body: some View {
        HStack(spacing: 6) {
            if swap.executable == nil {
                Button { model.openSettings(.accounts) } label: {
                    Label("Set up claude-swap", systemImage: "arrow.left.arrow.right").font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 8).frame(height: 20).background(Capsule().fill(Color.purple.opacity(0.3)))
                }
                .buttonStyle(PressableStyle())
                .help("claude-swap switches your Claude accounts: install it in Settings › Accounts")
            } else {
                Chip(text: "claude-swap", color: .purple)
                Button { swap.autoSwitch.toggle() } label: {
                    HStack(spacing: 4) {
                        Circle().fill(running ? Color.green : .white.opacity(0.3)).frame(width: 6, height: 6)
                        Text(swap.autoSwitch ? "Auto" : "Auto off").font(.system(size: 10, weight: .semibold, design: .rounded))
                    }
                    .padding(.horizontal, 8).frame(height: 18)
                    .background(Capsule().fill((swap.autoSwitch ? Color.green : .white).opacity(swap.autoSwitch ? 0.18 : 0.08)))
                    .foregroundStyle(swap.autoSwitch ? Color.green : .white.opacity(0.6))
                }
                .buttonStyle(PressableStyle())
                .help(swap.autoSwitch ? "claude-swap switches before an account runs out. Tap to turn off." : "Let claude-swap switch before an account runs out")
                Button { model.openSettings(.accounts, anchor: "console") } label: {
                    Image(systemName: "terminal").font(.system(size: 9, weight: .bold))
                        .frame(width: 20, height: 18).background(Capsule().fill(.white.opacity(0.08)))
                        .foregroundStyle(.white.opacity(0.65))
                }
                .buttonStyle(PressableStyle())
                .help("claude-swap's console: every command and its output")
                if let last = swap.lastEvent, swap.autoSwitch {
                    Text(last.summary).font(.system(size: 9.5)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var running: Bool {
        if case .running = swap.auto { return true }
        return false
    }
}

private struct SectionHeader: View {
    let kind: AgentKind
    let detail: String
    let on: Bool

    var body: some View {
        HStack(spacing: 6) {
            Chip(text: detail, color: on ? .orange : .gray)
            Spacer(minLength: 0)
        }
    }
}

private struct AccountRow: View {
    @EnvironmentObject private var model: IslandModel
    let account: ClaudeAccount
    let isBest: Bool

    var body: some View {
        HStack(spacing: 10) {
            AccountAvatar(identity: account.identity, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(account.identity.displayName).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    if let plan = account.identity.plan {
                        Text(plan).font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(0.6))
                            .padding(.horizontal, 5).frame(height: 15).background(Capsule().fill(.white.opacity(0.1)))
                    }
                }
                Text(account.identity.email).font(.system(size: 10)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
            }
            .frame(width: 168, alignment: .leading)
            LimitMeter(label: "5 hours", window: account.fiveHour)
            LimitMeter(label: "Week", window: account.sevenDay)
            Spacer(minLength: 4)
            action
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(account.isActive ? 0.1 : 0.05)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(border, lineWidth: account.isActive || isBest ? 1 : 0.5))
    }

    private var border: Color {
        if account.isActive { return account.isAtLimit ? .orange.opacity(0.6) : .green.opacity(0.4) }
        return isBest ? .orange.opacity(0.45) : .white.opacity(0.07)
    }

    @ViewBuilder private var action: some View {
        if account.isActive {
            Chip(text: account.isAtLimit ? "Out of room" : "In use", color: account.isAtLimit ? .orange : .green)
        } else if model.accountsState.switching == account.id {
            ProgressView().controlSize(.small).frame(width: 64)
        } else if account.needsLogin {
            Chip(text: "Sign in again", color: .orange)
                .help("Log in to \(account.identity.email) once with \(account.kind == .codex ? "codex login" : "/login in Claude Code")")
        } else if account.switcher != nil {
            Button { model.switchAccount(account) } label: {
                Text(isBest ? "Switch ★" : "Switch").font(.system(size: 11, weight: .semibold)).padding(.horizontal, 10).frame(height: 26)
                    .contentShape(Capsule())
            }
            .buttonStyle(PressableStyle())
            .liquidGlass(in: Capsule(), tint: isBest ? Color.orange.opacity(0.35) : nil, interactive: true)
            .disabled(model.accountsState.switching != nil)
            .help(isBest ? "The account with the most room" : "Use this account in \(account.kind.displayName)")
        } else if account.kind == .codex ? model.codexSwitching : model.accountsState.claudeSwapInstalled {
            Text(account.kind == .codex ? "Not saved" : "Not in claude-swap").font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.4))
                .help(account.kind == .codex ? "Log in to it once with codex login so LiveIsland can switch to it" : "Add it in Settings › Accounts")
        }
    }
}

/// One limit as a thin bar, its percentage and when it resets.
struct LimitMeter: View {
    let label: String
    let window: RateLimitWindow?
    var width: CGFloat = 108

    var body: some View {
        let used = window.map { min(max($0.usedPercent, 0), 100) }
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(label).font(.system(size: 9, weight: .semibold)).foregroundStyle(.white.opacity(0.5))
                Spacer(minLength: 0)
                Text(used.map { "\(Int($0.rounded()))%" } ?? "—").font(.system(size: 10, weight: .bold, design: .rounded)).monospacedDigit()
            }
            Capsule().fill(.white.opacity(0.12)).frame(height: 4)
                .overlay(alignment: .leading) {
                    Capsule().fill(color(used ?? 0)).frame(width: width * CGFloat((used ?? 0) / 100), height: 4)
                }
            Text(window?.resetsAt.map { "resets \(Format.until($0))" } ?? (used == nil ? "not seen yet" : "fresh"))
                .font(.system(size: 9)).foregroundStyle(.white.opacity(0.4)).lineLimit(1)
        }
        .frame(width: width)
    }

    private func color(_ used: Double) -> Color {
        used >= 90 ? .red : used >= 70 ? .orange : .green
    }
}

/// Initials on a color picked from the email, so each account keeps its color.
struct AccountAvatar: View {
    let identity: ClaudeAccountIdentity
    var size: CGFloat = 30

    var body: some View {
        let hue = Double(identity.email.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }) / 65_535
        Circle()
            .fill(LinearGradient(colors: [Color(hue: hue, saturation: 0.55, brightness: 0.95), Color(hue: hue, saturation: 0.7, brightness: 0.65)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(Text(initials).font(.system(size: size * 0.38, weight: .bold, design: .rounded)).foregroundStyle(.white))
            .frame(width: size, height: size)
    }

    private var initials: String {
        let words = identity.displayName.split(whereSeparator: { $0 == " " || $0 == "." || $0 == "@" })
        return String(words.prefix(2).compactMap(\.first)).uppercased()
    }
}
