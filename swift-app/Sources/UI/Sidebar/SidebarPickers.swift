// goty — see CLAUDE.md for the working principles.
import AppKit

// MARK: - Sidebar context-menu pickers (color swatch + icon grids)

/// Compact color-swatch GRID for the context menu (Ghostty-style table).
/// draw()-based vector circles on integral frames — layer-backed menu
/// views rasterize blurry; this path stays sharp.
final class ColorGridView: NSView {
    private let swatches = SidebarRowView.tagPalette
    private let onPick: (String?) -> Void
    private let cell: CGFloat = 16
    private let gap: CGFloat = 7
    private let edge: CGFloat = 9
    private let cols = 4

    init(onPick: @escaping (String?) -> Void) {
        self.onPick = onPick
        let rows = (swatches.count + cols - 1) / cols
        let gridW = CGFloat(cols) * cell + CGFloat(cols - 1) * gap
        let gridH = CGFloat(rows) * cell + CGFloat(rows - 1) * gap
        // Match typical menu width so the grid isn't the narrow item, and
        // stretch with the menu (NSMenu sizes to the widest item; without
        // width-flexible autoresizing the custom view stays pinned narrow).
        let w = max(gridW + 2 * edge, 150)
        let h = (edge + gridH + 9 + 0.8 + 7 + cell + edge).rounded()
        super.init(frame: NSRect(x: 0, y: 0, width: w, height: h).integral)
        autoresizingMask = [.width]
        needsDisplay = true
    }

    override func resize(withOldSuperviewSize oldSize: NSSize) {
        super.resize(withOldSuperviewSize: oldSize)
        needsDisplay = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    private var cellFrames: [(NSRect, String?)] {
        var frames: [(NSRect, String?)] = []
        let gridW = CGFloat(cols) * cell + CGFloat(cols - 1) * gap
        let originX = ((bounds.width - gridW) / 2).rounded()
        for (i, item) in swatches.enumerated() {
            let r = i / cols, col = i % cols
            let x = originX + CGFloat(col) * (cell + gap)
            let y = bounds.height - edge - cell - CGFloat(r) * (cell + gap)
            frames.append((NSRect(x: x, y: y, width: cell, height: cell).integral, item.1))
        }
        // None cell centered under a hairline
        let noneY = edge
        frames.append((NSRect(x: ((bounds.width - cell) / 2).rounded(), y: noneY,
                              width: cell, height: cell).integral, nil))
        return frames
    }

    override func draw(_ dirtyRect: NSRect) {
        var separatorY: CGFloat?
        for (frame, hex) in cellFrames {
            if hex == nil { separatorY = frame.maxY + 7 }
            let rect = frame.insetBy(dx: 0.5, dy: 0.5)
            if let hex {
                (NSColor(hex: hex) ?? .white).setFill()
                NSBezierPath(ovalIn: rect).fill()
            } else {
                Chrome.theme.topBarBackground.setFill()
                NSBezierPath(ovalIn: rect).fill()
                Chrome.theme.secondaryText.setStroke()
                let slash = NSBezierPath()
                slash.move(to: NSPoint(x: rect.minX + 2, y: rect.minY + 2))
                slash.line(to: NSPoint(x: rect.maxX - 2, y: rect.maxY - 2))
                slash.lineWidth = 1
                slash.stroke()
            }
            NSColor.black.withAlphaComponent(0.35).setStroke()
            let ring = NSBezierPath(ovalIn: rect)
            ring.lineWidth = 0.8
            ring.stroke()
        }
        if let y = separatorY {
            Chrome.theme.hairline.setFill()
            NSRect(x: edge, y: y, width: bounds.width - 2 * edge, height: 0.8).integral.fill()
        }
    }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        for (frame, hex) in cellFrames where frame.contains(p) {
            onPick(hex)
            if let menu = enclosingMenuItem?.menu { menu.cancelTracking() }
            return
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Icon-picker grid for the context menu (same cell geometry as
/// ColorGridView; cells are palette-tinted SF Symbols).
final class IconGridView: NSView {
    static let choices = [
        "globe", "hammer", "doc.text", "folder",
        "gearshape", "flask", "ant.fill", "book",
        "chart.bar", "server.rack", "brain", "star",
    ]
    private let onPick: (String?) -> Void
    private let cell: CGFloat = 24
    private let gap: CGFloat = 7
    private let edge: CGFloat = 9
    private let cols = 4
    private lazy var icons: [String: NSImage] = {
        var m: [String: NSImage] = [:]
        for s in Self.choices + ["terminal"] {
            m[s] = NSImage(systemSymbolName: s, accessibilityDescription: s)?
                .withSymbolConfiguration(
                    .init(pointSize: 13, weight: .regular)
                        .applying(.init(paletteColors: [Chrome.theme.iconTint])))
        }
        return m
    }()

    init(onPick: @escaping (String?) -> Void) {
        self.onPick = onPick
        let rows = (Self.choices.count + cols - 1) / cols
        let gridW = CGFloat(cols) * cell + CGFloat(cols - 1) * gap
        let gridH = CGFloat(rows) * cell + CGFloat(rows - 1) * gap
        let w = max(gridW + 2 * edge, 150)
        let h = (edge + gridH + 9 + 0.8 + 7 + cell + edge).rounded()
        super.init(frame: NSRect(x: 0, y: 0, width: w, height: h).integral)
        autoresizingMask = [.width]
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    private var cellFrames: [(NSRect, String?)] {
        var frames: [(NSRect, String?)] = []
        let gridW = CGFloat(cols) * cell + CGFloat(cols - 1) * gap
        let originX = ((bounds.width - gridW) / 2).rounded()
        for (i, symbol) in Self.choices.enumerated() {
            let r = i / cols, col = i % cols
            frames.append((NSRect(
                x: originX + CGFloat(col) * (cell + gap),
                y: bounds.height - edge - cell - CGFloat(r) * (cell + gap),
                width: cell, height: cell).integral, symbol))
        }
        frames.append((NSRect(x: ((bounds.width - cell) / 2).rounded(), y: edge,
                              width: cell, height: cell).integral, nil))
        return frames
    }

    /// Center an image at its natural size inside the cell — draw(in: cell)
    /// stretched glyphs to 24pt (big + rough from bitmap scaling).
    private func drawCentered(_ image: NSImage?, in cell: NSRect) {
        guard let image else { return }
        let scale = min(cell.width / image.size.width, cell.height / image.size.height, 1)
        let w = image.size.width * scale, h = image.size.height * scale
        image.draw(in: NSRect(x: cell.midX - w / 2, y: cell.midY - h / 2,
                              width: w, height: h).integral)
    }

    override func draw(_ dirtyRect: NSRect) {
        var separatorY: CGFloat?
        for (frame, symbol) in cellFrames {
            if symbol == nil { separatorY = frame.maxY + 7 }
            if let symbol {
                drawCentered(icons[symbol], in: frame)
            } else {
                // Default: terminal glyph
                drawCentered(icons["terminal"], in: frame)
            }
        }
        if let y = separatorY {
            Chrome.theme.hairline.setFill()
            NSRect(x: edge, y: y, width: bounds.width - 2 * edge, height: 0.8).integral.fill()
        }
    }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        for (frame, symbol) in cellFrames where frame.contains(p) {
            onPick(symbol)
            if let menu = enclosingMenuItem?.menu { menu.cancelTracking() }
            return
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
