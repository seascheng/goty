// goty — see CLAUDE.md for the working principles.
import AppKit

func buildServerMenu(rowEnabled: Bool, onReconnect: (() -> Void)?,
                onDisconnect: (() -> Void)?,
                onDeleteWorkspace: ((Bool) -> Void)?) -> NSMenu {
    let menu = NSMenu()
    if let onReconnect {
        menu.addItem(ActionMenuItem("Reconnect", symbol: "arrow.clockwise",
                                    action: onReconnect))
        menu.addItem(.separator())
    }
    if rowEnabled, let onDisconnect {
        menu.addItem(ActionMenuItem("Remove Server…", symbol: "trash",
                                    action: onDisconnect))
    }
    if let onDeleteWorkspace {
        let destructive = rowEnabled
        menu.addItem(ActionMenuItem(destructive ? "Close Server…" : "Remove Server…",
                                    symbol: destructive ? "xmark.bin" : "trash") {
            onDeleteWorkspace(destructive)
        })
    }
    return menu
}

/// Collapsed-rail server tile: the connection dot IS the row at rail
/// width — hover/selection pill, tooltip with the state word, and the
/// same click (select) and right-click menu as the full server row.
final class ServerRailButton: NSView {
    /// Current dot color (test seam for the rail assertions).
    private(set) var dotFill: NSColor
    private let dot = SidebarRowView.DotView()
    private let onClick: () -> Void
    private let rowEnabled: Bool
    private let onReconnect: (() -> Void)?
    private let onDisconnect: (() -> Void)?
    private let onDeleteWorkspace: ((Bool) -> Void)?
    private var selected: Bool
    private var isHovered = false
    private var trackedBounds: NSRect = .null

    init(name: String, state: WorkspaceCoordinator.WsState, selected: Bool,
         onReconnect: (() -> Void)?, onDisconnect: (() -> Void)?,
         onDeleteWorkspace: ((Bool) -> Void)?, select: @escaping () -> Void) {
        self.selected = selected
        self.rowEnabled = state != .disconnected
        self.onClick = select
        self.onReconnect = onReconnect
        self.onDisconnect = onDisconnect
        self.onDeleteWorkspace = onDeleteWorkspace
        switch state {
        case .connected: dotFill = Chrome.theme.wsConnected
        case .connecting: dotFill = Chrome.theme.wsConnecting
        case .disconnected: dotFill = Chrome.theme.wsDisconnected
        }
        super.init(frame: .zero)
        let word: String
        switch state {
        case .connected: word = "Connected"
        case .connecting: word = "Connecting"
        case .disconnected: word = "Offline"
        }
        toolTip = "\(name) — \(word)"

        dot.fill = dotFill
        dot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dot)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 34),
            heightAnchor.constraint(equalToConstant: 26),
            dot.centerXAnchor.constraint(equalTo: centerXAnchor),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 9),
            dot.heightAnchor.constraint(equalToConstant: 9),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func draw(_ dirtyRect: NSRect) {
        let fill = selected ? Chrome.theme.selectionPill
            : (isHovered ? Chrome.theme.hoverFill : nil)
        guard let fill else { return }
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5),
                     xRadius: 8, yRadius: 8).setClip()
        fill.setFill()
        bounds.fill()
    }

    override func mouseDown(with event: NSEvent) { onClick() }

    override func rightMouseDown(with event: NSEvent) {
        NSMenu.popUpContextMenu(
            buildServerMenu(rowEnabled: rowEnabled, onReconnect: onReconnect,
                       onDisconnect: onDisconnect,
                       onDeleteWorkspace: onDeleteWorkspace),
            with: event, for: self)
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
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        guard isHovered else { return }
        isHovered = false
        needsDisplay = true
    }
}
