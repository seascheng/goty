// goty — see CLAUDE.md for the working principles.
import Foundation

// MARK: - Shell helpers

/// Shell-quoting shared by the terminal-insert path and remote file ops.
/// One implementation, one truth (was duplicated in three call sites).
enum Shell {
    /// A path that is safe to paste into a shell command line: quoted
    /// only when it needs to be (spaces or embedded quotes).
    static func quotedPath(_ path: String) -> String {
        guard path.contains(" ") || path.contains("'") else { return path }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Always single-quoted (for embedding inside a remote command).
    static func forceQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
