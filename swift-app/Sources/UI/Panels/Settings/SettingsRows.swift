// goty — see CLAUDE.md for the working principles.
import AppKit
import GhosttyKit

/// The Config File section as a DOCUMENT page, not a form: path card +
/// actions + load status. Three 56pt rows with mismatched controls
/// (button / button / sentence) is what read as clutter — this page
/// has no settings, only facts and verbs about one file.
final class ConfigFilePage: NSView {
    override var isFlipped: Bool { true }

    init(title: String, subtitle: String, path: String,
         errors: [String], onOpen: @escaping () -> Void,
         onReload: @escaping () -> Void) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = chromeSurface(Chrome.theme.background).cgColor

        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 17, weight: .semibold)
        heading.textColor = Chrome.theme.foreground
        heading.translatesAutoresizingMaskIntoConstraints = false
        addSubview(heading)

        let sub = NSTextField(labelWithString: subtitle)
        sub.font = .systemFont(ofSize: 11.5)
        sub.textColor = Chrome.theme.secondaryText
        sub.lineBreakMode = .byWordWrapping
        sub.maximumNumberOfLines = 2
        sub.cell?.truncatesLastVisibleLine = true
        sub.cell?.wraps = true
        sub.translatesAutoresizingMaskIntoConstraints = false
        addSubview(sub)

        // --- The file card (Dialog card language: lifted fill,
        //     hairline border, 12pt corners) ---
        let card = NSView()
        card.wantsLayer = true
        card.layer?.backgroundColor = chromeSurface(Chrome.theme.topBarBackground).cgColor
        card.layer?.borderColor = Chrome.theme.hairline.cgColor
        card.layer?.borderWidth = 1
        card.layer?.cornerRadius = 12
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)

        let caps = NSTextField(labelWithString: "FILE")
        caps.font = .systemFont(ofSize: 10.5, weight: .semibold)
        caps.textColor = Chrome.theme.secondaryText
        caps.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(caps)

        let home = NSHomeDirectory()
        let shown = path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
        let pathField = NSTextField(labelWithString: shown)
        pathField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        pathField.textColor = Chrome.theme.foreground
        pathField.lineBreakMode = .byTruncatingMiddle
        pathField.maximumNumberOfLines = 1
        pathField.cell?.wraps = false
        pathField.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(pathField)

        let copy = ChromeButton.make("Copy", style: .ghost) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(path, forType: .string)
        }
        copy.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(copy)

        let divider1 = HairlineView()
        divider1.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(divider1)

        let open = ChromeButton.make("Open in Editor", style: .ghost, onClick: onOpen)
        open.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(open)
        let reload = ChromeButton.make("Reload Now", style: .primary, onClick: onReload)
        reload.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(reload)

        let divider2 = HairlineView()
        divider2.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(divider2)

        // --- Load status: dot + sentence, full width, no pretending
        //     to be a form control ---
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.backgroundColor = (errors.isEmpty
            ? Chrome.theme.wsConnected : Chrome.theme.wsDisconnected).cgColor
        dot.layer?.cornerRadius = 3.5
        dot.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(dot)

        let status = NSTextField(labelWithString: errors.isEmpty
            ? "No errors — last load was clean."
            : "\(errors.count) error(s) on the last load — see Console.app (goty prefix).")
        status.font = .systemFont(ofSize: 11.5)
        status.textColor = Chrome.theme.secondaryText
        status.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(status)

        NSLayoutConstraint.activate([
            heading.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            heading.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
            heading.topAnchor.constraint(equalTo: topAnchor, constant: 22),
            sub.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            sub.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
            sub.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 4),

            card.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            card.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            card.topAnchor.constraint(equalTo: sub.bottomAnchor, constant: 16),

            caps.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            caps.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            pathField.leadingAnchor.constraint(equalTo: caps.leadingAnchor),
            pathField.topAnchor.constraint(equalTo: caps.bottomAnchor, constant: 3),
            copy.centerYAnchor.constraint(equalTo: pathField.centerYAnchor),
            copy.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            pathField.trailingAnchor.constraint(lessThanOrEqualTo: copy.leadingAnchor, constant: -10),

            divider1.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            divider1.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            divider1.topAnchor.constraint(equalTo: pathField.bottomAnchor, constant: 14),

            open.leadingAnchor.constraint(equalTo: caps.leadingAnchor),
            open.topAnchor.constraint(equalTo: divider1.bottomAnchor, constant: 12),
            reload.leadingAnchor.constraint(equalTo: open.trailingAnchor, constant: 10),
            reload.centerYAnchor.constraint(equalTo: open.centerYAnchor),

            divider2.leadingAnchor.constraint(equalTo: divider1.leadingAnchor),
            divider2.trailingAnchor.constraint(equalTo: divider1.trailingAnchor),
            divider2.topAnchor.constraint(equalTo: open.bottomAnchor, constant: 14),

            dot.leadingAnchor.constraint(equalTo: caps.leadingAnchor),
            dot.widthAnchor.constraint(equalToConstant: 7),
            dot.heightAnchor.constraint(equalToConstant: 7),
            dot.centerYAnchor.constraint(equalTo: status.centerYAnchor),
            status.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 8),
            status.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -16),
            status.topAnchor.constraint(equalTo: divider2.bottomAnchor, constant: 13),
            card.bottomAnchor.constraint(equalTo: status.bottomAnchor, constant: 14),

            bottomAnchor.constraint(greaterThanOrEqualTo: card.bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder: not implemented") }
}

final class SettingsSectionRow: NSView {
    var onClick: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    private var ownTracking: NSTrackingArea?
    private var hovered = false
    private var selected = false

    init(_ section: SettingsSection) {
        super.init(frame: .zero)
        wantsLayer = true

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: section.symbol,
                             accessibilityDescription: nil)
        icon.contentTintColor = Chrome.theme.iconTint
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)

        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = Chrome.theme.foreground
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)
        titleLabel.stringValue = section.title

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
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

    // Tracking created ONCE (the IconButton rule): rebuilding it on
    // every updateTrackingAreas re-fires mouseEntered while the mouse
    // stands still and the hover state oscillates.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard ownTracking == nil else { return }
        let t = NSTrackingArea(rect: .zero,
                               options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        ownTracking = t
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; applyFill() }
    override func mouseExited(with event: NSEvent) { hovered = false; applyFill() }
    override func mouseDown(with event: NSEvent) { onClick?() }
}

/// The right pane: page title + stacked label/control rows separated
/// by hairlines, inside the root's scroll view. Controls built by the
/// root register themselves under their managed key so tests (and a
/// future re-sync) can find them.
final class SettingsFormPage: NSView {
    override var isFlipped: Bool { true }

    private(set) var controlsByKey: [String: NSView] = [:]
    private var previousBottom: NSLayoutYAxisAnchor!

    init(title: String, subtitle: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = chromeSurface(Chrome.theme.background).cgColor

        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 17, weight: .semibold)
        heading.textColor = Chrome.theme.foreground
        heading.translatesAutoresizingMaskIntoConstraints = false
        addSubview(heading)

        let sub = NSTextField(labelWithString: subtitle)
        sub.font = .systemFont(ofSize: 11.5)
        sub.textColor = Chrome.theme.secondaryText
        sub.lineBreakMode = .byWordWrapping
        sub.maximumNumberOfLines = 2
        sub.cell?.truncatesLastVisibleLine = true
        sub.cell?.wraps = true
        sub.translatesAutoresizingMaskIntoConstraints = false
        addSubview(sub)

        NSLayoutConstraint.activate([
            heading.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            heading.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
            heading.topAnchor.constraint(equalTo: topAnchor, constant: 22),
            sub.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            sub.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
            sub.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 4),
        ])
        previousBottom = sub.bottomAnchor
    }

    required init?(coder: NSCoder) { fatalError("init(coder: not implemented") }

    private var rows: [NSView] = []

    /// One settings row, FIXED 48pt (uniform tty7 rhythm): label
    /// (+optional mono detail line) left, control right. Fixed height
    /// is the layout contract — native-control intrinsic sizes (the
    /// oversized-first-row bug) can never stretch it.
    func addRow(label: String, detail: String? = nil, key: String? = nil,
                control: NSView) {
        if let key { controlsByKey[key] = control }

        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        rows.append(row)
        row.addSubview(control)

        let titleField = NSTextField(labelWithString: label)
        titleField.font = .systemFont(ofSize: 13)
        titleField.textColor = Chrome.theme.foreground
        titleField.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(titleField)

        var labelBottom = titleField.bottomAnchor
        if let detail, !detail.isEmpty {
            let detailField = NSTextField(labelWithString: detail)
            detailField.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
            detailField.textColor = Chrome.theme.secondaryText
            detailField.lineBreakMode = .byTruncatingMiddle
            detailField.maximumNumberOfLines = 1
            detailField.cell?.wraps = false
            detailField.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(detailField)
            NSLayoutConstraint.activate([
                detailField.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 24),
                detailField.trailingAnchor.constraint(lessThanOrEqualTo: control.leadingAnchor, constant: -12),
                detailField.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 1),
            ])
            labelBottom = detailField.bottomAnchor
        }

        let hairline = HairlineView()
        hairline.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hairline)

        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: previousBottom, constant: 2),
            row.heightAnchor.constraint(equalToConstant: 56),
            titleField.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 24),
            titleField.trailingAnchor.constraint(lessThanOrEqualTo: control.leadingAnchor, constant: -12),
            titleField.topAnchor.constraint(equalTo: row.topAnchor, constant: detail == nil ? 18 : 9),
            control.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -24),
            control.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            hairline.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            hairline.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            hairline.topAnchor.constraint(equalTo: row.bottomAnchor),
            hairline.heightAnchor.constraint(equalToConstant: 1),
        ])
        _ = labelBottom
        previousBottom = hairline.bottomAnchor
        // Close the chain: the page's intrinsic height = its rows.
        bottomAnchor.constraint(greaterThanOrEqualTo: hairline.bottomAnchor)
            .isActive = true
    }

    /// Layout lock surface: every row must be exactly 48pt.
    var rowHeightsForTest: [CGFloat] { rows.map { $0.frame.height } }
}

/// Settings root: header strip, section list, divider, scrolling page
/// — the SSHConfigWindow chassis with the manager's forms swapped for
/// settings rows. Every change writes the config and reloads
/// libghostty; the file stays hand-editable (reload() re-syncs).
