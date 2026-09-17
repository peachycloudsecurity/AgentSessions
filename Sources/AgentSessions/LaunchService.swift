import AppKit
import Foundation

enum LaunchResult {
    case success(String)
    case failure(String)
}

/// Resumes a session in Terminal.app.
///
/// Editors are deliberately not supported: neither VS Code nor Cursor exposes a
/// way to run a command in its integrated terminal from outside — no CLI flag,
/// no URI scheme — so the best they could do was open a folder, which is not
/// what this button is for.
enum LaunchService {
    private static let terminalBundleID = "com.apple.Terminal"

    /// The shell command a user would type to resume this session.
    static func resumeCommand(for session: ClaudeSession) -> String {
        "cd \(shellQuote(session.projectPath)) && claude --resume \(session.id)"
    }

    static func resume(session: ClaudeSession) -> LaunchResult {
        guard let terminalURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: terminalBundleID
        ) else {
            return .failure("Terminal is not available")
        }

        // Session ids and project paths come from ~/.claude/history.jsonl, which
        // this app does not own. Validate before either reaches a filename or a
        // shell, rather than relying on quoting alone.
        guard let sessionId = validatedSessionId(session.id) else {
            return .failure("Session has a malformed id")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: session.projectPath, isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            return .failure("Project folder no longer exists")
        }

        // Driving Terminal with AppleScript needs the Automation entitlement and
        // a TCC prompt, and fails silently without them. Opening a throwaway
        // .command script needs no special permission.
        let claude = resolveClaudeCLI() ?? "claude"
        let script = """
        #!/bin/bash
        cd \(shellQuote(session.projectPath)) || exit 1
        exec \(shellQuote(claude)) --resume \(shellQuote(sessionId))
        """

        // Own subdirectory, owner-only, so the script is never world-readable nor
        // sitting somewhere another process can race us.
        let scriptDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("resume", isDirectory: true)
        let scriptURL = scriptDirectory.appendingPathComponent("\(sessionId).command")

        do {
            try FileManager.default.createDirectory(
                at: scriptDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try? FileManager.default.removeItem(at: scriptURL)
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: scriptURL.path
            )
        } catch {
            return .failure("Could not prepare the resume script")
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(
            [scriptURL], withApplicationAt: terminalURL, configuration: configuration
        ) { _, error in
            // Terminal keeps the script running; clean up once it has started.
            DispatchQueue.global().asyncAfter(deadline: .now() + 30) {
                try? FileManager.default.removeItem(at: scriptURL)
            }
            if let error {
                NSLog("Terminal launch failed: \(error.localizedDescription)")
            }
        }

        return .success("Resuming in Terminal")
    }

    // MARK: - Helpers

    /// Claude Code is usually installed outside the GUI PATH, so probe directly.
    private static func resolveClaudeCLI() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.bun/bin/claude",
            "\(home)/.npm-global/bin/claude",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Claude session ids are UUIDs. Parsing with `UUID` rejects path separators,
    /// `..`, shell metacharacters and anything else that could turn a filename
    /// into a traversal or a command into an injection.
    ///
    /// The *original* string is returned, not `uuid.uuidString`: the latter
    /// upper-cases, and transcripts on disk are named in lower case, so the
    /// normalised form would fail to resume. Anything that parses as a UUID can
    /// only contain hex digits and dashes, so the original is equally safe.
    private static func validatedSessionId(_ id: String) -> String? {
        UUID(uuidString: id) == nil ? nil : id
    }

    /// POSIX single-quote escaping: wrap in `'…'` and rewrite each embedded
    /// quote as `'\''`. Inside single quotes the shell expands nothing, so no
    /// metacharacter in `value` can escape the literal.
    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
