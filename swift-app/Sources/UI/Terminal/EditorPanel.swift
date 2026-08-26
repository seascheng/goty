// goty — see CLAUDE.md for the working principles.
import AppKit

// MARK: - Built-in editor (tty7 code panel: overlay, ⌘S, Esc back)

/// One open buffer. The FileSource is HELD (tty7 holds its SharedHost):
/// saves, reloads and duplicate detection key on the machine the file
/// lives on — a remote `/etc/hosts` and a local one are different files.
final class EditorOpenFile {
    let path: String
    let source: FileSource
    var text: String
    var dirty = false
    var conflict = false
    var wrap = false
    var preview = false
    /// mtime observed at load/save; the changed-on-disk verdict compares
    /// against it.
    var diskMtime: Date?

    init(path: String, source: FileSource, text: String, mtime: Date?) {
        self.path = path
        self.source = source
        self.text = text
        self.diskMtime = mtime
    }

    var label: String {
        (path as NSString).lastPathComponent
    }
}


/// The editor overlay: covers the terminal column (sidebar and the right
/// panel stay), Esc hides it back, files stay open across hides.
final class EditorPanelView: NSView {
    var onVisibilityChange: ((Bool) -> Void)?

    private(set) var files: [EditorOpenFile] = []
    private(set) var active = -1
    private(set) var visible = false
    private var saving = false

    // Local-file watchers (vnode events); remote files get none — same
    // trade tty7 documents: unwatched means save-time checks carry it.
    private var watchers: [String: DispatchSourceFileSystemObject] = [:]
    private var reloadDebounce: DispatchWorkItem?

    private let headerBackground = NSView()
    private let nameLabel = NSTextField(labelWithString: "No file open")
    private let dirtyDot = NSView(frame: NSRect(x: 0, y: 0, width: 6, height: 6))
    private let reloadButton = ClosureButton()
    private let keepButton = ClosureButton()
    private let scrollView = NSScrollView()
    /// Line-number gutter (tty7 Input line_number(true)): a sibling
    /// column that draws one number per LOGICAL line, synced to the
    /// clip view's scroll and the layout manager's fragment rects.
    private let gutter = EditorLineNumberGutter()
    private var gutterWidthConstraint: NSLayoutConstraint?
    private let textView: EditorTextView = {
        // TextKit1 by construction (own layoutManager+container): this
        // macOS build's TextKit2 estimation path crashes inside layout
        // passes on our attribute writes (_fixAttributesInRange /
        // NSCoreTypesetter lineMetrics → exception → _crashOnException).
        // The container needs a REAL size: bare NSTextContainer() is
        // {0,0} and lays out zero glyphs (the empty-editor regression).
        let storage = NSTextStorage()
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        let manager = NSLayoutManager()
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        return EditorTextView(frame: .zero, textContainer: container)
    }()
    private let statusBar = NSView()
    private let pathLabel = NSTextField(labelWithString: "")
    private let wrapButton = ClosureButton()
    private let cursorLabel = NSTextField(labelWithString: "")
    private let emptyLabel = NSTextField(labelWithString: "Open a file from the tree")
    private let saveButton = ClosureButton()
    private let previewButton = ClosureButton()
    private let previewScroll = NSScrollView()
    private let previewTextView: MarkdownPreviewTextView = {
        // Same TextKit1-by-construction as the editor body (see above).
        // The subclass paints the block decorations (full-width code
        // backgrounds, quote bars) the renderer marks as attributes.
        let storage = NSTextStorage()
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        let manager = NSLayoutManager()
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        return MarkdownPreviewTextView(frame: .zero, textContainer: container)
    }()
    /// Test surface: glyph counts prove content actually RENDERS — a
    /// degenerate text container produces a laid-out frame but zero
    /// glyphs (both regressions of 2026-08-22 were invisible to
    /// frame-only assertions).
    var renderedGlyphCount: Int { textView.layoutManager?.numberOfGlyphs ?? 0 }
    var previewGlyphCount: Int { previewTextView.layoutManager?.numberOfGlyphs ?? 0 }

    /// Test surfaces: chrome wiring the headless suite can assert.
    var gutterForTest: EditorLineNumberGutter { gutter }
    var findBarEnabledForTest: Bool {
        textView.usesFindBar && textView.isIncrementalSearchingEnabled
    }
    /// Wrap regression surface: set wrap + apply, and read the text
    /// container's live width (must track the clip view, not the old
    /// wrap-off max-line width).
    func setWrapForTest(_ on: Bool) {
        currentFile?.wrap = on
        applyWrap()
        renderChrome()
    }
    var textContainerWidthForTest: CGFloat { textView.textContainer?.size.width ?? 0 }
    var editorTextForTest: String { textView.string }
    func insertTabForTest() { textView.insertTab(nil) }

    /// Theme flip: re-bake the panel chrome and re-highlight the text
    /// (the foreground color rides the highlight attribute pass).
    /// ponytail: nameLabel/dirtyDot assume their init-time semantic
    /// colors — state-driven recolors win on their next state change.
    @objc private func themeChanged() {
        layer?.backgroundColor = Chrome.theme.background.cgColor
        headerBackground.layer?.backgroundColor = Chrome.theme.topBarBackground.cgColor
        nameLabel.textColor = Chrome.theme.secondaryText
        applyFont()
    }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = Chrome.theme.background.cgColor
        NotificationCenter.default.addObserver(
            self, selector: #selector(themeChanged),
            name: Chrome.themeDidChange, object: nil)

        // Header: filename, dirty dot, close (= back to terminal).
        headerBackground.wantsLayer = true
        headerBackground.layer?.backgroundColor = Chrome.theme.topBarBackground.cgColor
        headerBackground.translatesAutoresizingMaskIntoConstraints = false
        addSubview(headerBackground)

        nameLabel.font = .systemFont(ofSize: 12.5, weight: .medium)
        nameLabel.textColor = Chrome.theme.secondaryText
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.maximumNumberOfLines = 1
        nameLabel.cell?.truncatesLastVisibleLine = true
        nameLabel.cell?.wraps = false
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        nameLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        headerBackground.addSubview(nameLabel)

        dirtyDot.wantsLayer = true
        dirtyDot.layer?.backgroundColor = Chrome.theme.wsConnecting.cgColor
        dirtyDot.layer?.cornerRadius = 3
        dirtyDot.translatesAutoresizingMaskIntoConstraints = false
        headerBackground.addSubview(dirtyDot)

        let close = IconButton.make("xmark", pointSize: 12) { [weak self] in
            self?.hide()
        }
        close.toolTip = "Back to terminal (Esc)"
        headerBackground.addSubview(close)
        saveButton.applyStandardStyle(title: "Save")
        saveButton.onClick = { [weak self] in self?.save() }
        headerBackground.addSubview(saveButton)

        previewButton.applyStandardStyle(title: "Preview")
        previewButton.onClick = { [weak self] in self?.togglePreview() }
        previewButton.isHidden = true
        headerBackground.addSubview(previewButton)

        // Conflict verbs live in the STATUS BAR (built below): the
        // floating banner's constraint group could not coexist with
        // the editor's scroll view — the window layout collapsed.

        // Body.
        textView.font = .monospacedSystemFont(ofSize: CGFloat(AppPreferences.shared.editorFontSize),
                                             weight: .regular)
        textView.textColor = Chrome.theme.foreground
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.autoresizingMask = [.width]
        // Canonical scrollable-text-view recipe (see TextKit1 factory
        // above): without vertically-resizable + unbounded max + a
        // tall container the document view stays 0-height inside the
        // clip view and the editor renders nothing.
        textView.isVerticallyResizable = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize =
            NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.onZoom = { [weak self] delta, reset in self?.zoomFont(delta: delta, reset: reset) }
        textView.onEscape = { [weak self] in self?.hide() }
        textView.onSave = { [weak self] in self?.save() }
        // tty7 Input searchable/replaceable: the system find bar rides
        // the scroll view (⌘F / ⌘G / ⇧⌘G arrive via performKeyEquivalent).
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        // (This single addSubview, lost to a bisect round on
        // 2026-08-22, is the root cause of the whole editor saga:
        // without it the editor's constraint activation throws "no
        // common ancestor", which surfaced as every layout mystery
        // that followed.)
        addSubview(scrollView)

        gutter.translatesAutoresizingMaskIntoConstraints = false
        addSubview(gutter)
        gutter.attach(to: scrollView, textView: textView)
        gutter.onWidthChange = { [weak self] width in
            self?.gutterWidthConstraint?.constant = width
        }

        previewTextView.autoresizingMask = [.width]
        previewTextView.textContainerInset = NSSize(width: 8, height: 12)
        // Same recipe as the editor body — preview must grow vertically
        // inside its scroll view or it renders zero glyphs.
        previewTextView.isVerticallyResizable = true
        previewTextView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                         height: CGFloat.greatestFiniteMagnitude)
        previewTextView.textContainer?.containerSize =
            NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        previewTextView.font = .systemFont(ofSize: 12.5)
        previewTextView.textColor = Chrome.theme.foreground
        previewTextView.backgroundColor = .clear
        previewTextView.drawsBackground = false
        previewTextView.isEditable = false
        previewTextView.isSelectable = true
        previewTextView.isRichText = true
        previewTextView.textContainer?.widthTracksTextView = true
        previewScroll.documentView = previewTextView
        previewScroll.hasVerticalScroller = true
        previewScroll.drawsBackground = false
        previewScroll.translatesAutoresizingMaskIntoConstraints = false
        previewScroll.isHidden = true
        addSubview(previewScroll)

        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = Chrome.theme.secondaryText
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.isHidden = true
        addSubview(emptyLabel)

        // Status bar: path, wrap toggle, Ln/Col (tty7 26pt strip).
        statusBar.wantsLayer = true
        statusBar.layer?.backgroundColor = Chrome.theme.topBarBackground.cgColor
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(statusBar)

        pathLabel.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        pathLabel.textColor = Chrome.theme.secondaryText
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.maximumNumberOfLines = 1
        pathLabel.cell?.truncatesLastVisibleLine = true
        pathLabel.cell?.wraps = false
        // Truncation is only reachable if autolayout may shrink the
        // field: at the default 750 compression resistance the full
        // path is a near-required constraint — it raised the window's
        // minimum width the moment a file opened (the window-grows-
        // and-cannot-shrink report).
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pathLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        pathLabel.translatesAutoresizingMaskIntoConstraints = false
        statusBar.addSubview(pathLabel)

        wrapButton.applyStatusBarStyle(title: "Wrap: Off")
        wrapButton.onClick = { [weak self] in self?.toggleWrap() }
        statusBar.addSubview(wrapButton)

        cursorLabel.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        cursorLabel.textColor = Chrome.theme.secondaryText
        cursorLabel.translatesAutoresizingMaskIntoConstraints = false
        statusBar.addSubview(cursorLabel)

        reloadButton.applyStatusBarStyle(title: "Reload")
        reloadButton.onClick = { [weak self] in self?.reloadFromDisk() }
        reloadButton.isHidden = true
        statusBar.addSubview(reloadButton)

        keepButton.applyStatusBarStyle(title: "Keep Mine")
        keepButton.onClick = { [weak self] in
            guard let self, let f = self.currentFile else { return }
            f.conflict = false
            self.renderChrome()
        }
        keepButton.isHidden = true
        statusBar.addSubview(keepButton)
        // (Preview button lives in the top bar, next to Save.)
        NSLayoutConstraint.activate([
            headerBackground.topAnchor.constraint(equalTo: topAnchor),
            headerBackground.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerBackground.trailingAnchor.constraint(equalTo: trailingAnchor),
            headerBackground.heightAnchor.constraint(equalToConstant: 32),
            nameLabel.leadingAnchor.constraint(equalTo: headerBackground.leadingAnchor, constant: 12),
            nameLabel.centerYAnchor.constraint(equalTo: headerBackground.centerYAnchor),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: dirtyDot.leadingAnchor, constant: -6),
            dirtyDot.centerYAnchor.constraint(equalTo: headerBackground.centerYAnchor),
            dirtyDot.widthAnchor.constraint(equalToConstant: 6),
            dirtyDot.heightAnchor.constraint(equalToConstant: 6),
            dirtyDot.trailingAnchor.constraint(lessThanOrEqualTo: previewButton.leadingAnchor, constant: -8),
            previewButton.centerYAnchor.constraint(equalTo: headerBackground.centerYAnchor),
            previewButton.trailingAnchor.constraint(equalTo: saveButton.leadingAnchor, constant: -8),
            saveButton.centerYAnchor.constraint(equalTo: headerBackground.centerYAnchor),
            saveButton.trailingAnchor.constraint(equalTo: close.leadingAnchor, constant: -8),
            close.trailingAnchor.constraint(equalTo: headerBackground.trailingAnchor, constant: -6),
            close.centerYAnchor.constraint(equalTo: headerBackground.centerYAnchor),
            close.widthAnchor.constraint(equalToConstant: 26),
            close.heightAnchor.constraint(equalToConstant: 26),


            gutter.topAnchor.constraint(equalTo: headerBackground.bottomAnchor),
            gutter.leadingAnchor.constraint(equalTo: leadingAnchor),
            gutter.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            scrollView.topAnchor.constraint(equalTo: headerBackground.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: gutter.trailingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            previewScroll.topAnchor.constraint(equalTo: scrollView.topAnchor),
            previewScroll.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            previewScroll.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            previewScroll.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),

            statusBar.bottomAnchor.constraint(equalTo: bottomAnchor),
            statusBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: 26),
            pathLabel.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor, constant: 10),
            pathLabel.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
            pathLabel.trailingAnchor.constraint(lessThanOrEqualTo: reloadButton.leadingAnchor, constant: -8),
            reloadButton.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
            reloadButton.trailingAnchor.constraint(equalTo: keepButton.leadingAnchor, constant: -6),
            keepButton.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
            keepButton.trailingAnchor.constraint(equalTo: wrapButton.leadingAnchor, constant: -8),
            wrapButton.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
            wrapButton.trailingAnchor.constraint(equalTo: cursorLabel.leadingAnchor, constant: -8),
            cursorLabel.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
            cursorLabel.trailingAnchor.constraint(equalTo: statusBar.trailingAnchor, constant: -10),
            cursorLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 70),
        ])
        gutterWidthConstraint = gutter.widthAnchor.constraint(equalToConstant: gutter.requiredWidth)
        gutterWidthConstraint?.isActive = true
        renderChrome()
        updateCursorLabel()
    }

    required init?(coder: NSCoder) { fatalError("init(coder: not implemented") }


    private var currentFile: EditorOpenFile? {
        files.indices.contains(active) ? files[active] : nil
    }

    /// Mono size for the editor (⌘+ / ⌘- / ⌘0), persisted.
    private var fontSize: CGFloat = CGFloat(AppPreferences.shared.editorFontSize) {
        didSet { AppPreferences.shared.editorFontSize = Double(fontSize) }
    }

    private func applyFont() {
        textView.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        highlightAll()
        applyWrap()
        if currentFile?.preview == true { applyPreview() }
    }

    /// delta in points (0 = reset). Clamped 9…24.
    func zoomFont(delta: CGFloat, reset: Bool = false) {
        let base: CGFloat = reset ? 12.5 : fontSize
        let clamped = min(max(base + delta, 9), 24)
        if clamped != fontSize {
            fontSize = clamped
            applyFont()
        }
    }

    /// Full-file highlight (load / activate / font change). Attribute
    /// runs are APPLIED to the existing storage — content untouched, so
    /// selection and undo survive re-highlighting.
    private func highlightAll() {
        guard let f = currentFile,
              f.text.utf8.count <= HighlightEngine.maxBytes,
              let lang = HighlightEngine.language(forPath: f.path)
        else { plainAll(); return }
        let font = textView.font ?? .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        apply(HighlightEngine.highlight(textView.string, language: lang,
                                               font: font, color: Chrome.theme.foreground))
    }

    /// No engine / unknown language: one plain foreground+font pass.
    private func plainAll() {
        let font = textView.font ?? .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        apply(NSAttributedString(string: textView.string,
                                 attributes: [.font: font,
                                              .foregroundColor: Chrome.theme.foreground]))
    }

    /// Copy the highlight result's attribute runs onto the live storage
    /// (same content; only attributes move).
    private func apply(_ source: NSAttributedString) {
        guard let storage = textView.textStorage else { return }
        let full = NSRange(location: 0, length: (textView.string as NSString).length)
        guard source.length == full.length else { return }
        storage.beginEditing()
        storage.removeAttribute(.foregroundColor, range: full)
        storage.removeAttribute(.font, range: full)
        var cursor = 0
        while cursor < full.length {
            var runEnd = NSRange()
            let attrs = source.attributes(at: cursor, effectiveRange: &runEnd)
            storage.addAttributes(attrs, range: runEnd)
            cursor = runEnd.upperBound
        }
        storage.endEditing()
    }
    private func highlightEditedParagraph() {
        guard let f = currentFile,
              f.text.utf8.count <= HighlightEngine.maxBytes,
              let lang = HighlightEngine.language(forPath: f.path),
              let storage = textView.textStorage
        else { return }
        let ns = storage.string as NSString
        var pStart = 0, pEnd = 0
        ns.getLineStart(&pStart, end: &pEnd, contentsEnd: nil, for: textView.selectedRange)
        let paragraph = ns.substring(with: NSRange(location: pStart, length: pEnd - pStart))
        let font = textView.font ?? .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let result = HighlightEngine.highlight(paragraph, language: lang,
                                                      font: font, color: Chrome.theme.foreground)
        storage.beginEditing()
        storage.removeAttribute(.foregroundColor, range: NSRange(location: pStart, length: pEnd - pStart))
        storage.removeAttribute(.font, range: NSRange(location: pStart, length: pEnd - pStart))
        var cursor = 0
        while cursor < result.length {
            var runEnd = NSRange()
            let attrs = result.attributes(at: cursor, effectiveRange: &runEnd)
            storage.addAttributes(attrs,
                                  range: NSRange(location: pStart + runEnd.location, length: runEnd.length))
            cursor = runEnd.upperBound
        }
        storage.endEditing()
    }


    /// Open (or re-activate) a file: guards first — size, then binary
    /// sniff, then UTF-8. Everything off-main; errors land on main.
    func open(path: String, source: FileSource) {
        if let ix = files.firstIndex(where: { $0.path == path && $0.source.isRemote == source.isRemote && sameHost($0.source, source) }) {
            activate(ix)
            show()
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let st = try source.stat(path)
                guard st.size <= EditorFileGuards.maxBytes else {
                    self?.failOnMain(title: "File too large",
                                     detail: "\(path) is \(st.size) bytes; the editor stops at 4 MB. Use the terminal for this one.")
                    return
                }
                let data = try source.read(path)
                guard !EditorFileGuards.looksBinary(data) else {
                    self?.failOnMain(title: "Binary file",
                                     detail: "\(path) looks binary — the editor only opens text.")
                    return
                }
                guard let text = String(data: data, encoding: .utf8) else {
                    self?.failOnMain(title: "Not UTF-8",
                                     detail: "\(path) is not valid UTF-8 text.")
                    return
                }
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.files.append(EditorOpenFile(path: path, source: source,
                                                     text: text, mtime: st.modified))
                    self.activate(self.files.count - 1)
                    self.show()
                    self.rebuildWatchers()
                }
            } catch {
                self?.failOnMain(title: "Could not open file",
                                 detail: "\(path): \(error.localizedDescription)")
            }
        }
    }

    private func sameHost(_ a: FileSource, _ b: FileSource) -> Bool {
        if let ra = a as? RemoteFileSource, let rb = b as? RemoteFileSource {
            return ra.host == rb.host
        }
        return !a.isRemote && !b.isRemote
    }

    private func failOnMain(title: String, detail: String) {
        DispatchQueue.main.async {
            Dialog.error(title: title, detail: detail)
        }
    }

    /// Swap the active buffer into the text view, storing the previous
    /// one back first (one text view, many files — only one is visible).
    private func activate(_ ix: Int) {
        if files.indices.contains(active) {
            files[active].text = textView.string
        }
        active = ix
        let f = files[ix]
        textView.string = f.text
        gutter.invalidate()
        textView.selectedRange = NSRange(location: 0, length: 0)
        highlightAll()
        applyWrap()
        applyPreview()
        renderChrome()
        updateCursorLabel()
    }

    // MARK: - Visibility

    func show() {
        visible = true
        isHidden = false
        onVisibilityChange?(true)
        window?.makeFirstResponder(textView)
        refreshRemoteStat()
    }

    /// Esc / close: hide, keep every file open (tty7 keeps TabCode).
    func hide() {
        visible = false
        isHidden = true
        onVisibilityChange?(false)
    }

    func toggle() {
        visible ? hide() : show()
    }

    // MARK: - Save

    @objc func save() {
        guard let f = currentFile, !saving else { return }
        if files.indices.contains(active) {
            files[active].text = textView.string
        }
        saving = true
        let text = textView.string
        let data = Data(text.utf8)
        let source = f.source
        let path = f.path

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                // Remote files have no watcher: the save-time probe is
                // the only changed-on-disk check they get.
                if source.isRemote, let known = f.diskMtime {
                    let st = try source.stat(path)
                    if st.modified != known {
                        DispatchQueue.main.async {
                            self?.saving = false
                            f.conflict = true
                            self?.renderChrome()
                            Dialog.error(title: "File changed on disk",
                                         detail: "\(path) was modified since it was read. Reload it (losing your edits) or save again to overwrite.")
                        }
                        return
                    }
                }
                try source.write(data, to: path)
                let st = try source.stat(path)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.saving = false
                    if let ix = self.files.firstIndex(where: { $0 === f }) {
                        self.files[ix].text = text
                        self.files[ix].dirty = false
                        self.files[ix].conflict = false
                        self.files[ix].diskMtime = st.modified
                    }
                    self.renderChrome()
                }
            } catch {
                DispatchQueue.main.async {
                    self?.saving = false
                    Dialog.error(title: "Could not save",
                                 detail: "\(path): \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Reload / conflict

    private func reloadFromDisk() {
        guard let f = currentFile else { return }
        let source = f.source
        let path = f.path
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let data = try source.read(path)
                let st = try source.stat(path)
                DispatchQueue.main.async {
                    guard let self else { return }
                    f.text = String(data: data, encoding: .utf8) ?? f.text
                    f.dirty = false
                    f.conflict = false
                    f.diskMtime = st.modified
                    self.textView.string = f.text
                    self.gutter.invalidate()
                    self.highlightAll()
                    self.renderChrome()
                }
            } catch {
                self?.failOnMain(title: "Could not reload",
                                 detail: "\(path): \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Wrap

    private func toggleWrap() {
        guard let f = currentFile else { return }
        f.wrap.toggle()
        applyWrap()
        renderChrome()
    }

    // MARK: - Markdown preview (tty7: Preview/Edit in the status bar)

    private static func isMarkdown(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return ext == "md" || ext == "markdown"
    }

    func togglePreview() {
        guard let f = currentFile, Self.isMarkdown(f.path) else { return }
        f.preview.toggle()
        applyPreview()
        renderChrome()
    }

    /// Preview always renders the CURRENT text — edit a little, toggle,
    /// and the preview is fresh (tty7 reads the input live).
    private func applyPreview() {
        guard let f = currentFile else {
            previewScroll.isHidden = true
            return
        }
        if f.preview {
            previewTextView.textStorage?.setAttributedString(
                MarkdownRenderer.render(
                    textView.string,
                    bodySize: 14,   // tty7/gpui-component markdown default; not zoom-linked
                    highlight: { code, lang in
                        HighlightEngine.highlight(
                            code, language: lang ?? HighlightEngine.language(forPath: f.path),
                            font: .monospacedSystemFont(ofSize: self.fontSize - 1, weight: .regular),
                            color: Chrome.theme.foreground)
                    }))
        }
        previewScroll.isHidden = !f.preview
        scrollView.isHidden = f.preview
    }

    private func applyWrap() {
        guard let f = currentFile else { return }
        wrapButton.title = f.wrap ? "Wrap: On" : "Wrap: Off"
        if f.wrap {
            textView.isHorizontallyResizable = false
            textView.textContainer?.widthTracksTextView = true
            textView.autoresizingMask = [.width]
            // Re-fit the frame the wrap-OFF pass left at max-line-width:
            // autoresizing only fires when the CLIP changes size, which
            // never happens at toggle time — so without this reset the
            // text kept the huge width and never re-wrapped, and later
            // window resizes just nudged the wrong baseline (the
            // wrap-on-but-no-rewrap report).
            let width = scrollView.contentView.bounds.width
            if width > 0 {
                textView.frame.size.width = width
                textView.textContainer?.containerSize =
                    NSSize(width: width, height: .greatestFiniteMagnitude)
            }
            textView.needsLayout = true
        } else {
            // Wrap OFF: the container's width IS the content's width and
            // the clip view scrolls horizontally. Width autoresizing MUST
            // go — "follow the scroll view" and "equal the content" are
            // contradictory requirements, and the engine escalates that
            // conflict to a crash inside layout passes (the Preview-click
            // crash, root-caused 2026-08-22).
            textView.isHorizontallyResizable = true
            textView.textContainer?.widthTracksTextView = false
            textView.autoresizingMask = []
            let font = textView.font ?? .monospacedSystemFont(ofSize: 12.5, weight: .regular)
            var width: CGFloat = scrollView.bounds.width - 24
            for line in textView.string.split(separator: "\n", omittingEmptySubsequences: false) {
                let w = (line as NSString).size(withAttributes: [.font: font]).width
                if w > width { width = w }
            }
            textView.textContainer?.containerSize =
                NSSize(width: width, height: .greatestFiniteMagnitude)
            textView.needsLayout = true
        }
    }

    private func updateCursorLabel() {
        guard currentFile != nil else { return }
        let range = textView.selectedRange
        let ns = textView.string as NSString
        var lineStart = 0, lineEnd = 0
        ns.getLineStart(&lineStart, end: &lineEnd, contentsEnd: nil, for: range)
        // Line number via the gutter's cached line starts (binary
        // search, O(log n)) — the old newline scan walked the whole
        // document on every caret move.
        let line = gutter.lineIndex(forCharacterAt: lineStart) + 1
        cursorLabel.stringValue = "Ln \(line), Col \(range.location - lineStart + 1)"
    }

    // MARK: - External change watching (local files only)

    private func rebuildWatchers() {
        for (_, w) in watchers { w.cancel() }
        watchers.removeAll()
        guard files.contains(where: { !$0.source.isRemote }) else { return }
        for f in files where !f.source.isRemote {
            let fd = Darwin.open(f.path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let src = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd, eventMask: [.write, .delete, .rename],
                queue: .main)
            let path = f.path
            src.setEventHandler { [weak self] in
                self?.externalChange(path: path)
            }
            src.setCancelHandler { close(fd) }
            src.resume()
            watchers[f.path] = src
        }
    }

    /// tty7: 200 ms debounce, then classify per file.
    private func externalChange(path: String) {
        reloadDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self,
                  let ix = self.files.firstIndex(where: { $0.path == path && !$0.source.isRemote })
            else { return }
            let f = self.files[ix]
            let source = f.source
            DispatchQueue.global(qos: .utility).async {
                guard let st = try? source.stat(path) else { return }
                let verdict = EditorExternalChange.classify(
                    saving: self.saving, dirty: f.dirty,
                    diskMtime: f.diskMtime, observed: st.modified)
                DispatchQueue.main.async {
                    guard self.files.indices.contains(ix) else { return }
                    switch verdict {
                    case .ignore: break
                    case .conflict:
                        self.files[ix].conflict = true
                        self.renderChrome()
                    case .reload:
                        if ix == self.active {
                            f.text = (try? String(data: source.read(path), encoding: .utf8)) ?? f.text
                            f.diskMtime = st.modified
                            f.dirty = false
                            self.textView.string = f.text
                            self.gutter.invalidate()
                            self.highlightAll()
                            self.renderChrome()
                        } else {
                            f.diskMtime = st.modified
                        }
                    }
                }
            }
        }
        reloadDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    /// No watcher for remote files; a cheap stat on every show keeps the
    /// conflict banner honest while the panel is in use.
    private func refreshRemoteStat() {
        guard let f = currentFile, f.source.isRemote else { return }
        let source = f.source
        let path = f.path
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let st = try? source.stat(path) else { return }
            DispatchQueue.main.async {
                guard let self, let f = self.currentFile, f.path == path else { return }
                let verdict = EditorExternalChange.classify(
                    saving: self.saving, dirty: f.dirty,
                    diskMtime: f.diskMtime, observed: st.modified)
                if verdict == .conflict {
                    f.conflict = true
                    self.renderChrome()
                }
            }
        }
    }

    // MARK: - Chrome

    private func renderChrome() {
        guard let f = currentFile else {
            nameLabel.stringValue = "No file open"
            nameLabel.textColor = Chrome.theme.secondaryText
            dirtyDot.isHidden = true
            saveButton.isEnabled = false
            previewButton.isHidden = true
            pathLabel.stringValue = ""
            cursorLabel.stringValue = ""
            wrapButton.isHidden = true
            scrollView.isHidden = visible
            gutter.isHidden = visible
            previewScroll.isHidden = true
            return
        }
        nameLabel.stringValue = f.label
        nameLabel.textColor = Chrome.theme.foreground
        dirtyDot.isHidden = !f.dirty
        saveButton.isEnabled = f.dirty && !saving
        previewButton.isHidden = !Self.isMarkdown(f.path)
        previewButton.title = f.preview ? "Edit" : "Preview"
        reloadButton.isHidden = !f.conflict
        keepButton.isHidden = !f.conflict
        pathLabel.textColor = f.conflict
            ? Chrome.theme.wsConnecting : Chrome.theme.secondaryText
        let hostPrefix = f.source.isRemote
            ? ((f.source as? RemoteFileSource).map { "\($0.host):" } ?? "") : ""
        pathLabel.stringValue = hostPrefix + f.path
        wrapButton.isHidden = f.preview
        scrollView.isHidden = f.preview
        gutter.isHidden = f.preview
        wrapButton.title = f.wrap ? "Wrap: On" : "Wrap: Off"
    }

}

// MARK: - Text view (Esc → back, ⌘S → save)

extension EditorPanelView: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        gutter.invalidate()
        guard let f = currentFile else { return }
        if !f.dirty {
            f.dirty = true
            renderChrome()
        }
        highlightEditedParagraph()
    }
    func textViewDidChangeSelection(_ notification: Notification) {
        updateCursorLabel()
    }
}
