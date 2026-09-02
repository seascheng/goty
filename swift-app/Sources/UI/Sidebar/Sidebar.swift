// goty — see CLAUDE.md for the working principles.
import AppKit

// MARK: - Sidebar (Ghostty-style unified chrome)

/// Section header with an inline trailing '+' (adds within the section)
/// and an optional muted row count (tty7 group headers carry one).
/// `emphasized` marks the two top-level titles (SERVERS/SPACES): one
/// size up, bold, always lit — the muted step is for group headers only.
/// The `plus` closure receives the button itself so popups can anchor
/// beside it.
///
/// Reconfigurable in place: section headers are REUSED across sidebar
/// renders (the row-reuse rule — no view churn, no hover flicker), so
/// the '+' stays hoverable while titles/counts rebind per pass.
final class SectionHeaderView: NSView, ThemeRefreshable {
    private var lastText = ""
    private var lastCount: Int?
    private let label = NSTextField(labelWithString: "")
    private let countField = NSTextField(labelWithString: "")
    private var onPlus: ((NSView) -> Void)?
    private var onToggle: (() -> Void)?
    private var lastExpanded = true
    private let plusButton = IconButton.make("plus", pointSize: 11)
    /// Section fold (SERVERS): chevron beside the '+' — down when the
    /// rows are listed, right when folded away. Hidden unless a toggle
    /// closure is configured (only the SERVERS header has one).
    private let toggleButton = IconButton.make("chevron.down", pointSize: 10)
    private let emphasized: Bool
    private var plusFlush: NSLayoutConstraint!
    private var plusShifted: NSLayoutConstraint!
    init(emphasized: Bool = false) {
        self.emphasized = emphasized
        super.init(frame: .zero)

        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        plusButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(plusButton)
        toggleButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(toggleButton)
        countField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(countField)
        // The anchor for flyout menus is the button itself — hand it to
        // the configured handler when the '+' fires.
        plusButton.onClick = { [weak self] in
            guard let self else { return }
            self.onPlus?(self.plusButton)
        }
        toggleButton.onClick = { [weak self] in self?.onToggle?() }

        // Chevron owns the trailing edge when present; the '+' rides
        // flush-right otherwise. Two mutually exclusive constraints —
        // hidden views still occupy constraint space in AppKit.
        plusFlush = plusButton.trailingAnchor.constraint(equalTo: trailingAnchor,
                                                        constant: 0)
        plusFlush.isActive = true
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor,
                                           constant: SidebarRowView.iconLeading),
            heightAnchor.constraint(equalToConstant: 20),
            toggleButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 0),
            toggleButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            toggleButton.widthAnchor.constraint(equalToConstant: 20),
            toggleButton.heightAnchor.constraint(equalToConstant: 18),
            plusButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            plusButton.widthAnchor.constraint(equalToConstant: 20),
            plusButton.heightAnchor.constraint(equalToConstant: 18),
            label.trailingAnchor.constraint(lessThanOrEqualTo: plusButton.leadingAnchor,
                                            constant: -6),
            countField.trailingAnchor.constraint(equalTo: plusButton.leadingAnchor, constant: -2),
            countField.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        plusShifted = plusButton.trailingAnchor.constraint(
            equalTo: toggleButton.leadingAnchor, constant: -2)
        plusShifted.isActive = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder: not implemented") }
    func configure(text: String, plus: ((NSView) -> Void)?, count: Int?,
                   toggle: (() -> Void)? = nil, expanded: Bool = true) {
        lastText = text
        lastCount = count
        lastExpanded = expanded
        label.attributedStringValue = NSAttributedString(string: text.uppercased(), attributes: [
            .font: NSFont.systemFont(ofSize: emphasized ? 11 : 10, weight: .semibold),
            .foregroundColor: emphasized ? Chrome.theme.foreground : Chrome.theme.secondaryText,
            .kern: emphasized ? 0.8 : 1.1,
        ])
        plusButton.isHidden = plus == nil
        onPlus = plus
        onToggle = toggle
        // Chevron rides the trailing edge; the '+' makes room only when
        // a fold actually exists (hidden views still hold constraint
        // space, so the two placements swap explicitly).
        toggleButton.isHidden = toggle == nil
        plusFlush.isActive = toggle == nil
        plusShifted.isActive = toggle != nil
        toggleButton.symbol = expanded ? "chevron.down" : "chevron.right"
        if let count {
            countField.attributedStringValue = NSAttributedString(
                string: String(count),
                attributes: [
                    .font: NSFont.systemFont(ofSize: 10, weight: .medium),
                    .foregroundColor: Chrome.theme.tertiaryText,
                ])
            countField.isHidden = false
        } else {
            countField.isHidden = true
        }
    }

    /// Flip the chevron WITHOUT a full reconfigure — the owning section
    /// keeps its render-time plus/count closures (toggleSpaceFold).
    func setExpanded(_ expanded: Bool) {
        guard expanded != lastExpanded else { return }
        lastExpanded = expanded
        toggleButton.symbol = expanded ? "chevron.down" : "chevron.right"
    }

    var isExpandedForTest: Bool { lastExpanded }

    /// Theme flip: re-run the last configure — the static SERVERS/
    /// SPACES headers are built once and never re-rendered by data
    /// passes, so without this they carry the launch theme forever.
    func retheme() {
        configure(text: lastText, plus: onPlus, count: lastCount,
                  toggle: onToggle, expanded: lastExpanded)
    }
}

/// One-shot builder for the static top-level headers (SERVERS/SPACES);
/// the Spaces section headers go through SectionHeaderView reuse.
func sectionHeader(_ text: String, plus: ((NSView) -> Void)? = nil, count: Int? = nil,
                   emphasized: Bool = false,
                   toggle: (() -> Void)? = nil, expanded: Bool = true) -> SectionHeaderView {
    let v = SectionHeaderView(emphasized: emphasized)
    v.configure(text: text, plus: plus, count: count, toggle: toggle, expanded: expanded)
    return v
}

final class WidthHandle: NSView {
    var onDrag: ((CGFloat) -> Void)?
    private var startWidth: CGFloat = 0
    private var startLoc: NSPoint = .zero

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        guard let sidebar = superview, sidebar.bounds.width > 80 else { return }
        startWidth = sidebar.bounds.width
        startLoc = NSEvent.mouseLocation
    }

    override func mouseDragged(with event: NSEvent) {
        let dx = NSEvent.mouseLocation.x - startLoc.x
        onDrag?(startWidth + dx)
    }
}

/// One sidebar row: leading symbol, label, trailing agent dot; rounded
/// translucent selection pill. Closure-driven — no target/action tags.

final class SidebarView: NSView {
    var onTabSelected: ((Int) -> Void)?
    var onNewTab: (() -> Void)?
    var onWorkspaceSelected: ((Int) -> Void)?
    var onManageSSHConfig: (() -> Void)?
    var onAddWorkspace: ((String) -> Void)?
    var onDeleteWorkspace: ((Int, Bool) -> Void)?
    var onCloseTab: ((Int) -> Void)?
    var onReconnectWorkspace: ((Int) -> Void)?
    var onDisconnectWorkspace: ((Int) -> Void)?

    /// Server-row menu → upgrade that host's daemon (visible only when
    /// the link reports a daemon below the store capability).
    var onUpgradeDaemonWorkspace: ((Int) -> Void)?
    var onRenameTab: ((Int) -> Void)?
    var onRenameTabTo: ((Int, String) -> Void)?
    /// Drag-reorder commit: one array move (from → to, `to` already
    /// post-removal). Fired on drop, after the row's live preview.
    var onReorderTab: ((Int, Int) -> Void)?
    var onTabIcon: ((Int, String?) -> Void)?
    var onTabColor: ((Int, String?) -> Void)?
    var onWidthChange: ((CGFloat) -> Void)?
    /// Per-space "+" — opens a new space in the given directory.
    var onNewTabInDir: ((String?) -> Void)?
    /// Per-space "+" → Agent GUI entry (flat: one item per manifest).
    var onNewAgentSessionInDir: ((String, String?) -> Void)?
    /// Availability for the + menu's agent entries; nil = local PATH.
    var agentAvailable: ((String) -> Bool)?
    /// Per-space "+" → "New Worktree…" — the git-repo-only entry of the
    /// space menu. Fires with the section's directory.
    var onNewWorktreeInDir: ((String?) -> Void)?

    // MARK: - Tab drag reorder (within a space section)

    /// The row being dragged right now; non-nil also suppresses data
    /// re-renders (title/git events arrive at shell-prompt cadence and
    /// would rebuild the pre-drag order mid-drag, like isRenaming).
    private var dragRow: SidebarRowView?
    /// Pointer-following snapshot of the dragged row (the lift).
    private var dragGhost: NSImageView?
    private var dragGrabOffset: CGFloat = 0

    /// Row drag session: a shadowed snapshot (ghost) follows the
    /// pointer while the row itself — dimmed — slides through the
    /// stack as the landing slot; midline crossings move it among its
    /// section's siblings. Drop commits one array move.
    private func handleTabDrag(_ row: SidebarRowView, _ event: NSEvent) {
        if dragRow == nil, event.type == .leftMouseDragged {
            beginDrag(row, with: event)
        }
        guard dragRow === row, row.tabIndex != nil, let container = row.superview else { return }
        // Arranged-view surgery targets OUR stack, but row FRAMES live
        // in AppKit's private container view (a plain NSView wrapper,
        // NOT the NSStackView — walking up with `as? NSStackView`
        // never matched, which is why the first build couldn't drag).
        // That wrapper is non-flipped: larger y = visually higher.
        // The row STAYS in the stack as the dimmed slot marker — hiding
        // it cuts AppKit's drag-event delivery to the mouse-down view
        // (the stuck-lift report: one drag event lands, then no
        // movement and no mouseUp ever arrive).
        let stack = tabsStack
        let siblings = stack.arrangedSubviews.compactMap { $0 as? SidebarRowView }
            .filter { $0 !== row && $0.spaceKey == row.spaceKey
                && $0.tabIndex != nil && !$0.isHidden }
        switch event.type {
        case .leftMouseDragged:
            moveGhost(with: event)
            let loc = container.convert(event.locationInWindow, from: nil)
            for s in siblings {
                if row.frame.midY < s.frame.midY, loc.y > s.frame.midY {
                    // Dragged UP past the sibling's midline.
                    place(row, in: stack, beside: s, below: false)
                } else if row.frame.midY > s.frame.midY, loc.y < s.frame.midY {
                    // Dragged DOWN past the sibling's midline.
                    place(row, in: stack, beside: s, below: true)
                }
            }
        case .leftMouseUp:
            endDrag()
            let order: [Int] = stack.arrangedSubviews.compactMap { v in
                guard let r = v as? SidebarRowView, r.spaceKey == row.spaceKey,
                      let idx = r.tabIndex else { return nil }
                return idx
            }
            if let (from, to) = Self.reorderMove(visualOrder: order,
                                                 moved: row.tabIndex!),
               from != to {
                onReorderTab?(from, to)
            }
        default:
            endDrag()   // cancelled: ghost down, dim off, no commit
        }
    }

    /// Lift: snapshot the row into a shadowed ghost that tracks the
    /// pointer; the row itself dims in place and becomes the slot.
    private func beginDrag(_ row: SidebarRowView, with event: NSEvent) {
        dragRow = row
        let ghost = NSImageView()
        if let rep = row.bitmapImageRepForCachingDisplay(in: row.bounds) {
            row.cacheDisplay(in: row.bounds, to: rep)
            let img = NSImage()
            img.addRepresentation(rep)
            ghost.image = img
        }
        let frame = row.convert(row.bounds, to: self)
        ghost.frame = frame
        ghost.alphaValue = 0.95
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
        shadow.shadowBlurRadius = 12
        shadow.shadowOffset = NSSize(width: 0, height: -4)
        ghost.shadow = shadow
        addSubview(ghost, positioned: .above, relativeTo: nil)
        row.alphaValue = 0.25
        dragGhost = ghost
        dragGrabOffset = convert(event.locationInWindow, from: nil).y - frame.minY
        moveGhost(with: event)
    }

    private func moveGhost(with event: NSEvent) {
        guard let ghost = dragGhost else { return }
        ghost.frame.origin.y = convert(event.locationInWindow, from: nil).y
            - dragGrabOffset
    }

    /// End the session: ghost down, row back to full opacity. Runs on
    /// drop AND cancel — cancel just skips the commit.
    private func endDrag() {
        guard let row = dragRow else { return }
        dragGhost?.removeFromSuperview()
        dragGhost = nil
        row.alphaValue = 1
        dragRow = nil
    }

    /// Move `row` to sit directly beside `sibling` in the stack. The
    /// target index is resolved AFTER removal (the render loop's proven
    /// remove/insert dance), so targets past the removed slot land
    /// beside — not past — the sibling. Redundant placements are
    /// skipped so idle drag events cause no layout churn.
    private func place(_ row: NSView, in stack: NSStackView, beside sibling: NSView, below: Bool) {
        let arranged = stack.arrangedSubviews
        guard let si = arranged.firstIndex(of: sibling) else { return }
        let slot = below ? si + 1 : si
        if slot < arranged.count, arranged[slot] === row { return }
        if arranged.contains(row) { stack.removeArrangedSubview(row) }
        let target = stack.arrangedSubviews.firstIndex(of: sibling) ?? 0
        stack.insertArrangedSubview(row, at: below ? target + 1 : target)
    }

    /// The array move that reproduces a dragged visual order:
    /// `visualOrder` = the section's tab indexes in current (live-moved)
    /// stack order. Anchor on the tab directly ABOVE (insert right
    /// after it in the array); for the top slot, insert right BEFORE
    /// the tab below. Within a section the sidebar order is array
    /// order, so this one move lands the tab exactly where it was
    /// dropped. nil = no move (single-member section).
    static func reorderMove(visualOrder: [Int], moved: Int) -> (from: Int, to: Int)? {
        guard let p = visualOrder.firstIndex(of: moved), visualOrder.count > 1 else { return nil }
        if p > 0 {
            let anchor = visualOrder[p - 1]
            return (moved, anchor < moved ? anchor + 1 : anchor)
        }
        let below = visualOrder[1]
        return (moved, below < moved ? below : below - 1)
    }

    private lazy var wsHeader: SectionHeaderView = sectionHeader("Servers",
                                                     plus: { [weak self] anchor in
        guard let self else { return }
        // Product-styled flyout from the '+' itself — the system NSMenu
        // chrome ignored the theme (the styled-popup report).
        HostFlyout.show(anchor: anchor,
                        entries: self.hostPickerEntries(hosts: SSHConfig.hosts()),
                        onPick: { [weak self] entry in self?.fireHostPicker(entry) })
    }, emphasized: true,
       toggle: { [weak self] in self?.setServersExpanded(!(self?.serversExpanded ?? true)) })

    /// SERVERS fold: rows hidden, header keeps its chevron + '+'.
    /// Persisted through onServersExpandChange (AppPreferences).
    var onServersExpandChange: ((Bool) -> Void)?
    private(set) var serversExpanded = true

    func setServersExpanded(_ expanded: Bool) {
        guard expanded != serversExpanded else { return }
        serversExpanded = expanded
        // Hidden arranged subviews collapse in NSStackView — the
        // section (and everything below it) moves up.
        wsStack.arrangedSubviews.forEach { $0.isHidden = !expanded }
        wsHeader.configure(text: "Servers",
                           plus: { [weak self] anchor in
                               guard let self else { return }
                               HostFlyout.show(anchor: anchor,
                                   entries: self.hostPickerEntries(hosts: SSHConfig.hosts()),
                                   onPick: { [weak self] entry in
                                       self?.fireHostPicker(entry) })
                           },
                           count: nil,
                           toggle: { [weak self] in
                               self?.setServersExpanded(!(self?.serversExpanded ?? true))
                           },
                           expanded: expanded)
        onServersExpandChange?(expanded)
    }

    /// Per-space fold: which directory sections are folded away (absent
    /// = expanded). Keyed by section name (the space's directory) so it
    /// survives tab churn inside the section.
    private var spaceFolds: Set<String> = []
    /// Section name → the foldable views beneath it (its spacing tile +
    /// tab rows, NOT the header). Rebuilt every render; reuse keeps the
    /// views identity-stable so toggling just flips isHidden.
    private var spaceSectionViews: [String: [NSView]] = [:]
    /// Fold key (directory root) → that section's header — the icon flip
    /// target. NOT spaceHeaders: that map is keyed by DISPLAY name, and
    /// the two keys differ ("fold-a" vs "/tmp/fold-a") — looking the
    /// header up by fold key there always missed, freezing the chevron
    /// at its configure-time glyph (the icon-never-flips report).
    private var spaceFoldHeaders: [String: SectionHeaderView] = [:]
    var onSpaceFoldsChange: (([String]) -> Void)?

    /// Restore folds (AppWindowController, before the first render).
    func setFoldedSpaces(_ names: Set<String>) {
        spaceFolds = names
        for (name, views) in spaceSectionViews {
            let folded = spaceFolds.contains(name)
            views.forEach { $0.isHidden = folded }
            spaceFoldHeaders[name]?.setExpanded(!folded)
        }
        onSpaceFoldsChange?(Array(names))
    }

    func toggleSpaceFold(_ name: String) {
        if !spaceFolds.insert(name).inserted { spaceFolds.remove(name) }
        spaceFoldHeaders[name]?.setExpanded(!spaceFolds.contains(name))
        onSpaceFoldsChange?(Array(spaceFolds))
        for view in spaceSectionViews[name] ?? [] {
            view.isHidden = spaceFolds.contains(name)
        }
    }


    // Test surface for the SERVERS fold.
    var wsRowsForTest: [NSView] { wsStack.arrangedSubviews }
    var wsHeaderForTest: NSView { wsHeader }
    var tabsRowsForTest: [NSView] {
        tabsStack.arrangedSubviews.compactMap { $0 as? SidebarRowView }
    }
    var tabsVisibleForTest: [NSView] {
        tabsStack.arrangedSubviews.filter { !$0.isHidden }
    }
    /// Chevron state of a space section (fold key = directory root).
    func spaceHeaderExpandedForTest(_ foldKey: String) -> Bool? {
        spaceFoldHeaders[foldKey]?.isExpandedForTest
    }
    /// Host picker for the Servers '+': one entry per SSH alias, then
    /// the manager entry (parse/add/edit/delete of ~/.ssh/config —
    /// hosts not in the file get added THERE, not through a prompt).
    /// Pure list + pure router — the flyout renders it, tests fire it
    /// (the 2026-08-23 dead-items bug: every entry must carry its host
    /// or the click does nothing).
    func hostPickerEntries(hosts: [String]) -> [HostPickerEntry] {
        hosts.map { .host($0) } + [.manage]
    }

    func fireHostPicker(_ entry: HostPickerEntry) {
        switch entry {
        case .host(let host): onAddWorkspace?(host)
        case .manage: onManageSSHConfig?()  // ~/.ssh/config manager overlay
        }
    }

    /// The per-space '+' flyout — EVERY space gets the same list now
    /// (2026-08-31 rule change; non-repos used to skip the menu and open
    /// a terminal directly): New Terminal, the focused workspace's
    /// available agents, and — for a git repo — a worktree beside it.
    /// Built pure so tests can inspect and fire it like the host picker.
    func spacePlusMenu(dir: String?, isGit: Bool) -> NSMenu {
        let menu = NSMenu()
        let term = NSMenuItem(title: "New Terminal",
                              action: #selector(spacePlusTerminalAction(_:)),
                              keyEquivalent: "")
        term.target = self
        term.representedObject = dir
        term.image = menuItemIcon("terminal", pointSize: 10)
        menu.addItem(term)
        if isGit {
            let worktree = NSMenuItem(title: "New Worktree…",
                                      action: #selector(spacePlusWorktreeAction(_:)),
                                      keyEquivalent: "")
            worktree.target = self
            worktree.representedObject = dir
            worktree.image = menuItemIcon("arrow.triangle.branch", pointSize: 10)
            menu.addItem(worktree)
        }
        menu.addItem(.separator())
        let available = agentAvailable ?? { key in
            AgentRegistry.descriptor(for: key)?
                .isAvailable(path: UserShellEnv.asDictionary["PATH"] ?? "") ?? false
        }
        for entry in AgentRegistry.pickerEntries(isAvailable: available) where entry.available {
            let item = NSMenuItem(title: entry.label, action: #selector(spacePlusAgentAction(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = [entry.key, dir ?? ""]
            item.image = AgentBrandIcons.menuImage(for: entry.key)
            menu.addItem(item)
        }
        return menu
    }

    @objc fileprivate func spacePlusAgentAction(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [String], pair.count == 2 else { return }
        onNewAgentSessionInDir?(pair[0], pair[1] == "" ? nil : pair[1])
    }

    @objc fileprivate func spacePlusTerminalAction(_ sender: NSMenuItem) {
        onNewTabInDir?(sender.representedObject as? String)
    }

    @objc fileprivate func spacePlusWorktreeAction(_ sender: NSMenuItem) {
        onNewWorktreeInDir?(sender.representedObject as? String)
    }
    private let wsStack = NSStackView()
    private lazy var tabsHeader: NSView = sectionHeader("Spaces",
                                                        plus: { [weak self] _ in
        self?.onNewTab?()
    }, emphasized: true)
    private let tabsStack = NSStackView()
    private var widthHandle: WidthHandle?

    // Collapsed rail: the sidebar never disappears — at railWidth it
    // becomes a strip of server status dots with the expand toggle on
    // top (tabs move to the terminal region's strip; see
    // TabStripView). One state machine swaps the two contents:
    // setCollapsed.
    static let railWidth: CGFloat = 48
    private let divider = HairlineView()
    private let railStack: NSStackView = {
        let s = NSStackView()
        s.orientation = .vertical
        s.alignment = .centerX
        s.spacing = 4
        return s
    }()


    init() {
        super.init(frame: .zero)

        let sep = HairlineView()
        sep.translatesAutoresizingMaskIntoConstraints = false
        addSubview(sep)

        let handle = WidthHandle()
        handle.onDrag = { [weak self] width in
            self?.onWidthChange?(width)
        }
        widthHandle = handle
        handle.translatesAutoresizingMaskIntoConstraints = false
        addSubview(handle)
        NSLayoutConstraint.activate([
            handle.trailingAnchor.constraint(equalTo: trailingAnchor),
            handle.topAnchor.constraint(equalTo: topAnchor),
            handle.bottomAnchor.constraint(equalTo: bottomAnchor),
            handle.widthAnchor.constraint(equalToConstant: 5),
        ])

        for (stack, head) in [(wsStack, wsHeader), (tabsStack, tabsHeader)] {
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 1
            stack.translatesAutoresizingMaskIntoConstraints = false
            addSubview(stack)
            head.translatesAutoresizingMaskIntoConstraints = false
            addSubview(head)
        }

        // Section divider: Servers and Spaces read as two areas (tty7's
        // sidebar rules off its groups).
        divider.translatesAutoresizingMaskIntoConstraints = false
        addSubview(divider)


        NSLayoutConstraint.activate([
            sep.trailingAnchor.constraint(equalTo: trailingAnchor),
            sep.topAnchor.constraint(equalTo: topAnchor),
            sep.bottomAnchor.constraint(equalTo: bottomAnchor),
            sep.widthAnchor.constraint(equalToConstant: 1),
            wsHeader.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            wsHeader.leadingAnchor.constraint(equalTo: leadingAnchor, constant: SidebarRowView.stackInset),
            wsHeader.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -SidebarRowView.stackInset),
            wsStack.topAnchor.constraint(equalTo: wsHeader.bottomAnchor, constant: 8),
            wsStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: SidebarRowView.stackInset),
            wsStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -SidebarRowView.stackInset),
            divider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: SidebarRowView.stackInset),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -SidebarRowView.stackInset),
            divider.topAnchor.constraint(equalTo: wsStack.bottomAnchor, constant: 10),
            divider.heightAnchor.constraint(equalToConstant: 1),
            tabsHeader.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 10),
            tabsHeader.leadingAnchor.constraint(equalTo: leadingAnchor, constant: SidebarRowView.stackInset),
            tabsHeader.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -SidebarRowView.stackInset),
            tabsStack.topAnchor.constraint(equalTo: tabsHeader.bottomAnchor, constant: 8),
            tabsStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: SidebarRowView.stackInset),
            tabsStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -SidebarRowView.stackInset),
        ])

        // Collapsed rail: the window titlebar (always up) carries the
        // expand toggle now — the rail itself is just the server dots.
        railStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(railStack)
        NSLayoutConstraint.activate([
            railStack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            railStack.centerXAnchor.constraint(equalTo: centerXAnchor),
            railStack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
            railStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
        ])
        setCollapsed(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func draw(_ dirtyRect: NSRect) {
        // Flat theme surface, the terminal's OWN background (tty7 rule:
        // workspace surface color): the ghostty surface renders pure
        // bg@opacity in Metal, so any lift here reads as a color MISMATCH
        // against the terminal (user report) — strips INSIDE stay lifted,
        // the column itself is exact.
        chromeSurface(Chrome.theme.background).setFill()
        bounds.fill()
    }

    /// Pins a full-width arranged subview into one of the section stacks.
    private func pin(_ view: NSView, to stack: NSStackView) {
        stack.addArrangedSubview(view)
        view.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
        view.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
    }
    private func addRow(_ stack: NSStackView, text: String, symbol: String?,
                        selected: Bool, dot: NSColor? = nil, tagColor: NSColor? = nil,
                        meta: String? = nil, enabled: Bool = true,
                        avatar: NSColor? = nil, git: GitSummary? = nil,
                        status: SpaceStatus? = nil,
                        brandImage: NSImage? = nil,
                        tabIndex: Int? = nil,
                        onClose: (() -> Void)? = nil,
                        onRename: (() -> Void)? = nil,
                        onSetColor: ((String?) -> Void)? = nil,
                        onCommitName: ((String) -> Void)? = nil,
                        onReconnect: (() -> Void)? = nil,
                        onDisconnect: (() -> Void)? = nil,
                        onUpgradeDaemon: (() -> Void)? = nil,
                        onSetIcon: ((String?) -> Void)? = nil,
                        onDeleteWorkspace: ((Bool) -> Void)? = nil,
                        select: @escaping () -> Void) {
        let row = SidebarRowView(click: select)
        row.configure(text: text, symbol: symbol, selected: selected, dot: dot,
                      tagColor: tagColor, meta: meta, enabled: enabled,
                      avatar: avatar, git: git, status: status, brandImage: brandImage,
                      tabIndex: tabIndex,
                      onClose: onClose, onRename: onRename, onSetColor: onSetColor,
                      onCommitName: onCommitName, onReconnect: onReconnect,
                      onDisconnect: onDisconnect, onUpgradeDaemon: onUpgradeDaemon,
                      onSetIcon: onSetIcon, onDeleteWorkspace: onDeleteWorkspace)
        pin(row, to: stack)
    }

    /// Theme switch (Settings): bump the generation so the next render
    /// rebuilds rows/headers with fresh Chrome.theme colors even with
    /// unchanged data, and repaint the self-drawn fills now.
    func retheme() {
        themeGeneration += 1
        needsDisplay = true
    }

    /// Opens the inline editor on the tab row for tab `index` — rows are
    /// grouped by directory, so the row is found by identity, not order.
    func beginRename(index: Int) {
        let row = tabsStack.arrangedSubviews
            .compactMap { $0 as? SidebarRowView }
            .first { $0.tabIndex == index }
        row?.beginInlineRename()
    }

    /// Full content swap between the expanded sidebar and the rail —
    /// one state machine, both contents always defined.
    func setCollapsed(_ collapsed: Bool) {
        wsHeader.isHidden = collapsed
        wsStack.isHidden = collapsed
        divider.isHidden = collapsed
        tabsHeader.isHidden = collapsed
        tabsStack.isHidden = collapsed
        widthHandle?.isHidden = collapsed
        railStack.isHidden = !collapsed
    }
    /// Last-rendered signature per surface: events fire at poll/prompt
    /// cadence but usually change nothing visible — a no-change render
    /// pass is pure waste. Same content → same signature → skip.
    /// `themeGeneration` salts BOTH signatures so a theme switch (no
    /// data change) still forces the rebuild that recolors rows.
    private var themeGeneration = 0
    private var spacesSignature: String?
    private var workspacesSignature: String?
    /// Live row/header identity for in-place reuse (the hover-flicker
    /// fix): tab id → row, section name → header. Rebuilt every render;
    /// rows that survive a pass are RECONFIGURED, never recreated, so
    /// tracking areas and hover state carry across data events.
    private var tabRows: [String: SidebarRowView] = [:]
    private var spaceHeaders: [String: SectionHeaderView] = [:]

    func render(workspace: WorkspaceState, offline: Bool = false,
                gitFor: ((String) -> GitSummary?)? = nil,
                spaceRoot: ((String) -> String?)? = nil,
                statusFor: ((TabState) -> SpaceStatus?)? = nil,
                commandFor: ((TabState) -> String?)? = nil,
                titleFor: ((TabState) -> String?)? = nil) {
        if ProcessInfo.processInfo.environment["GOTY_DUMP_VIEWS"] == "1" {
            var out = "SIDEBAR bounds=\(Int(bounds.width))x\(Int(bounds.height))\n"
            func dump(_ v: NSView, depth: Int) {
                let f = v.frame
                out += String(repeating: " ", count: depth * 2)
                    + String(describing: type(of: v))
                    + " [\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height))]\n"
                if depth < 4 { v.subviews.forEach { dump($0, depth: 1 + depth) } }
            }
            dump(self, depth: 1)
            try? out.data(using: .utf8)?.write(to: URL(fileURLWithPath: "/tmp/goty-views.log"))
        }
        // An in-flight inline rename must not be torn down: title/cwd/
        // git events rebuild these rows at shell-prompt cadence, which
        // is exactly what made rename unusable. Skip this pass; the
        // next event after the commit re-renders.
        if tabsStack.arrangedSubviews.contains(where: { ($0 as? SidebarRowView)?.isRenaming == true }) {
            return
        }
        // Same rule for an in-flight drag-reorder: the store still
        // holds the pre-drag order until the drop commits, so a
        // mid-drag data pass would snap the rows back.
        if dragRow != nil { return }
        // Everything the rows below depend on, folded into one string:
        // identity (id/cwd/icon/color/userTitle), resolved display name,
        // selection, status, and the git line. Equal signature = equal
        // pixels; the rebuild is pure waste.
        var signature = "theme=\(themeGeneration)|offline=\(offline)"
        for tab in workspace.tabs {
            let command = commandFor?(tab) ?? tab.paneCommand
            let spec = AgentCatalog.spec(for: command)
            let running = AgentCatalog.isAgent(command)
            let git = tab.panes.first?.cwd.flatMap { gitFor?($0) }
            let status = running ? statusFor?(tab) : nil
            let title = titleFor?(tab)
            let display = tab.userTitle ?? tab.agentTitle ?? spec?.label ?? title ?? tab.name
            // The SPACE key (repo root when inside one), not the raw
            // cwd: cd-ing into a subdir or another worktree of the same
            // repo must not re-fire the render — only a real space move
            // (different key) does.
            let space = tab.panes.first?.cwd.map { spaceRoot?($0) ?? $0 }
            signature += "|\(tab.id):\(space ?? "-")"
                + ":\(tab.icon ?? "-"):\(tab.color ?? "-"):\(tab.userTitle ?? "-")"
                + ":\(display):\(tab.id == workspace.focusedTab?.id)"
                + ":\(status.map { "\($0.activity)|\($0.seen)|\($0.spinner.map(String.init) ?? "")" } ?? "-")"
                + ":\(git?.branch ?? "-"):\(spec?.label ?? "-")"
        }
        guard signature != spacesSignature else { return }
        spacesSignature = signature
        if offline {
            // An unreachable workspace shows NO cached session list — the
            // reconnect panel IS the workspace view. Full swap: every
            // row dies, so the reuse maps reset with them.
            tabRows.removeAll()
            spaceHeaders.removeAll()
            spaceFoldHeaders.removeAll()
            spaceSectionViews.removeAll()
            tabsStack.arrangedSubviews.forEach { tabsStack.removeView($0) }
            addRow(tabsStack, text: "Offline — reconnect to see sessions",
                   symbol: "wifi.exclamationmark", selected: false) {}
            return
        }
        var desired: [NSView] = []
        var nextRows: [String: SidebarRowView] = [:]
        var nextHeaders: [String: SectionHeaderView] = [:]
        var nextFoldHeaders: [String: SectionHeaderView] = [:]
        var nextSectionViews: [String: [NSView]] = [:]
        for section in SpaceGrouping.sections(for: workspace.tabs, spaceRoot: spaceRoot) {
            var sectionViews: [NSView] = []   // this section's foldable members
            let dir = workspace.tabs[section.tabIndexs[0]].panes.first?.cwd
                .map { spaceRoot?($0) ?? $0 }
            // Fold key = the section's directory ROOT, not the display
            // name — tail names grow on collision ("goty"
            // → "ai_project/goty"), which would silently drop folds.
            // Also the rows' spaceKey: drag-reorder never crosses it.
            let foldKey = section.name != nil ? (dir ?? section.name!) : nil
            if let name = section.name, let foldKey {
                if !desired.isEmpty {
                    // Plain spacing tile — no identity, no interaction;
                    // recreating it is invisible. NEVER folds: a
                    // collapsed section keeps its distance from whatever
                    // is above it, so folding doesn't shift the layout
                    // (the position-jump report).
                    let gap = NSView()
                    gap.heightAnchor.constraint(equalToConstant: 10).isActive = true
                    desired.append(gap)
                }
                // The group's "+" opens the SAME add menu for every
                // space (2026-08-31 rule change): New Terminal, the
                // available agents, and — for a git repo — a worktree
                // beside it; non-repos used to open a terminal
                // directly, no menu. `isGit` is captured at render
                // cadence: git events re-render the sections, so the
                // flag tracks the store without SidebarView holding
                // another closure.
                let isGit = dir.flatMap { gitFor?($0) } != nil
                let header: SectionHeaderView
                if let reused = spaceHeaders[name] {
                    header = reused
                } else {
                    header = SectionHeaderView()
                    pin(header, to: tabsStack)
                }
                header.configure(text: name,
                                 plus: { [weak self] anchor in
                    guard let self else { return }
                    let menu = self.spacePlusMenu(dir: dir, isGit: isGit)
                    menu.popUp(positioning: nil,
                               at: NSPoint(x: anchor.bounds.width,
                                           y: anchor.bounds.height),
                               in: anchor)
                }, count: section.tabIndexs.count,
                   toggle: { [weak self] in self?.toggleSpaceFold(foldKey) },
                   expanded: !spaceFolds.contains(foldKey))
                nextHeaders[name] = header
                nextFoldHeaders[foldKey] = header
                desired.append(header)
            }
            for idx in section.tabIndexs {
                let tab = workspace.tabs[idx]
                let selected = idx == workspace.focusedTabIndex
                // Identity is live: spawn command, or the agent the user is
                // running in the shell right now (foreground report).
                let command = commandFor?(tab) ?? tab.paneCommand
                let spec = AgentCatalog.spec(for: command)
                let running = AgentCatalog.isAgent(command)
                let tagColor = tab.color.flatMap { NSColor(hex: $0) }
                // Brand disc for agent spaces (a custom user icon wins —
                // their choice replaces the avatar treatment entirely).
                let avatar = (tab.icon == nil && running) ? spec?.accent : nil
                // Official logo glyph when we have one (AgentIcons.swift);
                // a custom user icon still wins over everything.
                let brand = (tab.icon == nil && running)
                    ? AgentBrandIcons.image(for: AgentCatalog.manifestKey(for: command))
                    : nil
                if ProcessInfo.processInfo.environment["GOTY_DUMP_VIEWS"] == "1" {
                    print("row-diag: \(tab.name) cmd=\(command ?? "nil") brand=\(brand != nil) avatar=\(avatar != nil)")
                }
                let git = tab.panes.first?.cwd.flatMap { gitFor?($0) }
                let meta = git == nil ? spec?.label : nil
                // Display name, ghostty's title rule: a user rename
                // wins; else an agent shows its brand; else the PTY's
                // own window title (OSC 0/2 through ghostty); else the
                // default counter. One channel for local and remote.
                let title = titleFor?(tab)
                let displayName = tab.userTitle ?? tab.agentTitle ?? spec?.label ?? title ?? tab.name
                // Live TUI status (agent-style badge); no passive
                // evidence (or a plain shell) shows nothing.
                let status = running ? statusFor?(tab) : nil
                let row: SidebarRowView
                if let reused = tabRows[tab.id] {
                    row = reused
                } else {
                    row = SidebarRowView(click: {})
                    row.dragHandler = { [weak self] row, event in
                        self?.handleTabDrag(row, event)
                    }
                    pin(row, to: tabsStack)
                }
                // Index-targeted actions rebind per pass: closing a tab
                // shifts every index after it.
                row.click = { [weak self] in self?.onTabSelected?(idx) }
                row.configure(text: displayName,
                              symbol: tab.icon ?? spec?.icon ?? "terminal",
                              selected: selected,
                              tagColor: tagColor, meta: meta,
                              avatar: avatar, git: git, status: status, brandImage: brand,
                              tabIndex: idx,
                              spaceKey: foldKey,
                              onClose: { [weak self] in self?.onCloseTab?(idx) },
                              onRename: { [weak self] in self?.onRenameTab?(idx) },
                              onSetColor: { [weak self] hex in self?.onTabColor?(idx, hex) },
                              onCommitName: { [weak self] name in self?.onRenameTabTo?(idx, name) },
                              onSetIcon: { [weak self] symbol in self?.onTabIcon?(idx, symbol) })
                nextRows[tab.id] = row
                desired.append(row)
                sectionViews.append(row)
            }
            if let name = section.name {
                // Same root key the toggle closure uses (see foldKey).
                nextSectionViews[dir ?? name] = sectionViews
            }
        }
        // Drop closed/switched-away views, then land the desired order.
        // Moving an arranged view never recreates it — bounds, tracking
        // areas and hover state ride along.
        let keep = Set(desired.map(ObjectIdentifier.init))
        for v in tabsStack.arrangedSubviews where !keep.contains(ObjectIdentifier(v)) {
            tabsStack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        for (i, v) in desired.enumerated() {
            let arranged = tabsStack.arrangedSubviews
            if i < arranged.count, arranged[i] === v { continue }
            if arranged.contains(v) { tabsStack.removeArrangedSubview(v) }
            tabsStack.insertArrangedSubview(v, at: i)
        }
        tabRows = nextRows
        spaceHeaders = nextHeaders
        spaceFoldHeaders = nextFoldHeaders
        spaceSectionViews = nextSectionViews
        // Fresh rows land visible; folded sections stay folded.
        for (name, views) in spaceSectionViews where spaceFolds.contains(name) {
            views.forEach { $0.isHidden = true }
        }
    }
    func renderWorkspaces(_ workspaces: [WorkspaceState], focusedIndex: Int,
                          states: [UUID: WorkspaceCoordinator.WsState] = [:],
                          daemonUpgradable: Set<UUID> = []) {
        let signature = "theme=\(themeGeneration)#" + workspaces.map { ws in
            "\(ws.id):\(ws.name):\(states[ws.id].map(String.init(describing:)) ?? "?")"
                + (daemonUpgradable.contains(ws.id) ? "+up" : "")
        }.joined(separator: "|") + "#\(focusedIndex)"
        guard signature != workspacesSignature else { return }
        workspacesSignature = signature
        wsStack.arrangedSubviews.forEach { wsStack.removeView($0) }
        for (idx, ws) in workspaces.enumerated() {
            let selected = idx == focusedIndex
            let state = states[ws.id] ?? .connecting
            let dot: NSColor?
            switch state {
            case .connected: dot = Chrome.theme.wsConnected
            case .connecting: dot = Chrome.theme.wsConnecting
            case .disconnected: dot = Chrome.theme.wsDisconnected
            }
            addRow(wsStack, text: ws.displayName, symbol: ws.isRemote ? "server.rack" : "desktopcomputer",
                   selected: selected, dot: dot,
                   enabled: state != .disconnected,
                   onReconnect: state == .disconnected ? { [weak self] in
                       self?.onReconnectWorkspace?(idx)
                   } : nil,
                   onDisconnect: ws.isRemote && state == .connected ? { [weak self] in
                       self?.onDisconnectWorkspace?(idx)
                   } : nil,
                   onUpgradeDaemon: daemonUpgradable.contains(ws.id) ? { [weak self] in
                       self?.onUpgradeDaemonWorkspace?(idx)
                   } : nil,
                   onDeleteWorkspace: { [weak self] destructive in
                       self?.onDeleteWorkspace?(idx, destructive)
                   }) { [weak self] in
                self?.onWorkspaceSelected?(idx)
            }
        }
        // Fresh rows land visible; a folded SERVERS section stays folded.
        wsStack.arrangedSubviews.forEach { $0.isHidden = !serversExpanded }
        // Same pass, same signature: the rail is the server list at
        // rail width — one dot per workspace, identical actions.
        railStack.arrangedSubviews.forEach { railStack.removeView($0) }
        for (idx, ws) in workspaces.enumerated() {
            let state = states[ws.id] ?? .connecting
            railStack.addArrangedSubview(ServerRailButton(
                name: ws.displayName, state: state, selected: idx == focusedIndex,
                onReconnect: state == .disconnected ? { [weak self] in
                    self?.onReconnectWorkspace?(idx)
                } : nil,
                onDisconnect: ws.isRemote && state == .connected ? { [weak self] in
                    self?.onDisconnectWorkspace?(idx)
                } : nil,
                onUpgradeDaemon: daemonUpgradable.contains(ws.id) ? { [weak self] in
                    self?.onUpgradeDaemonWorkspace?(idx)
                } : nil,
                onDeleteWorkspace: { [weak self] destructive in
                    self?.onDeleteWorkspace?(idx, destructive)
                }) { [weak self] in
                self?.onWorkspaceSelected?(idx)
            })
        }
    }
}
