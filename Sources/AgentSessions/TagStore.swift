import Foundation

/// User-assigned labels on sessions.
///
/// Kept in the app's own Application Support directory rather than under
/// `~/.claude` — tags must survive even after a transcript is pruned by
/// Claude Code's own retention (see the "no transcript found" case), and this
/// app has no business writing into Claude's data directory.
///
/// Storage is a single `[sessionId: [tag]]` JSON file. At the scale this app
/// operates at — hundreds to low thousands of sessions, on the order of a
/// hundred distinct tags — that's a few tens of KB, loaded once into memory.
/// A database would add complexity without buying anything at this size.
@MainActor
final class TagStore: ObservableObject {
    @Published private(set) var tagsBySession: [String: [String]] = [:]

    private let fileURL: URL
    private let saveDebouncer = Debouncer(delay: 0.3)

    init() {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgentSessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("tags.json")
        load()
    }

    /// Every distinct tag in use, sorted — the autocomplete vocabulary.
    var allTags: [String] {
        Array(Set(tagsBySession.values.flatMap { $0 })).sorted()
    }

    func tags(for sessionId: String) -> [String] {
        tagsBySession[sessionId] ?? []
    }

    func add(_ raw: String, to sessionId: String) {
        let tag = Self.normalize(raw)
        guard !tag.isEmpty else { return }
        var current = tagsBySession[sessionId] ?? []
        guard !current.contains(tag) else { return }
        current.append(tag)
        tagsBySession[sessionId] = current.sorted()
        scheduleSave()
    }

    func remove(_ tag: String, from sessionId: String) {
        guard var current = tagsBySession[sessionId] else { return }
        current.removeAll { $0 == tag }
        tagsBySession[sessionId] = current.isEmpty ? nil : current
        scheduleSave()
    }

    /// Session ids carrying an exact tag — backs `tag:` search filters.
    func sessionIds(taggedWith tag: String) -> Set<String> {
        Set(tagsBySession.filter { $0.value.contains(tag) }.map(\.key))
    }

    static func normalize(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: [String]].self, from: data)
        else { return }
        tagsBySession = decoded
    }

    private func scheduleSave() {
        let snapshot = tagsBySession
        let url = fileURL
        saveDebouncer.call {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
}
