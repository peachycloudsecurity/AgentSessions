import Foundation

/// User-assigned triage status on a `SecretScanner.Finding`.
///
/// Mirrors `TagStore`'s storage shape (a small `[findingId: status]` JSON
/// file in Application Support) — same reasoning applies: hundreds of
/// findings at most, so a flat file beats a database.
enum FindingStatus: String, CaseIterable, Codable {
    case unclassified = "Unclassified"
    case truePositive = "True positive"
    case benignPositive = "Benign positive"
    case falsePositive = "False positive"
}

@MainActor
final class FindingClassificationStore: ObservableObject {
    @Published private(set) var statusByFinding: [String: FindingStatus] = [:]

    private let fileURL: URL
    private let saveDebouncer = Debouncer(delay: 0.3)

    init() {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgentSessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("finding_classifications.json")
        load()
    }

    /// Unclassified is the implicit default — nothing is persisted for it,
    /// so a finding that's never been touched costs nothing in the file.
    func status(for findingId: String) -> FindingStatus {
        statusByFinding[findingId] ?? .unclassified
    }

    func setStatus(_ status: FindingStatus, for findingId: String) {
        if status == .unclassified {
            statusByFinding.removeValue(forKey: findingId)
        } else {
            statusByFinding[findingId] = status
        }
        scheduleSave()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: FindingStatus].self, from: data)
        else { return }
        statusByFinding = decoded
    }

    private func scheduleSave() {
        let snapshot = statusByFinding
        let url = fileURL
        saveDebouncer.call {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
}
