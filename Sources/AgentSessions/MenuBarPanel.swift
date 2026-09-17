import SwiftUI

/// Compact popover for the menu bar item: current context load plus the few
/// most recent sessions, each one click away from a resume command.
struct MenuBarPanel: View {
    @EnvironmentObject private var store: SessionStore
    @Environment(\.openWindow) private var openWindow

    private static let recentCount = 5

    private var recent: [ClaudeSession] {
        Array(store.sessions.prefix(Self.recentCount))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if !store.todayUsage.isEmpty {
                Divider()
                todaySection
            }

            if let usage = store.latestUsage {
                Divider()
                contextSection(usage)
            }

            Divider()

            if recent.isEmpty {
                Text("No sessions yet")
                    .font(Theme.monoFont(11))
                    .foregroundStyle(Theme.textGhost)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    Text("RECENT")
                        .font(Theme.monoFont(9, .bold))
                        .foregroundStyle(Theme.textGhost)
                        .tracking(0.7)
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                        .padding(.bottom, 4)

                    ForEach(recent) { session in
                        RecentRow(
                            session: session,
                            isActive: store.activeSessionIds.contains(session.id)
                        )
                    }
                }
            }

            Divider()
            footer
        }
        .frame(width: 290)
        .background(Theme.bg)
    }

    // MARK: Sections

    /// Which coding agent these sessions belong to. Only Claude Code is read
    /// today; Codex and Cursor would each add a row here.
    private var header: some View {
        HStack(spacing: 8) {
            StackMark()
                .foregroundStyle(Theme.brand)
                .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text("Agent Sessions")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text("\(store.sessions.count) from Claude Code")
                    .font(Theme.monoFont(9))
                    .foregroundStyle(Theme.textGhost)
            }

            Spacer()

            if !store.activeSessionIds.isEmpty {
                HStack(spacing: 4) {
                    ActivityDot(size: 5)
                    Text("\(store.activeSessionIds.count) live")
                        .font(Theme.monoFont(9, .medium))
                        .foregroundStyle(Theme.result)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    /// Today's token spend across every session touched since midnight.
    private var todaySection: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("TOKENS TODAY")
                    .font(Theme.monoFont(8, .bold))
                    .foregroundStyle(Theme.textGhost)
                    .tracking(0.6)
                Text(TokenFormat.compact(store.todayUsage.tokens))
                    .font(Theme.monoFont(14, .semibold))
                    .foregroundStyle(Theme.text)
            }

            Spacer()

            if store.todayUsage.hasCost {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("EST. COST")
                        .font(Theme.monoFont(8, .bold))
                        .foregroundStyle(Theme.textGhost)
                        .tracking(0.6)
                    Text(TokenFormat.cost(store.todayUsage.cost))
                        .font(Theme.monoFont(14, .semibold))
                        .foregroundStyle(Theme.claude)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private func contextSection(_ usage: ContextUsage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Latest context")
                    .font(Theme.monoFont(10))
                    .foregroundStyle(Theme.textDim)
                Spacer()
                Text("\(usage.percent)%")
                    .font(Theme.monoFont(10, .semibold))
                    .foregroundStyle(tint(for: usage.fraction))
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.textGhost.opacity(0.18))
                    Capsule()
                        .fill(tint(for: usage.fraction))
                        .frame(width: max(2, geo.size.width * usage.fraction))
                }
            }
            .frame(height: 5)

            HStack {
                Text("\(TokenFormat.compact(usage.used)) / \(TokenFormat.compact(usage.limit))")
                    .font(Theme.monoFont(9))
                    .foregroundStyle(Theme.textGhost)
                Spacer()
                if let model = usage.model {
                    Text(model)
                        .font(Theme.monoFont(9))
                        .foregroundStyle(Theme.textGhost)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "macwindow").font(.system(size: 10, weight: .semibold))
                    Text("Open Session Manager")
                        .font(Theme.monoFont(11, .medium))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.brand))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                store.reload()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textDim)
                    .frame(width: 24, height: 24)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.bgElevated))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Reload sessions")

            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textDim)
                    .frame(width: 24, height: 24)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.bgElevated))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Quit")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private func tint(for fraction: Double) -> Color {
        switch fraction {
        case ..<0.6:  return Theme.result
        case ..<0.85: return Theme.thinking
        default:      return Theme.error
        }
    }
}

// MARK: - Recent session row

private struct RecentRow: View {
    let session: ClaudeSession
    let isActive: Bool
    @State private var isHovered = false
    @State private var didCopy = false

    var body: some View {
        Button {
            let command = "cd \(session.projectPath) && claude --resume \(session.id)"
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
            didCopy = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { didCopy = false }
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.display)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        if isActive { ActivityDot(size: 4) }
                        Text(session.projectName)
                            .font(Theme.monoFont(9))
                            .foregroundStyle(isActive ? Theme.result : Theme.textFaint)
                            .lineLimit(1)
                        Text(isActive ? "active now" : session.relativeTime)
                            .font(Theme.monoFont(9))
                            .foregroundStyle(Theme.textGhost)
                    }
                }
                Spacer(minLength: 4)
                Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 9))
                    .foregroundStyle(didCopy ? Theme.result : Theme.textGhost)
                    .opacity(isHovered || didCopy ? 1 : 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(isHovered ? Theme.bgHover : .clear)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("Copy resume command")
    }
}
