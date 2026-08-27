// goty — see CLAUDE.md for the working principles.
import AppKit
import GhosttyKit

/// The app window: one override, one purpose. In a fullSizeContentView
/// window the system titlebar container (top 32pt, above content)
/// claims multi-click sequences for its own gestures — probe-verified
/// 2026-08-25: clicks with clickCount ≥ 2 reach window.sendEvent but
/// are never delivered to any content view. Chrome tiles live in that
/// band by design, so rapid clicking on them lost every click after
/// the first (the "rapid-click dead toggle" report). Re-dispatch those
/// events straight to the hit IconButton; single clicks keep the normal
/// path (titlebar drag behavior untouched).
final class GotyWindow: NSWindow {
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, event.clickCount >= 2,
           let content = contentView {
            var v = content.hitTest(event.locationInWindow)
            while let cur = v {
                if cur is IconButton {
                    cur.mouseDown(with: event)
                    return
                }
                v = cur.superview
            }
        }
        super.sendEvent(event)
    }
}

// MARK: - Window titlebar band (Ghostty-style)

/// The one window-wide top band: traffic lights (window-level, absolute
/// at the far left) + sidebar toggle, the window title centered, and
/// settings + right-panel toggle at the right edge. The band is a drag
/// surface — empty areas move the window. Below it, the three regions;
/// with the sidebar collapsed the terminal region grows a tab strip
/// right under this band (Ghostty's collapsed shape).
final class TitleBarView: NSView, ThemeRefreshable {
    var onToggleSidebar: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onToggleRightPanel: (() -> Void)?

    private let titleLabel = ChromeTitleLabel("Goty")
    private let sidebarToggle = IconButton.make(
        "rectangle.lefthalf.inset.filled", pointSize: 12)
    private let settingsButton = IconButton.make("gearshape", pointSize: 12)
    private(set) var rightToggle = IconButton.make(
        "rectangle.righthalf.inset.filled", pointSize: 12)

    private var titlebarConstraintsInstalled = false

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = chromeSurface(Chrome.theme.background).cgColor
        // Empty areas drag the window (the old sidebar DragStrip's role).
        // mouseDownCanMoveWindow: true

        sidebarToggle.onClick = { [weak self] in self?.onToggleSidebar?() }
        settingsButton.onClick = { [weak self] in self?.onOpenSettings?() }
        rightToggle.onClick = { [weak self] in self?.onToggleRightPanel?() }
        for v in [sidebarToggle, titleLabel, settingsButton, rightToggle] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError("init(coder: not implemented") }

    override var mouseDownCanMoveWindow: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Lazy: constraints need the common ancestor first. Built ONCE
        // (a rebuild on every move re-registers and duplicates).
        guard titlebarConstraintsInstalled == false else { return }
        titlebarConstraintsInstalled = true
        NSLayoutConstraint.activate([
            sidebarToggle.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 78),
            sidebarToggle.centerYAnchor.constraint(equalTo: centerYAnchor),
            sidebarToggle.widthAnchor.constraint(equalToConstant: 26),
            sidebarToggle.heightAnchor.constraint(equalToConstant: 26),
            // The title sits LEFT, after the sidebar toggle (Ghostty's
            // band shape). NEVER a centerX equality on an autoresizing-
            // content window: it feeds the engine a symmetrical-size
            // pressure it will happily solve by SHRINKING THE WINDOW
            // (the 276pt collapse, root-caused by bisect).
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.leadingAnchor.constraint(
                equalTo: sidebarToggle.trailingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: settingsButton.leadingAnchor, constant: -8),
            rightToggle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            rightToggle.centerYAnchor.constraint(equalTo: centerYAnchor),
            rightToggle.widthAnchor.constraint(equalToConstant: 26),
            rightToggle.heightAnchor.constraint(equalToConstant: 26),
            settingsButton.trailingAnchor.constraint(
                equalTo: rightToggle.leadingAnchor, constant: -2),
            settingsButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            settingsButton.widthAnchor.constraint(equalToConstant: 26),
            settingsButton.heightAnchor.constraint(equalToConstant: 26),
        ])
    }

    private func applyTheme() {
        layer?.backgroundColor = chromeSurface(Chrome.theme.background).cgColor
        // The label must FIGHT for its text width: with only the two
        // spacing inequalities a lazy solve gives it zero width and the
        // band reads empty (the "no title" report).
        titleLabel.setContentHuggingPriority(.required, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(
            .init(750), for: .horizontal)
    }

    func retheme() { applyTheme() }
    var titleLabelFrameForProbe: CGRect { titleLabel.frame }

    /// Text change → intrinsic width change; the label now joins the
    /// solver properly (translatesAutoresizingMaskIntoConstraints off — the
    /// autoresize mask's width==29 pinned it through every solve, the
    /// actual zero-width root cause).
    func setTitle(_ text: String) {
        titleLabel.stringValue = text
        titleLabel.invalidateIntrinsicContentSize()
    }
}

// MARK: - Window composition root (the ONLY cross-region layout)

/// The window's composition root. Owns the shell and exactly three
/// region containers — sidebar, terminal area, right panel — plus the
/// ONLY constraints in the app allowed to reference one region from
/// another. Everything inside a region constrains only within its own
/// container.
///
/// Why this exists: adding one leaf feature (an editor overlay, since
/// rolled back) once collapsed the whole window — its constraints
/// fought the shared engine and the mechanism could not be isolated.
/// With regions as hard boundaries, a leaf can only ever mis-lay-out
/// itself, never the window (2026-08-22 postmortem).
final class AppWindowController: NSObject {
    let window: NSWindow
    let titlebar = TitleBarView()
    let sidebar: SidebarView
    let terminalArea: TerminalAreaView
    let rightPanel: RightPanelView

    private let prefs = AppPreferences.shared
    private var sidebarWidth: NSLayoutConstraint?

    override init() {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800))
        // Regions are created BEFORE super.init (they reference nothing
        // of self) so they can be `let`.
        let sidebar = SidebarView()
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(sidebar)

        let terminalArea = TerminalAreaView()
        terminalArea.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(terminalArea)

        let rightPanel = RightPanelView()
        rightPanel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(rightPanel)
        // Implicit frame animation (Chrome.animate) needs the resizing
        // regions layer-backed.
        for region in [sidebar, terminalArea, rightPanel] { region.wantsLayer = true }
        self.sidebar = sidebar
        self.terminalArea = terminalArea
        self.rightPanel = rightPanel

        // The window-wide titlebar band (traffic lights + toggles +
        // title) — a region ABOVE the three region containers.
        let titlebar = self.titlebar
        titlebar.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(titlebar)

        let window = GotyWindow(
            contentRect: content.bounds,
            // fullSizeContentView must be present at init: inserting it
            // later leaves the native titlebar band in place (black strip).
            styleMask: [.titled, .closable, .miniaturizable, .resizable,
                        .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.title = "Goty"
        // The window never shrinks below the region map's real needs:
        // without a floor, layout-time fitting (the titlebar's intrinsic
        // chain) once collapsed the window to its minimum satisfying
        // size — 276pt wide (user report).
        window.contentMinSize = NSSize(width: 720, height: 420)
        // Programmatic window: close must not release it — the app keeps
        // it alive for the dock-reopen path.
        window.isReleasedWhenClosed = false
        content.wantsLayer = true
        // NO fill on the root content layer: a square window-wide fill
        // sits behind the strip band's capsule and shows as a SECOND
        // (square) background around it (the two-backgrounds report).
        // Each region paints itself; the window backdrop shows through
        // around the capsule.
        window.contentView = content
        // Unified chrome: transparent titlebar, content spans the full
        // window — the frosted sidebar carries the traffic lights and the
        // terminal gets its own slim top strip (Ghostty-style).
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // Tahoe parks the floating capsules low (~y43) which forces a
        // tall blank band above the sidebar; pull them to the classic
        // top-left so content starts at 40pt.
        for (i, button) in [window.standardWindowButton(.closeButton),
                            window.standardWindowButton(.miniaturizeButton),
                            window.standardWindowButton(.zoomButton)].compactMap({ $0 }).enumerated() {
            button.frame.origin = CGPoint(x: 12 + CGFloat(i) * 20, y: 6)
        }
        window.appearance = NSAppearance(
            named: Chrome.theme.isDark ? .darkAqua : .aqua)
        self.window = window
        super.init()

        // --- The region map. Nothing else in the app may constrain ---
        // --- across these boundaries.                                ---
        let widthC = sidebar.widthAnchor.constraint(equalToConstant:
            prefs.sidebarCollapsed ? SidebarView.railWidth : prefs.sidebarWidth)
        sidebarWidth = widthC
        // Priority <required on the horizontal pair: a fully-required
        // chain let the engine solve the WINDOW from the titlebar's
        // intrinsic content (the 276pt collapse) instead of the frame.
        let tbLead = titlebar.leadingAnchor.constraint(equalTo: content.leadingAnchor)
        let tbTrail = titlebar.trailingAnchor.constraint(equalTo: content.trailingAnchor)
        tbLead.priority = .init(999)
        tbTrail.priority = .init(999)
        NSLayoutConstraint.activate([
            tbLead,
            tbTrail,
            titlebar.topAnchor.constraint(equalTo: content.topAnchor),
            titlebar.heightAnchor.constraint(equalToConstant: 30),
            sidebar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: titlebar.bottomAnchor),
            sidebar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            widthC,
            terminalArea.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            terminalArea.trailingAnchor.constraint(equalTo: rightPanel.leadingAnchor),
            rightPanel.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            terminalArea.topAnchor.constraint(equalTo: titlebar.bottomAnchor),
            terminalArea.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            rightPanel.topAnchor.constraint(equalTo: titlebar.bottomAnchor),
            rightPanel.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        // The band's window-owned toggles (settings is the delegate's —
        // it owns the settings window).
        titlebar.onToggleSidebar = { [weak self] in self?.toggleSidebar() }
        titlebar.onToggleRightPanel = { [weak self] in self?.toggleRightPanel() }

        // Restore persisted region state — one place, one order.
        sidebar.setCollapsed(prefs.sidebarCollapsed)
        sidebar.setServersExpanded(!prefs.serversCollapsed)
        sidebar.setFoldedSpaces(Set(prefs.foldedSpaces))
        terminalArea.setTabStripVisible(prefs.sidebarCollapsed)
        rightPanel.setWidth(prefs.rightPanelWidth)
        rightPanel.setCollapsed(!prefs.rightPanelVisible)
        rightPanel.activate(tab: prefs.rightPanelTab)

        window.center()
        // Explicit frame: the first layout pass can otherwise adopt the
        // content's FITTING size (the titlebar chain) and collapse the
        // window to ~276pt — contentRect is only a hint before layout.
        window.setFrame(NSRect(x: window.frame.origin.x, y: window.frame.origin.y,
                               width: 1280, height: 800), display: true)
    }

    // MARK: - Region toggles (menus, shortcuts, collapse buttons)

    /// Repaints window-level surfaces after a theme switch — the
    /// chrome follows the resolved ghostty config (Chrome.swift), and
    /// Settings can now switch it at runtime. Called from the app
    /// delegate's config-change observer.
    func applyChromeTheme(cfg: Ghostty.Config? = nil) {
        // APP-wide, not just this window: popup menus (host pickers,
        // context menus) are their own windows — they follow the app's
        // effective appearance, and a light-theme app with dark menus
        // (or menu hover fills that mismatch the chrome) is the whole
        // "menu items don't follow the theme" class.
        NSApp.appearance = NSAppearance(
            named: Chrome.theme.isDark ? .darkAqua : .aqua)
        window.appearance = NSAppearance(
            named: Chrome.theme.isDark ? .darkAqua : .aqua)

        // background-opacity / background-blur are WINDOW properties —
        // the surface renders its own alpha, but an opaque window and
        // opaque chrome layers behind it swallow it (the "opacity and
        // blur do nothing" report; in real Ghostty the un-vendored
        // TerminalController owns this). ghostty_set_window_background_blur
        // reads the live config itself and no-ops when disabled. `cfg` is
        // the NOTIFICATION's config on change — ghostty.config is
        // replaced only AFTER the post, so reading it there lags one.
        let conf = cfg ?? liveGhostty?.config
        let opacity = conf?.backgroundOpacity ?? 1
        // Ghostty's own rule (TerminalWindow.syncAppearance): a plain
        // radius blur NEVER forces transparency — only opacity < 1 (or
        // the glass styles, which our slider can't write) does. Blur on
        // an opaque window just no-ops (ghostty_set_window_background_
        // blur checks opacity itself), while marking it transparent
        // bought the edge/corner artifacts for nothing.
        let transparent = opacity < 0.999
        window.isOpaque = !transparent
        // OPAQUE: the WINDOW carries the page color. TRANSLUCENT:
        // ghostty's exact recipe (TerminalWindow.swift) — white@0.001,
        // NOT .clear: the near-zero white base keeps the surface's
        // alpha composite bright/neutral (pixel-probed: .clear darkens
        // the whole window; real Ghostty at opacity 0.6 over white reads
        // exactly 119/120 and only with this background). Chrome parity
        // with the surface is then closed on the COLOR side: theme
        // colors are P3-tagged raw values (ChromeTheme.themeColor — the
        // same "Apple-style blending" the surface's P3 IOSurface uses).
        window.backgroundColor = transparent
            ? .white.withAlphaComponent(0.001)
            : Chrome.theme.background
        // Call ONLY when the config enables blur: the C helper maps a
        // zero radius to CGSSetWindowBackgroundBlurRadius(win, 0) — which
        // INSTALLS a zero-radius blur material (a dimming layer behind the
        // window) rather than skipping it. Pixel-probed against real
        // Ghostty at opacity 0.6 over pure white: its terminal reads 119
        // (the exact gamma blend) while ours read 74-113 — everything
        // darkened by the phantom zero-radius material.
        if let gapp = liveGhostty?.app, conf?.backgroundBlur.isEnabled == true {
            ghostty_set_window_background_blur(
                gapp, Unmanaged.passUnretained(window).toOpaque())
        }

        // ONE composite per band: the strip band paints bg@opacity; the
        // pane area stays CLEAR because the ghostty surface itself
        // renders bg@opacity (any layer behind panes double-composites
        // — the mismatched-strip bug).
        let bandColor = chromeSurface(Chrome.theme.topBarBackground)
        terminalArea.setBackdrop(bandColor)
        for host in terminalArea.paneGrid.visibleHosts {
            host.setSurfaceBackdrop(transparent ? nil : Chrome.theme.background)
        }

        titlebar.retheme()
        // Root layer stays clear (see init) — translucency is owned by
        // the window itself, never a fill here.
        window.contentView?.needsDisplay = true
    }

    /// Collapsed ≠ hidden: the sidebar becomes a server-dot rail at
    /// railWidth, and the tabs it was listing move to the terminal
    /// region's top strip. One state machine, persisted.
    func toggleSidebar() {
        prefs.sidebarCollapsed.toggle()
        let collapsed = prefs.sidebarCollapsed
        // Instant width, like every major terminal (Ghostty/iTerm collapse
        // is a hard cut): constraint-driven AppKit width animation proved
        // unreliable (implicit latching and animator() both defer the model
        // value past the layout pass).
        sidebarWidth?.constant = collapsed ? SidebarView.railWidth : prefs.sidebarWidth
        sidebar.setCollapsed(collapsed)
        terminalArea.setTabStripVisible(collapsed)
    }

    func toggleRightPanel() {
        prefs.rightPanelVisible.toggle()
        let visible = prefs.rightPanelVisible
        rightPanel.setCollapsed(!visible)
    }

    /// The titlebar's centered title (AppDelegate owns the text).
    func setChromeTitle(_ text: String) { titlebar.setTitle(text) }

    /// Sidebar drag-resize passthrough (clamped, persisted). Min 225 per
    /// the source-list guideline (Aguzman); the 460 max exceeds the
    /// 350–400 recommendation deliberately — long SSH host names.
    /// ponytail: tighten to 400 if row-truncation reports come in.
    /// Drag stays unanimated: live 1:1 tracking beats any curve.
    func setSidebarWidth(_ width: Double) {
        let clamped = min(max(width, 225), 460)
        sidebarWidth?.constant = clamped
        prefs.sidebarWidth = clamped
    }

    // MARK: - Expand chrome overlays
}

/// The strip's backdrop: ONE self-drawn rounded surface. The fill is
/// set via bandFill (theme/opacity changes repaint); the rounded path
/// itself is the geometry — no outline, no clip tricks, no layer
/// cornerRadius (each of those produced the black-border or
/// square-corner reports).
final class StripBandView: NSView {
    var bandFill: NSColor = .clear { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        bandFill.setFill()
        bounds.fill()
    }
}

// MARK: - Terminal region (pane grid + overlay slot)

/// The terminal column: the pane grid today, full-region overlays when
/// presented. Overlays live INSIDE this container — a presented view
/// covers the terminal area and nothing else, and can never reach the
final class TerminalAreaView: NSView {
    let paneGrid = PaneGridView()
    /// 32pt backdrop band behind the strip (see init for why a band,
    /// not a region fill).
    private let stripBackdrop = StripBandView()

    /// The collapsed-sidebar tab surface (Ghostty-style top bar).
    /// Lives INSIDE the region's top strip, below every overlay a
    /// full-bleed presentation (the editor) puts above it — the
    /// region map never moves.
    let tabStrip = TabStripView()

    /// What the overlay slot currently holds — one slot, several owners
    /// (the editor, the offline cover). Dismissal is scoped to a kind so
    /// a connection event can never tear down the editor (and vice
    /// versa) — the single-slot conflation was a latent cross-feature
    /// bug.
    enum OverlayKind { case editor, offline }
    private(set) var overlayKind: OverlayKind = .offline

    /// The pane grid hangs 32pt below the region's top — the window's
    /// slim top strip. INTERNAL to the region now: a full-bleed overlay
    /// may cover it, and the region map never moves.
    static let topStrip: CGFloat = 28
    private var gridTop: NSLayoutConstraint!

    /// The presented overlay, if any (offline panel, the editor).
    /// Replaced, never stacked.
    private var overlay: NSView?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // The strip's OWN backdrop band: the ghostty surface renders its
        // bg at the config alpha itself, so ANY layer painted behind
        // panes double-composites — one band exactly 32pt tall, clear
        // pane area, and strip + terminal finally read as one piece
        // (the mismatched-strip report).
        stripBackdrop.bandFill = chromeSurface(Chrome.theme.topBarBackground)
        stripBackdrop.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stripBackdrop)
        paneGrid.translatesAutoresizingMaskIntoConstraints = false
        addSubview(paneGrid)
        gridTop = paneGrid.topAnchor.constraint(equalTo: topAnchor, constant: Self.topStrip)
        NSLayoutConstraint.activate([
            paneGrid.leadingAnchor.constraint(equalTo: leadingAnchor),
            paneGrid.trailingAnchor.constraint(equalTo: trailingAnchor),
            gridTop,
            paneGrid.bottomAnchor.constraint(equalTo: bottomAnchor),
            // A flat, full-bleed gray bar: edge to edge, no insets, no
            // rounding (the capsule experiments are rolled back).
            stripBackdrop.leadingAnchor.constraint(equalTo: leadingAnchor),
            stripBackdrop.trailingAnchor.constraint(equalTo: trailingAnchor),
            stripBackdrop.topAnchor.constraint(equalTo: topAnchor),
            stripBackdrop.heightAnchor.constraint(equalToConstant: Self.topStrip),
        ])
        tabStrip.translatesAutoresizingMaskIntoConstraints = false
        tabStrip.isHidden = true   // visible only while the sidebar is a rail
        stripBackdrop.isHidden = true
        addSubview(tabStrip)
        NSLayoutConstraint.activate([
            tabStrip.leadingAnchor.constraint(equalTo: leadingAnchor,
                                              constant: TabStripView.leadingInset),
            tabStrip.trailingAnchor.constraint(equalTo: trailingAnchor),
            tabStrip.topAnchor.constraint(equalTo: topAnchor),
            tabStrip.heightAnchor.constraint(equalToConstant: Self.topStrip),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    /// Written only on change — a no-op isHidden write still dirties
    /// layout (the SidebarRowView hover rule). The strip EXISTS only in
    /// rail mode: expanded, the grid is flush to the region top (the
    /// window titlebar is the only top chrome) and the band is gone;
    /// collapsed, the strip (tabs) sits right under the titlebar and
    /// the grid starts 32pt lower (Ghostty's collapsed shape).
    func setTabStripVisible(_ visible: Bool) {
        if tabStrip.isHidden != !visible {
            tabStrip.isHidden = !visible
            stripBackdrop.isHidden = !visible
        }
        gridTop.constant = visible ? Self.topStrip : 0
    }

    /// Strip band repaint (config change). The pill is SELF-DRAWN
    /// (draw(_:), not a layer fill): a layer's square bounds would
    /// need cornerRadius + masksToBounds juggling on every repaint,
    /// and a same-color surround made the corners invisible anyway —
    /// the pill now draws a hairline outline so its shape reads.
    func setBackdrop(_ color: NSColor) {
        stripBackdrop.bandFill = color
        stripBackdrop.needsDisplay = true
    }


    /// Present a view covering the terminal region. `coversGrid` false
    /// keeps the grid visible for translucent covers; `fullBleed` also
    /// covers the top strip — the editor reaches the window's top edge.
    func presentOverlay(_ view: NSView, kind: OverlayKind = .offline,
                        coversGrid: Bool = true, fullBleed: Bool = false) {
        dismissOverlay()
        overlayKind = kind
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.topAnchor.constraint(equalTo: topAnchor,
                                      constant: fullBleed ? 0 : Self.topStrip),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        overlay = view
        if coversGrid { paneGrid.isHidden = true }
    }

    func dismissOverlay() {
        overlay?.removeFromSuperview()
        overlay = nil
        paneGrid.isHidden = false
    }

    /// Dismiss only if the slot holds THIS kind.
    func dismissOverlay(kind: OverlayKind) {
        guard overlay != nil, overlayKind == kind else { return }
        dismissOverlay()
    }

    var isShowingOverlay: Bool { overlay != nil }
}
