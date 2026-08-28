// goty — see CLAUDE.md for the working principles.
import AppKit

/// Bridge between the app's ChromeTheme (resolved Ghostty config) and
/// the agent webview's CSS variables. The web side derives all further
/// lifts with color-mix, so only the base palette crosses the bridge.
enum AgentTheme {
    /// The CSS variable set for the live theme. Keys match the web
    /// `:root` custom properties (without the `--` prefix).
    static func vars() -> [String: String] {
        let t = Chrome.theme
        let bg = t.background.usingColorSpace(.deviceRGB)!
        // Alpha-wash chrome colors (hairline, translucent-mode hover)
        // composite over the page background: CSS vars carry solid
        // colors only, so borders don't double-blend on lift layers.
        func composited(_ c: NSColor) -> NSColor {
            let x = c.usingColorSpace(.deviceRGB)!
            let a = x.alphaComponent
            if a >= 0.999 { return x }
            return NSColor(deviceRed: bg.redComponent * (1 - a) + x.redComponent * a,
                           green: bg.greenComponent * (1 - a) + x.greenComponent * a,
                           blue: bg.blueComponent * (1 - a) + x.blueComponent * a,
                           alpha: 1)
        }
        func hex(_ c: NSColor) -> String {
            let x = c.usingColorSpace(.deviceRGB)!
            return String(format: "#%02x%02x%02x",
                          Int(round(x.redComponent * 255)),
                          Int(round(x.greenComponent * 255)),
                          Int(round(x.blueComponent * 255)))
        }
        return [
            "surface0": hex(bg),
            "foreground": hex(t.foreground),
            "fg-muted": hex(t.secondaryText),
            "accent": hex(t.accent),
            "accent-bright": hex(t.accentBright),
            "destructive": hex(t.dangerFill),
            "border": hex(composited(t.hairline)),
            "border-accent": hex(composited(t.hoverFill)),
            "mode": t.isDark ? "dark" : "light",
        ]
    }

    /// Push the current theme into the page.
    static func push(to bridge: AgentWebBridge) {
        bridge.push(["type": "theme", "vars": vars()])
    }
}
