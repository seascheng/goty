// goty — see CLAUDE.md for the working principles.
import AppKit

// MARK: - Shared UI primitives (design-system level)

/// Static glyph view (NOT a button): theme-tinted SF Symbol at an
/// explicit size, density-aware — the one way rows, headers and tiles
/// place decorative icons. Use `IconButton` when it clicks.
final class IconLabel: NSImageView, ThemeRefreshable {
    private var explicitTint: NSColor?
    convenience init(_ symbol: String, pointSize: CGFloat = 12,
                     weight: NSFont.Weight = .regular, tint: NSColor? = nil) {
        let base = NSImage(systemSymbolName: symbol, accessibilityDescription: symbol)
        self.init(image: base ?? NSImage())
        symbolConfiguration = .init(pointSize: pointSize, weight: weight)
        explicitTint = tint
        contentTintColor = tint ?? Chrome.theme.iconTint
        imageScaling = .scaleProportionallyUpOrDown
        unregisterDraggedTypes()
        translatesAutoresizingMaskIntoConstraints = false
    }

    /// ThemeRefreshable: decorative glyphs re-tint with the theme
    /// (branch icon in the git header) unless the call site chose a
    /// color — same rule as IconButton.
    func retheme() { contentTintColor = explicitTint ?? Chrome.theme.iconTint }
}

/// The ONE window-title label — the main window's "Goty" recipe:
/// 12pt medium, secondaryText, theme-follows on the fan-out. Every
/// titled window's band label (main, SETTINGS, SSH HOSTS) uses this;
/// per-window attributed strings drifted into three different looks
/// that followed the theme three different ways.
final class ChromeTitleLabel: NSTextField, ThemeRefreshable {
    init(_ title: String) {
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        stringValue = title
        font = .systemFont(ofSize: 12, weight: .medium)
        textColor = Chrome.theme.secondaryText
        lineBreakMode = .byTruncatingMiddle
        maximumNumberOfLines = 1
        cell?.truncatesLastVisibleLine = true
        // TAMIC=false or every position constraint on this label loses
        // to the autoresizing mask (the "title under the lights" report).
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    func retheme() { textColor = Chrome.theme.secondaryText }
}

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
final class IconButton: NSView, ThemeRefreshable {
    var onClick: (() -> Void)?
    var tint: NSColor = .secondaryLabelColor { didSet { applyIcon() } }
    /// True while the tile still owns the make()-time themed tint.
    /// A call site that assigns its own color sets this false so the
    /// theme fan-out leaves it alone; every other tile re-tints on
    /// every flip (the SettingsNavRow rule) instead of keeping its
    /// baked color — the light-theme-invisible titlebar buttons.
    var usesThemeTint = true
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

    /// Pointing hand (the AI-card close report) — every icon tile in
    /// the chrome is clickable chrome.
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

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

    /// ThemeRefreshable: re-tint on the app-wide fan-out (titlebar
    /// toggles, sidebar +, git chevron, row action strips).
    func retheme() {
        guard usesThemeTint else { return }
        tint = Chrome.theme.iconTint
    }
}

/// Closure-driven titled button (system bezel).
class ClosureButton: NSButton {
    var onClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onClick?() }
    /// Pointing hand over every closure button (the AI-panel cursor
    /// report) — one base class, product-wide.
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    /// AX presses (VoiceOver, AppleScript) come through here, not
    /// mouseDown — without this override every closure button in the
    /// app is dead to assistive tech.
    override func performClick(_ sender: Any?) { onClick?() }

    /// Standard constructor: small bezel + medium caption, the panel
    /// chrome's one titled-button look (was re-styled by hand at every
    /// call site).
    static func make(title: String, emphasized: Bool = false,
                     onClick: (() -> Void)? = nil) -> ClosureButton {
        let b = ClosureButton()
        b.bezelStyle = .rounded
        b.controlSize = emphasized ? .regular : .small
        b.font = .systemFont(ofSize: emphasized ? 13 : 11, weight: .medium)
        b.title = title
        b.onClick = onClick
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }

    /// In-place style for buttons created as stored members: the same
    /// standard look without re-allocating.
    func applyStandardStyle(title: String) {
        bezelStyle = .rounded
        controlSize = .small
        font = .systemFont(ofSize: 11, weight: .medium)
        self.title = title
        translatesAutoresizingMaskIntoConstraints = false
    }

    /// Status-bar variant: one size down (10.5pt) — the bar's denser
    /// metric, distinct from panel chrome buttons.
    func applyStatusBarStyle(title: String) {
        bezelStyle = .rounded
        controlSize = .small
        font = .systemFont(ofSize: 10.5)
        self.title = title
        translatesAutoresizingMaskIntoConstraints = false
    }
}
