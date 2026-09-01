// goty — see CLAUDE.md for the working principles.
import AppKit

// MARK: - Right tool panel (tty7 geometry: 260pt default, 216 min,
// MARK: - 8pt resize handle, sidebar surface + 1px left border)

/// The Info tab: server-side facts (OS/kernel/CPU/GPU/RAM/IP/boot) —
/// fixed per machine, fetched through SystemInfoStore, never re-derived
/// from the focused pane's cwd.

/// The right-side panel: Info + Files tabs. Fully hidden when closed
/// (⌘J). All colors come from ChromeTheme tokens; all icon buttons
/// from the shared IconButton factory.
final class RightPanelView: NSView, ThemeRefreshable {
    /// Click a file in the tree → the built-in editor (wired by the
    /// delegate layer, which knows the focused workspace's machine).
    var onOpenFile: ((String) -> Void)? {
        didSet { filesView?.onOpenFile = onOpenFile }
    }

    /// Double-clicked a file row → its path goes to the terminal pane.
    var onInsertPath: ((String) -> Void)?
    /// Remote transfers, forwarded to the Files tab (delegate layer wires
    /// the host + engine).
    var onUpload: (([URL], String, @escaping (Int64) -> Void,
                    @escaping (Result<Void, Error>) -> Void) -> Void)? {
        didSet { filesView?.onUpload = onUpload }
    }
    var onDownload: ((String, Bool, URL, @escaping (Int64, Int64?) -> Void,
                      @escaping (Result<Void, Error>) -> Void) -> Void)? {
        didSet { filesView?.onDownload = onDownload }
    }

    private var widthConstraint: NSLayoutConstraint!
    private var systemRows: [String: NSTextField] = [:]
    private var systemHost: String?
    private var systemTargetSet = false
    private var infoStack: NSStackView!
    private var filesView: FilesView!
    private var scmView: ScmPanelView!
    private var terminalView: SideTerminalPanelView!

    static let defaultWidth: CGFloat = 260
    static let minWidth: CGFloat = 216
    static let maxWidth: CGFloat = 460
    /// The Terminal tab's own default (a shell at tool width is a
    /// sliver; spec 2026-08-30). Its width memory is per-tab.
    static let terminalDefaultWidth: CGFloat = 400

    /// Build-time-baked colors, re-baked by the theme fan-out walk.
    private var infoLabels: [NSTextField] = []
    private var infoValues: [NSTextField] = []
    private var panelTabs: [PanelTabButton] = []

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        // Tabs (tty7 order: Info / Source Control / Files).
        let tabBar = NSStackView()
        tabBar.orientation = .horizontal
        tabBar.spacing = 6
        tabBar.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tabBar)

        let infoTab = PanelTabButton(label: "Info", symbol: "info.circle")
        let gitTab = PanelTabButton(label: "Git", symbol: "arrow.triangle.branch")
        let filesTab = PanelTabButton(label: "Files", symbol: "folder.fill")
        let terminalTab = PanelTabButton(label: "Terminal", symbol: "terminal")
        infoTab.onClick = { [weak self] in self?.show(tab: .info) }
        gitTab.onClick = { [weak self] in self?.show(tab: .git) }
        filesTab.onClick = { [weak self] in self?.show(tab: .files) }
        terminalTab.onClick = { [weak self] in self?.show(tab: .terminal) }
        // Files first — it is what the panel is opened for; Info last,
        // the machine facts it shows are reference, not workflow.
        tabBar.addArrangedSubview(filesTab)
        tabBar.addArrangedSubview(gitTab)
        tabBar.addArrangedSubview(terminalTab)
        tabBar.addArrangedSubview(infoTab)
        panelTabs = [filesTab, gitTab, terminalTab, infoTab]
        filesTab.isActive = true

        infoStack = makeInfoStack()
        infoStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(infoStack)

        filesView = FilesView()
        filesView.translatesAutoresizingMaskIntoConstraints = false
        filesView.onInsertPath = { [weak self] path in
            self?.onInsertPath?(path)
        }
        addSubview(filesView)
        filesView.isHidden = true

        scmView = ScmPanelView()
        scmView.translatesAutoresizingMaskIntoConstraints = false
        // One git run feeds both tabs: the panel's groups and the tree's
        // status badges.
        scmView.onStatus = { [weak self] st in
            self?.filesView.setGitDecorations(st.map(ScmDecoIndex.build))
        }
        addSubview(scmView)
        scmView.isHidden = true

        terminalView = SideTerminalPanelView()
        terminalView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(terminalView)
        terminalView.isHidden = true

        let hairline = HairlineView()
        hairline.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hairline)

        widthConstraint = widthAnchor.constraint(equalToConstant: Self.defaultWidth)
        NSLayoutConstraint.activate([
            widthConstraint,
            tabBar.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            tabBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            tabBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            hairline.leadingAnchor.constraint(equalTo: leadingAnchor),
            hairline.topAnchor.constraint(equalTo: topAnchor),
            hairline.bottomAnchor.constraint(equalTo: bottomAnchor),
            hairline.widthAnchor.constraint(equalToConstant: 1),
            infoStack.topAnchor.constraint(equalTo: tabBar.bottomAnchor, constant: 10),
            infoStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            infoStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            filesView.topAnchor.constraint(equalTo: tabBar.bottomAnchor, constant: 4),
            filesView.leadingAnchor.constraint(equalTo: leadingAnchor),
            filesView.trailingAnchor.constraint(equalTo: trailingAnchor),
            filesView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scmView.topAnchor.constraint(equalTo: tabBar.bottomAnchor, constant: 4),
            scmView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scmView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scmView.bottomAnchor.constraint(equalTo: bottomAnchor),
            terminalView.topAnchor.constraint(equalTo: tabBar.bottomAnchor, constant: 4),
            terminalView.leadingAnchor.constraint(equalTo: leadingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: trailingAnchor),
            terminalView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        installResizeHandle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder: not implemented") }

    override func draw(_ dirtyRect: NSRect) {
        // tty7: the panel surface IS the sidebar surface.
        // The panel's page uses the terminal's exact background (see
        // SidebarView.draw — any lift mismatches the terminal surface).
        chromeSurface(Chrome.theme.background).setFill()
        bounds.fill()
    }

    // MARK: - Public state

    private var storedWidth = RightPanelView.defaultWidth
    /// The Terminal tab's width slot (spec 2026-08-30): a shell wants
    /// more room than the tool tabs, and its drags must not move the
    /// Files/Git width.
    private var storedTerminalWidth = RightPanelView.terminalDefaultWidth
    private var collapsedNow = false

    /// The width of whichever tab is showing.
    private var activeWidth: CGFloat {
        currentTab == .terminal ? storedTerminalWidth : storedWidth
    }

    /// Clamp-and-store into the ACTIVE tab's slot; drag handle and
    /// preferences both come through here. `onWidthChange` carries the
    /// tab so the owner persists into the matching preference.
    var onWidthChange: ((RightPanelTab?, CGFloat) -> Void)?

    func setWidth(_ w: CGFloat) {
        let clamped = min(max(w, Self.minWidth), Self.maxWidth)
        if currentTab == .terminal {
            storedTerminalWidth = clamped
        } else {
            storedWidth = clamped
        }
        if !collapsedNow { widthConstraint.constant = clamped }
        needsLayout = true
        onWidthChange?(currentTab, clamped)
    }

    /// Fully hidden = zero width (tty7 model; the terminal reclaims the
    /// space). Uncollapsed restores the active tab's width and reports
    /// the reveal — the side terminal's creation gate re-runs with the
    /// panel actually shown.
    var onReveal: (() -> Void)?

    func setCollapsed(_ collapsed: Bool) {
        let wasCollapsed = collapsedNow
        collapsedNow = collapsed
        widthConstraint.constant = collapsed ? 0 : activeWidth
        isHidden = collapsed
        needsLayout = true
        // Only a real show fires the reveal (not the startup restore,
        // whose wiring may not exist yet).
        if !collapsed, wasCollapsed { onReveal?() }
    }

    var width: CGFloat { widthConstraint.constant }

    /// Point the Info tab at the focused workspace's MACHINE (nil host =
    /// local). Same machine = no refetch (TTL in the store). nil is a
    /// VALID host (local), so "never targeted" is its own flag — a nil
    /// sentinel would skip the first local fetch forever.
    func setSystemTarget(host: String?) {
        if systemTargetSet, host == systemHost { return }
        systemTargetSet = true
        systemHost = host
        renderSystem(SystemInfoStore.shared.cached(host: host))
        SystemInfoStore.shared.fetch(host: host) { [weak self] info in
            self?.renderSystem(info)
        }
    }

    private func renderSystem(_ info: SystemInfo?) {
        guard let info else {
            systemRows.values.forEach { $0.stringValue = "…" }
            return
        }
        systemRows["os"]?.stringValue = info.osName.isEmpty ? "—" : info.osName
        systemRows["kernel"]?.stringValue = info.kernel.isEmpty ? "—" : info.kernel
        systemRows["cpu"]?.stringValue = info.cpu.isEmpty ? "—" : info.cpu
        systemRows["gpu"]?.stringValue = info.gpu.isEmpty ? "—" : info.gpu
        systemRows["memory"]?.stringValue = info.memoryText
        systemRows["ip"]?.stringValue = info.ip.isEmpty ? "—" : info.ip
        systemRows["boot"]?.stringValue = info.bootText
    }

    /// Point the Files tab at a directory (nil = nothing to list yet).
    /// Same path + same machine = no-op (refresh() fires often).
    func setDirectory(_ path: String?, source: FileSource?) {
        filesView.setDirectory(path, source: source)
    }

    /// Point the Git tab at the focused pane's repository.
    func setScmTarget(cwd: String?, host: String?) {
        scmView.setTarget(cwd: cwd, host: host,
                          fetchNow: !isHidden && currentTab == .git)
    }

    /// Poll entry for the Git tab (TTL-guarded in the store). No-op
    /// while the panel is collapsed OR another tab is showing — a
    /// hidden view must not run git. Switching back to the Git tab
    /// re-renders from cache on the next tick (the store's TTL keeps
    /// the answer hot), so the gate costs no staleness.
    func refreshScm(force: Bool = false) {
        guard !isHidden, currentTab == .git else { return }
        scmView.refresh(force: force)
    }

    var onScmActivity: (() -> Void)? {
        didSet { scmView.onGitActivity = onScmActivity }
    }

    /// Change-row click → diff document, routed to the editor overlay.
    var onOpenDiff: ((_ path: String, _ staged: Bool, _ untracked: Bool) -> Void)? {
        didSet { scmView.onOpenDiff = onOpenDiff }
    }

    /// Worktrees row → Open, routed to the coordinator.
    var onOpenWorktree: ((String) -> Void)? {
        didSet { scmView.onOpenWorktree = onOpenWorktree }
    }
    var onTabChange: ((RightPanelTab) -> Void)?

    // MARK: Side terminal (Terminal tab; spec 2026-08-30)

    var onNewSideTerminal: (() -> Void)? {
        didSet { terminalView.onNewTerminal = onNewSideTerminal }
    }
    var onCloseSideTerminal: (() -> Void)? {
        didSet { terminalView.onCloseTerminal = onCloseSideTerminal }
    }
    var onCdSideTerminal: (() -> Void)? {
        didSet { terminalView.onCdToSpace = onCdSideTerminal }
    }
    /// The click monitor's side-terminal leg: the live pane hosts.
    var sideTerminalHosts: [any PaneHosting] { terminalView.visibleHosts }

    func setTerminalPanes(_ entries: [(paneKey: HostKey, host: any PaneHosting,
                                        fraction: NSRect)]) {
        terminalView.setPanes(entries)
    }
    func setTerminalCwd(_ path: String?) { terminalView.setCwd(path) }
    func setTerminalCd(enabled: Bool) { terminalView.setCdEnabled(enabled) }

    /// Seed the two width memories from preferences (before the
    /// persisted tab activates; setWidth would route by currentTab).
    func adoptWidths(tool: CGFloat, terminal: CGFloat) {
        storedWidth = min(max(tool, Self.minWidth), Self.maxWidth)
        storedTerminalWidth = min(max(terminal, Self.minWidth), Self.maxWidth)
        if !collapsedNow { widthConstraint.constant = activeWidth }
        needsLayout = true
    }

    // MARK: - Internals

    private var currentTab: RightPanelTab?

    /// The tab bar's activity-bar behavior (lit tile puts the panel
    /// away) routes here; the OWNER wires it to the window controller's
    /// toggle (the in-panel collapse tile is gone — the titlebar owns
    /// the toggle).
    var onCollapseViaTabs: (() -> Void)?

    private func show(tab: RightPanelTab) {
        // tty7: a tile for another tab switches to it; the lit one puts
        // the panel away (activity-bar behavior — a dead click on the
        // one control that looks like it should undo itself).
        if currentTab == tab {
            onCollapseViaTabs?()
            return
        }
        currentTab = tab
        infoStack.isHidden = tab != .info
        filesView.isHidden = tab != .files
        scmView.isHidden = tab != .git
        terminalView.isHidden = tab != .terminal
        if !collapsedNow { widthConstraint.constant = activeWidth }
        let names: [RightPanelTab: String] = [.info: "Info", .git: "Git",
                                              .files: "Files", .terminal: "Terminal"]
        for case let button as PanelTabButton in tabBarSubviews() {
            button.isActive = names[tab] == button.labelText
        }
        onTabChange?(tab)
        if tab == .git { scmView.refresh(force: false) }
    }

    /// Startup restore of the persisted tab (fires onTabChange, which
    /// writes back the same value — harmless; currentTab is nil so the
    /// lit-tile collapse rule cannot fire from a restore).
    func activate(tab: RightPanelTab) { show(tab: tab) }

    /// Theme flip: the panel's contents are built once (show() only
    /// toggles isHidden), so labels/values/tab glyphs re-bake here;
    /// FileRow/PanelTabButton conform and are reached by the walk.
    func retheme() {
        for l in infoLabels { l.textColor = Chrome.theme.secondaryText }
        for v in infoValues { v.textColor = Chrome.theme.foreground }
    }

    private func tabBarSubviews() -> [NSView] {
        subviews.compactMap { $0 as? NSStackView }.first?.arrangedSubviews ?? []
    }


    private func makeInfoStack() -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10

        func row(_ key: String, _ title: String) {
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 10.5, weight: .medium)
            label.textColor = Chrome.theme.secondaryText
            infoLabels.append(label)

            let value = NSTextField(labelWithString: "…")
            value.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            value.textColor = Chrome.theme.foreground
            value.lineBreakMode = .byTruncatingMiddle
            value.cell?.truncatesLastVisibleLine = true
            value.cell?.wraps = false
            value.maximumNumberOfLines = 1
            value.setContentHuggingPriority(.defaultLow, for: .horizontal)
            value.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            infoValues.append(value)
            let pair = NSStackView(views: [label, value])
            pair.orientation = .horizontal
            pair.spacing = 8
            pair.alignment = .firstBaseline
            pair.leadingAnchor.constraint(equalTo: label.leadingAnchor).isActive = true
            systemRows[key] = value
            stack.addArrangedSubview(pair)
        }

        row("os", "System")
        row("kernel", "Kernel")
        row("cpu", "CPU")
        row("gpu", "GPU")
        row("memory", "Memory")
        row("ip", "IP")
        row("boot", "Booted")
        return stack
    }

    private func installResizeHandle() {
        let handle = ResizeHandleView()
        handle.translatesAutoresizingMaskIntoConstraints = false
        handle.onDrag = { [weak self] delta in
            guard let self else { return }
            self.setWidth(self.width - delta)
        }
        addSubview(handle)
        NSLayoutConstraint.activate([
            handle.leadingAnchor.constraint(equalTo: leadingAnchor),
            handle.topAnchor.constraint(equalTo: topAnchor),
            handle.bottomAnchor.constraint(equalTo: bottomAnchor),
            handle.widthAnchor.constraint(equalToConstant: 8),
        ])
    }
}

// MARK: - Tab tile

final class PanelTabButton: NSView, ThemeRefreshable {
    var onClick: (() -> Void)?
    var isActive = false { didSet { needsDisplay = true } }
    let labelText: String

    private var isHovered = false
    private var glyph: IconLabel!

    /// tty7 tab tiles: icon only, 26pt square, the lit one reads by ink
    /// not by width — the label lives in the tooltip.
    init(label text: String, symbol: String) {
        labelText = text
        super.init(frame: .zero)
        toolTip = text
        wantsLayer = true
        layer?.cornerRadius = 6

        let glyph = IconLabel(symbol, pointSize: 12)
        self.glyph = glyph
        addSubview(glyph)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 26),
            heightAnchor.constraint(equalToConstant: 26),
            glyph.centerXAnchor.constraint(equalTo: centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        addTrackingArea(NSTrackingArea(rect: .zero, options: [.inVisibleRect, .activeAlways,
                                                              .mouseEnteredAndExited],
                                       owner: self, userInfo: nil))
        addGestureRecognizer(ActionClickRecognizer { [weak self] in self?.onClick?() })
    }

    required init?(coder: NSCoder) { fatalError("init(coder: not implemented") }

    override func draw(_ dirtyRect: NSRect) {
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).setClip()
        if isActive {
            Chrome.theme.hoverFill.setFill()
            bounds.fill()
        } else if isHovered {
            Chrome.theme.hoverFill.withAlphaComponent(0.5).setFill()
            bounds.fill()
        }
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { isHovered = false; needsDisplay = true }

    /// Theme flip: the glyph tint is baked at init (hover/active fills
    /// already draw from the live theme).
    func retheme() { glyph.contentTintColor = Chrome.theme.iconTint }
}

// MARK: - Status dot (Info agent state)

// MARK: - Files tab

/// 8pt left-edge drag strip (tty7 spec) — grows/shrinks the panel.
final class ResizeHandleView: NSView {
    var onDrag: ((CGFloat) -> Void)?
    private var lastX: CGFloat = 0

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        lastX = event.locationInWindow.x
    }

    override func mouseDragged(with event: NSEvent) {
        let x = event.locationInWindow.x
        onDrag?(x - lastX)
        lastX = x
    }
}



