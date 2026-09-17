import Foundation

/// Token spend aggregated across several sessions.
struct UsageRollup: Sendable {
    var tokens = 0
    var cost = 0.0
    var sessionCount = 0
    var hasCost = false

    static let empty = UsageRollup()

    var isEmpty: Bool { tokens == 0 }
}

extension UsageRollup {
    /// Sum usage for every session started today.
    ///
    /// Only today's transcripts are read — scanning all of history would mean
    /// parsing thousands of files on every refresh, and the day's burn is the
    /// number worth watching.
    static func forToday(sessions: [ClaudeSession]) -> UsageRollup {
        let startOfDay = Calendar.current.startOfDay(for: Date())
        let todays = sessions.filter {
            $0.timestamp >= startOfDay && !$0.filePath.isEmpty
        }
        guard !todays.isEmpty else { return .empty }

        var rollup = UsageRollup()
        for session in todays {
            let stats = TranscriptUsageCache.shared.stats(for: session.filePath)
            guard !stats.isEmpty else { continue }

            rollup.tokens += stats.totalTokens
            rollup.sessionCount += 1
            if let cost = stats.estimatedCost {
                rollup.cost += cost
                rollup.hasCost = true
            }
        }
        return rollup
    }
}

/// Caches per-transcript usage keyed by file identity, so a refresh only re-reads
/// transcripts that actually changed. Transcripts are append-only, so a matching
/// size and modification date means the previous total still stands.
final class TranscriptUsageCache: @unchecked Sendable {
    static let shared = TranscriptUsageCache()

    private struct Entry {
        let modified: Date
        let size: Int
        let stats: ConversationStats
    }

    private var entries: [String: Entry] = [:]
    private let lock = NSLock()

    func stats(for filePath: String) -> ConversationStats {
        let attributes = try? FileManager.default.attributesOfItem(atPath: filePath)
        let modified = attributes?[.modificationDate] as? Date ?? .distantPast
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0

        lock.lock()
        if let cached = entries[filePath],
           cached.modified == modified,
           cached.size == size {
            lock.unlock()
            return cached.stats
        }
        lock.unlock()

        let stats = ConversationLoader.scanUsage(filePath: filePath)

        lock.lock()
        entries[filePath] = Entry(modified: modified, size: size, stats: stats)
        lock.unlock()

        return stats
    }
}
