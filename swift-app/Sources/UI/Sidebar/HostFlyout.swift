// goty — see CLAUDE.md for the working principles.
import AppKit

/// One pickable row of the Servers '+' flyout.
enum HostPickerEntry: Equatable {
    case host(String)
    case manage
}

/// Themed host-picker flyout (the Servers '+'): our card language —
/// chromeSurface fill, hairline border, 10pt corners, hoverFill rows —
/// instead of the system NSMenu chrome, which never followed the
/// theme. Borderless popUpMenu-level panel below the anchor; closes on
/// any pick or any click outside its own panel.
enum HostFlyout {
    private static var panel: NSPanel?
    private static var monitors: [Any] = []

    static func show(anchor: NSView, entries: [HostPickerEntry],
                     onPick: @escaping (HostPickerEntry) -> Void) {
        close()
        guard let window = anchor.window else { return }

        let content = HostFlyoutView(entries: entries) { entry in
            close()
            onPick(entry)
        }
        content.fit()

        let p = NSPanel(contentRect: NSRect(x: 0, y: 0,
                                            width: content.fittingSize.width,
                                            height: content.fittingSize.height),
                        styleMask: .borderless, backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .popUpMenu
        p.contentView = content
        panel = p

        // Below the anchor's left edge, clamped to the screen.
        let anchorRect = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let screen = NSScreen.main?.visibleFrame ?? .zero
        let size = content.fittingSize
        let x = min(max(anchorRect.minX, screen.minX + 8), screen.maxX - size.width - 8)
        let y = max(anchorRect.minY - size.height - 6, screen.minY + 8)
        p.setFrameOrigin(NSPoint(x: x, y: y))
        window.addChildWindow(p, ordered: .above)

        // Click-outside dismissal: global (other apps) + local (our own
        // windows — the global monitor never sees those).
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in
            close()
        })
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            if event.window !== p { close() }
            return event
        })
    }

    static func close() {
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors.removeAll()
        if let p = panel { p.parent?.removeChildWindow(p) }
        panel?.orderOut(nil)
        panel = nil
    }
}

/// The flyout card: caption + host rows + hairline + manage row.
final class HostFlyoutView: NSView, ThemeRefreshable {
    private let entries: [HostPickerEntry]
    private let onPick: (HostPickerEntry) -> Void
    private var cardBackground: NSColor = .clear

    init(entries: [HostPickerEntry], onPick: @escaping (HostPickerEntry) -> Void) {
        self.entries = entries
        self.onPick = onPick
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 1

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        let caption = NSTextField(labelWithString: "ADD SERVER")
        caption.font = .systemFont(ofSize: 10, weight: .semibold)
        caption.textColor = Chrome.theme.tertiaryText
        stack.addView(caption, in: .leading)
        stack.setCustomSpacing(6, after: caption)

        for (i, entry) in entries.enumerated() {
            if case .manage = entry, i > 0 {
                let divider = HairlineView()
                divider.heightAnchor.constraint(equalToConstant: 1).isActive = true
                stack.addView(divider, in: .leading)
                stack.setCustomSpacing(4, after: divider)
                stack.setCustomSpacing(4, after: stack.arrangedSubviews.last ?? divider)
            }
            let (title, symbol) = {
                switch entry {
                case .host(let h): return (h, "server.rack")
                case .manage: return ("Manage Hosts…", "slider.horizontal.3")
                }
            }()
            let row = FlyoutRow(title: title, symbol: symbol) { [weak self] in
                self?.onPick(entry)
            }
            row.widthAnchor.constraint(greaterThanOrEqualToConstant: 190).isActive = true
            stack.addView(row, in: .leading)
        }

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError("init(coder: not implemented") }

    func fit() { layoutSubtreeIfNeeded() }

    override func draw(_ dirtyRect: NSRect) {
        // Card fill at draw time — the flyout is transient (built per
        // open), so this is belt-and-braces next to applyTheme().
        chromeSurface(cardBackground).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
    }

    private func applyTheme() {
        cardBackground = Chrome.theme.background
        layer?.borderColor = Chrome.theme.hairline.cgColor
    }

    func retheme() {
        applyTheme()
        needsDisplay = true
    }
}

/// One flyout row: symbol + title, hoverFill wash, pointing-hand cursor.
final class FlyoutRow: NSView {
    private let onClick: (() -> Void)?
    private var hovered = false
    private var ownTracking: NSTrackingArea?

    init(title: String, symbol: String, onClick: (() -> Void)?) {
        self.onClick = onClick
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 6

        let icon = IconLabel(symbol, pointSize: 12)
        addSubview(icon)
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12.5, weight: .regular)
        label.textColor = Chrome.theme.foreground
        label.lineBreakMode = .byTruncatingMiddle
        label.cell?.truncatesLastVisibleLine = true
        label.cell?.wraps = false
        addSubview(label)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder: not implemented") }

    override func draw(_ dirtyRect: NSRect) {
        if hovered {
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).setClip()
            Chrome.theme.hoverFill.setFill()
            bounds.fill()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Tracking created ONCE (the IconButton rule).
        guard ownTracking == nil, window != nil else { return }
        let t = NSTrackingArea(rect: .zero,
                               options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        ownTracking = t
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}
