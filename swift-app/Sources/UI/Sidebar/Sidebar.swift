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
final class SectionHeaderView: NSView {
    private let label = NSTextField(labelWithString: "")
    private let countField = NSTextField(labelWithString: "")
    private var onPlus: ((NSView) -> Void)?
    private let plusButton = IconButton.make("plus", pointSize: 11)
    private let emphasized: Bool

    init(emphasized: Bool = false) {
        self.emphasized = emphasized
        super.init(frame: .zero)

        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        // Flush with the row's leading edge (the avatar column) — tty7
        // group headers; the '+' and count own the trailing edge.
        plusButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(plusButton)
        countField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(countField)
        // The anchor for flyout menus is the button itself — hand it to
        // the configured handler when the '+' fires.
        plusButton.onClick = { [weak self] in
            guard let self else { return }
            self.onPlus?(self.plusButton)
        }

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor,
                                           constant: SidebarRowView.iconLeading),
            heightAnchor.constraint(equalToConstant: 20),
            plusButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 0),
            plusButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            plusButton.widthAnchor.constraint(equalToConstant: 20),
            plusButton.heightAnchor.constraint(equalToConstant: 18),
            label.trailingAnchor.constraint(lessThanOrEqualTo: plusButton.leadingAnchor,
                                            constant: -6),
            countField.trailingAnchor.constraint(equalTo: plusButton.leadingAnchor, constant: -2),
            countField.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder: not implemented") }

    func configure(text: String, plus: ((NSView) -> Void)?, count: Int?) {
        label.attributedStringValue = NSAttributedString(string: text.uppercased(), attributes: [
            .font: NSFont.systemFont(ofSize: emphasized ? 11 : 10, weight: .semibold),
            .foregroundColor: emphasized ? Chrome.theme.foreground : Chrome.theme.secondaryText,
            .kern: emphasized ? 0.8 : 1.1,
        ])
        plusButton.isHidden = plus == nil
        onPlus = plus
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
}

/// One-shot builder for the static top-level headers (SERVERS/SPACES);
/// the Spaces section headers go through SectionHeaderView reuse.
func sectionHeader(_ text: String, plus: ((NSView) -> Void)? = nil, count: Int? = nil,
                   emphasized: Bool = false) -> NSView {
    let v = SectionHeaderView(emphasized: emphasized)
    v.configure(text: text, plus: plus, count: count)
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
    var onRenameTab: ((Int) -> Void)?
    var onRenameTabTo: ((Int, String) -> Void)?
    var onTabIcon: ((Int, String?) -> Void)?
    var onTabColor: ((Int, String?) -> Void)?
    var onWidthChange: ((CGFloat) -> Void)?
    /// Per-space "+" — opens a new space in the given directory.
    var onNewTabInDir: ((String?) -> Void)?
    /// Per-space "+" → "New Worktree…" — the git-repo-only entry of the
    /// space menu. Fires with the section's directory.
    var onNewWorktreeInDir: ((String?) -> Void)?
    private lazy var wsHeader: NSView = sectionHeader("Servers",
                                                     plus: { [weak self] anchor in
        guard let self else { return }
        let menu = hostPickerMenu(hosts: SSHConfig.hosts())
        // Fly out from the '+' itself (top-right corner, extending
        // right), not from the header's leading edge.
        menu.popUp(positioning: nil, at: NSPoint(x: anchor.bounds.width,
                                                 y: anchor.bounds.height), in: anchor)
    }, emphasized: true)

    /// Host picker for the Servers '+': one item per SSH alias, then the
    /// manager entry (parse/add/edit/delete of ~/.ssh/config — hosts
    /// not in the file get added THERE, not through a prompt). Built
    /// pure (hosts passed in) so tests can inspect and fire it — each
    /// item must carry its host, or the click does nothing (the
    /// 2026-08-23 dead-items bug).
    func hostPickerMenu(hosts: [String]) -> NSMenu {
        let menu = NSMenu()
        for host in hosts {
            let item = NSMenuItem(title: host, action: #selector(hostMenuAction),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = host
            menu.addItem(item)
        }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        let manage = NSMenuItem(title: "Manage Hosts…", action: #selector(hostMenuAction),
                                keyEquivalent: "")
        manage.target = self
        manage.representedObject = NSNull()
        manage.image = menuItemIcon("server.rack", pointSize: 10)
        menu.addItem(manage)
        return menu
    }

    @objc fileprivate func hostMenuAction(_ sender: NSMenuItem) {
        if sender.representedObject is NSNull {
            onManageSSHConfig?()  // ~/.ssh/config manager overlay
        } else if let host = sender.representedObject as? String {
            onAddWorkspace?(host)
        }
    }

    /// The per-space '+' flyout when the section's directory is a git
    /// repo: a new terminal (same as before), or a worktree beside the
    /// repo. Built pure so tests can inspect and fire it like the host
    /// picker; non-repo sections never build it — they keep the direct
    /// terminal behavior.
    func spacePlusMenu(dir: String) -> NSMenu {
        let menu = NSMenu()
        let term = NSMenuItem(title: "New Terminal",
                              action: #selector(spacePlusTerminalAction(_:)),
                              keyEquivalent: "")
        term.target = self
        term.representedObject = dir
        term.image = menuItemIcon("terminal", pointSize: 10)
        let worktree = NSMenuItem(title: "New Worktree…",
                                  action: #selector(spacePlusWorktreeAction(_:)),
                                  keyEquivalent: "")
        worktree.target = self
        worktree.representedObject = dir
        worktree.image = menuItemIcon("arrow.triangle.branch", pointSize: 10)
        menu.addItem(term)
        menu.addItem(worktree)
        return menu
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
                      onDisconnect: onDisconnect,
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
            let display = tab.userTitle ?? spec?.label ?? title ?? tab.name
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
            tabsStack.arrangedSubviews.forEach { tabsStack.removeView($0) }
            addRow(tabsStack, text: "Offline — reconnect to see sessions",
                   symbol: "wifi.exclamationmark", selected: false) {}
            return
        }
        // tty7 spaces: one section per working directory — the section is
        // named after the directory and every space opened in it is listed
        // underneath. Unknown cwds trail in Scratch; before any cwd is
        // known the list stays flat (tty7's single headerless section).
        //
        // Rows and headers are REUSED, keyed by tab id / section name: a
        // pass reconfigures in place and at most reorders arranged views.
        // Recreating views made every volatile field (the OSC title, the
        // spinner char riding it) drop and re-fire mouseEntered under a
        // still cursor — the hover flicker (2026-08-24). Identity-stable
        // views keep their tracking areas; hover never blinks.
        var desired: [NSView] = []
        var nextRows: [String: SidebarRowView] = [:]
        var nextHeaders: [String: SectionHeaderView] = [:]
        for section in SpaceGrouping.sections(for: workspace.tabs, spaceRoot: spaceRoot) {
            if let name = section.name {
                if !desired.isEmpty {
                    // Plain spacing tile — no identity, no interaction;
                    // recreating it is invisible.
                    let gap = NSView()
                    gap.heightAnchor.constraint(equalToConstant: 10).isActive = true
                    desired.append(gap)
                }
                // The group's "+" opens a new space straight into this
                // SPACE (the repo root when the section is a repo), next
                // to the space count — and when the space is a git repo,
                // a menu offering a worktree beside it. `isGit` is
                // captured at render cadence: git events re-render the
                // sections, so the flag tracks the store without
                // SidebarView holding another closure.
                let dir = workspace.tabs[section.tabIndexs[0]].panes.first?.cwd
                    .map { spaceRoot?($0) ?? $0 }
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
                    if isGit, let dir {
                        let menu = self.spacePlusMenu(dir: dir)
                        menu.popUp(positioning: nil,
                                   at: NSPoint(x: anchor.bounds.width,
                                               y: anchor.bounds.height),
                                   in: anchor)
                    } else {
                        self.onNewTabInDir?(dir)
                    }
                }, count: section.tabIndexs.count)
                nextHeaders[name] = header
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
                let displayName = tab.userTitle ?? spec?.label ?? title ?? tab.name
                // Live TUI status (agent-style badge); no passive
                // evidence (or a plain shell) shows nothing.
                let status = running ? statusFor?(tab) : nil
                let row: SidebarRowView
                if let reused = tabRows[tab.id] {
                    row = reused
                } else {
                    row = SidebarRowView(click: {})
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
                              onClose: { [weak self] in self?.onCloseTab?(idx) },
                              onRename: { [weak self] in self?.onRenameTab?(idx) },
                              onSetColor: { [weak self] hex in self?.onTabColor?(idx, hex) },
                              onCommitName: { [weak self] name in self?.onRenameTabTo?(idx, name) },
                              onSetIcon: { [weak self] symbol in self?.onTabIcon?(idx, symbol) })
                nextRows[tab.id] = row
                desired.append(row)
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
    }

    func renderWorkspaces(_ workspaces: [WorkspaceState], focusedIndex: Int,
                          states: [UUID: WorkspaceCoordinator.WsState] = [:]) {
        let signature = "theme=\(themeGeneration)#" + workspaces.map { ws in
            "\(ws.id):\(ws.name):\(states[ws.id].map(String.init(describing:)) ?? "?")"
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
                   onDeleteWorkspace: { [weak self] destructive in
                       self?.onDeleteWorkspace?(idx, destructive)
                   }) { [weak self] in
                self?.onWorkspaceSelected?(idx)
            }
        }
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
                onDeleteWorkspace: { [weak self] destructive in
                    self?.onDeleteWorkspace?(idx, destructive)
                }) { [weak self] in
                self?.onWorkspaceSelected?(idx)
            })
        }
    }
}
