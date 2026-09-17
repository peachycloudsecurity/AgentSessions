import Foundation

/// Regex-based secret detection over raw transcript text. Scans full raw
/// lines (not just prose), caches per session, and rescans incrementally
/// (append-only transcripts) so an active session doesn't get fully
/// re-scanned on every message.
final class SecretScanner: @unchecked Sendable {
    static let shared = SecretScanner()

    /// Serializes scan() so concurrent triggers (FSEvents + baseline loop)
    /// can't run overlapping regex passes on the same/different files.
    private let scanQueue = DispatchQueue(label: "com.peachycloudsecurity.agent-sessions.secret-scan")

    /// Caps how much of one line gets regexed — a single giant pasted blob
    /// living on one JSONL record shouldn't be scanned in full.
    private static let maxScannedLineLength = 20_000

    enum Severity: Int, Comparable {
        case low, medium, high
        static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    struct Finding: Identifiable {
        let sessionId: String
        let label: String
        let severity: Severity
        /// First/last few characters only — never the full matched secret.
        let masked: String
        /// 1-based position in the raw JSONL file, matching
        /// `ConversationMessage.lineNumber` so a finding can be jumped to.
        let lineNumber: Int
        /// Where the match starts on that line — one long line can contain
        /// several distinct real matches of the same label, and without
        /// this they'd collapse onto one id.
        let columnOffset: Int

        /// Built from position, never the matched value — this id is
        /// persisted (classification store), so it can't leak the secret.
        var id: String { "\(sessionId)|\(lineNumber)|\(columnOffset)|\(label)" }
    }

    private struct Pattern {
        let label: String
        let severity: Severity
        let regex: NSRegularExpression
        let maskValue: Bool
    }

    /// Wraps a token pattern so it can't match as a bare substring of a
    /// longer identifier (message/tool IDs, base64 blobs).
    private static func bounded(_ core: String, leftClass: String = "A-Za-z0-9") -> String {
        "(?<![\(leftClass)])\(core)(?![A-Za-z0-9])"
    }

    private static func pattern(
        _ label: String, _ severity: Severity, _ raw: String, mask: Bool = true
    ) -> Pattern {
        Pattern(label: label, severity: severity, regex: try! NSRegularExpression(pattern: raw), maskValue: mask)
    }

    private static let patterns: [Pattern] = [
        // MARK: Credentials — high confidence, high severity.
        pattern("Private key", .high, #"-----BEGIN (RSA |EC |DSA |OPENSSH )?PRIVATE KEY-----"#, mask: false),
        pattern("AWS access key ID", .high, bounded(#"A(BIA|CCA|GPA|I(DA|PA)|KIA|N(PA|VA)|PKA|ROA|S(CA|IA))[A-Z0-9]{16,17}"#)),
        pattern("AWS secret access key", .high, #"(?i)aws([^;]{0,32}?)['"][0-9a-zA-Z/+=]{40}['"]"#),
        pattern("Amazon MWS auth token", .high, #"(?i)amzn\.mws\.[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}"#),
        pattern("Google API key", .high, bounded(#"AIza[0-9A-Za-z\-_]{35}"#)),
        pattern("Google OAuth access token", .high, #"ya29\.[0-9A-Za-z\-_]{32,48}"#),
        pattern("Google OAuth client secret", .high, #"GOCSPX-[0-9a-zA-Z\-_]{28}"#),
        pattern("MailGun API key", .high, bounded(#"key-[0-9a-f]{32}"#, leftClass: "A-Za-z0-9-")),
        pattern("NuGet API key", .high, bounded(#"oy2[a-z0-9]{43}"#)),
        pattern("SendGrid API key", .high, #"SG\.[0-9A-Za-z\-_]{22}\.[0-9A-Za-z\-_]{43}"#),
        pattern("Slack token", .high, #"x(ox[psboare]|app)(-[a-zA-Z0-9]{1,64}){1,5}"#),
        pattern("Slack webhook", .high, #"hooks\.slack\.com/services/T[a-zA-Z0-9_]{8,10}/B[a-zA-Z0-9_]{8,10}/[a-zA-Z0-9_]{24}"#, mask: false),
        pattern("Microsoft Teams webhook", .high, #"outlook\.office(365)?\.com/webhook/[\w\-@]{1,128}"#, mask: false),
        pattern("Microsoft Teams webhook", .high, #"[\w\-]+\.webhook\.office\.com"#, mask: false),
        pattern("Square token", .high, #"sq0(atp|csp|idp)-[0-9A-Za-z\-_]{22,43}"#),
        pattern("Stripe API key", .high, #"[sr]k_(live|test)_[0-9a-zA-Z]{24}"#),
        pattern("Stripe webhook secret", .high, #"whsec_[0-9a-zA-Z]{32}"#),
        pattern("Twilio API key SID", .high, bounded(#"SK[0-9a-zA-Z]{32}"#)),
        pattern("GitHub token", .high, #"gh[pousr]_[A-Za-z0-9]{36}"#),
        pattern("GitHub fine-grained PAT", .high, #"github_pat_[0-9a-zA-Z]{22}_[0-9a-zA-Z]{59}"#),
        pattern("OpenAI API key", .high, bounded(#"sk-[a-zA-Z0-9]{40,128}"#, leftClass: "A-Za-z0-9-")),
        pattern("Linear API key", .high, bounded(#"lin_api_[A-Za-z0-9]{36,44}"#)),

        // MARK: Lower-confidence / generic — worth a look, not proof of a leak.
        pattern("JWT", .medium, #"eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}"#),
        pattern("Generic API key", .medium, #"(?i)api.{0,5}key[^&|;?,]{0,32}?['"][a-zA-Z0-9_\-+=/\\]{10,128}['"]"#),
        pattern("Generic secret", .medium, #"(?i)secret[^&|;?,]{0,32}?['"][a-zA-Z0-9_\-+=/\\]{10,128}['"]"#),

        // MARK: Informational / PII — not secrets, just worth surfacing.
        pattern("Google OAuth client ID", .low, #"\d{1,20}-\w{32}\.apps\.googleusercontent\.com"#, mask: false),
        pattern("Firebase database URL", .low, #"[\w.\-]+\.(firebaseio\.com|firebasedatabase\.app)"#, mask: false),
        pattern("Environment file reference", .low, #"\.env\b"#, mask: false),
        pattern("Private IPv4 address", .low, #"1(0(\.[0-2]\d{0,2}){3}|27(\.[0-2]\d{0,2}){3}|92\.168(\.[0-2]\d{0,2}){2}|72\.(1[6-9]|2\d|3[0-2])(\.[0-2]\d{0,2}){2})(?![\d.])"#, mask: false),
        pattern("Email address", .low, #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, mask: false),
        pattern("AWS S3 bucket URL", .low, #"[a-z0-9\-]{3,63}\.s3(\.dualstack|-acce(lerate|sspoint))?\.([a-z]{1,8}-[a-z]{1,16}-\d{1,3}\.)?amazonaws\.com"#, mask: false),
        pattern("Azure Blob Storage URL", .low, #"[\w\-]+\.blob\.core\.windows\.net"#, mask: false),
        pattern("Google Cloud Storage URI", .low, #"gs://[a-z0-9\-]{3,63}"#, mask: false),
        pattern("Amazon ARN", .low, #"arn:aws(-(cn|us-gov|iso-[bcd]))?:[\w/.\-]{1,63}:([\w/.\-]{0,63}:){2}[\w:/.\-]{0,1023}"#, mask: false),
    ]

    /// Marks a pasted secret-detection ruleset/fixture (e.g. `{"regex": "...",
    /// "tests": [...]}`), not a live credential — suppresses the whole line.
    private static let fixtureContextMarkers = [#""tests":"#, #""regex":"#]

    private struct CacheEntry {
        var modified: Date
        var size: Int
        var scannedLineCount: Int
        var seen: Set<String>
        var findings: [Finding]
    }

    /// Keyed by session id, not file path — a path string can vary in
    /// representation across call sites and would otherwise double-count.
    private var cache: [String: CacheEntry] = [:]
    private let lock = NSLock()

    /// Scans (or returns the cached result for) one transcript. Only lines
    /// appended since the last scan get regexed.
    @discardableResult
    func scan(sessionId: String, filePath: String) -> [Finding] {
        guard !filePath.isEmpty else { return [] }

        let attributes = try? FileManager.default.attributesOfItem(atPath: filePath)
        let modified = attributes?[.modificationDate] as? Date ?? .distantPast
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0

        lock.lock()
        let cached = cache[sessionId]
        lock.unlock()

        if let cached, cached.modified == modified, cached.size == size {
            return cached.findings
        }

        return scanQueue.sync {
            lock.lock()
            let recheck = cache[sessionId]
            lock.unlock()
            if let recheck, recheck.modified == modified, recheck.size == size {
                return recheck.findings
            }

            guard let raw = try? String(contentsOfFile: filePath, encoding: .utf8) else {
                return recheck?.findings ?? []
            }
            let allLines = raw.split(separator: "\n", omittingEmptySubsequences: true)

            let canAppendOnly = recheck.map { size > $0.size && allLines.count >= $0.scannedLineCount } ?? false
            let startIndex = canAppendOnly ? recheck!.scannedLineCount : 0
            var findings: [Finding] = canAppendOnly ? recheck!.findings : []
            var seen: Set<String> = canAppendOnly ? recheck!.seen : []

            for index in startIndex..<allLines.count {
                let fullLine = String(allLines[index])

                // Checked pre-truncation, and with `\"` normalized to `"` —
                // a JSONL line is itself JSON, so pasted JSON content has
                // its quotes escaped (`\"regex\":`), not literal.
                let markerCheckLine = fullLine.replacingOccurrences(of: "\\\"", with: "\"")
                if Self.fixtureContextMarkers.contains(where: { markerCheckLine.contains($0) }) { continue }

                let line = fullLine.count > Self.maxScannedLineLength
                    ? String(fullLine.prefix(Self.maxScannedLineLength))
                    : fullLine

                let nsLine = line as NSString
                let fullRange = NSRange(location: 0, length: nsLine.length)

                for entry in Self.patterns {
                    entry.regex.enumerateMatches(in: line, range: fullRange) { match, _, _ in
                        guard let match, let range = Range(match.range, in: line) else { return }
                        let matched = String(line[range])

                        // AWS's own docs use this placeholder everywhere.
                        if matched.uppercased().contains("EXAMPLE") { return }

                        let key = "\(entry.label)|\(matched)"
                        guard !seen.contains(key) else { return }
                        seen.insert(key)
                        findings.append(Finding(
                            sessionId: sessionId,
                            label: entry.label,
                            severity: entry.severity,
                            masked: entry.maskValue ? Self.mask(matched) : matched,
                            lineNumber: index + 1,
                            columnOffset: match.range.location
                        ))
                    }
                }
            }

            lock.lock()
            cache[sessionId] = CacheEntry(
                modified: modified, size: size, scannedLineCount: allLines.count, seen: seen, findings: findings
            )
            lock.unlock()

            return findings
        }
    }

    /// Everything scanned so far, across every session. Callers sort/filter.
    func allFindings() -> [Finding] {
        lock.lock()
        defer { lock.unlock() }
        return cache.values.flatMap { $0.findings }
    }

    private static func mask(_ secret: String) -> String {
        guard secret.count > 8 else { return String(repeating: "•", count: secret.count) }
        return "\(secret.prefix(4))…\(secret.suffix(4))"
    }
}
