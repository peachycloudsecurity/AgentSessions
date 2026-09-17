import Foundation

// MARK: - Model

struct ClaudeSession: Identifiable {
    let id: String           // session UUID
    let display: String      // pre-computed title from history.jsonl
    let projectPath: String  // full project path (the cwd)
    let projectName: String  // last path component — short label
    let timestamp: Date
    let filePath: String     // path to the .jsonl conversation file (may be "" if not found)
}

extension ClaudeSession {
    var relativeTime: String {
        let diff = Date().timeIntervalSince(timestamp)
        switch diff {
        case ..<60:     return "just now"
        case ..<3600:   return "\(Int(diff / 60))m ago"
        case ..<86400:  return "\(Int(diff / 3600))h ago"
        case ..<604800: return "\(Int(diff / 86400))d ago"
        default:
            let fmt = DateFormatter()
            fmt.dateStyle = .medium
            fmt.timeStyle = .none
            return fmt.string(from: timestamp)
        }
    }
}

// MARK: - history.jsonl entry

private struct HistoryEntry: Decodable {
    let display: String
    let timestamp: Double   // Unix ms
    let project: String     // full project path, e.g. "/Users/me/Desktop/myapp"
    let sessionId: String?  // nil on old entries
}

// MARK: - Loader

struct SessionLoader {
    static let claudeDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude")

    private static let projectsDir = claudeDir.appendingPathComponent("projects")

    static func loadAll() -> [ClaudeSession] {
        let historyFile = claudeDir.appendingPathComponent("history.jsonl")
        guard let raw = try? String(contentsOf: historyFile, encoding: .utf8) else {
            return []
        }

        let lines = raw
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        // One pass over ~/.claude/projects builds sessionId -> path for every
        // transcript, so per-entry lookup is O(1) instead of a directory scan.
        let index = buildFileIndex()

        let decoder = JSONDecoder()
        var sessions: [ClaudeSession] = []
        var seenIds = Set<String>()

        for line in lines {
            guard let data = line.data(using: .utf8),
                  let entry = try? decoder.decode(HistoryEntry.self, from: data)
            else { continue }

            let sessionId: String
            if let sid = entry.sessionId, !sid.isEmpty {
                sessionId = sid
            } else {
                // Fallback for old entries without a stored sessionId:
                // find the .jsonl file whose mtime is closest to the entry timestamp.
                guard let sid = findSessionByMtime(
                    projectPath: entry.project,
                    unixMs: entry.timestamp
                ) else { continue }
                sessionId = sid
            }

            guard !seenIds.contains(sessionId) else { continue }
            seenIds.insert(sessionId)

            let ts = Date(timeIntervalSince1970: entry.timestamp / 1000.0)
            let filePath = index[sessionId] ?? ""
            let projectName = entry.project
                .split(separator: "/")
                .last
                .map(String.init) ?? entry.project

            // history.jsonl stores the raw prompt, which may carry harness wrappers.
            let cleaned = TextSanitizer.clean(entry.display)
            let display = cleaned.isEmpty ? "Untitled session" : cleaned

            sessions.append(ClaudeSession(
                id: sessionId,
                display: display,
                projectPath: entry.project,
                projectName: projectName,
                timestamp: ts,
                filePath: filePath
            ))
        }

        // history.jsonl is oldest-first; reverse to show newest first
        return sessions.reversed()
    }

    // MARK: - Helpers

    /// Encode a project path to the directory name used under ~/.claude/projects/
    /// Mirrors: path.replace(/[/.]/g, "-")
    private static func encodedProjectDir(_ path: String) -> String {
        path
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")
    }

    /// Map every transcript on disk to its session id in a single directory walk.
    /// Filenames are `<sessionId>.jsonl`, so no file contents are read here.
    private static func buildFileIndex() -> [String: String] {
        let fm = FileManager.default
        guard let projectDirs = try? fm.contentsOfDirectory(atPath: projectsDir.path)
        else { return [:] }

        var index: [String: String] = [:]
        index.reserveCapacity(2048)

        for dir in projectDirs {
            let dirPath = projectsDir.appendingPathComponent(dir)
            guard let files = try? fm.contentsOfDirectory(atPath: dirPath.path) else { continue }
            for file in files where file.hasSuffix(".jsonl") {
                let sessionId = String(file.dropLast(".jsonl".count))
                index[sessionId] = dirPath.appendingPathComponent(file).path
            }
        }
        return index
    }

    private static func findSessionByMtime(projectPath: String, unixMs: Double) -> String? {
        let encoded = encodedProjectDir(projectPath)
        let dir = projectsDir.appendingPathComponent(encoded)
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path)
        else { return nil }

        let targetTs = unixMs / 1000.0
        var bestId: String? = nil
        var bestDiff = Double.infinity

        for file in files where file.hasSuffix(".jsonl") {
            let filePath = dir.appendingPathComponent(file)
            if let attrs = try? FileManager.default.attributesOfItem(atPath: filePath.path),
               let mtime = attrs[.modificationDate] as? Date {
                let diff = abs(mtime.timeIntervalSince1970 - targetTs)
                if diff < bestDiff {
                    bestDiff = diff
                    bestId = String(file.dropLast(".jsonl".count))
                }
            }
        }
        return bestId
    }
}
