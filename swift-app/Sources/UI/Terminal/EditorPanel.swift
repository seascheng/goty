// goty — see CLAUDE.md for the working principles.
import AppKit
import WebKit

// MARK: - Built-in editor (tty7 code panel: overlay, ⌘S, Esc back)

/// One git patch shown as a document: repo root, machine, and which
/// side of the index — `Worktree`/`Staged` in tty7's DiffSource terms.
struct EditorDiffRef: Equatable {
    let root: String
    let host: String?
    let staged: Bool
}

/// One open buffer. The FileSource is HELD (tty7 holds its SharedHost):
/// saves, reloads and duplicate detection key on the machine the file
/// lives on — a remote `/etc/hosts` and a local one are different files.
/// A document with `diff` set is a git patch (path is repo-relative,
/// text holds the unified diff); everything write-related is disabled.
final class EditorOpenFile {
    let path: String
    let source: FileSource
    var text: String
    var dirty = false
    var conflict = false
    var wrap = false
    var preview = false
    /// mtime observed at load/save; the changed-on-disk verdict compares
    /// against it. (nil = diff document.)
    var diskMtime: Date?
    var diff: EditorDiffRef?

    init(path: String, source: FileSource, text: String, mtime: Date?,
         diff: EditorDiffRef? = nil) {
        self.path = path
        self.source = source
        self.text = text
        self.diskMtime = mtime
        self.diff = diff
    }

    var isDiff: Bool { diff != nil }
    var label: String {
        (path as NSString).lastPathComponent
    }
}

/// The editor overlay: covers the terminal column (sidebar and the right
/// panel stay), Esc hides it back, files stay open across hides. The
/// body is the files-web WKWebView (CodeMirror editing, markdown
/// preview, split/unified git diff) — same Tauri model as the agent
/// pane; Swift keeps the chrome and the FileSource/git side.
final class EditorPanelView: NSView, ThemeRefreshable {
    var onVisibilityChange: ((Bool) -> Void)?

    private(set) var files: [EditorOpenFile] = []
    private(set) var active = -1
    private(set) var visible = false
    private var saving = false
    /// Split/unified for diff documents — one preference, panel-wide.
    private var diffSplit = true

    // Local-file watchers (vnode events); remote files get none — same
    // trade tty7 documents: unwatched means save-time checks carry it.
    private var watchers: [String: DispatchSourceFileSystemObject] = [:]
    private var reloadDebounce: DispatchWorkItem?

    // Web body (files-web): goty:// assets, structured bridge, themed
    // cover until first paint — the AgentPaneHost recipe.
    private let webView: WKWebView
    private let bridge: EditorWebBridge
    private let coverView = NSView()
    /// Doc ids the page has materialized; re-activations load from the
    /// page-side cache (the page's text is newer than the model's).
    private var pushedDocs: Set<Int> = []
    /// True while the panel is swapping the page's document — the dirty
    /// ping that follows a programmatic text swap is not an edit.
    private var loadingIntoPage = false

    private let headerBackground = NSView()
    private let nameLabel = NSTextField(labelWithString: "No file open")
    private let dirtyDot = NSView(frame: NSRect(x: 0, y: 0, width: 6, height: 6))
    private let reloadButton = ChromeButton(title: "Reload", style: .ghost, compact: true)
    private let keepButton = ChromeButton(title: "Keep Mine", style: .ghost, compact: true)
    private let statusBar = NSView()
    private let pathLabel = NSTextField(labelWithString: "")
    private let wrapButton = ChromeButton(title: "Wrap: Off", style: .ghost, compact: true)
    private let splitButton = ChromeButton(title: "Split", style: .ghost, compact: true)
    private let cursorLabel = NSTextField(labelWithString: "")
    private let emptyLabel = NSTextField(labelWithString: "Open a file from the tree")
    private let saveButton = ChromeButton(title: "Save", style: .primary)
    private let previewButton = ChromeButton(title: "Preview", style: .ghost)

    /// Test surfaces: chrome wiring the headless suite can assert.
    var findBarEnabledForTest: Bool { true }   // search lives in the page (Mod-F)
    var editorTextForTest: String { currentFile?.text ?? "" }
    var diffSplitForTest: Bool { diffSplit }
    /// True once the page posted `ready` — the headless suite pumps
    /// the runloop until the web app is actually loadable.
    private(set) var pageReadyForTest = false
    var webViewForTest: WKWebView { webView }
    var bridgeDeliveredForTest: Int { bridge.delivered }

    /// Theme flip: re-bake the panel chrome and push the fresh palette
    /// into the page.
    func retheme() {
        layer?.backgroundColor = chromeSurface(Chrome.theme.background).cgColor
        headerBackground.layer?.backgroundColor = chromeContainerFill(Chrome.theme.topBarBackground)?.cgColor
        statusBar.layer?.backgroundColor = chromeContainerFill(Chrome.theme.topBarBackground)?.cgColor
        nameLabel.textColor = currentFile == nil
            ? Chrome.theme.secondaryText : Chrome.theme.foreground
        coverView.layer?.backgroundColor = chromeSurface(Chrome.theme.background).cgColor
        AgentTheme.push(to: bridge)
    }

    override init(frame frameRect: NSRect) {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(
            AgentSchemeHandler(root: Self.webAppDirectory()),
            forURLScheme: "goty")
        config.websiteDataStore = WKWebsiteDataStore.nonPersistent()
        webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .clear
        bridge = EditorWebBridge(webView: webView)

        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = chromeSurface(Chrome.theme.background).cgColor

        // Header: filename, dirty dot, close (= back to terminal).
        headerBackground.wantsLayer = true
        headerBackground.layer?.backgroundColor = chromeContainerFill(Chrome.theme.topBarBackground)?.cgColor
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
        saveButton.onClick = { [weak self] in self?.save() }
        headerBackground.addSubview(saveButton)

        previewButton.onClick = { [weak self] in self?.togglePreview() }
        previewButton.isHidden = true
        headerBackground.addSubview(previewButton)

        // Body: the webview between header and status bar, with the
        // themed cover above it until the page paints (WKWebView's own
        // compositing layer is black before first render).
        webView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(webView)

        coverView.wantsLayer = true
        coverView.layer?.backgroundColor = chromeSurface(Chrome.theme.background).cgColor
        coverView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(coverView)

        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = Chrome.theme.secondaryText
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.isHidden = true
        addSubview(emptyLabel)

        // Status bar: path, wrap toggle, Ln/Col (tty7 26pt strip).
        statusBar.wantsLayer = true
        statusBar.layer?.backgroundColor = chromeContainerFill(Chrome.theme.topBarBackground)?.cgColor
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(statusBar)

        pathLabel.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        pathLabel.textColor = Chrome.theme.secondaryText
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.maximumNumberOfLines = 1
        pathLabel.cell?.truncatesLastVisibleLine = true
        pathLabel.cell?.wraps = false
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pathLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        pathLabel.translatesAutoresizingMaskIntoConstraints = false
        statusBar.addSubview(pathLabel)

        wrapButton.onClick = { [weak self] in self?.toggleWrap() }
        statusBar.addSubview(wrapButton)

        splitButton.onClick = { [weak self] in self?.toggleDiffView() }
        splitButton.isHidden = true
        statusBar.addSubview(splitButton)

        cursorLabel.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        cursorLabel.textColor = Chrome.theme.secondaryText
        cursorLabel.translatesAutoresizingMaskIntoConstraints = false
        statusBar.addSubview(cursorLabel)
        reloadButton.onClick = { [weak self] in self?.reloadFromDisk() }
        reloadButton.isHidden = true
        statusBar.addSubview(reloadButton)

        keepButton.onClick = { [weak self] in
            guard let self, let f = self.currentFile else { return }
            f.conflict = false
            self.renderChrome()
        }
        keepButton.isHidden = true
        statusBar.addSubview(keepButton)

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

            webView.topAnchor.constraint(equalTo: headerBackground.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            coverView.topAnchor.constraint(equalTo: webView.topAnchor),
            coverView.leadingAnchor.constraint(equalTo: webView.leadingAnchor),
            coverView.trailingAnchor.constraint(equalTo: webView.trailingAnchor),
            coverView.bottomAnchor.constraint(equalTo: webView.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: webView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: webView.centerYAnchor),

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
            wrapButton.trailingAnchor.constraint(equalTo: splitButton.leadingAnchor, constant: -8),
            splitButton.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
            splitButton.trailingAnchor.constraint(equalTo: cursorLabel.leadingAnchor, constant: -8),
            cursorLabel.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
            cursorLabel.trailingAnchor.constraint(equalTo: statusBar.trailingAnchor, constant: -10),
            cursorLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 70),
        ])

        wireBridge()
        webView.load(URLRequest(url: URL(string: "goty://app/index.html")!))
        renderChrome()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    static func webAppDirectory() -> URL {
        if let bundled = Bundle.main.url(forResource: "index", withExtension: "html",
                                         subdirectory: "files-web") {
            return bundled.deletingLastPathComponent()
        }
        // #filePath is relative when run-tests compiles from swift-app/ —
        // complete it with the process cwd (filestest's rule), or the
        // deletions below fall through "" into "/".
        var sourcePath = #filePath
        if !sourcePath.hasPrefix("/") {
            sourcePath = FileManager.default.currentDirectoryPath + "/" + sourcePath
        }
        let repo = URL(fileURLWithPath: sourcePath) // Sources/UI/Terminal/EditorPanel.swift
            .deletingLastPathComponent().deletingLastPathComponent() // UI/Terminal
            .deletingLastPathComponent() // Sources
            .deletingLastPathComponent() // swift-app
        return repo.appendingPathComponent("files-web/dist")
    }

    // MARK: - Bridge wiring

    private func wireBridge() {
        bridge.onReady = { [weak self] in
            guard let self else { return }
            self.pageReadyForTest = true
            AgentTheme.push(to: self.bridge)
            if self.files.indices.contains(self.active) {
                self.pushDocument(self.active, forceText: true)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                self.coverView.removeFromSuperview()
            }
        }
        bridge.onSave = { [weak self] in self?.save() }
        bridge.onEscape = { [weak self] in self?.hide() }
        bridge.onDirty = { [weak self] value in
            guard let self, let f = self.currentFile, !f.isDiff,
                  !self.loadingIntoPage else { return }
            if f.dirty != value {
                f.dirty = value
                self.renderChrome()
            }
        }
        bridge.onCursor = { [weak self] line, col in
            self?.cursorLabel.stringValue = "Ln \(line), Col \(col)"
        }
        bridge.onZoom = { [weak self] delta, reset in
            self?.zoomFont(delta: delta, reset: reset)
        }
        bridge.onLink = { url in
            guard let url = URL(string: url), let scheme = url.scheme,
                  ["http", "https", "file"].contains(scheme.lowercased())
            else { return }
            NSWorkspace.shared.open(url)
        }
    }

    private var currentFile: EditorOpenFile? {
        files.indices.contains(active) ? files[active] : nil
    }

    /// Mono size for the editor (⌘+ / ⌘- / ⌘0), persisted.
    private var fontSize: Double = AppPreferences.shared.editorFontSize {
        didSet { AppPreferences.shared.editorFontSize = fontSize }
    }
    /// CSS px for the page (pt × 96/72).
    private var fontSizePx: Int { Int((fontSize * 96.0 / 72.0).rounded()) }

    private func applyFontSize() {
        pushState()
    }

    /// delta in steps (0 = reset). Clamped 9…24 pt.
    func zoomFont(delta: Int, reset: Bool = false) {
        let base: Double = reset ? 12.5 : fontSize
        let clamped = min(max(base + Double(delta), 9), 24)
        if clamped != fontSize {
            fontSize = clamped
            applyFontSize()
        }
    }

    // MARK: - Document pushes

    /// Push the active document into the page. `forceText` sends the
    /// model's text (initial load, reload, diff refresh); otherwise a
    /// doc the page already holds re-activates from the page cache,
    /// which is never older than the model.
    private func pushDocument(_ ix: Int, forceText: Bool) {
        guard files.indices.contains(ix) else { return }
        let f = files[ix]
        loadingIntoPage = true
        let knownDoc = pushedDocs.contains(ix)
        let sendText = forceText || !knownDoc
        var event: [String: Any] = [
            "type": "load",
            "docId": ix,
            "path": f.path,
            "mode": f.isDiff ? "diff" : (f.preview ? "preview" : "edit"),
            "isMarkdown": Self.isMarkdown(f.path),
            "wrap": f.wrap,
            "fontSize": fontSizePx,
        ]
        if !sendText {
            bridge.push(event)
            pushedDocs.insert(ix)
            loadingIntoPage = false
            return
        }
        if f.text.utf8.count <= Self.inlineTextBytes {
            event["text"] = f.text
            bridge.push(event)
        } else {
            event["text"] = NSNull()
            bridge.push(event)
            let bytes = Array(f.text.utf8)
            var start = 0
            while start < bytes.count {
                let end = min(start + Self.chunkBytes, bytes.count)
                bridge.push(["type": "chunk", "docId": ix,
                             "text": String(decoding: bytes[start..<end], as: UTF8.self)])
                start = end
            }
            bridge.push(["type": "endChunk", "docId": ix])
        }
        pushedDocs.insert(ix)
        loadingIntoPage = false
    }

    /// One 4 MB file must not ride a single IPC call — the transport
    /// halves event COUNT, not bytes. Text is valid UTF-8 by the open
    /// guards, so byte-boundary chunks decode cleanly.
    private static let inlineTextBytes = 256 * 1024
    private static let chunkBytes = 128 * 1024

    /// Chrome-driven state flips (wrap, font size, mode, diff view).
    private func pushState() {
        guard let f = currentFile else { return }
        var event: [String: Any] = [
            "type": "state",
            "wrap": f.wrap,
            "fontSize": fontSizePx,
            "diffView": diffSplit ? "split" : "unified",
        ]
        if f.isDiff {
            event["mode"] = "diff"
        } else {
            event["mode"] = f.preview ? "preview" : "edit"
        }
        bridge.push(event)
    }

    private static func isMarkdown(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return ext == "md" || ext == "markdown"
    }

    // MARK: - Open / activate

    /// Open (or re-activate) a file: guards first — size, then binary
    /// sniff, then UTF-8. Everything off-main; errors land on main.
    func open(path: String, source: FileSource) {
        if let ix = files.firstIndex(where: {
            $0.path == path && $0.diff == nil
                && $0.source.isRemote == source.isRemote && sameHost($0.source, source)
        }) {
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

    /// Open (or re-activate) a git change document. `path` is
    /// repo-root-relative; untracked files diff against /dev/null.
    func openDiff(root: String, host: String?, path: String, staged: Bool,
                  untracked: Bool, source: FileSource) {
        let displayPath = root + "/" + path
        if let ix = files.firstIndex(where: {
            $0.diff == EditorDiffRef(root: root, host: host, staged: staged)
                && $0.path == displayPath
        }) {
            activate(ix)
            refreshDiff(ix)
            show()
            return
        }
        fetchPatch(root: root, host: host, path: path, staged: staged,
                   untracked: untracked) { [weak self] patch in
            guard let self else { return }
            let file = EditorOpenFile(path: displayPath, source: source,
                                      text: patch ?? "", mtime: nil,
                                      diff: EditorDiffRef(root: root, host: host, staged: staged))
            self.files.append(file)
            self.activate(self.files.count - 1)
            self.show()
            if patch == nil {
                self.failOnMain(title: "No diff",
                                detail: "\(path): git produced no patch for this change.")
            }
        }
    }

    /// Re-fetch every open diff document (git landed new activity).
    func refreshDiffs() {
        for ix in files.indices where files[ix].isDiff {
            refreshDiff(ix)
        }
    }

    private func refreshDiff(_ ix: Int) {
        guard files.indices.contains(ix), let d = files[ix].diff else { return }
        fetchPatch(root: d.root, host: d.host,
                   path: relativeDiffPath(files[ix].path, root: d.root),
                   staged: d.staged, untracked: false) { [weak self] patch in
            guard let self, let patch,
                  self.files.indices.contains(ix), self.files[ix].text != patch
            else { return }
            self.files[ix].text = patch
            if ix == self.active {
                self.pushDocument(ix, forceText: true)
            }
        }
    }

    /// `path` was stored display-absolute; git wants it repo-relative.
    private func relativeDiffPath(_ display: String, root: String) -> String {
        guard display.hasPrefix(root + "/") else { return display }
        return String(display.dropFirst(root.count + 1))
    }

    private func fetchPatch(root: String, host: String?, path: String, staged: Bool,
                            untracked: Bool,
                            completion: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let patch = ScmStore.shared.diff(root: root, host: host, path: path,
                                             staged: staged, untracked: untracked)
            DispatchQueue.main.async {
                completion(patch)
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

    /// Swap the active buffer into the page.
    private func activate(_ ix: Int) {
        active = ix
        pushDocument(ix, forceText: false)
        renderChrome()
        cursorLabel.stringValue = ""
    }

    // MARK: - Visibility

    func show() {
        visible = true
        isHidden = false
        onVisibilityChange?(true)
        window?.makeFirstResponder(webView)
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
        guard let f = currentFile, !f.isDiff, !saving else { return }
        saving = true
        renderChrome()
        // Mark the pull boundary first: edits that land after this
        // point are not in the write, and the page's savedAck logic
        // keeps them reported as dirty. Then pull the live text
        // through the structured channel (postMessage with megabyte
        // strings is the lossy path the agent pane already buried).
        bridge.push(["type": "pulling"])
        webView.callAsyncJavaScript(
            "return window.__goty.getText();",
            arguments: [:], in: nil, in: WKContentWorld.page
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let value):
                guard let text = value as? String else {
                    self.saving = false
                    self.renderChrome()
                    return
                }
                self.write(text: text, file: f)
            case .failure(let error):
                self.saving = false
                self.renderChrome()
                Dialog.error(title: "Could not save",
                             detail: "\(f.path): \(error.localizedDescription)")
            }
        }
    }

    private func write(text: String, file f: EditorOpenFile) {
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
                    // Clear the page's pending dirty ping so a timer
                    // armed before the pull cannot resurrect the dot.
                    self.bridge.push(["type": "savedAck"])
                    self.renderChrome()
                }
            } catch {
                DispatchQueue.main.async {
                    self?.saving = false
                    self?.renderChrome()
                    Dialog.error(title: "Could not save",
                                 detail: "\(path): \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Reload / conflict

    private func reloadFromDisk() {
        guard let f = currentFile, !f.isDiff else { return }
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
                    if let ix = self.files.firstIndex(where: { $0 === f }), ix == self.active {
                        self.pushDocument(ix, forceText: true)
                    }
                    self.renderChrome()
                }
            } catch {
                self?.failOnMain(title: "Could not reload",
                                 detail: "\(path): \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Wrap / preview / diff view

    private func toggleWrap() {
        guard let f = currentFile, !f.isDiff else { return }
        f.wrap.toggle()
        pushState()
        renderChrome()
    }

    private func toggleDiffView() {
        diffSplit.toggle()
        pushState()
        renderChrome()
    }

    func togglePreview() {
        guard let f = currentFile, !f.isDiff, Self.isMarkdown(f.path) else { return }
        f.preview.toggle()
        pushState()
        renderChrome()
    }

    // MARK: - External change watching (local files only)

    private func rebuildWatchers() {
        for (_, w) in watchers { w.cancel() }
        watchers.removeAll()
        guard files.contains(where: { !$0.source.isRemote }) else { return }
        for f in files where !f.source.isRemote && !f.isDiff {
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
                            self.pushDocument(ix, forceText: true)
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
        guard let f = currentFile, !f.isDiff, f.source.isRemote else {
            if currentFile?.isDiff == true { refreshDiffs() }
            return
        }
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
            splitButton.isHidden = true
            webView.isHidden = visible
            emptyLabel.isHidden = !visible
            return
        }
        nameLabel.stringValue = f.label + (f.isDiff ? " — changes" : "")
        nameLabel.textColor = Chrome.theme.foreground
        dirtyDot.isHidden = f.isDiff || !f.dirty
        saveButton.isEnabled = !f.isDiff && f.dirty && !saving
        saveButton.setTitle(f.isDiff ? "—" : (saving ? "Saving…" : "Save"))
        previewButton.isHidden = f.isDiff || !Self.isMarkdown(f.path)
        previewButton.setTitle(f.preview ? "Edit" : "Preview")
        reloadButton.isHidden = f.isDiff || !f.conflict
        keepButton.isHidden = f.isDiff || !f.conflict
        pathLabel.textColor = f.conflict
            ? Chrome.theme.wsConnecting : Chrome.theme.secondaryText
        let hostPrefix = f.source.isRemote
            ? ((f.source as? RemoteFileSource).map { "\($0.host):" } ?? "") : ""
        let diffNote = f.isDiff
            ? ((f.diff?.staged == true) ? " [staged]" : " [worktree]") : ""
        pathLabel.stringValue = hostPrefix + f.path + diffNote
        wrapButton.isHidden = f.isDiff || f.preview
        wrapButton.setTitle(f.wrap ? "Wrap: On" : "Wrap: Off")
        splitButton.isHidden = !f.isDiff
        splitButton.setTitle(diffSplit ? "Split" : "Unified")
        webView.isHidden = false
        emptyLabel.isHidden = true
    }
}
