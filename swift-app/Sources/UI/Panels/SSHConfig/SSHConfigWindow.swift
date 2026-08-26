// goty — see CLAUDE.md for the working principles.
import AppKit

// MARK: - SSH config manager (standalone window, master-detail)

/// Simple ~/.ssh/config manager in its OWN window — nothing of it lives
/// in the main window. Left column: host list (+ to add). Right pane:
/// the selected host's form (Alias/HostName/User/Port, Delete, Save).
/// Saves write the file surgically (see SSHConfigDocument); the Servers
/// '+' picker picks changes up on its next open (mtime-keyed cache).
/// Non-modal by construction — no nested runloop anywhere, which is
/// also why this REPLACES the old "Custom host…" prompt that deadlocked
/// inside the '+' menu tracking session (2026-08-23 hang).
final class SSHConfigManagerView: NSView {
    override var isFlipped: Bool { true }

    private let store: SSHConfigStore
    private var document = SSHConfigDocument(text: "")

    private enum Selection {
        case stanza(Int)
        case newHost
    }
    private var selection: Selection?

    private let listColumn = NSView()
    private let listHeader = NSView()
    private let listContainer = SSHListContainer()
    private let listScroll = NSScrollView()
    private let editor = SSHHostEditor()
    private let hintLabel = NSTextField(
        labelWithString: "Edits write directly to ~/.ssh/config; the Servers ‘+’ menu lists every alias.")

    init(store: SSHConfigStore = SSHConfigStore()) {
        self.store = store
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = chromeSurface(Chrome.theme.background).cgColor

        // Top strip (40pt): window title + config path — the traffic
        // lights' band (transparent titlebar, main-window chrome).
        let headerStrip = NSView()
        headerStrip.wantsLayer = true
        headerStrip.layer?.backgroundColor = chromeSurface(Chrome.theme.topBarBackground).cgColor
        headerStrip.translatesAutoresizingMaskIntoConstraints = false
        addSubview(headerStrip)

        let windowTitle = NSTextField(labelWithString: "SSH HOSTS")
        windowTitle.attributedStringValue = NSAttributedString(
            string: "SSH HOSTS",
            attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                         .foregroundColor: Chrome.theme.foreground,
                         .kern: 0.8])
        windowTitle.translatesAutoresizingMaskIntoConstraints = false
        headerStrip.addSubview(windowTitle)
        let home = NSHomeDirectory()
        let rawPath = store.url.path
        let pathLabel = NSTextField(labelWithString: "")
        pathLabel.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        pathLabel.textColor = Chrome.theme.secondaryText
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.maximumNumberOfLines = 1
        pathLabel.cell?.wraps = false
        pathLabel.setContentCompressionResistancePriority(.init(200), for: .horizontal)
        pathLabel.stringValue = rawPath.hasPrefix(home)
            ? "~" + rawPath.dropFirst(home.count) : rawPath
        pathLabel.translatesAutoresizingMaskIntoConstraints = false
        headerStrip.addSubview(pathLabel)

        // Left column: section-style header (HOSTS + count + compact
        // '+', the sidebar sectionHeader geometry), scrolling list.
        listColumn.translatesAutoresizingMaskIntoConstraints = false
        addSubview(listColumn)

        listHeader.translatesAutoresizingMaskIntoConstraints = false
        listColumn.addSubview(listHeader)
        let hostsTitle = NSTextField(labelWithString: "HOSTS")
        hostsTitle.attributedStringValue = NSAttributedString(
            string: "HOSTS",
            attributes: [.font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                         .foregroundColor: Chrome.theme.secondaryText,
                         .kern: 1.1])
        hostsTitle.translatesAutoresizingMaskIntoConstraints = false
        listHeader.addSubview(hostsTitle)
        let add = IconButton.make("plus", pointSize: 11) { [weak self] in
            self?.beginAdd()
        }
        listHeader.addSubview(add)


        listScroll.documentView = listContainer
        listContainer.autoresizingMask = [.width]
        listScroll.hasVerticalScroller = true
        listScroll.autohidesScrollers = true
        listScroll.drawsBackground = false
        listScroll.translatesAutoresizingMaskIntoConstraints = false
        listColumn.addSubview(listScroll)

        // Divider between the columns.
        let divider = HairlineView()
        divider.translatesAutoresizingMaskIntoConstraints = false
        addSubview(divider)

        // Right column: the editor pane.
        editor.translatesAutoresizingMaskIntoConstraints = false
        addSubview(editor)
        editor.onCommit = { [weak self] fields in self?.commit(fields) }
        editor.onCancel = { [weak self] in self?.cancelEdit() }
        editor.onDelete = { [weak self] in self?.deleteSelected() }

        // Status bar across the bottom (tty7 26pt strip).
        let statusBar = NSView()
        statusBar.wantsLayer = true
        statusBar.layer?.backgroundColor = chromeSurface(Chrome.theme.topBarBackground).cgColor
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(statusBar)
        hintLabel.font = .systemFont(ofSize: 10.5)
        hintLabel.textColor = Chrome.theme.secondaryText
        hintLabel.cell?.wraps = false
        hintLabel.setContentCompressionResistancePriority(.init(200), for: .horizontal)
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        statusBar.addSubview(hintLabel)

        NSLayoutConstraint.activate([
            headerStrip.topAnchor.constraint(equalTo: topAnchor),
            headerStrip.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerStrip.trailingAnchor.constraint(equalTo: trailingAnchor),
            headerStrip.heightAnchor.constraint(equalToConstant: 40),
            // 84 clears the traffic-light capsules (they own the
            // top-left ~70pt — sidebar DragStrip's rule).
            windowTitle.leadingAnchor.constraint(equalTo: headerStrip.leadingAnchor, constant: 84),
            windowTitle.centerYAnchor.constraint(equalTo: headerStrip.centerYAnchor),
            windowTitle.trailingAnchor.constraint(lessThanOrEqualTo: pathLabel.leadingAnchor, constant: -8),
            pathLabel.trailingAnchor.constraint(equalTo: headerStrip.trailingAnchor, constant: -14),
            pathLabel.centerYAnchor.constraint(equalTo: headerStrip.centerYAnchor),

            listColumn.leadingAnchor.constraint(equalTo: leadingAnchor),
            listColumn.topAnchor.constraint(equalTo: headerStrip.bottomAnchor),
            listColumn.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            listColumn.widthAnchor.constraint(equalToConstant: 250),
            listHeader.topAnchor.constraint(equalTo: listColumn.topAnchor),
            listHeader.leadingAnchor.constraint(equalTo: listColumn.leadingAnchor),
            listHeader.trailingAnchor.constraint(equalTo: listColumn.trailingAnchor),
            listHeader.heightAnchor.constraint(equalToConstant: 20),
            hostsTitle.leadingAnchor.constraint(equalTo: listHeader.leadingAnchor, constant: 12),
            hostsTitle.centerYAnchor.constraint(equalTo: listHeader.centerYAnchor),
            hostsTitle.trailingAnchor.constraint(lessThanOrEqualTo: add.leadingAnchor, constant: -6),
            add.trailingAnchor.constraint(equalTo: listHeader.trailingAnchor),
            add.centerYAnchor.constraint(equalTo: listHeader.centerYAnchor),
            add.widthAnchor.constraint(equalToConstant: 20),
            add.heightAnchor.constraint(equalToConstant: 18),
            listScroll.topAnchor.constraint(equalTo: listHeader.bottomAnchor),
            listScroll.leadingAnchor.constraint(equalTo: listColumn.leadingAnchor),
            listScroll.trailingAnchor.constraint(equalTo: listColumn.trailingAnchor),
            listScroll.bottomAnchor.constraint(equalTo: listColumn.bottomAnchor),

            divider.leadingAnchor.constraint(equalTo: listColumn.trailingAnchor),
            divider.topAnchor.constraint(equalTo: headerStrip.bottomAnchor),
            divider.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),

            editor.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            editor.topAnchor.constraint(equalTo: headerStrip.bottomAnchor),
            editor.trailingAnchor.constraint(equalTo: trailingAnchor),
            editor.bottomAnchor.constraint(equalTo: statusBar.topAnchor),

            statusBar.bottomAnchor.constraint(equalTo: bottomAnchor),
            statusBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: 26),
            hintLabel.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor, constant: 10),
            hintLabel.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
        ])


        reload()
    }

    required init?(coder: NSCoder) { fatalError("init(coder: not implemented") }

    // MARK: Data

    /// Fresh load: external editors (vim, ssh tools) are the norm for
    /// this file; stale in-memory state overwriting one is exactly the
    /// class of loss this manager must not cause.
    func reload() {
        document = store.load()
        if case .stanza(let i) = selection, i >= document.stanzas.count {
            selection = nil
        }
        editor.load(fields: editorFields(), existing: editorShowsDelete())
        rebuildList()
    }

    private func editorFields() -> SSHHostEditor.Fields? {
        switch selection {
        case .newHost:
            return SSHHostEditor.Fields()
        case .stanza(let i):
            guard document.stanzas.indices.contains(i) else { return nil }
            let s = document.stanzas[i]
            return SSHHostEditor.Fields(
                alias: s.aliases.joined(separator: " "),
                hostName: s.hostName ?? "",
                user: s.user ?? "",
                port: s.port ?? "")
        case nil:
            return nil
        }
    }

    private func editorShowsDelete() -> Bool {
        if case .stanza = selection { return true }
        return false
    }

    // MARK: Actions

    private func selectHost(_ index: Int) {
        selection = .stanza(index)
        editor.load(fields: editorFields(), existing: true)
        rebuildList()
    }

    private func beginAdd() {
        selection = .newHost
        editor.load(fields: SSHHostEditor.Fields(), existing: false)
        rebuildList()
    }

    /// Cancel is DISMISS, always visible: drop the selection (form →
    /// placeholder, list unhighlights). A revert-only cancel reads as
    /// a dead button when nothing was typed — with no dirty tracking
    /// the honest semantic is leave-editing (2026-08-24 report). Esc
    /// rides the same path.
    private func cancelEdit() {
        selection = nil
        editor.load(fields: nil, existing: false)
        rebuildList()
    }

    private func commit(_ fields: SSHHostEditor.Fields) {
        let aliases = fields.alias.split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map(String.init)
        var next = document
        do {
            switch selection {
            case .newHost:
                try next.addHost(aliases: aliases, hostName: nonEmpty(fields.hostName),
                                 user: nonEmpty(fields.user), port: nonEmpty(fields.port))
            case .stanza(let i):
                try next.updateHost(i, aliases: aliases, hostName: nonEmpty(fields.hostName),
                                    user: nonEmpty(fields.user), port: nonEmpty(fields.port))
            case nil:
                return
            }
            try store.save(next)
        } catch let error as SSHConfigDocument.EditError {
            Dialog.error(title: "Invalid host", detail: error.description)
            return
        } catch {
            Dialog.error(title: "Could not save ~/.ssh/config",
                         detail: error.localizedDescription)
            return
        }
        document = next
        if case .newHost = selection {
            selection = .stanza(document.stanzas.count - 1)
        }
        editor.load(fields: editorFields(), existing: true)
        rebuildList()
    }

    /// The editor's Delete button confirms first; tests call this
    /// directly.
    private func deleteSelected() {
        guard case .stanza(let i) = selection,
              document.stanzas.indices.contains(i) else { return }
        var next = document
        next.removeHost(i)
        do {
            try store.save(next)
        } catch {
            Dialog.error(title: "Could not save ~/.ssh/config",
                         detail: error.localizedDescription)
            return
        }
        document = next
        selection = nil
        editor.load(fields: nil, existing: false)
        rebuildList()
    }

    private func nonEmpty(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : t
    }

    // MARK: List

    private static let rowHeight: CGFloat = 40

    private func rebuildList() {
        listContainer.subviews.forEach { $0.removeFromSuperview() }
        let stanzas = document.stanzas
        for (i, stanza) in stanzas.enumerated() {
            let row = SSHHostRow(stanza: stanza)
            row.onClick = { [weak self] in self?.selectHost(i) }
            var selected = false
            if case .stanza(i) = selection { selected = true }
            row.setSelected(selected)
            listContainer.addSubview(row)
            row.frame = NSRect(x: 0, y: CGFloat(i) * Self.rowHeight,
                               width: listContainer.bounds.width, height: Self.rowHeight)
        }
        listContainer.setFrameSize(NSSize(width: listContainer.bounds.width,
                                          height: max(CGFloat(stanzas.count) * Self.rowHeight,
                                                      listScroll.bounds.height)))
    }
    /// Esc while not in a field: cancel the edit, else close the window.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 53 {
            if selection != nil {
                cancelEdit()
            } else {
                window?.performClose(nil)
            }
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    var hasSelectionForTest: Bool { selection != nil }
    var documentForTest: SSHConfigDocument { document }
    var hostRowCountForTest: Int {
        listContainer.subviews.filter { $0 is SSHHostRow }.count
    }
    var editorForTest: SSHHostEditor { editor }
    func reloadForTest() { reload() }
    func beginAddForTest() { beginAdd() }
    func selectForTest(_ index: Int) { selectHost(index) }
    var listColumnFrameForTest: CGRect { listColumn.frame }
    var editorFrameForTest: CGRect { editor.frame }
    func cancelEditingForTest() { cancelEdit() }
    func deleteSelectedForTest() { deleteSelected() }
}

/// Owns the manager's window. Non-modal: an independent floating window
/// with the app's unified chrome (transparent titlebar, hidden title —
/// the 40pt strip in the content carries the traffic lights).
final class SSHConfigWindowController: NSObject {
    let window: NSWindow
    private let store: SSHConfigStore
    private var manager: SSHConfigManagerView

    init(store: SSHConfigStore = SSHConfigStore()) {
        self.store = store
        let manager = SSHConfigManagerView(store: store)
        self.manager = manager
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable,
                        .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "SSH Hosts"
        window.contentView = manager
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden   // the header strip's own title is the one title
        // Same rule as the main window (AppWindowController): the
        // system appearance follows the ghostty theme — every native
        // text behavior (selection fills, inactive selection, focus
        // borders) renders from the EFFECTIVE appearance, and a Light
        // system appearance under dark chrome is the entire
        // white/gray selection artifact class.
        window.appearance = NSAppearance(
            named: Chrome.theme.isDark ? .darkAqua : .aqua)
        window.contentMinSize = NSSize(width: 560, height: 400)
        // Persistent window held by its controller: close must NOT
        // release it (the '+' menu reopens this same instance).
        window.isReleasedWhenClosed = false
        self.window = window
        super.init()
        // Theme flips rebuild the whole manager (its colors are baked
        // into build-time locals — the strips/labels can't be surgically
        // recolored). Unsaved editor text is lost.
        // ponytail: surgical recolor if mid-edit theme flips ever bite.
        NotificationCenter.default.addObserver(
            self, selector: #selector(themeChanged),
            name: Chrome.themeDidChange, object: nil)
    }

    @objc private func themeChanged() {
        window.appearance = NSAppearance(
            named: Chrome.theme.isDark ? .darkAqua : .aqua)
        let fresh = SSHConfigManagerView(store: store)
        window.contentView = fresh
        manager = fresh
    }

    /// Re-reads the file (see reload()) and brings the window front,
    /// centered over the app's main window when one is given.
    func show(over parent: NSWindow?) {
        manager.reload()
        if let parent, parent.frame.width > 0 {
            let f = parent.frame
            let size = window.frame.size
            window.setFrameOrigin(NSPoint(x: f.midX - size.width / 2,
                                          y: f.midY - size.height / 2))
        } else {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
    }
}

/// Flipped row host with manual frames (the Files list geometry — rows
/// are only ever rebuilt by USER acts here, so plain relayout suffices).
final class SSHListContainer: NSView {
    override var isFlipped: Bool { true }
    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        var y: CGFloat = 0
        for row in subviews {
            row.frame = NSRect(x: 0, y: y, width: bounds.width, height: row.frame.height)
            y += row.frame.height
        }
    }
}
