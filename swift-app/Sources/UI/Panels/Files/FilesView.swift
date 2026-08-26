// goty — see CLAUDE.md for the working principles.
import AppKit

// MARK: - Files module facade
final class FilesView: NSView {
    /// Intra-tree drag payload: absolute paths on the tree's own source.
    static let treePathsType = NSPasteboard.PasteboardType("goty.treePaths")
    var onInsertPath: ((String) -> Void)?
    /// Click a file row → the built-in editor opens it (tty7).
    var onOpenFile: ((String) -> Void)?
    /// Remote transfers (wired by the delegate layer, which knows the
    /// focused workspace's host). Progress arrives on a background
    /// thread, completion on main. Upload progress carries the running
    /// byte count (its total was walked locally); download progress
    /// carries (bytes, total-or-nil).
    var onUpload: (([URL], String, @escaping (Int64) -> Void,
                    @escaping (Result<Void, Error>) -> Void) -> Void)?
    var onDownload: ((String, Bool, URL, @escaping (Int64, Int64?) -> Void,
                      @escaping (Result<Void, Error>) -> Void) -> Void)?

    private var source: FileSource?
    private var rootPath: String?
    /// Expanded directory paths (absolute).
    private var expanded: Set<String> = []
    /// Children cache per directory path; reloaded per refresh/mutation.
    private var children: [String: [FileEntry]] = [:]
    /// Inline creation in progress (Zed-style editable row in the tree).
    private var creating: (dir: String, isDir: Bool)?
    /// Inline rename in progress (tty7 TreeEdit::Rename): the row's path.
    private var renaming: String?
    private var loading: Set<String> = []
    /// Git status badges for the tree, repo-root-relative (built by the
    /// Git tab's fetch — one git run serves both tabs).
    private var decoIndex: ScmDecoIndex?
    private let pathLabel = NSTextField(labelWithString: "")
    private let listContainer = FileListContainer()
    private let listScroll = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "No directory")
    /// Live transfer line; the tail of the last finished transfer stays
    /// until the next one replaces it.
    private let statusLabel = NSTextField(labelWithString: "")
    /// Slim determinate bar under the toolbar while transfers run.
    private let progressBar = NSProgressIndicator()
    private var nextTransferID = 0
    /// id → (bytes done, total or nil). Aggregate drives the bar.
    private var activeTransfers: [Int: (done: Int64, total: Int64?)] = [:] {
        didSet { renderTransferUI() }
    }
    private var statusTail = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // tty7 drop semantics: a folder row takes a drop itself, a file
        // row stands in for its parent, and the empty space below the
        // tree means the root. Rows register themselves; the view is
        // the empty-space target. (GOTY_HEADLESS skips the drag
        // machinery entirely — no window server, no drag destinations.)
        if ProcessInfo.processInfo.environment["GOTY_HEADLESS"] == nil {
            registerForDraggedTypes([FilesView.treePathsType, .fileURL])
        }
        wantsLayer = true

        let toolbar = NSStackView()
        toolbar.orientation = .horizontal
        toolbar.spacing = 4
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(toolbar)

        let refresh = IconButton.make("arrow.clockwise", pointSize: 11) { [weak self] in
            self?.hardReload()
        }
        refresh.widthAnchor.constraint(equalToConstant: 22).isActive = true
        refresh.heightAnchor.constraint(equalToConstant: 22).isActive = true
        pathLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        pathLabel.textColor = Chrome.theme.secondaryText
        pathLabel.lineBreakMode = .byTruncatingHead
        pathLabel.cell?.truncatesLastVisibleLine = true
        pathLabel.cell?.wraps = false
        pathLabel.maximumNumberOfLines = 1
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        toolbar.addArrangedSubview(refresh)
        toolbar.addArrangedSubview(pathLabel)
        statusLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        statusLabel.textColor = Chrome.theme.secondaryText
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.cell?.truncatesLastVisibleLine = true
        statusLabel.cell?.wraps = false
        statusLabel.maximumNumberOfLines = 1
        statusLabel.isHidden = true
        toolbar.addArrangedSubview(statusLabel)
        toolbar.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)

        progressBar.style = .bar
        progressBar.controlSize = .small
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.doubleValue = 0
        progressBar.isHidden = true
        progressBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(progressBar)

        // Classic document view (manual frames — auto layout across the
        // scroll boundary misplaces rows).
        listScroll.documentView = listContainer
        listContainer.autoresizingMask = [.width]
        listScroll.hasVerticalScroller = true
        listScroll.drawsBackground = false
        listScroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(listScroll)

        emptyLabel.font = .systemFont(ofSize: 11)
        emptyLabel.textColor = Chrome.theme.secondaryText
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.isHidden = true
        addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            toolbar.leadingAnchor.constraint(equalTo: leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            progressBar.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 1),
            progressBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            progressBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            progressBar.heightAnchor.constraint(equalToConstant: 4),
            listScroll.topAnchor.constraint(equalTo: progressBar.bottomAnchor, constant: 2),
            listScroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            listScroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            listScroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyLabel.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 24),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    // MARK: - Tree state

    func setDirectory(_ newPath: String?, source: FileSource?) {
        self.source = source
        creating = nil
        // Drag-to-upload is a remote-workspace feature; locally a Finder
        // drop onto the tree means nothing, so the destination is not
        // even registered (no fake-allowed cursor).
        if source?.isRemote == true {
            registerForDraggedTypes([.fileURL])
        } else {
            unregisterDraggedTypes()
        }
        guard let newPath, !newPath.isEmpty else {
            rootPath = nil
            children.removeAll()
            expanded.removeAll()
            pathLabel.stringValue = ""
            renderRows()
            emptyLabel.stringValue = "No directory"
            emptyLabel.isHidden = false
            return
        }
        if newPath != rootPath {
            rootPath = newPath
            expanded.removeAll()
            children.removeAll()
            pathLabel.stringValue = newPath
            loadChildren(of: newPath)
        }
    }

    /// Full reset (refresh button / new source): drop caches, reload root.
    private func hardReload() {
        guard let rootPath else { return }
        children.removeAll()
        creating = nil
        loadChildren(of: rootPath)
    }

    private func loadChildren(of dir: String) {
        guard let source, !loading.contains(dir) else { return }
        loading.insert(dir)
        let src = source
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try src.entries(at: dir) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.loading.remove(dir)
                switch result {
                case .success(let entries):
                    self.children[dir] = entries
                    if dir == self.rootPath, entries.isEmpty {
                        self.emptyLabel.stringValue = "Empty directory"
                        self.emptyLabel.isHidden = false
                    } else if dir == self.rootPath {
                        self.emptyLabel.isHidden = true
                    }
                    self.renderRows()
                case .failure(let err):
                    if dir == self.rootPath {
                        self.emptyLabel.stringValue = err.localizedDescription
                        self.emptyLabel.isHidden = false
                        self.children[dir] = []
                        self.renderRows()
                    }
                    // A subdirectory that fails to list simply stays closed.
                }
            }
        }
    }

    /// Flatten the expanded tree into rows (depth-first, dirs first per
    /// level via the sorted cache).
    private func renderRows() {
        guard let rootPath else {
            listContainer.setRows([])
            return
        }
        var rows: [(key: String, view: NSView)] = []
        var pendingFocus: CreationRow?

        func emit(_ dir: String, depth: Int) {
            // The inline-creation row leads the target directory's rows.
            if let creating, creating.dir == dir {
                let row = CreationRow(isDirectory: creating.isDir, depth: depth + 1)
                row.creatingDir = dir
                row.onCommit = { [weak self] name in self?.commitCreation(name) }
                row.onCancel = { [weak self] in self?.cancelCreation() }
                rows.append((key: row.rowKey, view: row))
                pendingFocus = row
            }
            guard let kids = children[dir] else { return }
            for entry in kids {
                let childPath = dir + "/" + entry.name
                // tty7: a rename swaps the row itself for the edit row,
                // prefilled with the current name.
                if renaming == childPath {
                    let row = CreationRow(isDirectory: entry.isDirectory, depth: depth,
                                          initialText: entry.name, placeholder: "new name")
                    row.editingPath = childPath
                    row.onCommit = { [weak self] name in self?.commitRename(name) }
                    row.onCancel = { [weak self] in self?.renaming = nil; self?.renderRows() }
                    rows.append((key: row.rowKey, view: row))
                    pendingFocus = row
                    continue
                }
                let isOpen = expanded.contains(childPath)
                let row = FileRow(entry: entry, depth: depth, expanded: isOpen,
                                  badge: gitBadge(for: childPath, isDirectory: entry.isDirectory),
                                  glyphTint: entry.isDirectory ? gitDirTint(for: childPath) : nil)
                row.onToggle = { [weak self] in self?.toggle(childPath) }
                // tty7: click a file → the editor; a folder toggles.
                // Sending the path to the terminal stays an explicit
                // context-menu command.
                row.onOpen = { [weak self] in
                    guard let self else { return }
                    if entry.isDirectory {
                        self.toggle(childPath)
                    } else {
                        self.onOpenFile?(childPath)
                    }
                }
                row.onContext = { [weak self] view in
                    self?.showRowMenu(entry, path: childPath, onView: view)
                }
                row.dragPath = childPath
                row.isLocalDrag = source?.isRemote == false
                row.onTreeDrop = { [weak self] paths in
                    self?.moveDropped(paths,
                                      into: entry.isDirectory ? childPath : dir)
                }
                // Remote tree: Finder drops land inside a folder row /
                // next to a file row (tty7 drop semantics).
                if source?.isRemote == true {
                    row.onDrop = { [weak self] urls in
                        self?.uploadDropped(urls: urls,
                                            into: entry.isDirectory ? childPath : dir)
                        return true
                    }
                }
                rows.append((key: childPath, view: row))
                if entry.isDirectory, isOpen {
                    emit(childPath, depth: depth + 1)
                }
            }
        }
        emit(rootPath, depth: 0)
        listContainer.setRows(rows)
        // Focus + select the inline editor once it's in the hierarchy.
        if let row = pendingFocus {
            DispatchQueue.main.async {
                row.beginEditing()
            }
        }
    }

    /// Repo-relative probe against the decoration index. Paths here are
    /// absolute; the index keys are repo-root-relative — the tree's root
    /// may sit deeper than the repository.
    private func gitBadge(for path: String, isDirectory: Bool) -> (letter: String, color: NSColor)? {
        guard let deco = decoIndex, path.hasPrefix(deco.root + "/"),
              !isDirectory,
              let d = deco.file(String(path.dropFirst(deco.root.count + 1))),
              let letter = d.letter else { return nil }
        return (letter, ScmStatusStyle.color(d))
    }

    /// Directories carry no letter (a rollup has none); a conflict
    /// anywhere beneath colors the folder glyph.
    private func gitDirTint(for path: String) -> NSColor? {
        guard let deco = decoIndex, path.hasPrefix(deco.root + "/"),
              let roll = deco.dir(String(path.dropFirst(deco.root.count + 1))),
              roll.conflict else { return nil }
        return Chrome.theme.gitRemoved
    }

    /// Test surface: the live creation row (nil = none/committed). The
    /// flash-then-die regression is exactly "row vanished with no input".
    var currentCreationRow: CreationRow? {
        listContainer.subviews.compactMap { $0 as? CreationRow }.first
    }
    var rowCountForTest: Int { listContainer.subviews.count }
    var currentRenameText: String? {
        guard renaming != nil else { return nil }
        return currentCreationRow?.fieldTextForTest
    }
    func beginRenameForTest(path: String) { startRename(path: path) }
    func refreshDirForTest(dir: String) { refreshDir(dir) }
    func moveForTest(from: String, to: String) {
        runOp("Test move") { src in try src.move(from: from, to: to) }
        refreshDir: { [weak self] in self?.refreshDir((from as NSString).deletingLastPathComponent) }
    }


    /// Status badges from the Git tab's latest fetch (nil = repo gone /
    /// not a repo — badges clear).
    func setGitDecorations(_ index: ScmDecoIndex?) {
        // The 2s git poll calls in with a fresh index every time; a
        // rebuild on every tick is what orphaned drag sessions and
        // churned the tree. Equal index = no render.
        guard index != decoIndex else { return }
        decoIndex = index
        renderRows()
    }

    private func toggle(_ dir: String) {
        if expanded.contains(dir) {
            expanded.remove(dir)
            renderRows()
        } else {
            expanded.insert(dir)
            if children[dir] == nil {
                loadChildren(of: dir)
            } else {
                renderRows()
            }
        }
    }

    /// File path into the terminal (shared quoting rules).
    private func shellReady(_ path: String) -> String {
        Shell.quotedPath(path)
    }

    /// What a file click used to do silently — now an explicit command.
    private func sendPathToTerminal(_ path: String) {
        onInsertPath?(shellReady(path))
    }

    /// Row context menu (built pure so tests can inspect it).
    func rowMenu(for entry: FileEntry, path: String) -> NSMenu {
        let menu = NSMenu()
        // VSCode semantics: new items land inside a right-clicked folder,
        // next to a right-clicked file.
        let target = entry.isDirectory ? path : (path as NSString).deletingLastPathComponent
        menu.addItem(ActionMenuItem("New File\u{2026}", symbol: "doc.badge.plus") { [weak self] in
            self?.newFile(in: target)
        })
        menu.addItem(ActionMenuItem("New Folder\u{2026}", symbol: "folder.badge.plus") { [weak self] in
            self?.newFolder(in: target)
        })
        menu.addItem(ActionMenuItem("Rename\u{2026}", symbol: "pencil") { [weak self] in
            self?.startRename(path: path)
        })
        menu.addItem(.separator())
        // The old click-to-paste behavior, made explicit and intentional.
        menu.addItem(ActionMenuItem("Send Path to Terminal", symbol: "terminal") { [weak self] in
            self?.sendPathToTerminal(path)
        })
        if source?.isRemote == false {
            menu.addItem(ActionMenuItem("Reveal in Finder", symbol: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting(
                    [URL(fileURLWithPath: path)])
            })
        }
        // Remote rows can be pulled to this Mac (file or folder).
        if source?.isRemote == true {
            menu.addItem(ActionMenuItem("Download\u{2026}", symbol: "arrow.down.circle") { [weak self] in
                self?.beginDownload(path: path, name: entry.name,
                                    isDirectory: entry.isDirectory)
            })
        }
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem("Copy Path", symbol: "doc.on.doc") { [weak self] in
            self?.copyString(path)
        })
        menu.addItem(ActionMenuItem("Copy Relative Path", symbol: "arrow.turn.down.right") { [weak self] in
            guard let self, let root = self.rootPath else { return }
            if path.hasPrefix(root + "/") {
                self.copyString(String(path.dropFirst(root.count + 1)))
            } else {
                self.copyString(path)
            }
        })
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem("Delete\u{2026}", symbol: "trash") { [weak self] in
            self?.confirmDelete(entry, path: path)
        })
        return menu
    }

    private func showRowMenu(_ entry: FileEntry, path: String, onView view: NSView) {
        NSMenu.popUpContextMenu(rowMenu(for: entry, path: path),
                                with: NSApp.currentEvent ?? NSEvent(), for: view)
    }

    private func copyString(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    private func confirmDelete(_ entry: FileEntry, path: String) {
        guard Dialog.confirm(
            title: "Delete \(entry.name)\(entry.isDirectory ? " and everything in it" : "")?",
            detail: path, action: "Delete") else { return }
        let parent = (path as NSString).deletingLastPathComponent
        runOp("Deleting \(entry.name)") { src in
            try src.delete(entry, at: parent)
        } refreshDir: { [weak self] in
            self?.refreshDir(parent)
        }
    }

    /// Insert the editable creation row as the target directory's first
    /// child (opening the directory if needed) — Zed-style, no dialog.
    private func startCreation(in dir: String, isDir: Bool) {
        guard !dir.isEmpty, rootPath != nil else { return }
        creating = (dir, isDir)
        if !expanded.contains(dir) {
            expanded.insert(dir)
            if children[dir] == nil {
                loadChildren(of: dir)   // renderRows runs on arrival
                return
            }
        }
        renderRows()
    }

    private func commitCreation(_ rawName: String) {
        guard let creating else { return }
        let name = rawName.trimmingCharacters(in: .whitespaces)
        self.creating = nil
        guard !name.isEmpty, !name.contains("/") else {
            renderRows()
            return
        }
        runOp("Creating \(name)") { src in
            if creating.isDir {
                try src.createFolder(name: name, in: creating.dir)
            } else {
                try src.createFile(name: name, in: creating.dir)
            }
        } refreshDir: { [weak self] in
            self?.refreshDir(creating.dir)
        }
    }

    private func cancelCreation() {
        creating = nil
        renderRows()
    }

    /// tty7 file_tree_begin_edit(Rename): the inline row is prefilled
    /// with the current name and commits as a move within the parent.
    private func startRename(path: String) {
        guard rootPath != nil else { return }
        renaming = path
        renderRows()
    }

    private func commitRename(_ rawName: String) {
        guard let path = renaming else { return }
        renaming = nil
        let name = rawName.trimmingCharacters(in: .whitespaces)
        let parent = (path as NSString).deletingLastPathComponent
        guard !name.isEmpty, !name.contains("/"), name != (path as NSString).lastPathComponent else {
            renderRows()
            return
        }
        runOp("Renaming to \(name)") { src in
            try src.move(from: path, to: parent + "/" + name)
        } refreshDir: { [weak self] in
            self?.refreshDir(parent)
            // A renamed directory's expanded-set keys moved with it.
            self?.expanded = TreeOps.rekeyedExpanded(self?.expanded ?? [], from: path, to: parent + "/" + name)
        }
    }


    /// Intra-tree drag = move (tty7 drags rows as paths; same-source
    /// drops relocate). The RULES live in Core (TreeOps); this executes
    /// the plan and refreshes what moved.
    func moveDropped(_ paths: [String], into dir: String) {
        guard source != nil, rootPath != nil else { return }
        let plan: TreeOps.Plan
        switch TreeOps.planMove(paths: paths, into: dir, existing: children[dir]) {
        case .failure:
            return   // into-itself / already there: nothing happened
        case .success(let p):
            plan = p
        }
        if !plan.conflicts.isEmpty {
            guard Dialog.confirm(title: "Replace items?",
                                 detail: "The destination already has items with these names:\n"
                                    + plan.conflicts.joined(separator: ", "),
                                 action: "Replace") else { return }
        }
        runOp("Moving \(paths.count) item(s)") { src in
            for move in plan.moves {
                try src.move(from: move.from, to: move.to)
            }
        } refreshDir: { [weak self] in
            self?.refreshDir(dir)
            for move in plan.moves {
                self?.refreshDir((move.from as NSString).deletingLastPathComponent)
                if let keys = self?.expanded {
                    self?.expanded = TreeOps.rekeyedExpanded(keys, from: move.from, to: move.to)
                }
            }
        }
    }

    private func newFile() {
        if let dir = targetDir(forNew: "file") { startCreation(in: dir, isDir: false) }
    }

    private func newFile(in dir: String) {
        startCreation(in: dir, isDir: false)
    }

    private func newFolder() {
        if let dir = targetDir(forNew: "folder") { startCreation(in: dir, isDir: true) }
    }

    private func newFolder(in dir: String) {
        startCreation(in: dir, isDir: true)
    }

    /// New items land in the last expanded directory (deepest open
    /// folder), falling back to the root.
    private func targetDir(forNew kind: String) -> String? {
        guard let rootPath else { return nil }
        var dir = rootPath
        // Deepest expanded directory.
        var frontier = [rootPath]
        while !frontier.isEmpty {
            var next: [String] = []
            for d in frontier {
                for entry in children[d] ?? [] where entry.isDirectory {
                    let child = d + "/" + entry.name
                    if expanded.contains(child) {
                        dir = child
                        next.append(child)
                    }
                }
            }
            frontier = next
        }
        return dir
    }

    /// Reload one directory's listing, keeping expansion state.
    /// Reload one directory's listing, keeping expansion state.
    private func refreshDir(_ dir: String) {
        children.removeValue(forKey: dir)
        loadChildren(of: dir)
    }

    /// Mutations run off-main (remote = one ssh round trip), then refresh
    /// the touched directory.
    private func runOp(_ what: String, _ op: @escaping (FileSource) throws -> Void,
                       refreshDir: @escaping () -> Void) {
        guard let source else { return }
        let src = source
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try op(src) }
            DispatchQueue.main.async {
                if case .failure(let err) = result {
                    Dialog.error(title: "Operation failed",
                                 detail: "\(what): \(err.localizedDescription)")
                }
                refreshDir()
            }
        }
    }

    // MARK: - Transfers (download menu + drag-to-upload)

    /// Pick a destination folder, pull the remote path into it, reveal
    /// the result in Finder.
    private func beginDownload(path: String, name: String, isDirectory: Bool) {
        let panel = NSOpenPanel()
        panel.message = "Download \(name) into"
        panel.prompt = "Download"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        performDownload(remotePath: path, name: name, isDirectory: isDirectory, into: dest)
    }

    func performDownload(remotePath: String, name: String, isDirectory: Bool, into dest: URL) {
        let id = beginTransfer()
        let started = Date()
        onDownload?(remotePath, isDirectory, dest,
                    progressSink(id: id)) { [weak self] result in
            guard let self else { return }
            self.endTransfer(id: id)
            switch result {
            case .success:
                let seconds = Date().timeIntervalSince(started)
                self.statusTail = "\(name) in \(String(format: "%.1f", seconds))s"
                NSWorkspace.shared.selectFile(dest.path + "/" + name,
                                              inFileViewerRootedAtPath: dest.path)
            case .failure(let err):
                Dialog.error(title: "Download failed", detail: err.localizedDescription)
            }
        }
    }

    /// A Finder drop landed: files go into a folder row (or next to a
    /// file row — "put it where this one is"), the root for empty space.
    func uploadDropped(urls: [URL], into dir: String) {
        guard source?.isRemote == true, !urls.isEmpty else { return }
        let bytes = Self.localBytes(urls)
        let id = beginTransfer()
        activeTransfers[id] = (0, bytes)   // upload total is known locally
        let started = Date()
        let count = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) items"
        onUpload?(urls, dir,
                  { [weak self] done in
                      self?.updateTransfer(id: id) { _ in (done, bytes) }
                  }) { [weak self] result in
            guard let self else { return }
            self.endTransfer(id: id)
            switch result {
            case .success:
                let seconds = Date().timeIntervalSince(started)
                self.statusTail = "\(count) \(Self.sizeLabel(bytes)) in "
                    + String(format: "%.1f", seconds) + "s"
                self.refreshDir(dir)
            case .failure(let err):
                Dialog.error(title: "Upload failed", detail: err.localizedDescription)
                self.refreshDir(dir)
            }
        }
    }

    private func beginTransfer() -> Int {
        statusTail = ""
        nextTransferID += 1
        activeTransfers[nextTransferID] = (0, nil)
        return nextTransferID
    }

    private func endTransfer(id: Int) {
        activeTransfers[id] = nil
    }

    /// Hop to main, throttled to ~30fps — the engine reports every chunk.
    private func progressSink(id: Int) -> (Int64, Int64?) -> Void {
        var lastDispatch = Date.distantPast
        return { [weak self] done, total in
            let now = Date()
            let isFinal = total.map { done >= $0 } ?? false
            guard isFinal || now.timeIntervalSince(lastDispatch) > 0.033 else { return }
            lastDispatch = now
            DispatchQueue.main.async {
                self?.updateTransfer(id: id) { _ in (done, total) }
            }
        }
    }

    private func updateTransfer(id: Int, _ mutate: ((done: Int64, total: Int64?)) -> (Int64, Int64?)) {
        guard var t = activeTransfers[id] else { return }
        let next = mutate(t)
        guard next != t else { return }
        t = next
        activeTransfers[id] = t   // fires renderTransferUI
    }

    private func renderTransferUI() {
        if activeTransfers.isEmpty {
            progressBar.isHidden = true
            progressBar.stopAnimation(nil)
            renderStatus()
            return
        }
        let done = activeTransfers.values.reduce(0) { $0 + $1.done }
        let knownTotals = activeTransfers.values.compactMap(\.total)
        progressBar.isHidden = false
        if knownTotals.count == activeTransfers.count, knownTotals.reduce(0, +) > 0 {
            progressBar.isIndeterminate = false
            progressBar.doubleValue = min(Double(done) / Double(knownTotals.reduce(0, +)), 1)
        } else {
            progressBar.isIndeterminate = true
            progressBar.startAnimation(nil)
        }
        renderStatus()
    }

    private func renderStatus() {
        if !activeTransfers.isEmpty {
            let done = activeTransfers.values.reduce(0) { $0 + $1.done }
            let knownTotals = activeTransfers.values.compactMap(\.total)
            var text = "\(activeTransfers.count == 1 ? "" : "\(activeTransfers.count)× ")"
                + Self.sizeLabel(done)
            if knownTotals.count == activeTransfers.count, knownTotals.reduce(0, +) > 0 {
                let pct = Int(min(Double(done) / Double(knownTotals.reduce(0, +)), 1) * 100)
                text += " · \(pct)%"
            }
            statusLabel.isHidden = false
            statusLabel.stringValue = text
        } else if !statusTail.isEmpty {
            statusLabel.isHidden = false
            statusLabel.stringValue = statusTail
        } else {
            statusLabel.isHidden = true
        }
    }

    private static func localBytes(_ urls: [URL]) -> Int64 {
        var total: Int64 = 0
        for url in urls {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
               isDir.boolValue {
                if let en = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) {
                    for case let file as URL in en {
                        total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                    }
                }
            } else {
                total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }
        return total
    }

    private static func sizeLabel(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    // Drag destination (empty area = the tree root). Rows handle their
    // own, more specific destinations; the deepmost view under the cursor
    // is asked first, so this only sees drops that missed every row.
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if FileRow.treeDragPaths(sender) != nil, rootPath != nil { return .move }
        return Self.dragURLs(sender) != nil ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if FileRow.treeDragPaths(sender) != nil, rootPath != nil { return .move }
        return Self.dragURLs(sender) != nil ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let rootPath else { return false }
        if let paths = FileRow.treeDragPaths(sender) {
            let dir = rootPath
            DispatchQueue.main.async { [weak self] in
                self?.moveDropped(paths, into: dir)
            }
            return true
        }
        guard let urls = Self.dragURLs(sender) else { return false }
        uploadDropped(urls: urls, into: rootPath)
        return true
    }

    static func dragURLs(_ sender: NSDraggingInfo) -> [URL]? {
        let pb = sender.draggingPasteboard
        guard let urls = pb.readObjects(forClasses: [NSURL.self],
                                        options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return nil }
        return urls
    }
}

/// Inline editable creation row (Zed-style): icon + text field, Enter
/// commits, Escape cancels, clicking elsewhere commits.
