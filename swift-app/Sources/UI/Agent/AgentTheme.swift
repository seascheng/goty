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
            "diff-added": hex(t.gitAdded),
            "diff-removed": hex(t.gitRemoved),
            // Terminal-parity translucency: the page paints its body at
            // the config's background-opacity; blur ships as a full
            // filter value (or "none") — see blurFilter().
            "bg-alpha": String(format: "%.2f", t.backgroundOpacity),
            "blur": blurFilter(),
        ]
    }

    /// The full backdrop-filter value, or an explicit "none": installing
    /// blur(0px) is NOT a no-op — any filter function forces WebKit's
    /// backdrop-sampling compositing path, which on a transparent
    /// WKWebView re-samples the native content behind it erratically on
    /// every repaint (the "pane background changes by itself" report).
    private static func blurFilter() -> String {
        guard let conf = liveGhostty?.config else { return "none" }
        switch conf.backgroundBlur {
        case .disabled: return "none"
        case .radius(let r): return "blur(\(Int(r))px)"
        default: return "blur(20px)"   // glass styles: a CSS approximation
        }
    }

    /// Push the current theme into the page.
    static func push(to bridge: WebBridge) {
        bridge.push(["type": "theme", "vars": vars()])
    }
}
