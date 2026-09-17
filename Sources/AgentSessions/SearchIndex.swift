import Foundation

/// Full-text search over the *prose* of each transcript.
///
/// Searching the raw JSONL is actively misleading: every session embeds its MCP
/// tool catalogue and system reminders, so a query like "linear" matches all of
/// them via `mcp__linear-server__*` rather than the ten sessions that actually
/// discuss Linear. Only user prompts and assistant text blocks are indexed.
final class SearchIndex: @unchecked Sendable {
    static let shared = SearchIndex()

    /// Bound per-session memory; long sessions are truncated rather than skipped.
    private static let maxCharactersPerSession = 200_000

    private struct Entry {
        let modified: Date
        let size: Int
        let text: String
    }

    private var entries: [String: Entry] = [:]
    private let lock = NSLock()

    // MARK: - Building

    /// Extract and cache prose for one transcript, reusing the cached copy when
    /// the file is unchanged. Transcripts are append-only, so matching size and
    /// modification date means the previous extraction still stands.
    @discardableResult
    func index(filePath: String) -> String {
        guard !filePath.isEmpty else { return "" }

        let attributes = try? FileManager.default.attributesOfItem(atPath: filePath)
        let modified = attributes?[.modificationDate] as? Date ?? .distantPast
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0

        lock.lock()
        if let cached = entries[filePath], cached.modified == modified, cached.size == size {
            lock.unlock()
            return cached.text
        }
        lock.unlock()

        let text = Self.extractProse(filePath: filePath)

        lock.lock()
        entries[filePath] = Entry(modified: modified, size: size, text: text)
        lock.unlock()

        return text
    }

    /// Session ids whose prose contains every whitespace-separated term.
    func matches(query: String, in sessions: [ClaudeSession]) -> Set<String> {
        let terms = query.lowercased()
            .split(separator: " ")
            .map(String.init)
            .filter { !$0.isEmpty }
        guard !terms.isEmpty else { return [] }

        lock.lock()
        let snapshot = entries
        lock.unlock()

        var matched = Set<String>()
        for session in sessions {
            guard let entry = snapshot[session.filePath] else { continue }
            if terms.allSatisfy({ entry.text.contains($0) }) {
                matched.insert(session.id)
            }
        }
        return matched
    }

    func isIndexed(filePath: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return entries[filePath] != nil
    }

    // MARK: - Extraction

    /// Concatenated, lower-cased user prompts and assistant text blocks.
    /// Tool calls, tool results, thinking and harness wrappers are excluded.
    private static func extractProse(filePath: String) -> String {
        guard let raw = try? String(contentsOfFile: filePath, encoding: .utf8) else { return "" }

        var prose = ""
        prose.reserveCapacity(min(raw.count / 4, maxCharactersPerSession))

        for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            guard prose.count < maxCharactersPerSession else { break }
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = obj["type"] as? String,
                  type == "user" || type == "assistant",
                  let msg = obj["message"] as? [String: Any]
            else { continue }

            switch msg["content"] {
            case let text as String:
                append(TextSanitizer.clean(text), to: &prose)

            case let blocks as [[String: Any]]:
                for block in blocks where block["type"] as? String == "text" {
                    if let text = block["text"] as? String {
                        append(TextSanitizer.clean(text), to: &prose)
                    }
                }

            default:
                continue
            }
        }
        return prose
    }

    private static func append(_ text: String, to prose: inout String) {
        guard !text.isEmpty else { return }
        prose += text.lowercased()
        prose += "\n"
    }
}
