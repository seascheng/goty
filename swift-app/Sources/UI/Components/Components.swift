// goty — see CLAUDE.md for the working principles.
import AppKit

// MARK: - Shared UI primitives (design-system level)

/// Menu-item icon: palette-tinted SF Symbol at menu scale (crisp).
func menuItemIcon(_ symbol: String, pointSize: CGFloat = 11) -> NSImage? {
    NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
        .withSymbolConfiguration(
            .init(pointSize: pointSize, weight: .regular)
                .applying(.init(paletteColors: [Chrome.theme.iconTint])))
}

/// 1px separator surface (sidebar splits, panel edge).
final class HairlineView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        Chrome.theme.hairline.setFill()
        bounds.fill()
    }
}


/// Single-click actuation for leaf rows.
final class ActionClickRecognizer: NSClickGestureRecognizer {
    var onFire: (() -> Void)?

    convenience init(_ action: @escaping () -> Void) {
        self.init(target: nil, action: nil)
        target = self
        self.action = #selector(fire(_:))
        onFire = action
        numberOfClicksRequired = 1
    }

    @objc private func fire(_ rec: NSClickGestureRecognizer) { onFire?() }
}

/// Menu item carrying its action inline (menus are built per click).
final class ActionMenuItem: NSMenuItem {
    private var onFire: (() -> Void)?

    init(_ title: String, symbol: String, action: @escaping () -> Void) {
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        onFire = action
        image = menuItemIcon(symbol, pointSize: 10)
    }

    required init(coder: NSCoder) { fatalError("init(coder: not implemented") }

    @objc private func fire() { onFire?() }
}
final class IconButton: NSView {
    var onClick: (() -> Void)?
    var tint: NSColor = .secondaryLabelColor { didSet { applyIcon() } }
    /// Explicit glyph point size (tty7: 13pt on 32pt tiles).
    var pointSize: CGFloat = 13 { didSet { applyIcon() } }
    var symbol: String = "plus" { didSet { applyIcon() } }

    private let imageView = NSImageView()
    private var hovered = false
    private var ownTracking: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true   // hover fill only
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.unregisterDraggedTypes()
        addSubview(imageView)
        imageView.centerXAnchor.constraint(equalTo: centerXAnchor).isActive = true
        imageView.centerYAnchor.constraint(equalTo: centerYAnchor).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func layout() {
        super.layout()
        // Post-realization only (layer is nil before); idempotent.
        layer?.cornerRadius = 5
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        applyIcon()   // re-render at the new density
    }

    private func applyIcon() {
        guard let base = NSImage(systemSymbolName: symbol, accessibilityDescription: symbol) else {
            imageView.image = nil
            return
        }
        let cfg = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
            .applying(.init(paletteColors: [tint]))
        imageView.image = base.withSymbolConfiguration(cfg) ?? base
    }

    // Tracking is created ONCE: .inVisibleRect follows the view's
    // frame automatically, and rebuilding tracking areas on every
    // updateTrackingAreas call makes AppKit re-fire mouseEntered for
    // the "new" area while the mouse stands still — the hover flicker
    // loop (enter → isHidden/layout → updateTrackingAreas → enter…).
    private func installTrackingOnce() {
        guard ownTracking == nil else { return }
        let t = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(t)
        ownTracking = t
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installTrackingOnce()
        applyIcon()
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        layer?.backgroundColor = Chrome.theme.hoverFill.cgColor
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        layer?.backgroundColor = nil
    }

    override func mouseDown(with event: NSEvent) { onClick?() }

    /// Standard constructor: themed tint, explicit glyph size, action.
    static func make(_ symbol: String, pointSize: CGFloat = 13,
                     onClick: (() -> Void)? = nil) -> IconButton {
        let b = IconButton(frame: .zero)
        b.symbol = symbol
        b.pointSize = pointSize
        b.tint = Chrome.theme.iconTint
        b.onClick = onClick
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }
}

/// Closure-driven titled button (system bezel).
class ClosureButton: NSButton {
    var onClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onClick?() }
    /// AX presses (VoiceOver, AppleScript) come through here, not
    /// mouseDown — without this override every closure button in the
    /// app is dead to assistive tech.
    override func performClick(_ sender: Any?) { onClick?() }
}
