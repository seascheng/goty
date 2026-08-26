// goty — see CLAUDE.md for the working principles.
import AppKit

// MARK: - Agent catalog (tty7's CLIAgent table, adapted)

/// One entry per CLI coding agent we can recognize in a space. Identity
/// is the command the space was spawned with (verified: omp/claude/codex
/// all run under their own binary name); no shell integration needed.
struct AgentSpec {
    let label: String
    let icon: String
    /// Brand hue for the sidebar avatar disc (tty7 `CLIAgent::accent_rgb`).
    let accent: NSColor

    /// goty status palette semantics (goty reference): working=
    /// amber, blocked=red, done=teal — attention colors that read
    /// instantly; blue "info" for active work was illegible.
    static let statusWorking = NSColor(hex: "#F59E00")!
    static let statusWaiting = NSColor(hex: "#F0595E")!
    static let statusDone = NSColor(hex: "#149996")!

}

/// A space row's live TUI status, mirror's agent-row style: the
/// activity plus its seen flag, and the braille spinner character
/// lifted from the live surface title (omp carries one there while it
/// works). The sidebar renders this as a trailing status badge.
struct SpaceStatus {
    let activity: AgentActivity
    let seen: Bool
    let spinner: Character?
}

enum AgentCatalog {
    /// Alias (binary-name stem) → spec. tty7 matches argv0 stems; our
    /// pane_current_command IS the stem, so exact-key lookup suffices.
    static let specs: [String: AgentSpec] = [
        "claude": AgentSpec(label: "Claude Code", icon: "sparkles", accent: NSColor(hex: "#D97757")!),
        "claude-code": AgentSpec(label: "Claude Code", icon: "sparkles", accent: NSColor(hex: "#D97757")!),
        "codex": AgentSpec(label: "Codex", icon: "curlybraces", accent: NSColor(hex: "#101010")!),
        "omp": AgentSpec(label: "OhMyPi", icon: "brain.head.profile", accent: NSColor(hex: "#F97316")!),
        "pi": AgentSpec(label: "Pi", icon: "function", accent: NSColor(hex: "#0EA5E9")!),
        "opencode": AgentSpec(label: "OpenCode", icon: "chevron.left.forwardslash.chevron.right", accent: NSColor(hex: "#6E56CF")!),
        "gemini": AgentSpec(label: "Gemini CLI", icon: "diamond", accent: NSColor(hex: "#4285F4")!),
        "grok": AgentSpec(label: "Grok CLI", icon: "bolt", accent: NSColor(hex: "#101010")!),
        "aider": AgentSpec(label: "Aider", icon: "wrench.and.screwdriver", accent: NSColor(hex: "#8B5CF6")!),
        "goose": AgentSpec(label: "Goose", icon: "bird", accent: NSColor(hex: "#9A8CFF")!),
        "copilot": AgentSpec(label: "Copilot CLI", icon: "person.crop.circle", accent: NSColor(hex: "#8957E5")!),
        "crush": AgentSpec(label: "Crush", icon: "hexagon", accent: NSColor(hex: "#00C2D1")!),
        "sgpt": AgentSpec(label: "ShellGPT", icon: "ant.fill", accent: NSColor(hex: "#10A37F")!),
        "droid": AgentSpec(label: "Droid", icon: "terminal.fill", accent: NSColor(hex: "#F59E0B")!),
    ]

    /// Ordered picker entries for the ⌘N "New Agent Space" submenu.
    static var pickerOrder: [(command: String, spec: AgentSpec)] {
        ["claude", "codex", "omp", "pi", "gemini", "grok", "aider"]
            .compactMap { command in
                specs[command].map { (command, $0) }
            }
    }

    static func spec(for command: String?) -> AgentSpec? {
        guard let command, !command.isEmpty else { return nil }
        if let exact = specs[command] { return exact }
        // Spawn commands drift with the launcher ("OhMyPil" vs "omp") and
        // may arrive as paths ("/usr/local/bin/gemini") — tty7 matches
        // argv0 stems, so normalize to the last path component first.
        let normalized = Self.normalized(command)
        if let mapped = specs[normalized] { return mapped }
        return aliases[normalized].flatMap { specs[$0] }
    }

    /// lowercase, path stem, separator-normalized command name.
    static func normalized(_ command: String) -> String {
        let stem = (command as NSString).lastPathComponent
        return stem.lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: " ", with: "-")
    }

    /// Normalized-but-not-exact names → catalog key.
    static let aliases: [String: String] = [
        "ohmypil": "omp",
        "oh-my-pi": "omp",
        "ohmy-pi": "omp",
        "claudecode": "claude",
    ]

    /// Is this pane command a known agent? (Drives the sidebar badge.)
    static func isAgent(_ command: String?) -> Bool {
        spec(for: command) != nil
    }

    /// Catalog key for a spawn command, after alias/normalization — the
    /// key the passive detection manifests (AgentDetect) are stored under.
    static func manifestKey(for command: String?) -> String? {
        guard let command, !command.isEmpty else { return nil }
        if specs[command] != nil { return command }
        let normalized = Self.normalized(command)
        if specs[normalized] != nil { return normalized }
        return aliases[normalized]
    }
}
