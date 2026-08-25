// ReadOnlyPolicy — the executor-side command classifier. The model never
// decides its own permissions; every bash tool call passes through here.
import Foundation

struct ReadOnlyPolicy {
    /// v1 allowlist: first word → allowed (git restricted to read subcommands).
    private static let plainAllow: Set<String> = [
        "pwd", "ls", "cat", "head", "tail", "file", "stat", "wc", "du", "df",
        "grep", "rg", "echo", "which", "whoami", "id", "uname", "hostname",
        "date", "ps",
    ]
    private static let gitRead: Set<String> = [
        "status", "diff", "log", "show", "branch", "remote", "rev-parse",
        "describe", "tag", "stash",
    ]
    /// Git subcommands that destroy work — red-warning risk, never auto.
    private static let gitDestructive: Set<String> = ["reset", "clean"]
    private static let destructiveHeads: Set<String> = [
        "rm", "rmdir", "chmod", "chown", "dd", "mkfs", "shutdown", "reboot",
        "kill", "pkill", "truncate", "shred",
    ]
    /// Any of these anywhere in the command disqualifies auto-execution.
    private static let metachars: Set<Character> = ["|", "&", ";", ">", "<", "`", "(", ")", "$", "\n"]

    static func autoExecutable(_ command: String) -> Bool {
        classify(command) == .readOnly
    }

    static func classify(_ command: String) -> CommandRisk {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .mutating }
        guard !trimmed.contains(where: { metachars.contains($0) }) else { return .mutating }
        let words = trimmed.split(separator: " ").map(String.init)
        guard let head = words.first?.lowercased() else { return .mutating }
        if destructiveHeads.contains(head) { return .destructive }
        if head == "git" {
            guard let sub = words.dropFirst().first?.lowercased() else { return .mutating }
            if gitDestructive.contains(sub) { return .destructive }
            return gitRead.contains(sub) ? .readOnly : .mutating
        }
        if head == "sudo" { return .mutating }
        if head == "env" || head == "printenv" { return .mutating }  // secrets
        if head == "find" {
            let flags = words.dropFirst()
            let banned = ["-exec", "-execdir", "-ok", "-okdir", "-delete", "-fprintf", "-fprint", "-fls"]
            if flags.contains(where: { banned.contains($0) }) { return .mutating }
            return .readOnly
        }
        return plainAllow.contains(head) ? .readOnly : .mutating
    }
}
