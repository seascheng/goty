// goty — see CLAUDE.md for the working principles.
import AppKit
import GhosttyKit

// MARK: - Chrome theme (follows the active Ghostty config)

/// The app shell follows the terminal's theme: colors are read from the
/// RESOLVED Ghostty config (theme file applied), not hardcoded, so the
/// sidebar/top bar/pane chrome match whatever theme the user runs.
struct ChromeTheme {
    let background: NSColor
    let foreground: NSColor
    let accent: NSColor
    /// background-opacity from the resolved config — every big chrome
    /// surface (sidebar, panels, dialogs, strips) paints at THIS alpha
    /// so our GUI composites like the terminal (1 when opaque).
    var backgroundOpacity: CGFloat = 1

    static let fallback = ChromeTheme(
        background: NSColor(srgbRed: 0.11, green: 0.11, blue: 0.11, alpha: 1),
        foreground: NSColor(srgbRed: 0.87, green: 0.87, blue: 0.87, alpha: 1),
        accent: NSColor(srgbRed: 0.30, green: 0.30, blue: 0.30, alpha: 1))

    static func from(_ cfg: Ghostty.Config?) -> ChromeTheme {
        guard let handle = cfg?.config else { return .fallback }
        func color(_ key: String) -> NSColor? {
            var v = ghostty_config_color_s()
            guard ghostty_config_get(handle, &v, key, UInt(key.utf8.count)) else { return nil }
            return NSColor(srgbRed: CGFloat(v.r) / 255, green: CGFloat(v.g) / 255,
                           blue: CGFloat(v.b) / 255, alpha: 1)
        }
        // Explicit config colors win; a theme-only config (theme = Arthur)
        // never surfaces its palette through ghostty_config_get — the
        // theme's own file is the source. Same key syntax as the config.
        let themed = Self.themeFileColors(cfg)
        var t = ChromeTheme(
            background: color("background") ?? themed["background"] ?? fallback.background,
            foreground: color("foreground") ?? themed["foreground"] ?? fallback.foreground,
            accent: color("selection-background") ?? themed["selection-background"] ?? fallback.accent)
        if let handle = cfg?.config {
            var v: Double = 1
            _ = ghostty_config_get(handle, &v, "background-opacity", 18)
            t.backgroundOpacity = CGFloat(max(0.1, min(1, v)))
        }
        return t
    }

    /// `background`/`foreground`/`selection-background` from the theme file
    /// the config names, searched where ghostty looks for themes. One small
    /// file read at startup — the chrome must match the terminal exactly.
    static func themeFileColors(_ cfg: Ghostty.Config?) -> [String: NSColor] {
        guard let trimmed = configuredThemeName(cfg) else { return [:] }
        let home = NSHomeDirectory()
        let candidates = [
            ProcessInfo.processInfo.environment["GHOSTTY_RESOURCES_DIR"]
                .map { $0 + "/themes/\(trimmed)" },
            home + "/Library/Application Support/com.mitchellh.ghostty/themes/\(trimmed)",
            home + "/.config/ghostty/themes/\(trimmed)",
            "/Applications/Ghostty.app/Contents/Resources/ghostty/themes/\(trimmed)",
        ].compactMap { $0 }
        guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }),
              let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [:] }
        var result: [String: NSColor] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let k = parts[0].trimmingCharacters(in: .whitespaces)
            guard ["background", "foreground", "selection-background"].contains(k) else { continue }
            let hex = parts[1].trimmingCharacters(in: .whitespaces)
            guard let c = Self.hexColor(hex) else { continue }
            result[k] = c
        }
        return result
    }
    static func configuredThemeName(_ cfg: Ghostty.Config?) -> String? {
        let home = NSHomeDirectory()
        let candidates = [
            home + "/Library/Application Support/goty/ghostty/config",
            home + "/Library/Application Support/com.mitchellh.ghostty/config.ghostty",
            home + "/Library/Application Support/com.mitchellh.ghostty/config",
            home + "/.config/ghostty/config",
        ]
        for path in candidates {
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                let parts = line.split(separator: "=", maxSplits: 1)
                guard parts.count == 2,
                      parts[0].trimmingCharacters(in: .whitespaces) == "theme" else { continue }
                return parts[1].split(separator: ",").first
                    .map { $0.trimmingCharacters(in: .whitespaces) }
            }
        }
        return nil
    }


    /// `#rrggbb` / `#rgb` theme-file colors.
    private static func hexColor(_ hex: String) -> NSColor? {
        let value = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard value.count == 3 || value.count == 6,
              let parsed = UInt64(value, radix: 16) else { return nil }
        if value.count == 3 {
            let r = CGFloat((parsed >> 8) & 0xF) / 15, g = CGFloat((parsed >> 4) & 0xF) / 15,
                b = CGFloat(parsed & 0xF) / 15
            return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
        }
        let r = CGFloat((parsed >> 16) & 0xFF) / 255, g = CGFloat((parsed >> 8) & 0xFF) / 255,
            b = CGFloat(parsed & 0xFF) / 255
        return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }

    var isDark: Bool {
        let c = background.usingColorSpace(.deviceRGB) ?? background
        return c.brightnessComponent < 0.5
    }

    private func blend(_ base: NSColor, with other: NSColor, fraction t: CGFloat) -> NSColor {
        let b = base.usingColorSpace(.deviceRGB)!, o = other.usingColorSpace(.deviceRGB)!
        return NSColor(srgbRed: b.redComponent + (o.redComponent - b.redComponent) * t,
                       green: b.greenComponent + (o.greenComponent - b.greenComponent) * t,
                       blue: b.blueComponent + (o.blueComponent - b.blueComponent) * t,
                       alpha: 1)
    }

    /// Top strip: one step lighter (dark themes) / darker (light) than the
    /// terminal background — a quiet boundary, not a band.
    var topBarBackground: NSColor {
        isDark ? blend(background, with: NSColor.white, fraction: 0.05)
               : blend(background, with: NSColor.black, fraction: 0.05)
    }

    var hairline: NSColor {
        NSColor.black.withAlphaComponent(isDark ? 0.35 : 0.12)
    }

    var secondaryText: NSColor {
        foreground.withAlphaComponent(0.55)
    }

    /// Hover fill: tty7's recipe — the surface lifted toward the foreground
    /// to a 1.18:1 contrast ratio (raise()); alpha washes read as nothing.
    var hoverFill: NSColor {
        lift(topBarBackground, toward: foreground, ratio: 1.18)
    }

    /// Icon glyphs sit brighter than secondary text (tty7 tiles use the
    /// sidebar foreground, not its muted step).
    var iconTint: NSColor {
        foreground.withAlphaComponent(0.85)
    }

    private func luminance(_ color: NSColor) -> CGFloat {
        guard let c = color.usingColorSpace(.deviceRGB) else { return 0 }
        func channel(_ v: CGFloat) -> CGFloat {
            v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(c.redComponent) + 0.7152 * channel(c.greenComponent)
            + 0.0722 * channel(c.blueComponent)
    }

    private func lift(_ base: NSColor, toward fg: NSColor, ratio: CGFloat) -> NSColor {
        let lb = luminance(base)
        var t: CGFloat = 0.05
        while t <= 1 {
            let mixed = blend(base, with: fg, fraction: t)
            let lm = luminance(mixed)
            if lb <= 0.001 ? lm > 0.05 : (lm + 0.05) / (lb + 0.05) >= ratio {
                return mixed
            }
            t += 0.05
        }
        return blend(base, with: fg, fraction: 1)
    }

    /// Sidebar git meta: diff counts need more contrast than a status dot,
    /// so light themes use the darker steps of the same hues.
    var gitAdded: NSColor {
        NSColor(hex: isDark ? "#22C55E" : "#15803D") ?? .systemGreen
    }
    var gitRemoved: NSColor {
        NSColor(hex: isDark ? "#EF4444" : "#B91C1C") ?? .systemRed
    }

    /// SCM status letters (tty7 pushes these over the theme's semantic
    /// colors; ours derive from the same hue family the counts use).
    var gitModified: NSColor {
        NSColor(hex: isDark ? "#F59E0B" : "#B45309") ?? .systemOrange
    }
    var gitRenamed: NSColor {
        NSColor(hex: isDark ? "#22D3EE" : "#0E7490") ?? .systemCyan
    }

    /// Ring that separates an avatar's status dot from the disc — the
    /// sidebar's own surface, so the dot reads as a badge on any accent.
    var avatarDotRing: NSColor { topBarBackground }

    /// Workspace connection dots (tty7 palette) — computed once per
    /// theme, not per row render.
    var wsConnected: NSColor { NSColor(hex: "#22C55E") ?? .systemGreen }
    var wsConnecting: NSColor { NSColor(hex: "#F59E0B") ?? .systemOrange }
    var wsDisconnected: NSColor { NSColor(hex: "#EF4444") ?? .systemRed }
    /// Destructive fill — THE red the Dialog card already uses,
    /// extracted so every control shares it (one source, ghostty-
    /// themed app: no second palette).
    var dangerFill: NSColor {
        NSColor(calibratedRed: 0.78, green: 0.22, blue: 0.25, alpha: 1)
    }
    /// Destructive text/glyph — the same red, stepped toward the theme
    /// background so it reads on both dark and light themes.
    var dangerText: NSColor {
        blend(dangerFill, with: isDark ? NSColor.white : NSColor.black, fraction: isDark ? 0.25 : 0.1)
    }

    /// Text on a filled accent button — ghostty's selection-background
    /// can be light or dark per theme, so contrast is computed, never
    /// assumed white.
    var accentText: NSColor {
        let c = accent.usingColorSpace(.deviceRGB) ?? accent
        return c.brightnessComponent > 0.6 ? NSColor.black : NSColor.white
    }

    var selectionPill: NSColor {
        isDark ? NSColor.white.withAlphaComponent(0.10) : NSColor.black.withAlphaComponent(0.08)
    }

    /// Editor current-line fill: the same quiet lift as the hover, one
    /// step quieter (tty7/Zed current-line is barely there).
    var lineHighlight: NSColor {
        blend(background, with: isDark ? NSColor.white : NSColor.black,
              fraction: isDark ? 0.045 : 0.035)
    }

    /// Markdown block surfaces (fenced code, table header): a step
    /// CLEARLY above the page — topBarBackground's 5% lift reads as
    /// nothing behind text (user report 2026-08-24).
    var markdownBlockBackground: NSColor {
        blend(background, with: isDark ? NSColor.white : NSColor.black,
              fraction: isDark ? 0.075 : 0.055)
    }
}

enum Chrome {
    /// Posted whenever `theme` is replaced — the single chokepoint.
    /// Chrome surfaces bake colors at build time (locals in inits), so
    /// they re-apply/rebuild themselves on this; the assignment sites
    /// need no fan-out of their own.
    static let themeDidChange = Notification.Name("chromeThemeDidChange")
    static var theme: ChromeTheme = .fallback {
        didSet { NotificationCenter.default.post(name: themeDidChange, object: nil) }
    }
}

/// A big chrome-surface color (sidebar, panel, dialog, strip) at the
/// config's background-opacity — the ONE rule that keeps our GUI
/// compositing in lockstep with the terminal surface. Accent fills
/// (pills, hover) stay opaque on purpose.
func chromeSurface(_ c: NSColor) -> NSColor {
    c.withAlphaComponent(Chrome.theme.backgroundOpacity)
}

/// The live Ghostty app, when the delegate is up (headless tests: nil).
/// One accessor instead of every consumer reaching through NSApp.delegate.
var liveGhostty: Ghostty.App? {
    (NSApp.delegate as? AppDelegate)?.ghostty
}


/// Centered server status page over the terminal region — the one slot
/// a remote workspace owns until it has a shell to show: "connecting"
/// (spinner) while the link boots, "unreachable" with a Reconnect
/// button once it gave up. Success never renders this page; the shell
/// grid replaces it.
final class ServerStatusView: NSView {
    enum Phase { case connecting, unreachable }

    init(wsName: String, phase: Phase, onReconnect: @escaping () -> Void) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Chrome.theme.background.cgColor

        let (symbol, titleText, subText): (String, String, String)
        switch phase {
        case .connecting:
            symbol = "antenna.radiowaves.left.and.right"
            titleText = "Connecting to \"\(wsName)\"…"
            subText = "Setting up Goty on the server over SSH."
        case .unreachable:
            symbol = "wifi.exclamationmark"
            titleText = "\"\(wsName)\" is unreachable"
            subText = "The connection was lost. Your session keeps "
                + "running on the machine."
        }

        let icon = NSImageView(image: NSImage(
            systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = Chrome.theme.secondaryText
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)

        let title = NSTextField(labelWithString: titleText)
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.textColor = Chrome.theme.foreground
        title.translatesAutoresizingMaskIntoConstraints = false
        addSubview(title)

        let sub = NSTextField(labelWithString: subText)
        sub.font = .systemFont(ofSize: 12)
        sub.textColor = Chrome.theme.secondaryText
        sub.translatesAutoresizingMaskIntoConstraints = false
        addSubview(sub)

        if phase == .connecting {
            // The boot pipeline is blocking-serial on one queue: probing,
            // uploading the daemon on first contact — that can take
            // seconds, so say so with a spinner.
            let spin = NSProgressIndicator()
            spin.style = .spinning
            spin.controlSize = .regular
            spin.startAnimation(nil)
            spin.translatesAutoresizingMaskIntoConstraints = false
            addSubview(spin)
            NSLayoutConstraint.activate([
                spin.centerXAnchor.constraint(equalTo: centerXAnchor),
                spin.topAnchor.constraint(equalTo: sub.bottomAnchor, constant: 18),
            ])
        } else {
            let button = ClosureButton.make(title: "Reconnect", emphasized: true,
                                           onClick: onReconnect)
            button.translatesAutoresizingMaskIntoConstraints = false
            addSubview(button)
            NSLayoutConstraint.activate([
                button.centerXAnchor.constraint(equalTo: centerXAnchor),
                button.topAnchor.constraint(equalTo: sub.bottomAnchor, constant: 18),
            ])
        }

        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -45),
            icon.widthAnchor.constraint(equalToConstant: 40),
            icon.heightAnchor.constraint(equalToConstant: 40),
            title.centerXAnchor.constraint(equalTo: centerXAnchor),
            title.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 12),
            sub.centerXAnchor.constraint(equalTo: centerXAnchor),
            sub.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder: not implemented") }
}

// MARK: - Standard UI transition

extension Chrome {
    /// The one animation vocabulary for chrome state changes: 0.3s
    /// (apple-design-motion: response 0.3–0.4, no overshoot on chrome),
    /// implicit — retargets from the live mid-flight value stay smooth
    /// (interruptible) — and instant under Reduce Motion. Frame
    /// animation needs the relayout INSIDE the group: pass the root of
    /// the subtree whose frames change (regions must be layer-backed).
    /// ponytail: Reduce Motion is read per call, not observed via
    /// NSWorkspace.accessibilityDisplayOptionsDidChange — subscribe if
    /// a stale read ever matters.
    static func animate(layout root: NSView? = nil,
                        _ changes: @escaping () -> Void,
                        completion: (() -> Void)? = nil) {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            changes()
            root?.needsLayout = true
            root?.layoutSubtreeIfNeeded()
            completion?()
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.3
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            ctx.allowsImplicitAnimation = true
            changes()
            root?.needsLayout = true
            root?.layoutSubtreeIfNeeded()
        }, completionHandler: completion)
    }
}
