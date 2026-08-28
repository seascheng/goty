// goty — see CLAUDE.md for the working principles.
import AppKit

// MARK: - Top tab strip (Ghostty-style; the collapsed-sidebar surface)

/// The terminal region's top tab bar — where tabs live while the
/// sidebar is collapsed to a server rail. Ghostty's tab bar is the
/// visual reference; the title rule is the sidebar's (a user rename
/// wins, then the agent brand, then the PTY's own OSC title, then the
/// counter — one channel for local and remote). Chips carry icon +
/// title + close only: the branch/diff/status detail is what the
/// sidebar row has room for and a horizontal chip does not (tty7's
/// own argument for its sidebar).
final class TabStripView: NSView {
    var onTabSelected: ((Int) -> Void)?
    var onCloseTab: ((Int) -> Void)?
    var onNewTab: (() -> Void)?
    /// Flat + menu's agent items (AgentManifests.acpPickerOrder).
    var onNewAgentSession: ((String) -> Void)?
    /// "Rename…" — the strip has no inline field; the owner prompts.
    var onRenameTab: ((Int) -> Void)?
    var onTabColor: ((Int, String?) -> Void)?
    var onTabIcon: ((Int, String?) -> Void)?

    /// Leading inset from the terminal region's leading edge. The strip
    /// sits BELOW the titlebar band (which owns the traffic lights), so
    /// only breathing room is needed — the old 26 cleared lights that
    /// no longer overhang (the gap-at-left report).
    static let leadingInset: CGFloat = 8
    /// Ghostty's native tab-bar layout: every tab gets a floor width,
    /// tabs then share the whole bar equally, and past the floor the
    /// bar scrolls instead of shrinking chips further.
    static let minTabWidth: CGFloat = 96

    private weak var plusButton: NSView?
    private let scroll = NSScrollView()
    private let chipRow = NSStackView()
    private var chipWidths: [NSLayoutConstraint] = []
    private var signature: String?
    /// Salts the render signature — a theme switch must rebuild chips
    /// (their colors bake in at configure) even with unchanged data.
    private var themeGeneration = 0

    func retheme() {
        themeGeneration += 1
        needsDisplay = true
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: .zero)

        chipRow.orientation = .horizontal
        chipRow.alignment = .height   // chips fill the band's height
        chipRow.spacing = 2
        chipRow.translatesAutoresizingMaskIntoConstraints = false

        // The chip row lives in a horizontal scroll view: widths come
        // from distribute() below — equal share of the visible bar,
        // floored at minTabWidth; overflow scrolls (native tab bar).
        scroll.documentView = chipRow
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets()
        scroll.horizontalScrollElasticity = .none
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)

        let plus = IconButton.make("plus", pointSize: 11) { [weak self] in
            guard let self, let anchor = self.plusButton else { return }
            self.popPlusMenu(from: anchor)
        }
        plus.translatesAutoresizingMaskIntoConstraints = false
        self.plusButton = plus
        addSubview(plus)

        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            plus.leadingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: 8),
            plus.topAnchor.constraint(equalTo: topAnchor),
            plus.bottomAnchor.constraint(equalTo: bottomAnchor),
            plus.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            plus.widthAnchor.constraint(equalToConstant: 26),
        ])
        // Autolayout-in-scrollview rule: pin the document view only on
        // the NON-scrolling axis (vertical). Horizontal pins here would
        // force the clip — and the window — to grow to the chips' width
        // and would defeat scrolling outright (the "window only grows"
        // bug). The row's width is its content: chips at their
        // distributed width; wider than the clip → scrolls, never
        // forces the clip wider.
        let clip = scroll.contentView
        NSLayoutConstraint.activate([
            // Chips fill the band vertically — its cells, not floats.
            chipRow.topAnchor.constraint(equalTo: clip.topAnchor),
            chipRow.bottomAnchor.constraint(equalTo: clip.bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    /// The +'s flat menu: new terminal, then every supported agent —
    /// one click from menu to space, no submenus.
    private func popPlusMenu(from anchor: NSView) {
        let menu = NSMenu()
        let term = NSMenuItem(title: "新建终端", action: #selector(plusTerminalAction(_:)),
                              keyEquivalent: "")
        term.target = self
        term.image = NSImage(systemSymbolName: "terminal",
                             accessibilityDescription: nil)
        menu.addItem(term)
        menu.addItem(.separator())
        for (key, label) in AgentManifests.acpPickerOrder {
            let item = NSMenuItem(title: label, action: #selector(plusAgentAction(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = key
            item.image = AgentBrandIcons.image(for: key)
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.maxY + 4),
                   in: anchor)
    }

    @objc private func plusTerminalAction(_ sender: NSMenuItem) { onNewTab?() }

    @objc private func plusAgentAction(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        onNewAgentSession?(key)
    }

    override func draw(_ dirtyRect: NSRect) {
        // The sidebar surface, continued across the terminal's top
        // band — rail and strip read as one chrome band when collapsed.
        Chrome.theme.topBarBackground.setFill()
        bounds.fill()
    }

    func render(workspace: WorkspaceState, offline: Bool,
                commandFor: ((TabState) -> String?)? = nil,
                titleFor: ((TabState) -> String?)? = nil) {
        // Same-signature skip as the sidebar: render events fire at
        // shell-prompt cadence and usually change no chip.
        var signature = "theme=\(themeGeneration)|offline=\(offline)"
        for tab in workspace.tabs {
            let command = commandFor?(tab) ?? tab.paneCommand
            let spec = AgentCatalog.spec(for: command)
            let title = titleFor?(tab)
            let display = tab.userTitle ?? spec?.label ?? title ?? tab.name
            signature += "|\(tab.id):\(display):\(tab.icon ?? "-"):\(tab.color ?? "-")"
                + ":\(tab.id == workspace.focusedTab?.id)"
        }
        guard signature != self.signature else { return }
        self.signature = signature
        chipRow.arrangedSubviews.forEach { chipRow.removeView($0) }
        chipWidths.forEach { $0.isActive = false }
        chipWidths = []
        // An unreachable workspace shows NO cached session list (the
        // offline cover behind is the workspace view); only "+" stays.
        guard !offline else { return }
        for (idx, tab) in workspace.tabs.enumerated() {
            let command = commandFor?(tab) ?? tab.paneCommand
            let spec = AgentCatalog.spec(for: command)
            let running = AgentCatalog.isAgent(command)
            // Official logo glyph when we have one; a custom user icon
            // wins over everything (the sidebar row's rule).
            let brand = (tab.icon == nil && running)
                ? AgentBrandIcons.image(for: AgentCatalog.manifestKey(for: command))
                : nil
            let title = titleFor?(tab)
            let display = tab.userTitle ?? spec?.label ?? title ?? tab.name
            let tint = tab.color.flatMap { NSColor(hex: $0) }
                ?? (running ? spec?.accent : nil)
            let chip = TabChipView(
                text: display,
                symbol: tab.icon ?? spec?.icon ?? "terminal",
                brandImage: brand, tint: tint,
                selected: idx == workspace.focusedTabIndex,
                tabIndex: idx,
                onSelect: { [weak self] in self?.onTabSelected?(idx) },
                onClose: { [weak self] in self?.onCloseTab?(idx) },
                onRename: { [weak self] in self?.onRenameTab?(idx) },
                onSetColor: { [weak self] hex in self?.onTabColor?(idx, hex) },
                onSetIcon: { [weak self] symbol in self?.onTabIcon?(idx, symbol) })
            chipRow.addArrangedSubview(chip)
            // Separator between neighbors (Ghostty's tab bar rule):
            // not after the last chip, and only between unselected
            // pairs — the selected chip is an island.
            if idx != workspace.tabs.count - 1 {
                chipRow.addArrangedSubview(TabSeparatorView())
            }
        }
        for case let chip as TabChipView in chipRow.arrangedSubviews {
            let width = chip.widthAnchor.constraint(equalToConstant: Self.minTabWidth)
            width.isActive = true
            chipWidths.append(width)
        }
        distributeChipWidths()
        // Keep the selected chip on screen when the bar overflows —
        // the native rule: what you selected is always visible.
        if chipRow.arrangedSubviews.indices.contains(workspace.focusedTabIndex) {
            let chip = chipRow.arrangedSubviews[workspace.focusedTabIndex]
            DispatchQueue.main.async { chip.scrollToVisible(chip.bounds) }
        }
    }

    override func layout() {
        super.layout()
        distributeChipWidths()
    }

    /// Ghostty's tab math: each chip takes an equal share of the bar's
    /// visible width, floored at minTabWidth. At the floor the row runs
    /// past the clip and the scroll view takes over (rubber-band only
    /// then; a fitting row doesn't bounce).
    private func distributeChipWidths() {
        guard !chipWidths.isEmpty, scroll.contentView.bounds.width > 0 else { return }
        let clip = scroll.contentView
        let count = CGFloat(chipWidths.count)
        // Separators (1pt + their 2pt spacing gaps) are fixed overhead;
        // the chips divide what remains — the fill-the-bar model.
        let sepCount = max(0, count - 1)
        let overhead = sepCount * (1 + chipRow.spacing)
        let share = (clip.bounds.width - overhead - chipRow.spacing * (count - 1)) / count
        let width = max(Self.minTabWidth, share.rounded(.down))
        let elasticity: NSScrollView.Elasticity = share < Self.minTabWidth ? .allowed : .none
        if scroll.horizontalScrollElasticity != elasticity {
            scroll.horizontalScrollElasticity = elasticity
        }
        for constraint in chipWidths where constraint.constant != width {
            constraint.constant = width
        }
    }
}

/// One strip chip: icon + title + hover-revealed close; the selection
/// pill / hover fill recipe is the sidebar row's at chip scale. The
/// close slot is reserved (no layout jump on hover).
final class TabChipView: NSView {
    /// Tab index this chip renders — identity, not order.
    let tabIndex: Int
    var displayText: String { label.stringValue }
    private let label = NSTextField(labelWithString: "")
    private let iconView = NSImageView()
    private let onSelect: () -> Void
    private let onClose: (() -> Void)?
    private let onRename: (() -> Void)?
    private let onSetColor: ((String?) -> Void)?
    private let onSetIcon: ((String?) -> Void)?
    private var pillColor: NSColor = .clear
    private var hoverColor: NSColor = .clear
    private var isHovered = false
    private var trackedBounds: NSRect = .null
    private var closeButton: IconButton?

    init(text: String, symbol: String, brandImage: NSImage?, tint: NSColor?,
         selected: Bool, tabIndex: Int,
         onSelect: @escaping () -> Void, onClose: (() -> Void)?,
         onRename: (() -> Void)?, onSetColor: ((String?) -> Void)?,
         onSetIcon: ((String?) -> Void)?) {
        self.tabIndex = tabIndex
        self.onSelect = onSelect
        self.onClose = onClose
        self.onRename = onRename
        self.onSetColor = onSetColor
        self.onSetIcon = onSetIcon
        super.init(frame: .zero)

        // No fixed height: the row pins top/bottom (band height).

        if let brandImage {
            iconView.image = brandImage
            // Theme foreground, never white: mask glyphs are template
            // images and white vanishes on light themes.
            iconView.contentTintColor = brandImage.isTemplate ? Chrome.theme.foreground : nil
        } else {
            let cfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
            iconView.image = NSImage(systemSymbolName: symbol,
                                     accessibilityDescription: nil)?
                .withSymbolConfiguration(cfg)
            iconView.contentTintColor = tint
                ?? (selected ? Chrome.theme.foreground : Chrome.theme.secondaryText)
        }
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)

        label.font = .systemFont(ofSize: 12, weight: selected ? .medium : .regular)
        label.stringValue = text
        label.textColor = selected ? Chrome.theme.foreground : Chrome.theme.secondaryText
        label.lineBreakMode = .byTruncatingTail
        label.cell?.truncatesLastVisibleLine = true
        label.cell?.wraps = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        let close = IconButton.make("xmark", pointSize: 8) { [weak self] in
            self?.onClose?()
        }
        closeButton = close
        close.translatesAutoresizingMaskIntoConstraints = false
        addSubview(close)
        // Revealed on hover — the selected chip keeps it (the row
        // rule: what you're looking at is what you can close).
        close.isHidden = !selected

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 15),
            iconView.heightAnchor.constraint(equalToConstant: 15),
            label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 5),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            // Close slot always reserved — the title never shifts on
            // hover (no reflow while the pointer crosses the strip).
            label.trailingAnchor.constraint(lessThanOrEqualTo: close.leadingAnchor,
                                            constant: -2),
            close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            close.centerYAnchor.constraint(equalTo: centerYAnchor),
            close.widthAnchor.constraint(equalToConstant: 18),
            close.heightAnchor.constraint(equalToConstant: 18),
        ])

        pillColor = selected ? Chrome.theme.selectionPill : .clear
        hoverColor = selected ? .clear : Chrome.theme.hoverFill
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func draw(_ dirtyRect: NSRect) {
        let fill = pillColor != .clear ? pillColor
            : (isHovered ? hoverColor : .clear)
        guard fill != .clear else { return }
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5),
                     xRadius: 8, yRadius: 8).setClip()
        fill.setFill()
        bounds.fill()
    }

    override func mouseDown(with event: NSEvent) { onSelect() }

    // Right-click: the sidebar tab row's menu, minus the inline field
    // (Rename… goes through the owner's prompt).
    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        if let onRename {
            let rename = ActionMenuItem("Rename…", symbol: "pencil", action: onRename)
            menu.addItem(rename)
        }
        if let onClose {
            menu.addItem(ActionMenuItem("Close Space", symbol: "xmark", action: onClose))
        }
        guard onSetColor != nil || onSetIcon != nil else {
            if menu.items.isEmpty { return super.rightMouseDown(with: event) }
            NSMenu.popUpContextMenu(menu, with: event, for: self)
            return
        }
        menu.addItem(.separator())
        if let onSetColor {
            let gridHost = NSMenuItem()
            gridHost.view = ColorGridView { hex in onSetColor(hex) }
            menu.addItem(gridHost)
        }
        if let onSetIcon {
            let iconHost = NSMenuItem()
            iconHost.view = IconGridView { symbol in onSetIcon(symbol) }
            menu.addItem(iconHost)
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    // Hover tracking: the SidebarRowView recipe — rebuild only on a
    // real geometry change, write state only when it changes.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard trackedBounds != bounds else { return }
        trackedBounds = bounds
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeAlways],
            owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        guard !isHovered else { return }
        isHovered = true
        setCloseRevealed(true)
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        guard isHovered else { return }
        isHovered = false
        setCloseRevealed(false)
        needsDisplay = true
    }

    /// Written only on change (a no-op isHidden write dirties layout).
    /// The selected chip keeps its close button — the row rule.
    private func setCloseRevealed(_ revealed: Bool) {
        let target = revealed || pillColor != .clear
        if closeButton?.isHidden == !target { closeButton?.isHidden = !target }
    }
}

/// 1pt vertical divider between strip chips (Ghostty's tab bar). Fills
/// the row's height minus breathing room; muted, never on the edges.
final class TabSeparatorView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 1).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder: not implemented") }
    override func draw(_ dirtyRect: NSRect) {
        let h = bounds.height - 10
        let line = NSRect(x: 0, y: (bounds.height - h) / 2, width: 1, height: h)
        Chrome.theme.hairline.setFill()
        line.fill()
    }
}
