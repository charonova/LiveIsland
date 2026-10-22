import LiveIslandCore
import SwiftUI

/// Every Claude account used on this Mac, with its 5-hour and weekly limits, and a Switch
/// button when switching is set up.
struct AccountsPage: View {
    @EnvironmentObject private var model: IslandModel

    var body: some View {
        let state = model.accountsState
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Claude accounts").font(.system(size: 12, weight: .bold))
                Chip(text: model.accountSwitching == .off ? "Switching off" : "Switch with \(model.accountSwitching.title)",
                     color: model.accountSwitching == .off ? .gray : .orange)
                Spacer(minLength: 6)
                if let message = state.message {
                    Label(message, systemImage: state.messageIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(state.messageIsError ? Color.orange : .green)
                        .lineLimit(1)
                        .transition(.opacity)
                }
                Button { model.openSettings(.agents) } label: {
                    Image(systemName: "slider.horizontal.3").font(.system(size: 11, weight: .semibold))
                        .frame(width: 24, height: 24).background(Circle().fill(.white.opacity(0.08))).contentShape(Circle())
                }
                .buttonStyle(PressableStyle())
                .help("Account settings")
            }
            if state.accounts.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "person.2.fill").font(.system(size: 26)).foregroundStyle(.white.opacity(0.35))
                    Text("No accounts yet").font(.system(size: 13, weight: .semibold))
                    Text("Use Claude Code once and its account shows up here. Log in to more with /login.")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(state.accounts) { account in
                            AccountRow(account: account, isBest: account.id == model.bestAccount?.id)
                        }
                    }
                }
                .scrollIndicators(.never)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: state.message)
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
            Chip(text: "Sign in again", color: .orange).help("Log in to \(account.identity.email) once with /login in Claude Code")
        } else if account.switcher != nil {
            Button { model.switchAccount(account) } label: {
                Text(isBest ? "Switch ★" : "Switch").font(.system(size: 11, weight: .semibold)).padding(.horizontal, 10).frame(height: 26)
                    .contentShape(Capsule())
            }
            .buttonStyle(PressableStyle())
            .liquidGlass(in: Capsule(), tint: isBest ? Color.orange.opacity(0.35) : nil, interactive: true)
            .disabled(model.accountsState.switching != nil)
            .help(isBest ? "The account with the most room" : "Use this account in Claude Code")
        } else if model.accountSwitching != .off {
            Text("Not saved").font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.4))
                .help("Log in to it once with /login so LiveIsland can switch to it")
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
