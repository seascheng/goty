// goty — see CLAUDE.md for the working principles.
import AppKit

/// One host stanza in the manager's list column: alias + muted
/// connection summary. Click selects (the right pane edits); the
/// selected row keeps a persistent pill fill.
final class SSHHostRow: NSView {
    override var isFlipped: Bool { true }

    var onClick: (() -> Void)?

    private let aliasLabel = NSTextField(labelWithString: "")
    private let iconView = NSImageView()
    private let detailLabel = NSTextField(labelWithString: "")
    private var ownTracking: NSTrackingArea?
    private var hovered = false
    private var selected = false

    init(stanza: SSHConfigDocument.Stanza) {
        super.init(frame: .zero)
        wantsLayer = true

        iconView.image = NSImage(systemSymbolName: "server.rack", accessibilityDescription: nil)
        iconView.contentTintColor = Chrome.theme.iconTint
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)

        aliasLabel.font = .systemFont(ofSize: 12.5, weight: .medium)
        aliasLabel.textColor = Chrome.theme.foreground
        aliasLabel.lineBreakMode = .byTruncatingMiddle
        aliasLabel.maximumNumberOfLines = 1
        aliasLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(aliasLabel)

        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = Chrome.theme.secondaryText
        detailLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.maximumNumberOfLines = 1
        detailLabel.cell?.truncatesLastVisibleLine = true
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(detailLabel)

        aliasLabel.stringValue = stanza.aliases.joined(separator: " ")
        var parts: [String] = []
        switch (stanza.user, stanza.hostName) {
        case let (user?, host?): parts.append("\(user)@\(host)")
        case let (_, host?): parts.append(host)
        case let (user?, nil): parts.append(user)
        default: break
        }
        if let port = stanza.port { parts.append("port \(port)") }
        detailLabel.stringValue = parts.isEmpty
            ? "no HostName — ssh resolves the alias itself"
            : parts.joined(separator: " · ")

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),
            aliasLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 9),
            aliasLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            aliasLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            detailLabel.leadingAnchor.constraint(equalTo: aliasLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            detailLabel.topAnchor.constraint(equalTo: aliasLabel.bottomAnchor, constant: 2),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder: not implemented") }

    func setSelected(_ on: Bool) {
        selected = on
        applyFill()
    }

    private func applyFill() {
        if selected {
            layer?.backgroundColor = Chrome.theme.selectionPill.cgColor
        } else if hovered {
            layer?.backgroundColor = Chrome.theme.hoverFill.cgColor
        } else {
            layer?.backgroundColor = nil
        }
    }

    // Tracking created ONCE (see IconButton): rebuilding it on every
    // updateTrackingAreas re-fires mouseEntered for the "new" area and
    // the hover state oscillates.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard ownTracking == nil else { return }
        let t = NSTrackingArea(rect: .zero,
                               options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        ownTracking = t
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        applyFill()
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        applyFill()
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
}
