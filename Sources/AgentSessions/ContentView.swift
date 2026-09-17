import AppKit
import SwiftUI

// MARK: - Tabs

/// Top-level view switcher, shown as a segmented control in the title bar.
enum AppTab: String, CaseIterable, Hashable {
    case sessions = "Sessions"
    case findings = "Findings"
}

// MARK: - Root

struct ContentView: View {
    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var tagStore: TagStore

    @State private var activeTab: AppTab = .sessions
    @State private var selectedProject: String? = nil
    @State private var selectedSessionId: String? = nil
    /// Set when a Findings row is tapped; `ConversationView` scrolls to and
    /// flashes this line, then it's cleared so re-selecting the same session
    /// later doesn't re-trigger the jump.
    @State private var pendingScrollLine: Int? = nil
    @State private var searchText = ""
    @State private var sidebarVisible = true
    @State private var toast: ToastItem? = nil
    @AppStorage("appearance") private var appearance: AppearanceMode = .system

    private var projectFiltered: [ClaudeSession] {
        guard let selectedProject else { return store.sessions }
        return store.sessions.filter { $0.projectPath == selectedProject }
    }

    /// Title matches first (they are the strongest signal), then sessions whose
    /// transcript prose contains the query — both in newest-first order.
    ///
    /// `tag:` terms are pulled out and matched exactly against `TagStore`
    /// (ANDed together), everything else falls through to the existing
    /// title/prose search over whatever tag filtering left behind.
    private var listed: [ClaudeSession] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return projectFiltered }

        let terms = query.lowercased().split(separator: " ").map(String.init)
        let tagTerms = terms
            .filter { $0.hasPrefix("tag:") }
            .map { String($0.dropFirst(4)) }
            .filter { !$0.isEmpty }
        let textQuery = terms
            .filter { !$0.hasPrefix("tag:") }
            .joined(separator: " ")

        var candidates = projectFiltered
        if !tagTerms.isEmpty {
            var matchedIds: Set<String>? = nil
            for tag in tagTerms {
                let ids = tagStore.sessionIds(taggedWith: tag)
                matchedIds = matchedIds.map { $0.intersection(ids) } ?? ids
            }
            candidates = candidates.filter { matchedIds?.contains($0.id) ?? false }
        }

        guard !textQuery.isEmpty else { return candidates }

        var titleMatched: [ClaudeSession] = []
        var rest: [ClaudeSession] = []

        for session in candidates {
            if session.display.lowercased().contains(textQuery)
                || session.projectName.lowercased().contains(textQuery)
                || session.id.lowercased().contains(textQuery)
                || tagStore.tags(for: session.id).contains(where: { $0.contains(textQuery) }) {
                titleMatched.append(session)
            } else {
                rest.append(session)
            }
        }

        // `indexGeneration` is read so SwiftUI re-runs this once indexing lands.
        _ = store.indexGeneration
        let contentMatched = SearchIndex.shared.matches(query: textQuery, in: rest)
        return titleMatched + rest.filter { contentMatched.contains($0.id) }
    }

    private var selectedSession: ClaudeSession? {
        guard let selectedSessionId else { return nil }
        return store.sessions.first { $0.id == selectedSessionId }
    }

    var body: some View {
        HStack(spacing: 0) {
            ToolRail()
            VDivider()

            switch activeTab {
            case .sessions:
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        if sidebarVisible {
                            SessionSidebar(
                                sessions: listed,
                                totalCount: store.sessions.count,
                                projects: store.projects,
                                selectedProject: $selectedProject,
                                selectedSessionId: $selectedSessionId,
                                searchText: $searchText,
                                isLoading: store.isLoading,
                                isIndexing: store.isIndexing,
                                activeSessionIds: store.activeSessionIds
                            )
                            .frame(width: 300)
                            VDivider()
                        }

                        VStack(spacing: 0) {
                            TopBar(
                                session: selectedSession,
                                isSelectedActive: selectedSessionId.map(store.activeSessionIds.contains) ?? false,
                                activeCount: store.activeSessionIds.count,
                                sidebarVisible: $sidebarVisible,
                                appearance: $appearance,
                                onCopyResume: copyResumeCommand,
                                onLaunch: launch,
                                onReload: store.reload
                            )
                            HDivider()

                            if !store.historyExists {
                                CenteredHint(
                                    title: "~/.claude/history.jsonl not found",
                                    subtitle: "Install Claude Code and start at least one session."
                                )
                                .background(Theme.bg)
                            } else if let selectedSession {
                                ConversationView(
                                    session: selectedSession,
                                    scrollToLine: $pendingScrollLine,
                                    onJumpMiss: {
                                        show(ToastItem(
                                            message: "That line is inside tool/system data, not a displayed message",
                                            isError: true
                                        ))
                                    }
                                )
                            } else {
                                CenteredHint(
                                    title: "Select a session",
                                    subtitle: "Choose a session from the list to view the conversation."
                                )
                                .background(Theme.bg)
                            }
                        }
                    }
                    HDivider()
                    BrandFooter {
                        if store.isIndexing {
                            ProgressView().scaleEffect(0.4).frame(width: 10, height: 10)
                            Text("indexing transcripts…")
                        } else {
                            Text("\(store.sessions.count) session\(store.sessions.count == 1 ? "" : "s")")
                        }
                    }
                }
            case .findings:
                FindingsView(
                    appearance: $appearance,
                    onReload: store.reload,
                    onSelectFinding: { id, line in
                        selectedSessionId = id
                        pendingScrollLine = line
                        activeTab = .sessions
                    }
                )
            }
        }
        .background(Theme.bg)
        .frame(minWidth: 980, minHeight: 620)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("", selection: $activeTab) {
                    ForEach(AppTab.allCases, id: \.self) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 165)
            }
        }
        // `NSApp.appearance` (not `.preferredColorScheme`) is what actually
        // tracks the OS setting live: once `.preferredColorScheme` had been
        // pinned to an explicit scheme, handing it `nil` again to mean
        // "system" does not reliably revert to following OS changes. Setting
        // `NSApp.appearance = nil` restores automatic system tracking; this
        // is a plain in-process AppKit property and needs no permission.
        .onChange(of: appearance) { newValue in applyAppearance(newValue) }
        .overlay(alignment: .bottom) {
            if let toast {
                ToastView(item: toast)
                    .padding(.bottom, 22)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: toast?.id)
        .animation(.easeInOut(duration: 0.18), value: sidebarVisible)
        .onAppear {
            store.reload()
            applyAppearance(appearance)
        }
    }

    // MARK: Actions

    private func applyAppearance(_ mode: AppearanceMode) {
        switch mode {
        case .system: NSApp.appearance = nil
        case .light:  NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:   NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    private func copyResumeCommand(_ session: ClaudeSession) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            LaunchService.resumeCommand(for: session), forType: .string
        )
        show(ToastItem(message: "Copied resume command", isError: false))
    }

    private func launch(_ session: ClaudeSession) {
        switch LaunchService.resume(session: session) {
        case .success(let msg): show(ToastItem(message: msg, isError: false))
        case .failure(let msg): show(ToastItem(message: msg, isError: true))
        }
    }

    private func show(_ item: ToastItem) {
        toast = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            if toast?.id == item.id { withAnimation { toast = nil } }
        }
    }
}

// MARK: - Dividers

private struct VDivider: View {
    var body: some View {
        Rectangle().fill(Theme.border).frame(width: 1)
    }
}

private struct HDivider: View {
    var body: some View {
        Rectangle().fill(Theme.border).frame(height: 1)
    }
}

// MARK: - Brand footer

/// Shared footer for both tabs: tab-specific status/count in the center,
/// branding at the corners.
struct BrandFooter<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ZStack {
            HStack(spacing: 5) { content }

            HStack {
                Text("By peachycloudsecurity")
                    .padding(.leading, 12)
                Spacer()
                Text("Made with ❤️ in India")
                    .padding(.trailing, 12)
            }
        }
        .font(Theme.monoFont(10))
        .foregroundStyle(Theme.textGhost)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 7)
    }
}

// MARK: - Tool rail (left-most)

private struct ToolRail: View {
    @State private var isHovered = false

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 50)
            HDivider()

            // One row per coding agent. Only Claude Code is read today; Codex
            // and Gemini CLI slot in here as their transcript formats land.
            VStack(spacing: 4) {
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Theme.claude)
                        .frame(width: 3, height: 24)
                        .offset(x: -7)

                    AgentBadge(
                        letter: "C",
                        colors: [Color(hex: 0xE8875C), Color(hex: 0xC65D3B)]
                    )
                    .shadow(color: Color(hex: 0xC65D3B).opacity(0.45), radius: 7, y: 2)
                    .scaleEffect(isHovered ? 1.05 : 1)
                    .animation(.spring(response: 0.22, dampingFraction: 0.6), value: isHovered)
                    .onHover { isHovered = $0 }
                }

                Text("Claude")
                    .font(Theme.monoFont(9, .medium))
                    .foregroundStyle(Theme.textDim)
            }
            .padding(.top, 14)
            .help("Claude Code sessions")

            Spacer()
        }
        .frame(width: 58)
        .background(Theme.bg)
    }
}

// MARK: - Top bar

private struct TopBar: View {
    let session: ClaudeSession?
    let isSelectedActive: Bool
    let activeCount: Int
    @Binding var sidebarVisible: Bool
    @Binding var appearance: AppearanceMode
    let onCopyResume: (ClaudeSession) -> Void
    let onLaunch: (ClaudeSession) -> Void
    let onReload: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            IconButton(
                systemName: "sidebar.left",
                help: sidebarVisible ? "Hide sidebar" : "Show sidebar"
            ) {
                sidebarVisible.toggle()
            }

            if isSelectedActive {
                ActivePill(label: "Active session")
            } else if activeCount > 0 {
                ActivePill(label: activeCount == 1 ? "1 active" : "\(activeCount) active")
            }

            if let session {
                // The only flexible element: it truncates so the controls on the
                // right keep their intrinsic width.
                HStack(spacing: 8) {
                    Text(session.display)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Text(session.projectName)
                        .font(Theme.monoFont(11))
                        .foregroundStyle(Theme.textGhost)
                        .lineLimit(1)
                        .layoutPriority(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Spacer(minLength: 8)
            }

            if let session {
                ResumeButton { onLaunch(session) }
                    .layoutPriority(2)

                CopyButton { onCopyResume(session) }
                    .layoutPriority(2)
            }

            AppearanceMenu(appearance: $appearance)

            IconButton(systemName: "arrow.clockwise", help: "Reload sessions", action: onReload)
        }
        .padding(.horizontal, 14)
        .frame(height: 50)
        .background(Theme.bg)
    }
}

/// Green "something is running right now" chip.
private struct ActivePill: View {
    let label: String

    var body: some View {
        HStack(spacing: 5) {
            ActivityDot(size: 5)
            Text(label)
                .font(Theme.monoFont(10, .medium))
                .foregroundStyle(Theme.result)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(Theme.result.opacity(0.12)))
        .overlay(Capsule().strokeBorder(Theme.result.opacity(0.3), lineWidth: 1))
        .fixedSize()
        .layoutPriority(2)
    }
}

// MARK: - Appearance switcher

struct AppearanceMenu: View {
    @Binding var appearance: AppearanceMode
    @State private var isHovered = false

    var body: some View {
        Menu {
            ForEach(AppearanceMode.allCases) { mode in
                Button {
                    appearance = mode
                } label: {
                    Label(mode.label, systemImage: mode.icon)
                    if appearance == mode { Image(systemName: "checkmark") }
                }
            }
        } label: {
            Image(systemName: appearance.icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isHovered ? Theme.text : Theme.textDim)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isHovered ? Theme.bgElevated : .clear)
                )
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { isHovered = $0 }
        .help("Appearance: \(appearance.label)")
    }
}

struct IconButton: View {
    let systemName: String
    let help: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isHovered ? Theme.text : Theme.textDim)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isHovered ? Theme.bgElevated : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(help)
    }
}

// MARK: - Session sidebar

private struct SessionSidebar: View {
    let sessions: [ClaudeSession]
    let totalCount: Int
    let projects: [String]
    @Binding var selectedProject: String?
    @Binding var selectedSessionId: String?
    @Binding var searchText: String
    let isLoading: Bool
    let isIndexing: Bool
    let activeSessionIds: Set<String>

    @State private var isProjectMenuOpen = false

    private var selectedProjectLabel: String {
        selectedProject.flatMap { $0.split(separator: "/").last.map(String.init) } ?? "All Projects"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Custom bounded/scrollable dropdown — a native `.menu` Picker
            // spills past the window with enough projects.
            Button {
                isProjectMenuOpen = true
            } label: {
                HStack(spacing: 6) {
                    Text(selectedProjectLabel)
                        .font(Theme.monoFont(12))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Theme.textGhost)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.bgElevated))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .frame(height: 50, alignment: .center)
            .popover(isPresented: $isProjectMenuOpen) {
                ProjectPickerPopover(
                    projects: projects,
                    selectedProject: $selectedProject,
                    isOpen: $isProjectMenuOpen
                )
            }

            HDivider()

            // Search
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textGhost)
                TextField("Search titles, transcripts, tag:value", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(Theme.monoFont(11))
                    .foregroundStyle(Theme.text)
                    .help("Filter by tag, e.g. tag:batman")
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Theme.textGhost)
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)

            HDivider()

            // List
            if isLoading {
                VStack { ProgressView().scaleEffect(0.6) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if sessions.isEmpty {
                Text(searchText.isEmpty ? "No sessions found" : "No sessions match")
                    .font(Theme.monoFont(11))
                    .foregroundStyle(Theme.textGhost)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(sessions) { session in
                            SessionCell(
                                session: session,
                                isSelected: session.id == selectedSessionId,
                                isActive: activeSessionIds.contains(session.id),
                                onTagTap: { tag in searchText = "tag:\(tag)" },
                                onSelect: { selectedSessionId = session.id }
                            )
                            HDivider().opacity(0.5)
                        }
                    }
                }
            }

            HDivider()

            HStack(spacing: 5) {
                if isIndexing {
                    ProgressView().scaleEffect(0.4).frame(width: 10, height: 10)
                    Text("indexing transcripts…")
                } else {
                    Text("\(totalCount) session\(totalCount == 1 ? "" : "s")")
                }
            }
            .font(Theme.monoFont(10))
            .foregroundStyle(Theme.textGhost)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
        }
        .background(Theme.bg)
    }
}

// MARK: - Project picker popover

private struct ProjectPickerPopover: View {
    let projects: [String]
    @Binding var selectedProject: String?
    @Binding var isOpen: Bool

    private let rowHeight: CGFloat = 30

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                row(label: "All Projects", isSelected: selectedProject == nil) {
                    selectedProject = nil
                }
                ForEach(projects, id: \.self) { project in
                    row(
                        label: project.split(separator: "/").last.map(String.init) ?? project,
                        isSelected: selectedProject == project
                    ) {
                        selectedProject = project
                    }
                }
            }
        }
        .frame(width: 260)
        .frame(height: min(CGFloat(projects.count + 1) * rowHeight, 320))
    }

    private func row(label: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            action()
            isOpen = false
        } label: {
            HStack {
                Text(label)
                    .font(Theme.monoFont(12))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.brand)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct SessionCell: View {
    let session: ClaudeSession
    let isSelected: Bool
    let isActive: Bool
    let onTagTap: (String) -> Void
    let onSelect: () -> Void

    @EnvironmentObject private var tagStore: TagStore
    @State private var isHovered = false
    @State private var isEditingTags = false
    @State private var isTagButtonHovered = false

    private var tags: [String] { tagStore.tags(for: session.id) }

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    if isActive { ActivityDot(size: 5) }
                    Text(session.projectName)
                        .font(Theme.monoFont(10, .medium))
                        .foregroundStyle(isActive ? Theme.result : Theme.textFaint)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text(session.relativeTime)
                        .font(Theme.monoFont(10))
                        .foregroundStyle(Theme.textGhost)
                        .lineLimit(1)
                }
                Text(session.display)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                // Always mounted (never wrapped in `if isHovered`), so the
                // popover's anchor view can't be yanked out from under it the
                // moment the cursor drifts off the row — that used to close
                // the editor on the slightest mouse move. Visibility is done
                // with opacity/height instead of removing the view.
                HStack(spacing: 5) {
                    FlowLayout {
                        ForEach(tags, id: \.self) { tag in
                            TagChip(tag: tag, onTap: { onTagTap(tag) })
                                .contextMenu {
                                    Button("Remove tag", role: .destructive) {
                                        tagStore.remove(tag, from: session.id)
                                    }
                                }
                        }
                    }
                    Button { isEditingTags = true } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "tag.fill")
                                .font(.system(size: 9, weight: .medium))
                            if isTagButtonHovered {
                                Text("Add tag")
                                    .font(Theme.monoFont(9, .medium))
                            }
                        }
                        .foregroundStyle(Theme.error)
                        .frame(height: 16)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { isTagButtonHovered = $0 }
                    .popover(isPresented: $isEditingTags) {
                        TagEditorPopover(sessionId: session.id)
                    }
                }
                .padding(.top, 1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isSelected ? Theme.selection
                : isHovered ? Theme.bgHover
                : Color.clear
            )
            // A clear background is not hit-tested, so without this the first
            // click on empty row space is swallowed and only lands once hover
            // has painted a background.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Launch button

/// Secondary action: put the resume command on the clipboard.
struct CopyButton: View {
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 10, weight: .medium))
                Text("Copy")
                    .font(Theme.monoFont(11, .medium))
            }
            .foregroundStyle(isHovered ? Theme.text : Theme.textDim)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Theme.bgElevated.opacity(isHovered ? 1 : 0.7))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .onHover { isHovered = $0 }
        .help("Copy the resume command")
    }
}

/// Primary action: resume this session in Terminal.
struct ResumeButton: View {
    let action: () -> Void
    @State private var isHovered = false

    private static let green = Color(hex: 0x22B04F)

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 10, weight: .semibold))
                Text("Resume")
                    .font(Theme.monoFont(11, .medium))
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 8, weight: .bold))
                    .opacity(0.85)
            }
            .foregroundStyle(.white)
            // Never wrap or shrink — the label must stay legible, so the
            // window's flexible content yields space instead of this.
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Self.green.opacity(isHovered ? 1 : 0.85))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .onHover { isHovered = $0 }
        .help("Open Terminal and run claude --resume")
    }
}

// MARK: - Toast

struct ToastItem: Identifiable {
    let id = UUID()
    let message: String
    let isError: Bool
}

struct ToastView: View {
    let item: ToastItem

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: item.isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(item.isError ? Theme.error : Theme.result)
            Text(item.message)
                .font(Theme.monoFont(12))
                .foregroundStyle(Theme.text)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.bgElevated))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.border, lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 14, y: 5)
    }
}

// MARK: - Store

@MainActor
final class SessionStore: ObservableObject {
    @Published var sessions: [ClaudeSession] = []
    @Published var projects: [String] = []
    @Published var isLoading = false
    @Published var historyExists = true

    /// Context usage of the most recent session — drives the menu bar readout.
    @Published var latestUsage: ContextUsage?

    /// Sessions whose transcript was written to recently — i.e. running right now.
    @Published var activeSessionIds: Set<String> = []

    /// Token spend across everything touched today.
    @Published var todayUsage: UsageRollup = .empty

    /// Bumped when the full-text index finishes, so searches re-run against it.
    @Published var indexGeneration = 0
    @Published var isIndexing = false

    /// Bumped when the secret scan finishes, so the Findings tab re-reads it.
    @Published var secretScanGeneration = 0
    @Published var isSecretScanning = false
    /// Real counts for the baseline-scan progress display — only meaningful
    /// while `isSecretScanning` is true.
    @Published var secretScanDone = 0
    @Published var secretScanTotal = 0

    private var watcher: FileWatcher?
    private let debouncer = Debouncer(delay: 0.35)

    /// Last write time per session, used to expire the "active" flag.
    private var lastActivity: [String: Date] = [:]
    private var expiryTimer: Timer?

    /// A transcript touched within this window counts as an active session.
    private let activeWindow: TimeInterval = 120

    private var historyPath: String {
        SessionLoader.claudeDir.appendingPathComponent("history.jsonl").path
    }

    private var projectsPath: String {
        SessionLoader.claudeDir.appendingPathComponent("projects").path
    }

    /// The running session, if any — newest activity wins.
    var activeSession: ClaudeSession? {
        sessions.first { activeSessionIds.contains($0.id) }
    }

    /// Load immediately so the menu bar has data even if the window is never opened.
    init() { reload() }

    func reload() {
        // No-op while already busy — repeated reload clicks shouldn't stack
        // up overlapping loads/scans.
        guard !isLoading, !isSecretScanning else { return }
        isLoading = true
        load(showSpinner: true)
        startWatching()
    }

    /// Watch history.jsonl for new sessions, and the transcripts themselves for
    /// live activity. A transcript write is cheap to handle; only history.jsonl
    /// triggers a full re-read.
    private func startWatching() {
        guard watcher == nil else { return }

        watcher = FileWatcher(paths: [historyPath, projectsPath]) { [weak self] changed in
            guard let self else { return }

            let historyTouched = changed.contains { $0.hasSuffix("history.jsonl") }
            let touchedTranscripts: [(id: String, path: String)] = changed
                .filter { $0.hasSuffix(".jsonl") && !$0.hasSuffix("history.jsonl") }
                .map { path in
                    let id = String((path as NSString).lastPathComponent.dropLast(".jsonl".count))
                    return (id, path)
                }

            Task { @MainActor in
                if !touchedTranscripts.isEmpty {
                    self.markActive(touchedTranscripts.map(\.id))
                    // Rescans only what actually changed (cache no-ops the rest).
                    Task.detached(priority: .utility) {
                        for transcript in touchedTranscripts {
                            SecretScanner.shared.scan(sessionId: transcript.id, filePath: transcript.path)
                        }
                        await MainActor.run { self.secretScanGeneration += 1 }
                    }
                }
                if historyTouched {
                    self.debouncer.call { self.load(showSpinner: false) }
                }
            }
        }
    }

    // MARK: - Activity tracking

    private func markActive(_ sessionIds: [String]) {
        let now = Date()
        for id in sessionIds { lastActivity[id] = now }
        refreshActiveSet()
        startExpiryTimer()
    }

    private func refreshActiveSet() {
        let cutoff = Date().addingTimeInterval(-activeWindow)
        lastActivity = lastActivity.filter { $0.value > cutoff }
        let ids = Set(lastActivity.keys)
        if ids != activeSessionIds { activeSessionIds = ids }
    }

    /// Runs only while something is active, so an idle app costs nothing.
    private func startExpiryTimer() {
        guard expiryTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.refreshActiveSet()
                if self.lastActivity.isEmpty { self.stopExpiryTimer() }
            }
        }
        timer.tolerance = 5
        expiryTimer = timer
    }

    private func stopExpiryTimer() {
        expiryTimer?.invalidate()
        expiryTimer = nil
    }

    private func load(showSpinner: Bool) {
        historyExists = FileManager.default.fileExists(atPath: historyPath)
        if showSpinner { isLoading = true }

        let window = activeWindow

        Task.detached(priority: .userInitiated) {
            let loaded = SessionLoader.loadAll()
            let projects = Array(Set(loaded.map(\.projectPath))).sorted()
            // Tail-read only the newest transcript — constant cost.
            let usage = loaded.first.flatMap {
                ConversationLoader.latestContextUsage(filePath: $0.filePath)
            }

            // A transcript written to very recently belongs to a live session;
            // only the newest handful can qualify, so stat just those.
            let cutoff = Date().addingTimeInterval(-window)
            let recentlyWritten: [String: Date] = loaded.prefix(25)
                .reduce(into: [:]) { result, session in
                    guard !session.filePath.isEmpty,
                          let attrs = try? FileManager.default.attributesOfItem(atPath: session.filePath),
                          let mtime = attrs[.modificationDate] as? Date,
                          mtime > cutoff
                    else { return }
                    result[session.id] = mtime
                }

            await MainActor.run {
                self.sessions = loaded
                self.projects = projects
                self.latestUsage = usage
                self.isLoading = false

                for (id, date) in recentlyWritten where (self.lastActivity[id] ?? .distantPast) < date {
                    self.lastActivity[id] = date
                }
                self.refreshActiveSet()
                if !self.lastActivity.isEmpty { self.startExpiryTimer() }
            }

            // Today's rollup last: it reads several transcripts, so let the list
            // render first rather than holding it up.
            let rollup = UsageRollup.forToday(sessions: loaded)
            await MainActor.run { self.todayUsage = rollup }

            // Then build the full-text index, newest first so recent sessions
            // become searchable soonest. Unchanged transcripts hit the cache.
            await MainActor.run { self.isIndexing = true }
            for session in loaded where !session.filePath.isEmpty {
                SearchIndex.shared.index(filePath: session.filePath)
            }
            await MainActor.run {
                self.isIndexing = false
                self.indexGeneration += 1
            }

            // Secret scan last, smallest file first — the active session
            // (largest, still growing) is already covered live by the
            // FSEvents rescan, so it doesn't need to go first here.
            let scanTargets = loaded
                .filter { !$0.filePath.isEmpty }
                .sorted {
                    let lhs = (try? FileManager.default.attributesOfItem(atPath: $0.filePath))?[.size] as? Int ?? 0
                    let rhs = (try? FileManager.default.attributesOfItem(atPath: $1.filePath))?[.size] as? Int ?? 0
                    return lhs < rhs
                }
            await MainActor.run {
                self.isSecretScanning = true
                self.secretScanDone = 0
                self.secretScanTotal = scanTargets.count
            }
            for session in scanTargets {
                SecretScanner.shared.scan(sessionId: session.id, filePath: session.filePath)
                await MainActor.run { self.secretScanDone += 1 }
            }
            await MainActor.run {
                self.isSecretScanning = false
                self.secretScanGeneration += 1
            }
        }
    }

    // No deinit: the store is created as a @StateObject on the App and lives for
    // the whole process. FileWatcher tears its own stream down in its deinit, and
    // the expiry timer holds only a weak reference back here.
}
