import SwiftUI

// MARK: - Conversation pane

struct ConversationView: View {
    let session: ClaudeSession
    /// Set (from a Findings-tab tap) to scroll to and flash the message at
    /// that line. Consumed once attempted either way.
    @Binding var scrollToLine: Int?
    /// Called when `scrollToLine` has no matching displayed message (e.g.
    /// the hit was on raw tool/system content, never shown as a bubble).
    var onJumpMiss: () -> Void = {}

    @State private var conversation = Conversation(summary: nil, messages: [], stats: .empty)
    @State private var isLoading = true
    @State private var watcher: FileWatcher? = nil
    @State private var isLive = false
    @State private var autoScroll = true
    @State private var flashedMessageId: String? = nil
    @AppStorage("statsExpanded") private var statsExpanded = false
    private let debouncer = Debouncer(delay: 0.25)

    // Find-in-transcript
    @State private var isFinding = false
    @State private var findText = ""
    @State private var currentMatch = 0
    @FocusState private var findFocused: Bool

    /// Ids of messages whose visible text contains the query, in reading order.
    private var matchingMessageIds: [String] {
        let query = findText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return [] }
        return conversation.messages.compactMap { message in
            let hit = message.blocks.contains { block in
                switch block {
                case .text(let text):          return text.lowercased().contains(query)
                case .thinking(let text):      return text.lowercased().contains(query)
                case .toolUse(_, let name, _, let preview, let detail):
                    return name.lowercased().contains(query)
                        || (preview?.lowercased().contains(query) ?? false)
                        || detail.lowercased().contains(query)
                case .toolResult(_, let content, _):
                    return content.lowercased().contains(query)
                }
            }
            return hit ? message.id : nil
        }
    }

    var body: some View {
        Group {
            if isLoading {
                VStack(spacing: 10) {
                    ProgressView().scaleEffect(0.7)
                    Text("Loading conversation…")
                        .font(Theme.monoFont(11))
                        .foregroundStyle(Theme.textFaint)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if conversation.messages.isEmpty {
                CenteredHint(
                    title: "No messages",
                    subtitle: session.filePath.isEmpty
                        ? "Transcript file not found on disk."
                        : "This transcript has no readable messages."
                )
            } else {
                VStack(spacing: 0) {
                    if !conversation.stats.isEmpty {
                        StatsBar(stats: conversation.stats, isExpanded: $statsExpanded)
                        Rectangle().fill(Theme.border).frame(height: 1)
                    }

                    if isFinding {
                        FindBar(
                            text: $findText,
                            focused: $findFocused,
                            matchCount: matchingMessageIds.count,
                            currentMatch: $currentMatch,
                            onClose: closeFind
                        )
                        Rectangle().fill(Theme.border).frame(height: 1)
                    }

                    ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            if let summary = conversation.summary {
                                SummaryCard(
                                    summary: summary,
                                    messageCount: conversation.messages.count
                                )
                            }

                            ForEach(timeline) { entry in
                                switch entry {
                                case .daySeparator(_, let label):
                                    DaySeparator(label: label)
                                case .message(let message):
                                    MessageRow(
                                        message: message,
                                        highlight: isFinding ? findText : "",
                                        isCurrentMatch: isFinding
                                            && currentMatchId == message.id,
                                        isFlashed: flashedMessageId == message.id
                                    )
                                    .id(message.id)
                                }
                            }

                            // Scroll anchor for auto-follow
                            Color.clear.frame(height: 1).id(bottomAnchor)
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 18)
                        .frame(maxWidth: 780, alignment: .leading)
                        .frame(maxWidth: .infinity)
                    }
                    .onChange(of: conversation.messages.count) { _ in
                        if scrollToLine != nil {
                            jumpToPendingLine(proxy)
                        } else if autoScroll, !isFinding {
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo(bottomAnchor, anchor: .bottom)
                            }
                        }
                    }
                    .onChange(of: currentMatch) { _ in scrollToMatch(proxy) }
                    .onChange(of: findText) { _ in
                        currentMatch = 0
                        scrollToMatch(proxy)
                    }
                    .onChange(of: scrollToLine) { newValue in
                        guard newValue != nil else { return }
                        jumpToPendingLine(proxy)
                    }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
        .overlay(alignment: .topTrailing) {
            if isLive {
                LiveBadge().padding(.top, 10).padding(.trailing, 16)
            }
        }
        .background {
            // Hidden accelerators: ⌘F opens find, Esc closes it.
            Button("") { openFind() }
                .keyboardShortcut("f", modifiers: .command)
                .hidden()
            Button("") { closeFind() }
                .keyboardShortcut(.escape, modifiers: [])
                .hidden()
        }
        .task(id: session.id) { await reload(showSpinner: true) }
        .onChange(of: session.id) { _ in
            startWatching()
            closeFind()
        }
        .onAppear { startWatching() }
        .onDisappear {
            watcher?.stop()
            watcher = nil
            debouncer.cancel()
        }
    }

    private var bottomAnchor: String { "bottom-\(session.id)" }

    private var currentMatchId: String? {
        let matches = matchingMessageIds
        guard !matches.isEmpty else { return nil }
        return matches[min(max(currentMatch, 0), matches.count - 1)]
    }

    // MARK: - Find

    private func openFind() {
        isFinding = true
        findFocused = true
    }

    private func closeFind() {
        isFinding = false
        findText = ""
        currentMatch = 0
        findFocused = false
    }

    private func scrollToMatch(_ proxy: ScrollViewProxy) {
        guard let id = currentMatchId else { return }
        withAnimation(.easeOut(duration: 0.18)) {
            proxy.scrollTo(id, anchor: .center)
        }
    }

    /// Scrolls to and flashes the message at `scrollToLine`, always
    /// consuming it (a miss shouldn't misfire on a later, unrelated reload).
    private func jumpToPendingLine(_ proxy: ScrollViewProxy) {
        guard let line = scrollToLine else { return }
        defer { scrollToLine = nil }
        guard let target = conversation.messages.first(where: { $0.lineNumber == line }) else {
            onJumpMiss()
            return
        }

        // Deferred a tick — scrollTo in the same pass the content just
        // populated can silently no-op before layout catches up.
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.25)) {
                proxy.scrollTo(target.id, anchor: .center)
            }
        }
        flashedMessageId = target.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            guard flashedMessageId == target.id else { return }
            withAnimation(.easeOut(duration: 0.5)) { flashedMessageId = nil }
        }
    }

    /// Messages interleaved with a separator whenever the local calendar day
    /// changes, the way a chat app groups history.
    private var timeline: [TimelineEntry] {
        var entries: [TimelineEntry] = []
        entries.reserveCapacity(conversation.messages.count + 8)

        let calendar = Calendar.current
        var currentDay: Date? = nil

        for message in conversation.messages {
            if let timestamp = message.timestamp {
                let day = calendar.startOfDay(for: timestamp)
                if day != currentDay {
                    currentDay = day
                    entries.append(.daySeparator(day, MessageTime.daySeparator(timestamp)))
                }
            }
            entries.append(.message(message))
        }
        return entries
    }

    // MARK: - Loading

    private func reload(showSpinner: Bool) async {
        if showSpinner { isLoading = true }
        let path = session.filePath
        let loaded = await Task.detached(priority: .userInitiated) {
            ConversationLoader.load(filePath: path)
        }.value
        conversation = loaded
        isLoading = false
    }

    /// Re-watch the transcript whenever the selected session changes.
    private func startWatching() {
        watcher?.stop()
        watcher = nil

        let path = session.filePath
        guard !path.isEmpty else { return }

        watcher = FileWatcher(paths: [path]) { _ in
            debouncer.call {
                Task { @MainActor in
                    await reload(showSpinner: false)
                    flashLive()
                }
            }
        }
    }

    private func flashLive() {
        withAnimation(.easeIn(duration: 0.15)) { isLive = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            withAnimation(.easeOut(duration: 0.4)) { isLive = false }
        }
    }
}

// MARK: - Live indicator

/// Shown briefly when the transcript changes on disk. Static by design — see
/// the note on `ActivityDot` about `repeatForever` and idle CPU.
private struct LiveBadge: View {
    var body: some View {
        HStack(spacing: 5) {
            ActivityDot(size: 5)
            Text("updated")
                .font(Theme.monoFont(9, .medium))
                .foregroundStyle(Theme.result)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(Theme.result.opacity(0.12)))
        .overlay(Capsule().strokeBorder(Theme.result.opacity(0.3), lineWidth: 1))
        .transition(.opacity.combined(with: .scale(scale: 0.9)))
    }
}

// MARK: - Find bar

private struct FindBar: View {
    @Binding var text: String
    @FocusState.Binding var focused: Bool
    let matchCount: Int
    @Binding var currentMatch: Int
    let onClose: () -> Void

    private var hasQuery: Bool {
        !text.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "text.magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textGhost)

            TextField("Find in conversation…", text: $text)
                .textFieldStyle(.plain)
                .font(Theme.monoFont(12))
                .foregroundStyle(Theme.text)
                .focused($focused)
                .onSubmit { step(1) }

            if hasQuery {
                Text(matchCount == 0 ? "no matches" : "\(currentMatch + 1) of \(matchCount)")
                    .font(Theme.monoFont(10))
                    .foregroundStyle(matchCount == 0 ? Theme.error : Theme.textGhost)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
            }

            HStack(spacing: 2) {
                StepButton(icon: "chevron.up", enabled: matchCount > 0) { step(-1) }
                StepButton(icon: "chevron.down", enabled: matchCount > 0) { step(1) }
            }

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.textGhost)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close find (Esc)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(Theme.bgElevated.opacity(0.6))
    }

    /// Wrap around at both ends, the way a document find bar does.
    private func step(_ delta: Int) {
        guard matchCount > 0 else { return }
        currentMatch = ((currentMatch + delta) % matchCount + matchCount) % matchCount
    }
}

private struct StepButton: View {
    let icon: String
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(enabled ? Theme.textDim : Theme.textGhost.opacity(0.4))
                .frame(width: 20, height: 18)
                .background(RoundedRectangle(cornerRadius: 4).fill(Theme.bgElevated))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

// MARK: - Highlighting

extension String {
    /// Case-insensitively emphasise every occurrence of `query`.
    ///
    /// Built by concatenating `Text` runs rather than via `AttributedString`:
    /// SwiftUI's attribute key paths are not Sendable, so styling an
    /// `AttributedString` trips strict-concurrency checking. This is also
    /// cheaper — no attributed-string allocation per message per keystroke.
    func highlighting(_ query: String) -> Text {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return Text(self) }

        var result = Text("")
        var cursor = startIndex

        while let found = range(
            of: needle, options: [.caseInsensitive], range: cursor..<endIndex
        ) {
            if cursor < found.lowerBound {
                result = result + Text(String(self[cursor..<found.lowerBound]))
            }
            result = result + Text(String(self[found]))
                .bold()
                .foregroundColor(Theme.thinking)
            cursor = found.upperBound
            if cursor >= endIndex { break }
        }

        if cursor < endIndex {
            result = result + Text(String(self[cursor...]))
        }
        return result
    }
}

// MARK: - Timeline entries

private enum TimelineEntry: Identifiable {
    case daySeparator(Date, String)
    case message(ConversationMessage)

    var id: String {
        switch self {
        case .daySeparator(let day, _): return "day-\(day.timeIntervalSince1970)"
        case .message(let message):     return message.id
        }
    }
}

/// Centred date pill dividing one day's messages from the next.
private struct DaySeparator: View {
    let label: String

    var body: some View {
        HStack(spacing: 10) {
            Rectangle().fill(Theme.border).frame(height: 1)
            Text(label)
                .font(Theme.monoFont(9, .semibold))
                .foregroundStyle(Theme.textFaint)
                .tracking(0.5)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(Capsule().fill(Theme.bgElevated))
                .overlay(Capsule().strokeBorder(Theme.border, lineWidth: 1))
                .fixedSize()
            Rectangle().fill(Theme.border).frame(height: 1)
        }
        .padding(.vertical, 8)
    }
}

// MARK: - Summary card

private struct SummaryCard: View {
    let summary: String
    let messageCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(summary)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
            Text("\(messageCount) messages")
                .font(Theme.monoFont(10))
                .foregroundStyle(Theme.textFaint)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12).fill(Theme.bgElevated.opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border, lineWidth: 1)
        )
        .padding(.bottom, 6)
    }
}

// MARK: - Message row

private struct MessageRow: View {
    let message: ConversationMessage
    var highlight: String = ""
    var isCurrentMatch: Bool = false
    /// Jumped to from the Findings tab — a stronger, temporary highlight
    /// distinct from the amber find-in-transcript match color.
    var isFlashed: Bool = false

    var body: some View {
        Group {
            if message.isUser {
                userMessage
            } else {
                assistantMessage
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(
                    isFlashed ? Theme.error.opacity(0.28)
                    : isCurrentMatch ? Theme.thinking.opacity(0.10)
                    : .clear
                )
                .padding(.horizontal, -6)
        )
        // A fill alone read as a faint tint easy to miss scrolling past —
        // a visible border is what actually reads as "this one, right here."
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Theme.error.opacity(isFlashed ? 0.7 : 0), lineWidth: 2)
                .padding(.horizontal, -6)
        )
    }

    // Right-aligned bubble — clearly "the human typed this".
    private var userMessage: some View {
        VStack(alignment: .trailing, spacing: 4) {
            if !message.textBlocks.isEmpty {
                HStack(spacing: 6) {
                    if let timestamp = message.timestamp {
                        Text(MessageTime.clock(timestamp))
                            .font(Theme.monoFont(9))
                            .foregroundStyle(Theme.textGhost)
                    }
                    Text("YOU")
                        .font(Theme.monoFont(9, .bold))
                        .foregroundStyle(Theme.userLabel)
                        .tracking(0.8)
                }

                VStack(alignment: .leading, spacing: 6) {
                    ForEach(message.textBlocks) { block in
                        if case .text(let text) = block {
                            text.highlighting(highlight)
                                .font(.system(size: 13))
                                .foregroundStyle(.white)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 10)
                .background(
                    UnevenRoundedRectangle(
                        topLeadingRadius: 14,
                        bottomLeadingRadius: 14,
                        bottomTrailingRadius: 4,
                        topTrailingRadius: 14
                    )
                    .fill(Theme.userBubble)
                )
                .frame(maxWidth: 560, alignment: .trailing)
            }

            auxColumn
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.top, 8)
    }

    // Left rail + plain prose — Claude "speaks on the page", not in a box.
    private var assistantMessage: some View {
        HStack(alignment: .top, spacing: 9) {
            // Avatar + connecting rail
            VStack(spacing: 4) {
                Circle()
                    .fill(Theme.claude)
                    .frame(width: 17, height: 17)
                    .overlay(
                        Text("C")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                    )
                Rectangle()
                    .fill(Theme.claudeSoft)
                    .frame(width: 1)
                    .frame(maxHeight: .infinity)
            }
            .padding(.top, 1)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("CLAUDE")
                        .font(Theme.monoFont(9, .bold))
                        .foregroundStyle(Theme.claude)
                        .tracking(0.8)
                    if let timestamp = message.timestamp {
                        Text(MessageTime.clock(timestamp))
                            .font(Theme.monoFont(9))
                            .foregroundStyle(Theme.textGhost)
                    }
                }

                ForEach(message.textBlocks) { block in
                    if case .text(let text) = block {
                        text.highlighting(highlight)
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.text)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                auxColumn
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
    }

    @ViewBuilder
    private var auxColumn: some View {
        if !message.auxBlocks.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(message.auxBlocks) { block in
                    // Expand every chip when jumped-to, so a secret inside
                    // a collapsed tool result is actually visible.
                    AuxBlockView(block: block, autoExpand: isFlashed)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Tool / thinking / result chips

private struct AuxBlockView: View {
    let block: ContentBlock
    var autoExpand: Bool = false
    @State private var isExpanded = false

    var body: some View {
        content
            .onAppear { if autoExpand { isExpanded = true } }
            .onChange(of: autoExpand) { newValue in
                if newValue { isExpanded = true }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch block {
        case .thinking(let text):
            Chip(
                icon: "lightbulb",
                label: "thinking",
                preview: nil,
                tint: Theme.thinking,
                hasBody: true,
                isExpanded: $isExpanded,
                detail: text,
                detailTint: Theme.textDim
            )

        case .toolUse(_, let name, let icon, let preview, let detail):
            Chip(
                icon: icon,
                label: name,
                preview: preview,
                tint: Theme.tool,
                hasBody: !detail.isEmpty,
                isExpanded: $isExpanded,
                detail: detail,
                detailTint: Theme.text
            )

        case .toolResult(_, let content, let isError):
            Chip(
                icon: isError ? "xmark" : "checkmark",
                label: isError ? "error" : "result",
                preview: content.isEmpty ? nil : previewLine(content),
                tint: isError ? Theme.error : Theme.result,
                hasBody: !content.isEmpty,
                isExpanded: $isExpanded,
                detail: truncate(content),
                detailTint: isError ? Theme.error.opacity(0.85) : Theme.result.opacity(0.85)
            )

        case .text:
            EmptyView()
        }
    }

    private func previewLine(_ s: String) -> String {
        let firstLine = s.split(separator: "\n").first.map(String.init) ?? s
        return firstLine.count > 60 ? String(firstLine.prefix(60)) + "…" : firstLine
    }

    private func truncate(_ s: String, limit: Int = 4000) -> String {
        guard s.count > limit else { return s }
        return String(s.prefix(limit)) + "\n… (\(s.count - limit) more characters)"
    }
}

private struct Chip: View {
    let icon: String
    let label: String
    let preview: String?
    let tint: Color
    let hasBody: Bool
    @Binding var isExpanded: Bool
    let detail: String
    let detailTint: Color

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                guard hasBody else { return }
                withAnimation(.easeOut(duration: 0.12)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: icon)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(tint.opacity(0.8))
                    Text(label)
                        .font(Theme.monoFont(11, .medium))
                        .foregroundStyle(tint)
                    if let preview {
                        Text(preview)
                            .font(Theme.monoFont(11))
                            .foregroundStyle(tint.opacity(0.55))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 260, alignment: .leading)
                    }
                    if hasBody {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(tint.opacity(0.45))
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(tint.opacity(isHovered && hasBody ? 0.16 : 0.10))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(tint.opacity(0.22), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }

            if isExpanded && hasBody {
                // Vertical, not horizontal — text wraps instead of needing
                // to scrub sideways to read long lines.
                ScrollView(.vertical, showsIndicators: true) {
                    Text(detail)
                        .font(Theme.monoFont(11))
                        .foregroundStyle(detailTint)
                        .textSelection(.enabled)
                        .padding(11)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 320)
                .background(
                    RoundedRectangle(cornerRadius: 9).fill(tint.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9).strokeBorder(tint.opacity(0.18), lineWidth: 1)
                )
            }
        }
    }
}

// MARK: - Shared hint view

struct CenteredHint: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 7) {
            Text(title)
                .font(.system(size: 14))
                .foregroundStyle(Theme.textFaint)
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textGhost)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}
