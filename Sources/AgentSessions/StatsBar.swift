import SwiftUI

// MARK: - Session stats strip
//
// Rendered from data already gathered during transcript parsing, using plain
// shapes only — no charting dependency, no timers, no retained history.

struct StatsBar: View {
    let stats: ConversationStats
    @Binding var isExpanded: Bool

    var body: some View {
        VStack(spacing: 0) {
            summaryRow

            if isExpanded {
                Divider().opacity(0.4)
                detailRow
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(Theme.bg)
    }

    // MARK: Collapsed line

    private var summaryRow: some View {
        Button {
            withAnimation(.easeOut(duration: 0.16)) { isExpanded.toggle() }
        } label: {
            HStack(spacing: 14) {
                ContextMeter(fraction: stats.contextFraction)

                Text("\(Int(stats.contextFraction * 100))% context")
                    .font(Theme.monoFont(10, .medium))
                    .foregroundStyle(contextTint)

                Separator()

                Stat(value: TokenFormat.compact(stats.totalTokens), label: "tokens")

                if let cost = stats.estimatedCost, cost > 0 {
                    Stat(value: TokenFormat.cost(cost), label: "est.")
                }

                Stat(value: "\(stats.userTurns + stats.assistantTurns)", label: "msgs")
                Stat(value: "\(stats.toolCalls)", label: "tools")

                if let duration = stats.duration {
                    Stat(value: TokenFormat.duration(duration), label: "elapsed")
                }

                Spacer(minLength: 4)

                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.textGhost)
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isExpanded ? "Hide token breakdown" : "Show token breakdown")
    }

    private var contextTint: Color {
        switch stats.contextFraction {
        case ..<0.6:  return Theme.result
        case ..<0.85: return Theme.thinking
        default:      return Theme.error
        }
    }

    // MARK: Expanded breakdown

    private var detailRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            TokenCompositionBar(stats: stats)

            HStack(spacing: 16) {
                Legend(color: Theme.claude,   label: "input",     value: stats.inputTokens)
                Legend(color: Theme.userLabel, label: "output",    value: stats.outputTokens)
                Legend(color: Theme.result,   label: "cache read", value: stats.cacheReadTokens)
                Legend(color: Theme.tool,     label: "cache write", value: stats.cacheWriteTokens)

                Spacer(minLength: 8)

                if let model = stats.model {
                    Text(model)
                        .font(Theme.monoFont(9))
                        .foregroundStyle(Theme.textGhost)
                        .lineLimit(1)
                }

                Text("peak \(TokenFormat.compact(stats.peakContext)) / \(TokenFormat.compact(stats.contextLimit))")
                    .font(Theme.monoFont(9))
                    .foregroundStyle(Theme.textGhost)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 9)
        .padding(.bottom, 10)
    }
}

// MARK: - Context meter

private struct ContextMeter: View {
    let fraction: Double

    private var tint: Color {
        switch fraction {
        case ..<0.6:  return Theme.result
        case ..<0.85: return Theme.thinking
        default:      return Theme.error
        }
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.textGhost.opacity(0.18))
                Capsule()
                    .fill(tint)
                    .frame(width: max(2, geo.size.width * fraction))
            }
        }
        .frame(width: 62, height: 5)
    }
}

// MARK: - Token composition

private struct TokenCompositionBar: View {
    let stats: ConversationStats

    private var segments: [(Color, Int)] {
        [
            (Theme.claude,    stats.inputTokens),
            (Theme.userLabel, stats.outputTokens),
            (Theme.result,    stats.cacheReadTokens),
            (Theme.tool,      stats.cacheWriteTokens),
        ].filter { $0.1 > 0 }
    }

    var body: some View {
        GeometryReader { geo in
            let total = max(stats.totalTokens, 1)
            HStack(spacing: 1.5) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(segment.0)
                        .frame(width: max(2, geo.size.width * Double(segment.1) / Double(total)))
                }
            }
        }
        .frame(height: 6)
    }
}

// MARK: - Small parts

private struct Stat: View {
    let value: String
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            Text(value)
                .font(Theme.monoFont(10, .medium))
                .foregroundStyle(Theme.textDim)
            Text(label)
                .font(Theme.monoFont(10))
                .foregroundStyle(Theme.textGhost)
        }
        .lineLimit(1)
        .fixedSize()
    }
}

private struct Legend: View {
    let color: Color
    let label: String
    let value: Int

    var body: some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(color)
                .frame(width: 7, height: 7)
            Text(label)
                .font(Theme.monoFont(9))
                .foregroundStyle(Theme.textGhost)
            Text(TokenFormat.compact(value))
                .font(Theme.monoFont(9, .medium))
                .foregroundStyle(Theme.textDim)
        }
    }
}

private struct Separator: View {
    var body: some View {
        Rectangle()
            .fill(Theme.border)
            .frame(width: 1, height: 11)
    }
}

// MARK: - Formatting

enum TokenFormat {
    static func compact(_ n: Int) -> String {
        switch n {
        case 1_000_000...:
            return String(format: "%.1fM", Double(n) / 1_000_000)
        case 1_000...:
            return String(format: "%.0fK", Double(n) / 1_000)
        default:
            return "\(n)"
        }
    }

    static func cost(_ usd: Double) -> String {
        usd < 10
            ? String(format: "$%.2f", usd)
            : String(format: "$%.0f", usd)
    }

    static func duration(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m" }
        return "\(total)s"
    }
}
