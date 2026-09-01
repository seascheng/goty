// goty — see CLAUDE.md for the working principles.
import AppKit

// MARK: - Agent catalog, the UI treatment

/// The NSColor side of `AgentSpec`: brand accents and the status
/// palette live HERE (UI) so Core keeps zero AppKit — the catalog's
/// colors travel as hex strings across the seam.
extension AgentSpec {
    /// Brand hue for the sidebar avatar disc / tab chip tint.
    var accent: NSColor? { NSColor(hex: accentHex) }
}

/// Status palette (synced with ChromeTheme.statusColor):
/// working=amber, blocked=red, done=teal, idle=green — attention
/// colors that read instantly; blue "info" for active work was
/// illegible. Light variants are the same hues darkened for light
/// backgrounds (the gitAdded rule); the caller picks by isDark.
enum AgentStatusPalette {
    static let working = NSColor(hex: "#F59E05")!
    static let waiting = NSColor(hex: "#F0595E")!
    static let done = NSColor(hex: "#149996")!
    static let idle = NSColor(hex: "#21C45E")!
    static let workingLight = NSColor(hex: "#B45309")!
    static let waitingLight = NSColor(hex: "#B91C1C")!
    static let doneLight = NSColor(hex: "#0E7490")!
    static let idleLight = NSColor(hex: "#15803D")!
}
