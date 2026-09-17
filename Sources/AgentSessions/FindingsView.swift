import SwiftUI

// MARK: - Findings tab

/// Findings tab. Secrets is the only category today; more (Actions,
/// Network, ...) slot in as their own chip in `CategoryRow` later.
struct FindingsView: View {
    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var classificationStore: FindingClassificationStore
    @Binding var appearance: AppearanceMode
    let onReload: () -> Void
    /// (sessionId, finding's line number) — lets the Sessions tab jump to it.
    let onSelectFinding: (String, Int) -> Void

    /// `.open` = Unclassified + True positive. True positive stays in the
    /// default view on purpose: confirming a secret is real must not hide
    /// it, only Benign/False positive (already resolved) does.
    @State private var filter: FindingFilter = .open
    @State private var sortAscending = false

    private var allRows: [FindingRow] {
        _ = store.secretScanGeneration

        let sessionsById = Dictionary(
            store.sessions.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        return SecretScanner.shared.allFindings()
            .compactMap { finding -> FindingRow? in
                guard let session = sessionsById[finding.sessionId] else { return nil }
                return FindingRow(finding: finding, session: session)
            }
            .sorted { lhs, rhs in
                if lhs.finding.severity != rhs.finding.severity {
                    return lhs.finding.severity > rhs.finding.severity
                }
                if lhs.session.timestamp != rhs.session.timestamp {
                    return sortAscending
                        ? lhs.session.timestamp < rhs.session.timestamp
                        : lhs.session.timestamp > rhs.session.timestamp
                }
                return sortAscending
                    ? lhs.finding.lineNumber < rhs.finding.lineNumber
                    : lhs.finding.lineNumber > rhs.finding.lineNumber
            }
    }

    private var rows: [FindingRow] {
        _ = classificationStore.statusByFinding
        switch filter {
        case .open:
            return allRows.filter {
                let status = classificationStore.status(for: $0.finding.id)
                return status == .unclassified || status == .truePositive
            }
        case .status(let status):
            return allRows.filter { classificationStore.status(for: $0.finding.id) == status }
        }
    }

    private var isBaselineScan: Bool {
        store.isSecretScanning && allRows.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CategoryRow(appearance: $appearance, onReload: onReload)
            HDividerLine()
            FilterRow(selection: $filter, sortAscending: $sortAscending)
            HDividerLine()

            if isBaselineScan {
                BaselineProgressView(done: store.secretScanDone, total: store.secretScanTotal)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if rows.isEmpty {
                CenteredHint(
                    title: allRows.isEmpty ? "No secrets found" : "No findings match",
                    subtitle: allRows.isEmpty
                        ? "Transcripts are scanned automatically as sessions load or change."
                        : "Try a different filter."
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // List, not ScrollView+LazyVStack — the latter produced
                // inconsistent row heights with this content.
                List(rows) { row in
                    FindingRowView(
                        row: row,
                        status: classificationStore.status(for: row.finding.id),
                        onTap: { onSelectFinding(row.session.id, row.finding.lineNumber) },
                        onSetStatus: { classificationStore.setStatus($0, for: row.finding.id) }
                    )
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }

            HDividerLine()
            BrandFooter {
                if store.isSecretScanning {
                    ProgressView().scaleEffect(0.4).frame(width: 10, height: 10)
                    Text("scanning transcripts…")
                } else {
                    Text("\(rows.count) finding\(rows.count == 1 ? "" : "s")")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
    }
}

// MARK: - Baseline scan progress

private struct BaselineProgressView: View {
    let done: Int
    let total: Int

    private var fraction: Double {
        total > 0 ? min(1, Double(done) / Double(total)) : 0
    }

    var body: some View {
        VStack(spacing: 10) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.textGhost.opacity(0.18))
                    Capsule()
                        .fill(Theme.brand)
                        .frame(width: max(3, geo.size.width * fraction))
                }
            }
            .frame(width: 160, height: 5)

            Text(total > 0 ? "Scanning \(done) of \(total) sessions… (\(Int(fraction * 100))%)" : "Scanning…")
                .font(Theme.monoFont(11))
                .foregroundStyle(Theme.textFaint)
            Text("One-time baseline — after this, only what changes gets rescanned.")
                .font(Theme.monoFont(10))
                .foregroundStyle(Theme.textGhost)
        }
    }
}

private struct FindingRow: Identifiable {
    let finding: SecretScanner.Finding
    let session: ClaudeSession
    var id: String { finding.id }
}

// MARK: - Category

/// Only "Secrets" exists today; Actions/Network etc. add their own chip
/// here later without touching the status filter below.
private struct CategoryRow: View {
    @Binding var appearance: AppearanceMode
    let onReload: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            FilterChip(label: "Secrets", isSelected: true) {}
            Spacer()
            AppearanceMenu(appearance: $appearance)
            IconButton(systemName: "arrow.clockwise", help: "Reload sessions", action: onReload)
        }
        .padding(.horizontal, 20)
        // Matches ToolRail/TopBar's 50pt header height so this row's
        // divider lines up with the one above the Claude badge.
        .frame(height: 50)
    }
}

// MARK: - Filter

private enum FindingFilter: Hashable {
    case open
    case status(FindingStatus)

    var label: String {
        switch self {
        case .open: return "Open"
        case .status(let s): return s.rawValue
        }
    }
}

private struct FilterRow: View {
    @Binding var selection: FindingFilter
    @Binding var sortAscending: Bool

    var body: some View {
        HStack(spacing: 6) {
            FilterChip(label: FindingFilter.open.label, isSelected: selection == .open) {
                selection = .open
            }
            ForEach(FindingStatus.allCases, id: \.self) { status in
                FilterChip(label: status.rawValue, isSelected: selection == .status(status)) {
                    selection = .status(status)
                }
            }

            Spacer(minLength: 8)

            Button { sortAscending.toggle() } label: {
                Image(systemName: sortAscending ? "arrow.up" : "arrow.down")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.textDim)
            }
            .buttonStyle(.plain)
            .help(sortAscending ? "Oldest first" : "Newest first")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }
}

private struct FilterChip: View {
    let label: String
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Text(label)
                .font(Theme.monoFont(11, isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Theme.text : Theme.textDim)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule().fill(isSelected ? Theme.bgElevated : Color.clear)
                )
                .overlay(Capsule().strokeBorder(Theme.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Row

private struct FindingRowView: View {
    let row: FindingRow
    let status: FindingStatus
    let onTap: () -> Void
    let onSetStatus: (FindingStatus) -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            // Tap gesture, not a Button — a Button here gets a persistent
            // system grey background inside a List.
            Group {
                HStack(spacing: 12) {
                    SeverityBadge(severity: row.finding.severity)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(row.finding.label)
                            .font(Theme.monoFont(12, .medium))
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                        Text(row.finding.masked)
                            .font(Theme.monoFont(11))
                            .foregroundStyle(Theme.textFaint)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 12)

                    VStack(alignment: .trailing, spacing: 3) {
                        Text(row.session.display)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textDim)
                            .lineLimit(1)
                        HStack(spacing: 5) {
                            Text(row.session.projectName)
                            Text(row.session.relativeTime)
                        }
                        .font(Theme.monoFont(10))
                        .foregroundStyle(Theme.textGhost)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture(perform: onTap)
            }
            .help("Open \(row.session.display)")

            StatusMenu(status: status, onSetStatus: onSetStatus)
        }
        .frame(height: 38)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isHovered ? Theme.bgHover : Color.clear)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.border).opacity(0.5).frame(height: 1)
        }
        .onHover { isHovered = $0 }
        .listRowBackground(Color.clear)
    }
}

private struct StatusMenu: View {
    let status: FindingStatus
    let onSetStatus: (FindingStatus) -> Void

    var body: some View {
        Menu {
            ForEach(FindingStatus.allCases, id: \.self) { option in
                Button {
                    onSetStatus(option)
                } label: {
                    Text(option.rawValue)
                    if status == option { Image(systemName: "checkmark") }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(status.rawValue)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .font(Theme.monoFont(10))
            .foregroundStyle(Theme.textDim)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.bgElevated))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

private struct SeverityBadge: View {
    let severity: SecretScanner.Severity

    private var color: Color {
        switch severity {
        case .high:   return Theme.error
        case .medium: return Theme.thinking
        case .low:    return Theme.tool
        }
    }

    private var label: String {
        switch severity {
        case .high:   return "HIGH"
        case .medium: return "MED"
        case .low:    return "LOW"
        }
    }

    var body: some View {
        Text(label)
            .font(Theme.monoFont(9, .bold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.14)))
    }
}

/// Local alias so this file doesn't depend on `ContentView.swift`'s private
/// `HDivider` — same look, just not `private` to that file.
private struct HDividerLine: View {
    var body: some View {
        Rectangle().fill(Theme.border).frame(height: 1)
    }
}
