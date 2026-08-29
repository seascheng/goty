// goty — see CLAUDE.md for the working principles.
import AppKit

// MARK: - Source control tab (tty7 scm panel, P1: groups + commit box)

/// tty7 status.rs: one definition of letter + color, shared by the SCM
/// rows and the Files tree — three hand-written A/M/D tables drift.
enum ScmStatusStyle {
    static func color(_ deco: ScmDeco) -> NSColor {
        switch deco {
        case .added, .untracked: return Chrome.theme.gitAdded
        case .deleted, .conflict: return Chrome.theme.gitRemoved
        case .modified: return Chrome.theme.gitModified
        case .renamed: return Chrome.theme.gitRenamed
        case .ignored: return Chrome.theme.secondaryText
        }
    }

    /// The letter for an SCM row's half of the XY pair (staged group
    /// shows X, changes group shows Y — tty7's rule).
    static func letter(_ code: ScmChangeCode) -> String {
        switch code {
        case .none: return "·"
        case .modified: return "M"
        case .typeChanged: return "T"
        case .added: return "A"
        case .deleted: return "D"
        case .renamed: return "R"
        case .copied: return "C"
        case .unmerged: return "U"
        }
    }
}

/// The four sections, in render order. Merge only appears while a merge
/// is unresolved — asked for by variant, not always drawn.
enum ScmPanelGroup: CaseIterable {
    case merge, staged, changes, untracked

    var title: String {
        switch self {
        case .merge: return "Merge Changes"
        case .staged: return "Staged Changes"
        case .changes: return "Changes"
        case .untracked: return "Untracked"
        }
    }
}

/// The Git tab body: branch line, commit box, and the four change
/// groups. Follows the focused pane's repository; every action runs
/// through ScmStore (off-main, one serial queue per process).
final class ScmPanelView: NSView, ThemeRefreshable {
    /// Any op landed → the sidebar's branch/counts are stale too.
    var onGitActivity: (() -> Void)?
    /// Change-row click → the editor overlay's diff document (routed
    /// up: only the delegate layer knows the focused workspace).
    var onOpenDiff: ((_ path: String, _ staged: Bool, _ untracked: Bool) -> Void)?
    /// Latest landed status — the Files tree's badges come from the same
    /// fetch (one git run serves both tabs).
    var onStatus: ((ScmStatus?) -> Void)?
    /// Worktrees row → Open: a terminal in that worktree directory.
    /// Routed up to the coordinator (the panel never spawns tabs).
    var onOpenWorktree: ((String) -> Void)?
    private var cwd: String?
    private var host: String?
    private var status: ScmStatus?
    private var loading = false
    private var collapsed: Set<ScmPanelGroup> = []
    private var worktreesCollapsed = false
    /// Equal (status, collapse-state) = equal pixels — refreshes land
    /// at tick/event cadence and usually change nothing; row candidates
    /// are allocations the keyed reconciler would just discard anyway.
    private var lastRender: (status: ScmStatus,
                             collapsedGroups: Set<ScmPanelGroup>,
                             worktrees: Bool)?

    private let branchIcon = IconLabel("arrow.triangle.branch", pointSize: 11,
                                       tint: Chrome.theme.secondaryText)
    private let branchField = NSTextField(labelWithString: "")
    private let abField = NSTextField(labelWithString: "")
    private let messageView = ChromeInput(
        placeholder: "Message (⌘⏎ to commit)", multiline: true)
    private let listContainer = FileListContainer()
    private let listScroll = NSScrollView()
    private let stateLabel = NSTextField(labelWithString: "")
    private let stagedNote = NSTextField(labelWithString: "")
    private let addButton = ChromeButton(title: "Add", style: .ghost, compact: true)
    private let commitButton = ChromeButton(title: "Commit", style: .primary, compact: true)
    /// its menu (tty7's joined split control).
    private let commitMore = IconButton.make("chevron.down", pointSize: 9)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        // Branch row (tty7 scm_branch_row): git glyph + full-ink sans
        // name — the most important word on the row earns full strength,
        // not a larger size — with the ahead/behind note in muted mono.
        addSubview(branchIcon)

        branchField.font = .systemFont(ofSize: 12.5, weight: .medium)
        branchField.textColor = Chrome.theme.foreground
        branchField.lineBreakMode = .byTruncatingMiddle
        branchField.cell?.truncatesLastVisibleLine = true
        branchField.maximumNumberOfLines = 1
        branchField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(branchField)

        abField.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        abField.textColor = Chrome.theme.secondaryText
        abField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(abField)

        // Commit box (tty7: soft rounded fill, no outline, one line at
        // rest so the file list — the thing the panel is for — starts
        messageView.onCommandReturn = { [weak self] in self?.commit(all: false) }
        messageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(messageView)

        // The commit control row: "N staged" note on the left, the split
        // control (Commit + chevron menu: Commit All) on the right —
        // tty7's shape: one frame, joined, sized like the rows.
        stagedNote.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        stagedNote.textColor = Chrome.theme.secondaryText
        stagedNote.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stagedNote)
        addButton.toolTip = "Stage all changes (git add -A)"
        addButton.onClick = { [weak self] in self?.act(.stageAll) }
        addSubview(addButton)
        commitButton.onClick = { [weak self] in self?.commit(all: false) }
        addSubview(commitButton)

        commitMore.onClick = { [weak self] in
            guard let self else { return }
            let menu = NSMenu()
            menu.addItem(ActionMenuItem("Commit All", symbol: "checkmark.circle") {
                self.commit(all: true)
            })
            NSMenu.popUpContextMenu(menu, with: NSApp.currentEvent ?? NSEvent(),
                                    for: self.commitMore)
        }
        addSubview(commitMore)

        // Group list (same flipped 26pt rows as the Files tree).
        listScroll.documentView = listContainer
        listContainer.autoresizingMask = [.width]
        listScroll.hasVerticalScroller = true
        listScroll.drawsBackground = false
        listScroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(listScroll)

        stateLabel.font = .systemFont(ofSize: 11)
        stateLabel.textColor = Chrome.theme.secondaryText
        stateLabel.translatesAutoresizingMaskIntoConstraints = false
        stateLabel.isHidden = true
        addSubview(stateLabel)

        NSLayoutConstraint.activate([
            branchIcon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            branchIcon.centerYAnchor.constraint(equalTo: branchField.centerYAnchor),
            branchField.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            branchField.leadingAnchor.constraint(equalTo: branchIcon.trailingAnchor, constant: 6),
            branchField.trailingAnchor.constraint(lessThanOrEqualTo: abField.leadingAnchor, constant: -6),
            abField.centerYAnchor.constraint(equalTo: branchField.centerYAnchor),
            abField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            messageView.topAnchor.constraint(equalTo: branchField.bottomAnchor, constant: 7),
            messageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            messageView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stagedNote.topAnchor.constraint(equalTo: messageView.bottomAnchor, constant: 6),
            stagedNote.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            commitButton.topAnchor.constraint(equalTo: messageView.bottomAnchor, constant: 4),
            addButton.trailingAnchor.constraint(equalTo: commitButton.leadingAnchor, constant: -6),
            addButton.centerYAnchor.constraint(equalTo: commitButton.centerYAnchor),
            commitButton.trailingAnchor.constraint(equalTo: commitMore.leadingAnchor, constant: 0),
            commitMore.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            // Split control: Add and Commit read as one group — equal
            // width (resolves to the wider label, "Commit").
            addButton.widthAnchor.constraint(equalTo: commitButton.widthAnchor),
            commitMore.centerYAnchor.constraint(equalTo: commitButton.centerYAnchor),
            listScroll.topAnchor.constraint(equalTo: commitButton.bottomAnchor, constant: 8),
            listScroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            listScroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            listScroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            stateLabel.centerXAnchor.constraint(equalTo: listScroll.centerXAnchor),
            stateLabel.topAnchor.constraint(equalTo: listScroll.topAnchor, constant: 24),
        ])
        render()
    }

    required init?(coder: NSCoder) { fatalError("init(coder: not implemented") }

    // MARK: - Target + refresh

    /// Focused pane moved: follow its repository (tty7 behavior).
    func setTarget(cwd: String?, host: String?, fetchNow: Bool = true) {
        guard cwd != self.cwd || host != self.host else { return }
        self.cwd = cwd
        self.host = host
        status = nil
        render()
        // A collapsed panel must not run git: the target is recorded so
        // the first visible refresh uses the right repo.
        if fetchNow { refresh(force: true) }
    }

    /// Poll entry — TTL-guarded inside the store, so the 2s timer is
    /// cheap. force = after an op or a repo switch.
    func refresh(force: Bool) {
        guard let cwd, !cwd.isEmpty else { return }
        if !force, loading { return }
        loading = true
        ScmStore.shared.refreshStatus(cwd: cwd, host: host, force: force) { [weak self] st in
            guard let self else { return }
            self.loading = false
            // A pane switch while in flight: the answer is not about the
            // repository we are showing now.
            guard self.cwd == cwd else { return }
            self.status = st
            self.onStatus?(st)
            self.render()
        }
    }

    // MARK: - Rendering

    private func render() {
        guard let st = status else {
            lastRender = nil
            branchField.stringValue = ""
            abField.stringValue = ""
            stagedNote.stringValue = ""
            listContainer.setRows([])
            if loading {
                stateLabel.stringValue = "Loading…"
                stateLabel.isHidden = false
            } else if cwd != nil {
                stateLabel.stringValue = "Not a git repository"
                stateLabel.isHidden = false
            } else {
                stateLabel.isHidden = true
            }
            return
        }
        if let last = lastRender, last.status == st,
           last.collapsedGroups == collapsed, last.worktrees == worktreesCollapsed {
            return   // equal status + equal collapse state = equal pixels
        }
        lastRender = (st, collapsed, worktreesCollapsed)

        branchField.stringValue = st.head.label
        var ab = ""
        if let ahead = st.ahead { ab += "↑\(ahead)" }
        if let behind = st.behind { ab += "\(ab.isEmpty ? "" : " ")↓\(behind)" }
        abField.stringValue = ab
        abField.textColor = Self.abColor(st)

        var rows: [(key: String, view: NSView)] = []
        for group in ScmPanelGroup.allCases {
            let entries: [ScmEntry]
            switch group {
            case .merge: entries = st.conflicts
            case .staged: entries = st.staged
            case .changes: entries = st.unstaged
            case .untracked: entries = st.untracked
            }
            if entries.isEmpty { continue }
            let header = groupHeader(group, entries: entries)
            header.rowKey = "hdr:\(group)"
            rows.append((key: header.rowKey, view: header))
            if !collapsed.contains(group) {
                for e in entries {
                    let row = entryRow(e, group: group)
                    row.rowKey = "row:\(group):\(e.path)"
                    rows.append((key: row.rowKey, view: row))
                }
            }
        }

        // Worktrees (design 2026-08-23): every worktree of this repo,
        // app-created or not — bare entries are repositories, not
        // places, and are dropped.
        let wts = st.worktrees.filter { !$0.bare }
        if !wts.isEmpty {
            let header = ScmGroupHeaderView(title: "Worktrees", count: wts.count,
                                            truncated: false)
            header.rowKey = "hdr:worktrees"
            header.onToggle = { [weak self] in
                guard let self else { return }
                self.worktreesCollapsed.toggle()
                self.render()
            }
            rows.append((key: header.rowKey, view: header))
            if !worktreesCollapsed {
                for w in wts {
                    let row = worktreeRow(w)
                    row.rowKey = "wt:\(w.path)"
                    rows.append((key: row.rowKey, view: row))
                }
            }
        }
        listContainer.setRows(rows)

        // The commit control's row note (tty7: the row reads "N staged"
        // on the left and offers the control on the right).
        stagedNote.stringValue = st.staged.isEmpty ? "" : "\(st.staged.count) staged"

        let clean = rows.isEmpty
        stateLabel.stringValue = clean ? "No changes" : ""
        stateLabel.isHidden = !clean
    }

    /// Ahead/behind ink: mixed = neutral, behind = removed-red,
    /// otherwise added-green (one definition for render + retheme).
    private static func abColor(_ st: ScmStatus) -> NSColor {
        if (st.ahead ?? 0) > 0 && (st.behind ?? 0) > 0 { return Chrome.theme.secondaryText }
        if (st.behind ?? 0) > 0 { return Chrome.theme.gitRemoved }
        return Chrome.theme.gitAdded
    }

    /// ThemeRefreshable: the persistent header/commit labels don't
    /// rebuild on render (equal status = equal pixels), so the fan-out
    /// recolors them here; row/header views are conformers or draw
    /// live theme with the needsDisplay sweep.
    func retheme() {
        branchField.textColor = Chrome.theme.foreground
        stagedNote.textColor = Chrome.theme.secondaryText
        stateLabel.textColor = Chrome.theme.secondaryText
        if let st = status { abField.textColor = Self.abColor(st) }
        listContainer.subviews.forEach { $0.needsDisplay = true }
    }


    private func groupHeader(_ group: ScmPanelGroup, entries: [ScmEntry]) -> ScmGroupHeaderView {
        let header = ScmGroupHeaderView(title: group.title, count: entries.count,
                                        truncated: status?.truncated == true)
        header.onToggle = { [weak self] in
            guard let self else { return }
            if self.collapsed.contains(group) {
                self.collapsed.remove(group)
            } else {
                self.collapsed.insert(group)
            }
            self.render()
        }
        // tty7: group verbs sit on the headers. Staged offers Unstage
        // All (discarding a staged file must first unstage it — an
        // explicit two-step, not a hidden one).
        switch group {
        case .merge:
            break
        case .staged:
            header.addAction(symbol: "minus.circle", tip: "Unstage All") { [weak self] in
                self?.act(.unstageAll(headHasCommits: self?.status?.head.hasCommits ?? true))
            }
        case .changes:
            header.addAction(symbol: "plus.circle", tip: "Stage All") { [weak self] in
                self?.act(.stageAll)
            }
            header.addAction(symbol: "trash", tip: "Discard All Changes") { [weak self] in
                self?.act(.discardWorktree(paths: entries.map(\.path)))
            }
        case .untracked:
            header.addAction(symbol: "plus.circle", tip: "Stage All") { [weak self] in
                self?.act(.stage(paths: entries.map(\.path)))
            }
            header.addAction(symbol: "trash", tip: "Delete All Untracked") { [weak self] in
                self?.act(.discardUntracked(paths: entries.map(\.path), directories: true))
            }
        }
        return header
    }

    private func entryRow(_ e: ScmEntry, group: ScmPanelGroup) -> ScmEntryRow {
        let letter: String
        switch group {
        case .merge: letter = "C"
        case .staged: letter = ScmStatusStyle.letter(e.index)
        case .changes: letter = ScmStatusStyle.letter(e.worktree)
        case .untracked: letter = "U"
        }
        let color = group == .merge
            ? ScmStatusStyle.color(.conflict)
            : ScmStatusStyle.color(ScmDeco.deco(index: e.index, worktree: e.worktree,
                                                untracked: e.isUntracked,
                                                conflict: e.conflict))
        let row = ScmEntryRow(path: e.path, origPath: e.origPath,
                              letter: letter, letterColor: color)
        // tty7: clicking a change row opens the diff overlay.
        row.onOpen = { [weak self] in
            self?.onOpenDiff?(e.path, group == .staged, group == .untracked)
        }
        switch group {
        case .merge:
            // Staging the resolution IS "mark as resolved".
            row.addAction(symbol: "plus.circle", tip: "Stage (mark resolved)") { [weak self] in
                self?.act(.stage(paths: [e.path]))
            }
        case .staged:
            row.addAction(symbol: "minus.circle", tip: "Unstage Changes") { [weak self] in
                self?.act(.unstage(paths: [e.path],
                                   headHasCommits: self?.status?.head.hasCommits ?? true))
            }
        case .changes:
            row.addAction(symbol: "plus.circle", tip: "Stage Changes") { [weak self] in
                self?.act(.stage(paths: [e.path]))
            }
            row.addAction(symbol: "trash", tip: "Discard Changes") { [weak self] in
                self?.act(.discardWorktree(paths: [e.path]))
            }
        case .untracked:
            row.addAction(symbol: "plus.circle", tip: "Stage Changes") { [weak self] in
                self?.act(.stage(paths: [e.path]))
            }
            row.addAction(symbol: "trash", tip: "Delete File") { [weak self] in
                self?.act(.discardUntracked(paths: [e.path], directories: false))
            }
        }
        return row
    }

    // MARK: - Actions

    private func act(_ op: ScmOp) {
        if let loss = op.loss {
            let verb: String
            let detail: String
            switch loss {
            case .worktreeEdits:
                verb = "Discard"
                detail = "Uncommitted changes to the selected files will be lost:\n"
                    + op.pathsSummary()
            case .untrackedFiles:
                verb = "Delete"
                detail = "The selected untracked files will be deleted:\n"
                    + op.pathsSummary()
            }
            guard Dialog.confirm(title: "\(verb) changes?", detail: detail, action: verb) else {
                return
            }
        }
        run(op, errorTitle: "Git \(op.label) failed")
    }

    /// One op through the store: success refreshes every git surface
    /// (panel groups, tree badges, sidebar branch line); failure shows
    /// git's first stderr line. Shared by ScmOp and WorktreeOp. `root`
    /// overrides the focused repo — a worktree-row verb runs in THAT
    /// worktree (merge into its checked-out branch), not the focused one.
    private func run(_ op: ScmCommand, root: String? = nil, errorTitle: String) {
        guard let st = status else { return }
        ScmStore.shared.run(op: op, root: root ?? st.root, host: host) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.onGitActivity?()
                self.refresh(force: true)
            case .failure(let f):
                Dialog.error(title: errorTitle, detail: f.detail)
            }
        }
    }

    private func worktreeRow(_ w: WorktreeRecord) -> WorktreeRowView {
        let isCurrent = w.path == status?.root
        var currentBranch: String?
        if case .branch(let name, _)? = status?.head { currentBranch = name }
        let row = WorktreeRowView(record: w, isCurrent: isCurrent)
        row.addAction(symbol: "terminal", tip: "Open Terminal in Worktree") { [weak self] in
            self?.onOpenWorktree?(w.path)
        }
        // Merge acts on the row's own worktree: the focused branch is
        // brought INTO the branch checked out there — hover main while
        // on a feature branch, get "merge feature into main" (run in
        // main's worktree; git refuses to merge into an unchecked-out
        // branch).
        if !isCurrent, let currentBranch, let branch = w.branch, branch != currentBranch {
            row.addAction(symbol: "arrow.triangle.branch",
                          tip: "Merge \(currentBranch) into \(branch)") { [weak self] in
                self?.run(WorktreeOp.merge(branch: currentBranch), root: w.path,
                          errorTitle: "Git merge failed")
            }
        }
        // git refuses to remove the main working tree; the button would
        // only ever produce that error.
        if !w.isMain {
            row.addAction(symbol: "trash", tip: "Remove Worktree") { [weak self] in
                self?.confirmRemoveWorktree(w)
            }
        }
        return row
    }

    private func confirmRemoveWorktree(_ w: WorktreeRecord) {
        let label = w.branch ?? (w.path as NSString).lastPathComponent
        guard Dialog.confirm(
            title: "Remove worktree?",
            detail: "\(label)\n\(w.path)\n\nThe worktree directory is deleted; the branch is kept.",
            action: "Remove") else { return }
        run(WorktreeOp.remove(path: w.path), errorTitle: "Git worktree remove failed")
    }

    private func commit(all: Bool) {
        guard let st = status else { return }
        let message = messageView.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else {
            Dialog.error(title: "Nothing to commit",
                         detail: "Write a commit message first.")
            return
        }
        ScmStore.shared.run(op: ScmOp.commit(message: message, all: all),
                            root: st.root, host: host) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.messageView.stringValue = ""
                self.onGitActivity?()
                self.refresh(force: true)
            case .failure(let f):
                Dialog.error(title: "Git commit failed", detail: f.detail)
            }
        }
    }
}

private extension ScmOp {
    /// Path list for the confirm dialog; long lists summarized — tty7's
    /// "nothing is dropped silently" without a wall of text.
    func pathsSummary() -> String {
        let paths: [String]
        switch self {
        case .stage(let p), .unstage(let p, _),
             .discardWorktree(let p), .discardUntracked(let p, _):
            paths = p
        default: return ""
        }
        guard !paths.isEmpty else { return "" }
        let shown = paths.prefix(6).joined(separator: ", ")
        let extra = paths.count - min(paths.count, 6)
        return extra > 0 ? "\(shown) … and \(extra) more" : shown
    }
}
