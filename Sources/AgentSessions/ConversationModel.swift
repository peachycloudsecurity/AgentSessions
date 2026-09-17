import Foundation

// MARK: - Content blocks

/// Tool input is rendered to display strings during parsing rather than stored
/// as `[String: Any]`: it keeps the model `Sendable` for the background parse,
/// and moves formatting off the render path.
enum ContentBlock: Identifiable, Sendable {
    case text(String)
    case thinking(String)
    case toolUse(id: String, name: String, icon: String, preview: String?, detail: String)
    case toolResult(toolUseId: String, content: String, isError: Bool)

    var id: String {
        switch self {
        case .text(let s):                  return "t-\(s.hashValue)"
        case .thinking(let s):              return "k-\(s.hashValue)"
        case .toolUse(let id, _, _, _, _):  return "u-\(id)"
        case .toolResult(let id, let c, _): return "r-\(id)-\(c.count)"
        }
    }
}

// MARK: - Message

struct ConversationMessage: Identifiable, Sendable {
    enum Role: Sendable { case user, assistant }

    let id: String
    let role: Role
    let blocks: [ContentBlock]
    let timestamp: Date?
    /// 1-based position in the raw JSONL file (same enumeration `SecretScanner`
    /// uses), so a Findings-tab hit can be matched back to the message that
    /// produced it.
    let lineNumber: Int

    var isUser: Bool { role == .user }

    /// Blocks rendered inside the chat bubble.
    var textBlocks: [ContentBlock] {
        blocks.filter { if case .text = $0 { return true }; return false }
    }

    /// Blocks rendered as standalone chips beneath the bubble.
    var auxBlocks: [ContentBlock] {
        blocks.filter {
            switch $0 {
            case .thinking, .toolUse, .toolResult: return true
            case .text: return false
            }
        }
    }

    var isEmpty: Bool { blocks.isEmpty }
}

struct Conversation: Sendable {
    let summary: String?
    let messages: [ConversationMessage]
    let stats: ConversationStats
}

// MARK: - Model pricing

/// Per-million-token USD rates, keyed by model family.
enum ModelPricing {
    struct Rates {
        let input: Double
        let output: Double
        let cacheWrite: Double
        let cacheRead: Double
    }

    private static let opus   = Rates(input:  5, output: 25, cacheWrite:  6.25, cacheRead: 0.5)
    private static let sonnet = Rates(input:  3, output: 15, cacheWrite:  3.75, cacheRead: 0.3)
    private static let haiku  = Rates(input:  1, output:  5, cacheWrite:  1.25, cacheRead: 0.1)
    private static let fable  = Rates(input: 10, output: 50, cacheWrite: 12.50, cacheRead: 1.0)
    /// Legacy Opus (3 / 4.0 / 4.1) billed at $15/$75 before Opus 4.5.
    private static let opusLegacy = Rates(input: 15, output: 75, cacheWrite: 18.75, cacheRead: 1.5)

    /// Nil for synthetic or non-Anthropic models — better to show nothing than
    /// to invent a Claude rate for a model we did not price.
    static func rates(for model: String?) -> Rates? {
        guard let model, !model.isEmpty, model != "<synthetic>" else { return nil }
        let name = model.lowercased()

        if name.contains("opus") {
            if name.contains("claude-3-opus")
                || name.contains("opus-4-0")
                || name.contains("opus-4-1") { return opusLegacy }
            return opus
        }
        if name.contains("sonnet") { return sonnet }
        if name.contains("haiku")  { return haiku }
        if name.contains("fable")  { return fable }
        return nil
    }

    /// Context window for a model. Claude Code's 1M-context tier only applies to
    /// recent Opus/Sonnet, so infer from observed usage rather than guessing.
    static func contextLimit(model: String?, observedPeak: Int) -> Int {
        observedPeak > 200_000 ? 1_000_000 : 200_000
    }
}

// MARK: - Context usage

/// A point-in-time snapshot of how full the context window is.
///
/// "Used" is the prompt side only — `input + cache_read + cache_creation`.
/// Output tokens are excluded: they are generated, not sent, and only enter the
/// window on the following turn.
struct ContextUsage: Sendable {
    let used: Int
    let model: String?

    var limit: Int { ModelPricing.contextLimit(model: model, observedPeak: used) }

    var fraction: Double {
        guard limit > 0 else { return 0 }
        return min(Double(used) / Double(limit), 1)
    }

    var percent: Int { Int((fraction * 100).rounded()) }
}

// MARK: - Usage stats

/// Aggregated from the `usage` block Claude Code records on assistant turns.
/// Everything here is accumulated during the single parse pass — no extra I/O.
struct ConversationStats: Sendable {
    var userTurns = 0
    var assistantTurns = 0
    var toolCalls = 0

    var inputTokens = 0
    var outputTokens = 0
    var cacheReadTokens = 0
    var cacheWriteTokens = 0

    /// Largest single-turn context footprint seen — approximates how full the
    /// window got, since every turn resends the whole conversation.
    var peakContext = 0
    var model: String?

    var firstTimestamp: Date?
    var lastTimestamp: Date?

    static let empty = ConversationStats()

    var totalTokens: Int {
        inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens
    }

    /// Context window for the model this session used.
    var contextLimit: Int {
        ModelPricing.contextLimit(model: model, observedPeak: peakContext)
    }

    /// Estimated USD spend. Nil when the model has no known Anthropic rate.
    var estimatedCost: Double? {
        guard let rates = ModelPricing.rates(for: model) else { return nil }
        let perMillion = 1_000_000.0
        return Double(inputTokens)      / perMillion * rates.input
             + Double(outputTokens)     / perMillion * rates.output
             + Double(cacheWriteTokens) / perMillion * rates.cacheWrite
             + Double(cacheReadTokens)  / perMillion * rates.cacheRead
    }

    var contextFraction: Double {
        guard contextLimit > 0 else { return 0 }
        return min(Double(peakContext) / Double(contextLimit), 1)
    }

    var duration: TimeInterval? {
        guard let first = firstTimestamp, let last = lastTimestamp else { return nil }
        let delta = last.timeIntervalSince(first)
        return delta > 0 ? delta : nil
    }

    var isEmpty: Bool { totalTokens == 0 && toolCalls == 0 }
}

// MARK: - Local date formatting

/// Transcripts store UTC ISO-8601 timestamps. These formatters use the system
/// calendar, locale and time zone, so a reader in IST sees IST and a reader in
/// UTC sees UTC, with 12- or 24-hour clock per their macOS preference.
enum MessageTime {
    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    /// Numeric day/month/year, ordered per locale — d/M/yyyy in en-IN,
    /// M/d/yyyy in en-US.
    private static let numericDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("dMyyyy")
        return formatter
    }()

    /// e.g. "1:45 PM" or "13:45".
    static func clock(_ date: Date) -> String {
        time.string(from: date)
    }

    /// e.g. "Today", "Yesterday", "22/7/2026".
    static func daySeparator(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        return numericDay.string(from: date)
    }
}

// MARK: - Sanitizer

enum TextSanitizer {
    /// Strips harness-injected wrappers that are noise to a human reader.
    private static let patterns: [NSRegularExpression] = {
        let sources = [
            "<command-name>[^<]*</command-name>",
            "<command-message>[^<]*</command-message>",
            "<command-args>[^<]*</command-args>",
            "<local-command-stdout>[^<]*</local-command-stdout>",
            "<local-command-caveat>[\\s\\S]*?</local-command-caveat>",
            "<system-reminder>[\\s\\S]*?</system-reminder>",
            "^\\s*Caveat: The messages below were generated by the user[\\s\\S]*?asks you to\\.",
        ]
        return sources.compactMap {
            try? NSRegularExpression(pattern: $0, options: [.anchorsMatchLines])
        }
    }()

    static func clean(_ text: String) -> String {
        var result = text
        for regex in patterns {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(
                in: result, range: range, withTemplate: ""
            )
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Loader

enum ConversationLoader {
    /// Parse a session's .jsonl transcript into renderable messages.
    static func load(filePath: String) -> Conversation {
        guard !filePath.isEmpty,
              let raw = try? String(contentsOfFile: filePath, encoding: .utf8)
        else { return Conversation(summary: nil, messages: [], stats: .empty) }

        var summary: String? = nil
        var messages: [ConversationMessage] = []
        var stats = ConversationStats()
        var index = 0

        // Claude Code appends an assistant entry per streaming chunk and per
        // retry, all sharing one (message.id, requestId). Counting every entry
        // inflates usage several-fold, so bill each pair exactly once.
        var countedUsage = Set<String>()

        let isoFractional = ISO8601DateFormatter()
        isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        isoPlain.formatOptions = [.withInternetDateTime]

        for (rawIndex, line) in raw.split(separator: "\n", omittingEmptySubsequences: true).enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty,
                  let data = trimmed.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            let type = obj["type"] as? String

            if type == "summary" {
                if summary == nil, let s = obj["summary"] as? String { summary = s }
                continue
            }

            guard type == "user" || type == "assistant" else { continue }
            guard let msg = obj["message"] as? [String: Any] else { continue }

            // Timestamps bound the session duration and label each message.
            var messageTimestamp: Date? = nil
            if let tsString = obj["timestamp"] as? String,
               let ts = isoFractional.date(from: tsString) ?? isoPlain.date(from: tsString) {
                if stats.firstTimestamp == nil { stats.firstTimestamp = ts }
                stats.lastTimestamp = ts
                messageTimestamp = ts
            }

            let blocks = parseContent(msg["content"])
            guard !blocks.isEmpty else { continue }

            // Roll up usage + composition.
            if type == "assistant" {
                stats.assistantTurns += 1

                let model = msg["model"] as? String
                if stats.model == nil, let model, model != "<synthetic>" {
                    stats.model = model
                }

                if let usage = msg["usage"] as? [String: Any] {
                    // Dedupe on (message.id, requestId); fall back to counting
                    // when either is absent rather than dropping real usage.
                    let messageId = msg["id"] as? String
                    let requestId = obj["requestId"] as? String ?? obj["request_id"] as? String
                    var shouldCount = true
                    if let messageId, let requestId {
                        shouldCount = countedUsage.insert("\(messageId):\(requestId)").inserted
                    }

                    if shouldCount {
                        let input  = usage["input_tokens"] as? Int ?? 0
                        let output = usage["output_tokens"] as? Int ?? 0
                        let read   = usage["cache_read_input_tokens"] as? Int ?? 0
                        let write  = usage["cache_creation_input_tokens"] as? Int ?? 0

                        stats.inputTokens      += input
                        stats.outputTokens     += output
                        stats.cacheReadTokens  += read
                        stats.cacheWriteTokens += write
                        stats.peakContext = max(stats.peakContext, input + read + write)
                    }
                }
            } else {
                stats.userTurns += 1
            }

            stats.toolCalls += blocks.reduce(into: 0) { count, block in
                if case .toolUse = block { count += 1 }
            }

            index += 1
            let uuid = (obj["uuid"] as? String) ?? "msg-\(index)"
            messages.append(ConversationMessage(
                id: uuid,
                role: type == "user" ? .user : .assistant,
                blocks: blocks,
                timestamp: messageTimestamp,
                lineNumber: rawIndex + 1
            ))
        }

        return Conversation(summary: summary, messages: messages, stats: stats)
    }

    /// Token totals only — no text sanitising, no block construction.
    ///
    /// The full `load` spends most of its time running regexes over message text,
    /// which is wasted when all we want is usage. Used for cross-session rollups.
    static func scanUsage(filePath: String) -> ConversationStats {
        guard !filePath.isEmpty,
              let raw = try? String(contentsOfFile: filePath, encoding: .utf8)
        else { return .empty }

        var stats = ConversationStats()
        var countedUsage = Set<String>()

        for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  obj["type"] as? String == "assistant",
                  let msg = obj["message"] as? [String: Any],
                  let usage = msg["usage"] as? [String: Any]
            else { continue }

            if stats.model == nil,
               let model = msg["model"] as? String,
               model != "<synthetic>" {
                stats.model = model
            }

            // Same (message.id, requestId) dedupe as the full parser: Claude Code
            // repeats an entry per streaming chunk and retry.
            if let messageId = msg["id"] as? String,
               let requestId = obj["requestId"] as? String ?? obj["request_id"] as? String {
                guard countedUsage.insert("\(messageId):\(requestId)").inserted else { continue }
            }

            let input  = usage["input_tokens"] as? Int ?? 0
            let output = usage["output_tokens"] as? Int ?? 0
            let read   = usage["cache_read_input_tokens"] as? Int ?? 0
            let write  = usage["cache_creation_input_tokens"] as? Int ?? 0

            stats.inputTokens      += input
            stats.outputTokens     += output
            stats.cacheReadTokens  += read
            stats.cacheWriteTokens += write
            stats.peakContext = max(stats.peakContext, input + read + write)
        }
        return stats
    }

    /// Context footprint of the most recent assistant turn.
    ///
    /// Reads only the tail of the file, so cost is constant no matter how large
    /// the transcript grows — used by the menu bar, which polls on every change.
    static func latestContextUsage(filePath: String, tailBytes: Int = 256_000) -> ContextUsage? {
        guard !filePath.isEmpty,
              let handle = FileHandle(forReadingAtPath: filePath)
        else { return nil }
        defer { try? handle.close() }

        guard let size = try? handle.seekToEnd(), size > 0 else { return nil }
        let offset = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd(),
              let chunk = String(data: data, encoding: .utf8)
        else { return nil }

        // Walk backwards to the newest assistant turn carrying a usage block.
        for line in chunk.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  obj["type"] as? String == "assistant",
                  let msg = obj["message"] as? [String: Any],
                  let usage = msg["usage"] as? [String: Any]
            else { continue }

            let input = usage["input_tokens"] as? Int ?? 0
            let read  = usage["cache_read_input_tokens"] as? Int ?? 0
            let write = usage["cache_creation_input_tokens"] as? Int ?? 0
            let used = input + read + write
            guard used > 0 else { continue }

            return ContextUsage(used: used, model: msg["model"] as? String)
        }
        return nil
    }

    // MARK: Content parsing

    private static func parseContent(_ content: Any?) -> [ContentBlock] {
        // Plain-string content
        if let str = content as? String {
            let cleaned = TextSanitizer.clean(str)
            return cleaned.isEmpty ? [] : [.text(cleaned)]
        }

        // Array of typed blocks
        guard let array = content as? [[String: Any]] else { return [] }

        var blocks: [ContentBlock] = []
        for part in array {
            switch part["type"] as? String {
            case "text":
                if let text = part["text"] as? String {
                    let cleaned = TextSanitizer.clean(text)
                    if !cleaned.isEmpty { blocks.append(.text(cleaned)) }
                }

            case "thinking":
                if let thinking = part["thinking"] as? String, !thinking.isEmpty {
                    blocks.append(.thinking(thinking))
                }

            case "tool_use":
                let id = (part["id"] as? String) ?? UUID().uuidString
                let name = (part["name"] as? String) ?? "tool"
                let input = (part["input"] as? [String: Any]) ?? [:]
                blocks.append(.toolUse(
                    id: id,
                    name: name,
                    icon: ToolPresentation.icon(for: name),
                    preview: ToolPresentation.preview(toolName: name, input: input),
                    detail: input.isEmpty
                        ? ""
                        : ToolPresentation.formatInput(input, toolName: name)
                ))

            case "tool_result":
                let id = (part["tool_use_id"] as? String) ?? UUID().uuidString
                let isError = (part["is_error"] as? Bool) ?? false
                let text = TextSanitizer.clean(stringify(part["content"]))
                blocks.append(.toolResult(toolUseId: id, content: text, isError: isError))

            default:
                continue
            }
        }
        return blocks
    }

    /// Flatten a tool_result payload (string, block array, or arbitrary JSON) to text.
    private static func stringify(_ value: Any?) -> String {
        if let s = value as? String { return s }

        if let array = value as? [[String: Any]] {
            let parts = array.compactMap { part -> String? in
                if part["type"] as? String == "text" { return part["text"] as? String }
                return nil
            }
            if !parts.isEmpty { return parts.joined(separator: "\n") }
        }

        guard let value,
              let data = try? JSONSerialization.data(
                withJSONObject: value, options: [.prettyPrinted, .sortedKeys]
              ),
              let json = String(data: data, encoding: .utf8)
        else { return "" }
        return json
    }
}

// MARK: - Tool presentation

enum ToolPresentation {
    /// SF Symbol for a tool name.
    static func icon(for toolName: String) -> String {
        switch toolName.lowercased() {
        case "todowrite":        return "checklist"
        case "read":             return "doc.text"
        case "bash":             return "terminal"
        case "grep":             return "magnifyingglass"
        case "edit":             return "pencil"
        case "write":            return "square.and.pencil"
        case "glob":             return "folder"
        case "task", "agent":    return "cpu"
        default:
            let name = toolName.lowercased()
            if name.contains("web") || name.contains("fetch") || name.contains("url") {
                return "globe"
            }
            if name.contains("ask") || name.contains("question") {
                return "bubble.left"
            }
            if name.contains("git") || name.contains("commit") {
                return "arrow.triangle.branch"
            }
            if name.contains("sql") || name.contains("database") || name.contains("query") {
                return "cylinder.split.1x2"
            }
            return "wrench.and.screwdriver"
        }
    }

    /// Short inline hint shown next to the tool name on the collapsed chip.
    static func preview(toolName: String, input: [String: Any]) -> String? {
        func shortPath(_ path: String) -> String {
            path.split(separator: "/").suffix(2).joined(separator: "/")
        }

        switch toolName.lowercased() {
        case "read", "edit", "write":
            return (input["file_path"] as? String).map(shortPath)

        case "bash":
            guard let cmd = input["command"] as? String else { return nil }
            return cmd.count > 50 ? String(cmd.prefix(50)) + "…" : cmd

        case "grep":
            return (input["pattern"] as? String).map { "\"\($0)\"" }

        case "glob":
            return input["pattern"] as? String

        case "task":
            return input["description"] as? String

        default:
            if let url = input["url"] as? String {
                return URL(string: url)?.host ?? String(url.prefix(30))
            }
            return nil
        }
    }

    /// Pretty-printed tool input for the expanded view.
    static func formatInput(_ input: [String: Any], toolName: String) -> String {
        let name = toolName.lowercased()

        // Favour the single most meaningful field for common tools.
        if name == "bash", let cmd = input["command"] as? String {
            let desc = input["description"] as? String
            return desc.map { "# \($0)\n\(cmd)" } ?? cmd
        }
        if name == "write",
           let path = input["file_path"] as? String,
           let content = input["content"] as? String {
            return "\(path)\n\n\(content)"
        }
        if name == "edit",
           let path = input["file_path"] as? String,
           let old = input["old_string"] as? String,
           let new = input["new_string"] as? String {
            let minus = old.split(separator: "\n", omittingEmptySubsequences: false)
                .map { "- \($0)" }.joined(separator: "\n")
            let plus = new.split(separator: "\n", omittingEmptySubsequences: false)
                .map { "+ \($0)" }.joined(separator: "\n")
            return "\(path)\n\n\(minus)\n\(plus)"
        }
        if name == "todowrite", let todos = input["todos"] as? [[String: Any]] {
            return todos.map { todo in
                let status = (todo["status"] as? String) ?? "pending"
                let mark = status == "completed" ? "[x]"
                         : status == "in_progress" ? "[~]" : "[ ]"
                return "\(mark) \((todo["content"] as? String) ?? "")"
            }.joined(separator: "\n")
        }

        guard let data = try? JSONSerialization.data(
                withJSONObject: input, options: [.prettyPrinted, .sortedKeys]
              ),
              let json = String(data: data, encoding: .utf8)
        else { return "\(input)" }
        return json
    }
}
