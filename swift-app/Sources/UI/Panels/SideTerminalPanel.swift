// goty — see CLAUDE.md for the working principles.
import AppKit

// MARK: - Side terminal tab (right panel; spec 2026-08-30)

/// The right panel's Terminal tab: a small terminal workspace per
/// SERVER — standard sessiond panes (attach, replay, reconnect — like
/// every pane) that belong to no TabState, split-capable like the
/// center (2026-08-31 revision: ghostty's right-click Split splits IN
/// the panel). The strip shows the FOCUSED pane's live cwd (tail +
/// tooltip) beside two quiet action tiles — cd (jumps to the center's
/// current space root, prompt-gated) and close; the panes sit flush
/// below the 28pt band. The delegate layer builds the PaneHosts and
/// feeds the grid; this container owns the strip, the empty state,
/// and nothing else.
final class SideTerminalPanelView: NSView, ThemeRefreshable {
    /// Empty state: "打开新终端" — materializes the pane via the
    /// coordinator (ensureAuxTerminal → structure → mount).
    var onNewTerminal: (() -> Void)?
    /// Strip close — the delegate confirms (destructive) and clears
    /// every pane.
    var onCloseTerminal: (() -> Void)?
    /// cd tile — the delegate injects `cd <current space root>` into
    /// the focused pane (prompt-gated on its side).
    var onCdToSpace: (() -> Void)?

    /// The center's own grid, reused: fraction layout, hairline seams,
    /// per-host occlusion — nothing here is tab-specific.
    private let grid = PaneGridView()
    /// The strip band (TerminalAreaView's collapsed-mode recipe): one
    /// chromeSurface fill, full bleed, 28pt — the panes hang flush
    /// beneath it, no hairline (the strip's own look).
    private let strip = StripBandView()
    /// Two quiet icon tiles close the strip — the Files toolbar idiom
    /// (22×22 tiles centered in the band), not chrome pills: a 22pt
    /// pill on a 28pt band reads as a full-height slab. Tooltips carry
    /// the words the tiles dropped.
    private let closeButton = IconButton.make("xmark", pointSize: 10)
    /// Jump the focused pane to the center's space root (prompt-gated
    /// by the delegate; the tile dims while gated).
    private let cdButton = IconButton.make("arrow.turn.down.right", pointSize: 11)
    /// The focused pane's cwd: path tail (tooltip carries the whole
    /// path), monospaced secondary — the Files path label's look.
    private let cwdLabel = NSTextField(labelWithString: "")
    private let emptyStack = NSStackView()
    private let emptyLabel = NSTextField(labelWithString: "终端未运行")
    private let newButton = ChromeButton(title: "打开新终端", style: .ghost, compact: true)

    /// The panel's live pane hosts — the click monitor asks for these
    /// to route focus (the center grid's visibleHosts, same contract).
    var visibleHosts: [any PaneHosting] { grid.visibleHosts }

    init() {
        super.init(frame: .zero)
        wantsLayer = true

        strip.bandFill = chromeSurface(Chrome.theme.topBarBackground)
        strip.translatesAutoresizingMaskIntoConstraints = false
        addSubview(strip)

        // Trailing tile pair: 22×22 squares centered in the 28pt band
        // (3pt breathing top/bottom) — a full-height close slab was the
        // size complaint. Both tiles hover-fill (IconButton) and say
        // themselves in the tooltip.
        closeButton.onClick = { [weak self] in self?.onCloseTerminal?() }
        closeButton.toolTip = "关闭侧边终端"
        cdButton.onClick = { [weak self] in self?.onCdToSpace?() }
        cdButton.toolTip = "cd → 当前 space 根目录"
        strip.addSubview(closeButton)
        strip.addSubview(cdButton)
        NSLayoutConstraint.activate([
            closeButton.trailingAnchor.constraint(equalTo: strip.trailingAnchor,
                                                  constant: -6),
            closeButton.centerYAnchor.constraint(equalTo: strip.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 22),
            closeButton.heightAnchor.constraint(equalToConstant: 22),
            cdButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor,
                                               constant: -2),
            cdButton.centerYAnchor.constraint(equalTo: strip.centerYAnchor),
            cdButton.widthAnchor.constraint(equalToConstant: 22),
            cdButton.heightAnchor.constraint(equalToConstant: 22),
        ])

        // Header payload: the focused pane's cwd tail on the left. The
        // label yields to the tiles when the panel narrows (middle
        // truncation keeps both path ends readable).
        cwdLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        cwdLabel.textColor = Chrome.theme.secondaryText
        cwdLabel.lineBreakMode = .byTruncatingMiddle
        strip.addSubview(cwdLabel)
        NSLayoutConstraint.activate([
            cwdLabel.leadingAnchor.constraint(equalTo: strip.leadingAnchor,
                                              constant: 10),
            cwdLabel.centerYAnchor.constraint(equalTo: strip.centerYAnchor),
            cwdLabel.trailingAnchor.constraint(lessThanOrEqualTo: cdButton.leadingAnchor,
                                               constant: -8),
        ])

        grid.translatesAutoresizingMaskIntoConstraints = false
        addSubview(grid)

        // Empty state: centered label + the one action.
        emptyStack.orientation = .vertical
        emptyStack.spacing = 10
        emptyStack.alignment = .centerX
        emptyStack.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.font = .systemFont(ofSize: 11, weight: .regular)
        emptyLabel.textColor = Chrome.theme.secondaryText
        newButton.onClick = { [weak self] in self?.onNewTerminal?() }
        emptyStack.addArrangedSubview(emptyLabel)
        emptyStack.addArrangedSubview(newButton)
        addSubview(emptyStack)

        NSLayoutConstraint.activate([
            strip.leadingAnchor.constraint(equalTo: leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: trailingAnchor),
            strip.topAnchor.constraint(equalTo: topAnchor),
            strip.heightAnchor.constraint(equalToConstant: 28),
            grid.topAnchor.constraint(equalTo: strip.bottomAnchor),
            grid.leadingAnchor.constraint(equalTo: leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: trailingAnchor),
            grid.bottomAnchor.constraint(equalTo: bottomAnchor),
            emptyStack.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyStack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setPanes([])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    // MARK: Delegate-layer surface

    /// Feed the workspace's PaneHosts with their layout fractions
    /// (empty = empty state). Every refresh pass re-runs the grid's
    /// mount path — setVisible + syncCoreVisibility + a layout kick —
    /// which is also the retry path for a session that could not start
    /// while its daemon target was nil (remote link down at first
    /// mount).
    func setPanes(_ entries: [(paneKey: HostKey, host: any PaneHosting,
                               fraction: NSRect)]) {
        grid.setVisiblePanes(entries, keepAlive: [])
        let empty = entries.isEmpty
        strip.isHidden = empty
        grid.isHidden = empty
        emptyStack.isHidden = !empty
    }

    /// The focused pane's live cwd — tail on screen, whole path in the
    /// tooltip (the panel is too narrow for full paths).
    func setCwd(_ path: String?) {
        cwdLabel.stringValue = path.map {
            URL(fileURLWithPath: $0).lastPathComponent
        } ?? ""
        cwdLabel.toolTip = path
    }

    /// The cd tile's gate (a shell prompt on the focused pane); the
    /// delegate computes it, the tile only renders the state.
    func setCdEnabled(_ enabled: Bool) {
        cdButton.isEnabled = enabled
    }

    func retheme() {
        // bandFill's didSet repaints; the strip's fill is config-driven
        // (chromeSurface) so every flip must re-derive it.
        strip.bandFill = chromeSurface(Chrome.theme.topBarBackground)
        emptyLabel.textColor = Chrome.theme.secondaryText
        cwdLabel.textColor = Chrome.theme.secondaryText
    }
}
