// goty — see CLAUDE.md for the working principles.
import AppKit

final class SidebarRowView: NSView {
    /// Rebound on every configure pass: tab indexes shift as spaces open
    /// and close, and reused rows must follow (identity stays, action
    /// retargets).
    var click: () -> Void
    /// Tab index this row renders (nil = non-tab row). Rows are grouped by
    /// directory, so identity — not visual order — addresses a row.
    var tabIndex: Int?
    /// Inline rename in progress (the edit field is up). SidebarView
    /// suppresses row rebuilds while any row is in this state.
    var isRenaming: Bool { !editField.isHidden }
    /// The row's current label text — the resolved display name.
    var displayText: String { labelField.stringValue }
    private let iconView = NSImageView()
    private let labelField = NSTextField(labelWithString: "")
    private let metaField = NSTextField(labelWithString: "")
    private let textStack = NSStackView()
    private let dotView = DotView()
    private let badgeView = SpaceStatusView()
    /// Unselected row fill while a TUI status badge is up (status wash).
    private var statusRowWash: NSColor?
    /// The row's current meta line (branch name or agent label).
    var metaText: String { metaField.stringValue }

    final class DotView: NSView {
        var fill: NSColor = .systemGreen
        override func draw(_ dirtyRect: NSRect) {
            fill.setFill()
            NSBezierPath(ovalIn: bounds).fill()
        }
    }

    /// Trailing status badge (mirror's agent style): a compact pill on
    /// a status-tinted wash, the state word on the tooltip. Working
    /// shows braille dots that morph — the agent's own title spinner
    /// when the surface title carries one, else a locally cycled frame
    /// sequence; every other state shows its SF symbol.
    final class SpaceStatusView: NSView {
        private let iconView = NSImageView()
        private let charField = NSTextField(labelWithString: "")
        private var wash: NSColor = .systemGray

        override var intrinsicContentSize: NSSize { NSSize(width: 26, height: 16) }

        var status: SpaceStatus? { didSet { refresh() } }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            iconView.imageScaling = .scaleProportionallyUpOrDown
            iconView.contentTintColor = .white
            iconView.translatesAutoresizingMaskIntoConstraints = false
            addSubview(iconView)

            charField.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
            charField.textColor = .white
            charField.alignment = .center
            charField.translatesAutoresizingMaskIntoConstraints = false
            charField.isHidden = true
            addSubview(charField)

            NSLayoutConstraint.activate([
                iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
                iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
                iconView.widthAnchor.constraint(equalToConstant: 11),
                iconView.heightAnchor.constraint(equalToConstant: 11),
                charField.centerXAnchor.constraint(equalTo: centerXAnchor),
                charField.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

        static func symbol(for s: SpaceStatus) -> String {
            switch s.activity {
            case .working: return "arrow.triangle.2.circlepath"
            case .blocked: return "hand.raised.fill"
            case .idle: return s.seen ? "moon.zzz.fill" : "checkmark.circle.fill"
            case .unknown: return "questionmark.circle"
            }
        }

        static func color(for s: SpaceStatus) -> NSColor {
            switch s.activity {
            case .working: return AgentSpec.statusWorking
            case .blocked: return AgentSpec.statusWaiting
            case .idle: return s.seen ? AgentSpec.statusIdle : AgentSpec.statusDone
            case .unknown: return Chrome.theme.secondaryText
            }
        }

        var stateWord: String {
            guard let s = status else { return "" }
            switch s.activity {
            case .working: return "working"
            case .blocked: return "blocked"
            case .idle: return s.seen ? "idle" : "done"
            case .unknown: return "unknown"
            }
        }

        private func refresh() {
            guard let s = status else {
                charField.isHidden = true
                iconView.isHidden = false
                stopFrameTimer()
                return
            }
            wash = Self.color(for: s)
            toolTip = stateWord
            // goty: working is always braille — the title's own spinner
            // char when present, else a locally cycled frame sequence.
            let showChar = s.activity == .working
            if showChar {
                charField.stringValue = s.spinner.map(String.init) ?? String(Self.frames[frameIndex])
            }
            charField.isHidden = !showChar
            iconView.isHidden = showChar
            if !showChar {
                iconView.image = NSImage(
                    systemSymbolName: Self.symbol(for: s),
                    accessibilityDescription: stateWord)?
                    .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
                stopFrameTimer()
            } else if s.spinner == nil {
                startFrameTimer()
            } else {
                stopFrameTimer()
            }
            needsDisplay = true
        }

        /// Braille spinner frames (⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏) cycled locally
        /// while working WITHOUT a title-driven char — the dots morph in
        /// place, so nothing ever rotates out of the badge bounds (the
        /// off-center pinwheel bug). Rows are reused across tabs, so
        /// leaving working (or gaining a live title char) must stop it.
        private static let frames: [Character] = Array("⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏")
        private var frameIndex = 0
        private var frameTimer: Timer?

        private func startFrameTimer() {
            guard frameTimer == nil else { return }
            frameTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.frameIndex = (self.frameIndex + 1) % Self.frames.count
                self.charField.stringValue = String(Self.frames[self.frameIndex])
            }
        }

        private func stopFrameTimer() {
            frameTimer?.invalidate()
            frameTimer = nil
        }

        override func draw(_ dirtyRect: NSRect) {
            let path = NSBezierPath(roundedRect: bounds,
                                    xRadius: bounds.height / 2,
                                    yRadius: bounds.height / 2)
            wash.withAlphaComponent(0.22).setFill()
            path.fill()
        }
    }

    /// Shared row chrome (tty7 tab-sidebar proportions): one fixed leading
    /// 20pt slot every title aligns behind, tight gutters, rounded pill.
    static let iconSlot: CGFloat = 20
    static let iconLeading: CGFloat = 6
    static let textGap: CGFloat = 6
    /// Stacks and header containers share this sidebar inset — SYMMETRIC
    /// gutters: the pill hugs the panel edge by the same gap on both
    /// sides (3 left / 8 right read as a lopsided row when selected);
    /// the icon sits deep inside its pill.
    static let stackInset: CGFloat = 3
    /// Row fill: selection pill, hover wash, brand avatar disc.
    private var pillColor: NSColor = .clear
    /// Full-row hover fill; only when the row is not selected.
    private var hoverColor: NSColor = .clear
    /// Brand disc under the leading glyph (agent rows); nil = plain symbol.
    private var avatarColor: NSColor?
    /// Status dot for avatar rows — drawn on the disc's rim, not trailing.
    private var avatarDot: NSColor?

    private var heightConstraint: NSLayoutConstraint?

    init(click: @escaping () -> Void) {
        self.click = click
        super.init(frame: .zero)

        heightConstraint = heightAnchor.constraint(equalToConstant: 32)
        heightConstraint?.isActive = true

        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)

        labelField.font = .systemFont(ofSize: 13)
        labelField.textColor = .secondaryLabelColor
        // Terminal titles are paths/commands — the informative end is the
        // tail, so overflow keeps it: "…xx/foo.rs", not "xx/foo.rs…".
        labelField.lineBreakMode = .byTruncatingHead
        labelField.cell?.truncatesLastVisibleLine = true
        labelField.cell?.wraps = false
        // Let long titles compress instead of pushing the row past the
        // sidebar edge.
        labelField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        labelField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        metaField.font = .systemFont(ofSize: 10.5)
        metaField.textColor = Chrome.theme.secondaryText
        metaField.lineBreakMode = .byTruncatingTail
        metaField.cell?.truncatesLastVisibleLine = true
        metaField.cell?.wraps = false
        metaField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        metaField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        // Text block centers as a unit against the icon's midline — both
        // single-line and two-line rows stay horizontally aligned.
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 0
        textStack.addArrangedSubview(labelField)
        textStack.addArrangedSubview(metaField)
        textStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textStack)

        dotView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dotView)

        badgeView.isHidden = true
        badgeView.setContentHuggingPriority(.required, for: .horizontal)
        badgeView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(badgeView)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.iconLeading),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: Self.iconSlot),
            textStack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor,
                                               constant: Self.textGap),
            textStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: dotView.leadingAnchor, constant: -4),
            dotView.leadingAnchor.constraint(greaterThanOrEqualTo: textStack.trailingAnchor, constant: 6),
            dotView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            dotView.centerYAnchor.constraint(equalTo: centerYAnchor),
            dotView.heightAnchor.constraint(equalToConstant: 6),
            // Width must be pinned: leading is only a FLOOR (≥), so an
            // unpinned width let the dot stretch from the text to the
            // trailing edge on short labels (the long-stripe bug).
            dotView.widthAnchor.constraint(equalToConstant: 6),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: badgeView.leadingAnchor, constant: -6),
            badgeView.leadingAnchor.constraint(greaterThanOrEqualTo: textStack.trailingAnchor, constant: 6),
            // ONE trailing constant for the whole right column (dot and
            // badge share -8): a second, conflicting -30 constraint from
            // the initial commit let autolayout break either one at
            // will — the right margin moved between launches.
            badgeView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            badgeView.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    func configure(text: String, symbol: String?, selected: Bool, dot: NSColor? = nil,
                   tagColor: NSColor? = nil, meta: String? = nil, enabled: Bool = true,
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
                   onDeleteWorkspace: ((Bool) -> Void)? = nil) {
        self.tabIndex = tabIndex
        rowEnabled = enabled
        self.onReconnect = onReconnect
        self.onDisconnect = onDisconnect
        self.onSetIcon = onSetIcon
        self.onDeleteWorkspace = onDeleteWorkspace
        self.onClose = onClose
        self.onRename = onRename
        self.onSetColor = onSetColor
        self.onCommitName = onCommitName
        closeButton.onClick = onClose
        // Two-line space rows (44pt); single-line server/action rows (32pt).
        heightConstraint?.constant = onCommitName != nil ? 44 : 32
        // The git line replaces the plain meta when a repo is known —
        // branch only (the old +/− counts dropped; the status badge
        // carries the live signal now).
        if let git {
            metaField.stringValue = git.branch
            metaField.isHidden = false
        } else {
            metaField.stringValue = meta ?? ""
            metaField.isHidden = (meta ?? "").isEmpty
        }
        if let brandImage {
            // Official tool logo (template alpha; AgentIcons.swift) in the
            // 18pt slot — AppKit picks the rep density at draw time.
            iconView.image = brandImage
            iconView.isHidden = false
        } else if let symbol {
            let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
            iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(cfg)
            iconView.isHidden = false
        } else {
            iconView.isHidden = true
        }
        labelField.stringValue = text
        labelField.font = .systemFont(ofSize: 13, weight: selected ? .semibold : .regular)
        labelField.textColor = !rowEnabled
            ? Chrome.theme.secondaryText.withAlphaComponent(0.5)
            : (selected ? Chrome.theme.foreground : Chrome.theme.secondaryText)
        // Brand images stand alone (no accent disc underneath). A pure
        // monochrome glyph (mask) is tinted white for the dark sidebar;
        // colored marks keep their native palette untouched.
        let hasBrand = brandImage != nil
        avatarColor = hasBrand ? nil : avatar
        // Agent rows tint their leading glyph with the live status
        // color (mirror's statusIconTint); a user tag color still wins.
        let statusTint: NSColor? = status.map { s in
            switch s.activity {
            case .working, .blocked: return SpaceStatusView.color(for: s)
            default: return nil
            }
        } ?? nil
        iconView.contentTintColor = (brandImage?.isTemplate == true)
            ? NSColor.white
            : hasBrand
                ? nil
                : tagColor ?? statusTint
                    ?? (selected ? Chrome.theme.foreground : Chrome.theme.secondaryText)
        pillColor = selected ? Chrome.theme.selectionPill : .clear
        // Agent-style rows (mirror): a live TUI status rides the trailing
        // badge and tints the row — the plain dot stays for non-agent
        // rows (server connection states).
        statusRowWash = nil
        if let status, status.activity != .unknown {
            badgeView.status = status
            badgeUp = true
            badgeView.isHidden = closeRevealed
            dotView.isHidden = true
            avatarDot = nil
            switch status.activity {
            case .working: statusRowWash = SpaceStatusView.color(for: status)
                .withAlphaComponent(0.10)
            case .blocked: statusRowWash = SpaceStatusView.color(for: status)
                .withAlphaComponent(0.12)
            default: break
            }
        } else {
            badgeUp = false
            badgeView.isHidden = true
            avatarDot = nil
            if avatar != nil && !hasBrand {
                // Status rides on the avatar's rim (tty7 tab_avatar).
                avatarDot = dot
                dotView.isHidden = true
            } else if let dot {
                dotView.fill = dot
                dotView.needsDisplay = true
                dotView.isHidden = false
            } else {
                dotView.isHidden = true
            }
        }
        hoverColor = selected ? .clear : (statusRowWash ?? Chrome.theme.hoverFill)
        // State→style writes MUST invalidate: reused rows repaint only
        // when dirty, and hover events are not a substitute — clicking a
        // different tab deselected this row inside configure while its
        // last paint (a pre-deselect mouseExited) left the selection
        // pill on screen (the stuck-gray report, 2026-08-25).
        needsDisplay = true
    }

    /// Test seam: is the selection pill currently mapped onto this row?
    var selectionPaintedForTest: Bool { pillColor != .clear }

    override func draw(_ dirtyRect: NSRect) {
        let fill = pillColor != .clear
            ? pillColor
            : (isHovered ? hoverColor : .clear)
        if fill != .clear {
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5),
                         xRadius: 8, yRadius: 8).setClip()
            fill.setFill()
            bounds.fill()
        }
        guard let avatarColor else { return }
        // Brand disc under the glyph; near-black brands get a hairline so
        // the disc doesn't dissolve into a dark sidebar (tty7 rule).
        let disc = iconView.frame
        let discPath = NSBezierPath(ovalIn: disc)
        avatarColor.setFill()
        discPath.fill()
        let r = avatarColor.redComponent, g = avatarColor.greenComponent,
            b = avatarColor.blueComponent
        if r + g + b < 0.36 {
            // Near-black brands dissolve on a dark sidebar — hairline rim.
            Chrome.theme.hairline.setStroke()
            discPath.lineWidth = 1
            discPath.stroke()
        }
        if let avatarDot {
            // Rim badge: 8pt dot ringed in the sidebar's own surface.
            let d: CGFloat = 8
            let dotRect = NSRect(x: disc.maxX - d + 2, y: disc.minY - 2, width: d, height: d)
            let dotPath = NSBezierPath(ovalIn: dotRect.insetBy(dx: -1, dy: -1))
            Chrome.theme.avatarDotRing.setFill()
            dotPath.fill()
            avatarDot.setFill()
            NSBezierPath(ovalIn: dotRect).fill()
        }
    }

    override func mouseDown(with event: NSEvent) {
        // Double-click opens the inline rename — detected on the DOWN
        // phase: the single click's re-render replaces this row before
        // any mouseUp could arrive, so a mouseUp-based check never fires.
        if event.clickCount >= 2, onCommitName != nil {
            beginInlineRename()
            return
        }
        click()
    }


    // Hover-revealed close button
    private lazy var closeButton: IconButton = {
        let b = IconButton.make("xmark", pointSize: 9)  // subtle ✕
        b.isHidden = true
        addSubview(b)
        NSLayoutConstraint.activate([
            b.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            b.centerYAnchor.constraint(equalTo: centerYAnchor),
            b.widthAnchor.constraint(equalToConstant: 18),
            b.heightAnchor.constraint(equalToConstant: 18),
        ])
        return b
    }()

    private var trackedBounds: NSRect = .null

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // Rebuild ONLY on a real geometry change. Rebuilding on every
        // call re-fires mouseEntered while the mouse stands inside, and
        // the enter handler (isHidden toggle → layout) then re-runs
        // updateTrackingAreas — the self-sustaining hover flicker.
        guard trackedBounds != bounds else { return }
        trackedBounds = bounds
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeAlways],
            owner: self, userInfo: nil))
    }

    /// A live badge is up (configure) — separate from isHidden: hover
    /// hides it while the close button owns the shared right column.
    private var badgeUp = false
    private var closeRevealed = false
    /// Reveal state is written only when it CHANGES: a no-op write
    /// would still dirty layout and keep the cycle alive.
    private func setCloseRevealed(_ revealed: Bool) {
        // Only real tab rows (with an onClose) reveal the close button —
        // never "New Tab" / "Add Remote…" / workspace rows.
        let target = revealed && onClose != nil
        closeRevealed = target
        if closeButton.isHidden != !target { closeButton.isHidden = !target }
        // The close button takes the row tail on hover: the badge (same
        // right column) steps aside — the verb in focus wins.
        let badgeHidden = !badgeUp || target
        if badgeView.isHidden != badgeHidden { badgeView.isHidden = badgeHidden }
    }

    override func mouseEntered(with event: NSEvent) {
        setCloseRevealed(true)
        setHovered(true)
    }

    override func mouseExited(with event: NSEvent) {
        setCloseRevealed(false)
        setHovered(false)
    }

    private var isHovered = false

    /// Full-row hover fill (tty7): written only on change so it can't
    /// retrigger layout cycles.
    private func setHovered(_ hovered: Bool) {
        guard isHovered != hovered else { return }
        isHovered = hovered
        needsDisplay = true
    }

    // Right-click: workspace rows get reconnect/delete; tab rows the
    // rename/color/icon/close menu.
    override func rightMouseDown(with event: NSEvent) {
        if onReconnect != nil || onDisconnect != nil || onDeleteWorkspace != nil {
            NSMenu.popUpContextMenu(serverMenu(), with: event, for: self)
            return
        }
        guard onRename != nil || onSetColor != nil || onClose != nil else {
            super.rightMouseDown(with: event)
            return
        }
        let menu = NSMenu()

        // Order: rename, close, color grid, icon grid (grids inline —
        // frequent adjustments, no submenu hops).
        let rename = NSMenuItem(title: "Rename…", action: #selector(renameAction),
                                keyEquivalent: "")
        rename.target = self
        rename.image = menuItemIcon("pencil")
        menu.addItem(rename)

        let close = NSMenuItem(title: "Close Space", action: #selector(closeAction),
                               keyEquivalent: "w")
        close.target = self
        close.image = menuItemIcon("xmark")
        menu.addItem(close)

        menu.addItem(.separator())

        let gridHost = NSMenuItem()
        gridHost.view = ColorGridView { [weak self] hex in
            self?.onSetColor?(hex)
        }
        menu.addItem(gridHost)

        let iconHost = NSMenuItem()
        iconHost.view = IconGridView { [weak self] symbol in
            self?.onSetIcon?(symbol)
        }
        menu.addItem(iconHost)

        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    /// A server row's menu — the shared builder, fed from this row's
    /// stored closures (the rail tiles build theirs the same way).
    func serverMenu() -> NSMenu {
        buildServerMenu(rowEnabled: rowEnabled, onReconnect: onReconnect,
                        onDisconnect: onDisconnect,
                        onDeleteWorkspace: onDeleteWorkspace)
    }

    static let tagPalette: [(String, String)] = [
        ("Red", "#ff5f57"), ("Orange", "#ff9f43"), ("Yellow", "#e8ae5b"),
        ("Green", "#86af80"), ("Blue", "#6495ed"), ("Purple", "#c586c0"),
        ("Pink", "#ff7ab2"), ("Gray", "#8a8a8a"),
    ]

    @objc private func renameAction() { beginInlineRename() }
    @objc private func reconnectAction() { onReconnect?() }
    @objc private func deleteWsAction() { onDeleteWorkspace?(rowEnabled) }
    @objc private func colorAction(_ sender: NSMenuItem) {
        let hex = sender.representedObject is NSNull ? nil : sender.representedObject as? String
        onSetColor?(hex)
    }
    @objc private func closeAction() { onClose?() }

    private var onRename: (() -> Void)?
    private var onSetColor: ((String?) -> Void)?
    private var onSetIcon: ((String?) -> Void)?
    private var onClose: (() -> Void)?
    private var onCommitName: ((String) -> Void)?
    private var rowEnabled = true
    private var onReconnect: (() -> Void)?
    private var onDisconnect: (() -> Void)?
    private var onDeleteWorkspace: ((Bool) -> Void)?

    private lazy var editField: RenameField = {
        let f = RenameField()
        f.font = .systemFont(ofSize: 12.5)
        f.textColor = Chrome.theme.foreground
        f.backgroundColor = Chrome.theme.selectionPill
        f.focusRingType = .none
        f.bezelStyle = .roundedBezel
        f.isHidden = true
        f.translatesAutoresizingMaskIntoConstraints = false
        addSubview(f)
        NSLayoutConstraint.activate([
            f.leadingAnchor.constraint(equalTo: textStack.leadingAnchor, constant: -3),
            f.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            f.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        return f
    }()

    private var clickCommitMonitor: Any?

    /// Inline title editing: the label swaps for a bordered field; Enter
    /// commits, Escape cancels, blur commits.
    func beginInlineRename() {
        guard onCommitName != nil else { return }
        editField.stringValue = labelField.stringValue
        labelField.isHidden = true
        editField.isHidden = false
        window?.makeFirstResponder(editField)
        editField.currentEditor()?.selectAll(nil)
        // Clicking anywhere outside the field commits — including areas that
        // never become first responder (sidebar background, terminal).
        clickCommitMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            if let self, event.window === self.window {
                self.endInlineRename(commit: true)
            }
            return event
        }
    }

    func endInlineRename(commit: Bool) {
        if let monitor = clickCommitMonitor {
            NSEvent.removeMonitor(monitor)
            clickCommitMonitor = nil
        }
        guard !editField.isHidden else { return }
        let name = editField.stringValue.trimmingCharacters(in: .whitespaces)
        editField.isHidden = true
        labelField.isHidden = false
        window?.makeFirstResponder(nil)
        guard commit else { return }
        // Ghostty rule: an emptied field CLEARS the user title (the
        // program's own title takes over again); a changed field sets
        // it; an untouched field is a no-op (don't freeze a transient
        // program title as the user's).
        if name.isEmpty {
            onCommitName?("")
        } else if name != labelField.stringValue {
            labelField.stringValue = name
            onCommitName?(name)
        }
    }

}
final class RenameField: NSTextField {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 53 {  // escape
            (superview as? SidebarRowView)?.endInlineRename(commit: false)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func textDidEndEditing(_ notification: Notification) {
        (superview as? SidebarRowView)?.endInlineRename(commit: true)
        super.textDidEndEditing(notification)
    }
}

/// A server's right-click menu, built pure so tests can inspect and
/// fire it. Shared by the full sidebar row and the collapsed-rail
/// tile. The two close modes live side by side: Remove drops the
/// connection and keeps every session running on the machine
/// (re-adding the host reattaches); Close Server terminates them and
/// removes the entry too. Offline rows can only offer Reconnect plus
