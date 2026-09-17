import SwiftUI

// MARK: - Flow layout

/// Left-to-right, top-to-bottom wrapping layout for chip rows.
struct FlowLayout: Layout {
    var spacing: CGFloat = 5

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var totalHeight: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth + size.width > maxWidth, rowWidth > 0 {
                totalHeight += rowHeight + spacing
                rowWidth = 0
                rowHeight = 0
            }
            rowWidth += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        totalHeight += rowHeight
        return CGSize(width: maxWidth.isFinite ? maxWidth : rowWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x - bounds.minX + size.width > maxWidth, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Chip

struct TagChip: View {
    let tag: String
    var onTap: (() -> Void)? = nil
    var onRemove: (() -> Void)? = nil

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 4) {
            Text(tag)
                .font(Theme.monoFont(10, .medium))
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 7, weight: .bold))
                }
                .buttonStyle(.plain)
            }
        }
        .foregroundStyle(Theme.brand)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(Theme.brand.opacity(isHovered ? 0.22 : 0.14)))
        .contentShape(Rectangle())
        .onTapGesture { onTap?() }
        .onHover { isHovered = $0 }
    }
}

// MARK: - Add-tag popover

/// Text field + autocomplete suggestions + removable chips for the tags
/// already on this session. Bound to `sessionId` rather than a `ClaudeSession`
/// so it keeps working even for sessions whose transcript file is missing.
struct TagEditorPopover: View {
    let sessionId: String
    @EnvironmentObject private var tagStore: TagStore
    @State private var text = ""
    @FocusState private var focused: Bool

    private var currentTags: [String] { tagStore.tags(for: sessionId) }

    /// Only surfaces once something is typed — with an empty box this would
    /// otherwise dump the entire global tag vocabulary regardless of
    /// relevance to this session.
    private var suggestions: [String] {
        let query = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return [] }
        return tagStore.allTags
            .filter { !currentTags.contains($0) && $0.contains(query) }
            .prefix(8)
            .map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Add tag…", text: $text)
                .textFieldStyle(.plain)
                .font(Theme.monoFont(12))
                .focused($focused)
                .onSubmit(commit)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.bgElevated))

            if !currentTags.isEmpty {
                FlowLayout {
                    ForEach(currentTags, id: \.self) { tag in
                        TagChip(tag: tag, onRemove: { tagStore.remove(tag, from: sessionId) })
                    }
                }
            }

            if !suggestions.isEmpty {
                Rectangle().fill(Theme.border).frame(height: 1)
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(suggestions, id: \.self) { tag in
                        // Only reachable once the field is non-empty (see
                        // `suggestions`), so this can't fire from an idle
                        // cursor resting near a freshly-opened, empty popover.
                        Button {
                            tagStore.add(tag, to: sessionId)
                            text = ""
                        } label: {
                            Text(tag)
                                .font(Theme.monoFont(11))
                                .foregroundStyle(Theme.textDim)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 3)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(10)
        .frame(width: 220)
        .onAppear { focused = true }
    }

    private func commit() {
        tagStore.add(text, to: sessionId)
        text = ""
    }
}
