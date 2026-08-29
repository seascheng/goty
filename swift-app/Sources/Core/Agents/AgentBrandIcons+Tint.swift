// goty — see CLAUDE.md for the working principles.
import AppKit

// Lives OUTSIDE the generated AgentIcons.swift so icon regeneration
// (build.sh → gen_agent_icons.py) cannot wipe it.

extension AgentBrandIcons {
    /// The sidebar's template-image treatment, baked to a PNG data URL
    /// for the agent webview: mask brands render in the given tint
    /// (Chrome.theme.iconTint — the sidebar's exact recipe), palette
    /// brands stay native. Theme flips re-push a fresh tint.
    static func tintedDataURL(for kind: String?, color: NSColor,
                              px: CGFloat = 36) -> String? {
        guard let image = image(for: kind) else { return nil }
        let tinted = NSImage(size: NSSize(width: px, height: px))
        tinted.lockFocus()
        let rect = NSRect(x: 0, y: 0, width: px, height: px)
        color.setFill()
        rect.fill()
        // Destination-in: the drawing's alpha masks the tint fill —
        // exactly what AppKit does for a template image.
        image.draw(in: rect, from: .zero, operation: .destinationIn, fraction: 1)
        tinted.unlockFocus()
        guard let tiff = tinted.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return "data:image/png;base64," + png.base64EncodedString()
    }
}

extension AgentBrandIcons {
    /// Menu-slot size: NSMenuItem draws at image.size, and brand images
    /// are 18pt — dwarfing the 10-11pt SF Symbols next to them in the
    /// same menu. The 18pt image stays the sidebar-row size.
    /// (Lives here, not in the GENERATED AgentIcons.swift.)
    static func menuImage(for kind: String?) -> NSImage? {
        guard let image = image(for: kind) else { return nil }
        let small = image.copy() as! NSImage
        small.size = NSSize(width: 11, height: 11)
        return small
    }
}
