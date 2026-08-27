// goty — see CLAUDE.md for the working principles.
import Foundation

// MARK: - Workspace coordinator (business core, no UI)

/// Owns everything workspace-shaped: the store, daemon routing, connection
/// states, cwd/focus tracking, and every tab/workspace mutation. Views
/// never touch sessiond directly — they observe through `delegate`.
final class WorkspaceCoordinator {
    weak var delegate: WorkspaceCoordinatorDelegate?

    enum ChangeDomain { case structure, connection, cwd, git, agent, title }
    enum WsState { case connecting, connected, disconnected }

    var store: WorkspaceStore?
    /// Daemon routing: local panes → the shared singleton; a remote
    /// workspace → its ssh-forwarded link. Injected by AppDelegate.
    var daemonFor: ((WorkspaceState) -> SessionDaemon?)?
    /// All per-workspace runtime state lives in ONE structure — the
    /// no-parallel-dicts invariant from CLAUDE.md.
    private struct Runtime {
        var state: WsState = .connecting
        var activePaneId: String?
        /// Passive agent status per pane (AgentDetect), keyed by pane id.
        /// Volatile: rebuilt from live panes after attach, never persisted.
        var agents: [String: AgentPaneRuntime] = [:]
        /// Live surface titles per pane (the PTY's own window title).
        /// Volatile like agents — deliberately never persisted, so a
        /// restored session doesn't show a stale title before the PTY
        /// sets its own.
        var titles: [String: String] = [:]
    }
    private var runtime: [UUID: Runtime] = [:]
    var onSendText: ((HostKey, String) -> Void)?

    /// Agent status of one pane, with the "done until seen" bit:
    /// an agent that finished while its tab was not focused stays green
    /// until the user opens it.
    struct AgentPaneRuntime: Equatable {
        var state: AgentActivity = .unknown
        var seen = true
        /// Live foreground command (sessiond list reply); nil = whatever
        /// the pane was spawned with is authoritative.
        var command: String?
    }

    var wsStates: [UUID: WsState] {
        var result = runtime.mapValues(\.state)
        guard let store else { return result }
        for workspace in store.workspaces where result[workspace.id] == nil {
            result[workspace.id] = workspace.isRemote ? .connecting : .connected
        }
        return result
    }


    func bootWorkspace(_ workspace: WorkspaceState) {
        runtime[workspace.id, default: Runtime()].state =
            workspace.isRemote ? .connecting : .connected
        delegate?.coordinatorDidChange(.connection)
    }

    func workspaceConnected(_ wsId: UUID) {
        guard runtime[wsId]?.state != .connected else { return }
        runtime[wsId, default: Runtime()].state = .connected
        delegate?.coordinatorDidChange(.connection)
    }

    func workspaceDisconnected(_ wsId: UUID) {
        guard runtime[wsId]?.state != .disconnected else { return }
        runtime[wsId, default: Runtime()].state = .disconnected
        delegate?.coordinatorDidChange(.connection)
    }

    func reconnectWorkspace(_ wsId: UUID) {
        runtime[wsId, default: Runtime()].state = .connecting
        delegate?.retireHosts(workspace: wsId)
        delegate?.coordinatorDidChange(.connection)
        delegate?.coordinatorDidChange(.structure)
    }

    func selectTab(index: Int) {
        guard let store, store.workspaces.indices.contains(store.focusedIndex),
              store.workspaces[store.focusedIndex].tabs.indices.contains(index) else { return }
        let wi = store.focusedIndex
        let alreadyFocused = store.workspaces[wi].focusedTabIndex == index
        store.workspaces[wi].focusedTabIndex = index
        if let pane = store.workspaces[wi].tabs[index].panes.first {
            runtime[store.workspaces[wi].id, default: Runtime()].activePaneId = pane.id
        }
        // Clicking the focused space again must not rebuild the sidebar —
        // a no-op re-render would destroy the row mid-double-click (and
        // its inline rename editor with it).
        markTabSeen(index: index)
        if alreadyFocused { return }
        store.save()
        delegate?.coordinatorDidChange(.structure)
        pollDaemonLists()
    }

    // MARK: Passive agent status (AgentDetect)

    /// A pane published a new agent activity (from its PaneHost detector).
    /// Applies the seen rules: live work is always seen; a finish while
    /// the tab was not focused stays "done" until the user opens it.
    func agentStateUpdated(wsId: UUID, paneId: String, state: AgentActivity) {
        guard runtime[wsId] != nil else { return }
        let previous = runtime[wsId]!.agents[paneId] ?? AgentPaneRuntime()
        var next = previous
        next.state = state
        if state != .idle {
            next.seen = true
        } else if previous.state == .working || previous.state == .blocked {
            next.seen = isPaneFocused(wsId: wsId, paneId: paneId)
        }
        guard next != previous else { return }
        runtime[wsId]!.agents[paneId] = next
    }

    /// Focusing a tab counts as seeing everything in it — a done badge
    /// waiting on that tab clears.
    func markTabSeen(index: Int) {
        guard let store, store.workspaces.indices.contains(store.focusedIndex),
              store.workspaces[store.focusedIndex].tabs.indices.contains(index) else { return }
        let wsId = store.workspaces[store.focusedIndex].id
        var changed = false
        for pane in store.workspaces[store.focusedIndex].tabs[index].panes {
            if runtime[wsId]?.agents[pane.id]?.seen == false {
                runtime[wsId]!.agents[pane.id]!.seen = true
                changed = true
            }
        }
        if changed { delegate?.coordinatorDidChange(.agent) }
    }

    /// Agent status of one pane in the focused workspace, for the sidebar
    /// rows and the Info panel.
    func agentStatus(paneId: String) -> AgentPaneRuntime? {
        guard let wsId = store?.focused?.id else { return nil }
        return runtime[wsId]?.agents[paneId]
    }

    /// The spawn command a tab was created with, or — when the user typed
    /// an agent into a shell — the pane's live foreground command. This is
    /// the identity every agent surface (badge, brand icon, detection)
    /// keys off.
    func effectiveCommand(for tab: TabState) -> String? {
        guard let paneId = tab.panes.first?.id,
              let wsId = store?.focused?.id,
              let fg = runtime[wsId]?.agents[paneId]?.command,
              AgentCatalog.spec(for: fg) != nil else {
            return tab.paneCommand
        }
        return fg
    }

    /// The surface's live window title changed (OSC 0/2 through ghostty).
    /// Sidebar rows read it as the tab's display name; never persisted.
    func paneTitleUpdated(wsId: UUID, paneId: String, title: String) {
        guard runtime[wsId] != nil else { return }
        guard runtime[wsId]!.titles[paneId] != title else { return }
        runtime[wsId]!.titles[paneId] = title
        if wsId == store?.focused?.id { delegate?.coordinatorDidChange(.title) }
    }

    /// The tab's live surface title for sidebar display; nil = no title
    /// yet (fresh pane) or the surface's ghost-emoji placeholder.
    func surfaceTitle(for tab: TabState) -> String? {
        guard let wsId = store?.focused?.id,
              let paneId = tab.panes.first?.id,
              let title = runtime[wsId]?.titles[paneId],
              !title.isEmpty, title != "👻" else { return nil }
        return title
    }


    /// ONE list round trip per connected daemon per tick — the same
    /// reply feeds cwd tracking (focused workspace; the sidebar groups
    /// spaces by directory, the Info panel shows the focused one) and
    /// foreground/agent identity (all workspaces). These were two
    /// separate polls over the identical reply.
    func pollDaemonLists() {
        guard let store else { return }
        let focusedId = store.focused?.id
        let targets = store.workspaces.compactMap { ws -> (WorkspaceState, SessionDaemon)? in
            guard (runtime[ws.id]?.state ?? .connecting) == .connected else { return nil }
            return (ws, daemonFor?(ws) ?? .shared)
        }
        guard !targets.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var cwdResult: (UUID, [String: String])?
            var fgResults: [(UUID, [String: String], [String: String])] = []
            for (ws, daemon) in targets {
                let panes = daemon.listPanes()
                if ws.id == focusedId {
                    var byRuntimeId: [String: String] = [:]
                    for info in panes where info.cwd != nil {
                        byRuntimeId[info.id] = info.cwd
                    }
                    cwdResult = (ws.id, byRuntimeId)
                }
                var fg: [String: String] = [:]
                var agents: [String: String] = [:]
                for info in panes {
                    // Daemon ids are "<workspace>_<pane>"; keep the pane half.
                    if let pane = info.id.split(separator: "_", maxSplits: 1).last {
                        if let command = info.fg {
                            fg[String(pane)] = command
                        }
                        if let agent = info.agent {
                            agents[String(pane)] = agent
                        }
                    }
                }
                fgResults.append((ws.id, fg, agents))
            }
            DispatchQueue.main.async { [weak self] in
                if let (wsId, byRuntimeId) = cwdResult {
                    self?.applyCwds(wsId: wsId, byRuntimeId: byRuntimeId)
                }
                self?.applyForegrounds(fgResults)
            }
        }
    }
    private func applyForegrounds(_ results: [(UUID, [String: String], [String: String])]) {
        guard let store else { return }
        var changed = false
        var identityChanges: [(HostKey, String?)] = []
        for (wsId, fg, agents) in results {
            guard runtime[wsId] != nil,
                  let wi = store.workspaces.firstIndex(where: { $0.id == wsId }) else { continue }
            for tab in store.workspaces[wi].tabs {
                for pane in tab.panes {
                    var entry = runtime[wsId]!.agents[pane.id] ?? AgentPaneRuntime()
                    let newCommand = fg[pane.id]
                    var entryChanged = false
                    if entry.command != newCommand {
                        // Signal on EVERY fg change, not just agent-identity
                        // changes: PaneHost retargets detection (deduped by
                        // `guard next != agentCommand`) and re-evaluates the
                        // @ai trigger arming. Identity filtering left the
                        // trigger armed inside vim/ssh/python — every
                        // non-agent program maps to identity nil, so the
                        // shell→vim transition never signalled (acceptance
                        // #8). Sidebar churn is driven by entryChanged,
                        // not this list.
                        entry.command = newCommand
                        entryChanged = true
                        identityChanges.append((HostKey(workspace: wsId, pane: pane.id), newCommand))
                    }
                    // The omp/pi extension reports the authoritative TUI
                    // state through its owning daemon — it outranks the
                    // passive screen tracker whenever it speaks.
                    if let reported = agents[pane.id],
                       let activity = AgentActivity(reported),
                       entry.state != activity {
                        entry.state = activity
                        entry.seen = true
                        entryChanged = true
                    }
                    guard entryChanged else { continue }
                    runtime[wsId]!.agents[pane.id] = entry
                    changed = true
                }
            }
        }
        guard changed else { return }
        delegate?.coordinatorDidChange(.agent)
        onForegroundChange?(identityChanges)
    }

    /// (pane, fg command) pairs whose identity changed — the delegate
    /// layer forwards them to the owning PaneHosts.
    var onForegroundChange: (([(HostKey, String?)]) -> Void)?

    /// True when this pane belongs to the tab the user is looking at.
    private func isPaneFocused(wsId: UUID, paneId: String) -> Bool {
        guard let store, store.focusedIndex == store.workspaces.firstIndex(where: { $0.id == wsId }),
              let tab = store.focused?.focusedTab else { return false }
        return tab.panes.contains { $0.id == paneId }
    }

    func focusPane(wsId: UUID, paneId: String) {
        runtime[wsId, default: Runtime()].activePaneId = paneId
        delegate?.coordinatorDidChange(.cwd)
    }

    /// AI execution target for one pane: local vs ssh follows the
    /// workspace, cwd is the pane's live cwd. Shell stays nil — host
    /// facts come from the AI coordinator's own probe, never a guess.
    func aiTarget(for key: HostKey) -> ExecutionTarget? {
        guard let store,
              let ws = store.workspaces.first(where: { $0.id == key.workspace }),
              let pane = ws.tabs.flatMap({ $0.panes })
                  .first(where: { $0.id == key.pane }) else { return nil }
        return ExecutionTarget(
            workspaceId: ws.id, paneId: pane.id, displayName: ws.displayName,
            transport: ws.sshHost.map { .ssh(host: $0) } ?? .local,
            cwd: pane.cwd, shell: nil)
    }

    func activePane(of workspace: WorkspaceState) -> PaneState? {
        if let id = runtime[workspace.id]?.activePaneId {
            for tab in workspace.tabs {
                if let pane = tab.panes.first(where: { $0.id == id }) { return pane }
            }
        }
        return workspace.focusedTab?.panes.first
    }


    private func applyCwds(wsId: UUID, byRuntimeId: [String: String]) {
        guard let store,
              let wi = store.workspaces.firstIndex(where: { $0.id == wsId }) else { return }
        var changed = false
        for ti in store.workspaces[wi].tabs.indices {
            for pi in store.workspaces[wi].tabs[ti].panes.indices {
                let pane = store.workspaces[wi].tabs[ti].panes[pi]
                let runtimeId = HostKey(workspace: wsId, pane: pane.id).runtimeId
                guard let cwd = byRuntimeId[runtimeId], pane.cwd != cwd else { continue }
                store.workspaces[wi].tabs[ti].panes[pi].cwd = cwd
                changed = true
            }
        }
        guard changed else { return }
        store.save()
        if wi == store.focusedIndex { delegate?.coordinatorDidChange(.cwd) }
    }

    /// Git summaries for the focused workspace's distinct space cwds —
    /// local repos via git, remote via one ssh exec each. The store's TTL
    /// and in-flight set make the 2s poll cheap; a change fires `.git`
    /// (sidebar spaces only — no pane-grid churn). `force` = after an
    /// SCM panel op.
    func pollGitStatuses(force: Bool = false) {
        guard let store, let workspace = store.focused,
              (runtime[workspace.id]?.state ?? .connecting) == .connected else { return }
        let cwds = workspace.tabs.compactMap { $0.panes.first?.cwd }
        guard !cwds.isEmpty else { return }
        GitStatusStore.shared.refresh(cwds: cwds, host: workspace.sshHost,
                                      force: force) { [weak self] in
            self?.delegate?.coordinatorDidChange(.git)
        }
    }


    func insertPathIntoFocusedPane(_ path: String) {
        guard let workspace = store?.focused, let pane = activePane(of: workspace) else { return }
        onSendText?(HostKey(workspace: workspace.id, pane: pane.id), Shell.quotedPath(path) + " ")
    }

    func selectWorkspace(_ index: Int) {
        guard let store, store.workspaces.indices.contains(index),
              store.focusedIndex != index else { return }
        store.focusedIndex = index
        store.save()
        delegate?.coordinatorDidChange(.structure)
    }

    func addWorkspace(host: String) {
        guard let store else { return }
        // Re-added server: restore the parked state verbatim — the same
        // workspace/pane ids make openPane's attach hit the panes still
        // running on the remote daemon (replay, titles, layout intact).
        if let idx = store.parked.lastIndex(where: { $0.sshHost == host }) {
            let workspace = store.parked.remove(at: idx)
            store.workspaces.append(workspace)
            store.focusedIndex = store.workspaces.count - 1
            runtime[workspace.id] = Runtime(state: .connecting)
            store.save()
            delegate?.coordinatorDidChange(.structure)
            return
        }
        let pane = PaneState(id: UUID().uuidString, cwd: nil)
        let workspace = WorkspaceState(
            id: UUID(), name: host,
            tabs: [TabState(id: UUID().uuidString, name: "1", panes: [pane])],
            focusedTabIndex: 0, sshHost: host)
        store.workspaces.append(workspace)
        // A new server becomes THE focused surface immediately — its
        // status page (connecting → shell) is what the user just asked
        // for by adding it.
        store.focusedIndex = store.workspaces.count - 1
        runtime[workspace.id] = Runtime(state: .connecting)
        store.save()
        delegate?.coordinatorDidChange(.structure)
    }

    /// `park: true` (Mode 1 remove: sessions keep running on the host)
    /// moves a remote workspace to the store's parked list instead of
    /// dropping it — pane ids survive, so re-adding the host reattaches.
    func teardownWorkspace(_ wsId: UUID, park: Bool = false) {
        runtime[wsId] = nil
        delegate?.retireHosts(workspace: wsId)
        guard let store else { return }
        if park, let idx = store.workspaces.lastIndex(where: { $0.id == wsId }),
           store.workspaces[idx].isRemote {
            store.parked.append(store.workspaces.remove(at: idx))
        } else {
            store.workspaces.removeAll { $0.id == wsId }
        }
        if store.workspaces.isEmpty {
            let pane = PaneState(id: UUID().uuidString, cwd: nil)
            store.workspaces.append(WorkspaceState(
                id: UUID(), name: "Local",
                tabs: [TabState(id: UUID().uuidString, name: "1", panes: [pane])],
                focusedTabIndex: 0, sshHost: nil))
        }
        if !store.workspaces.indices.contains(store.focusedIndex) { store.focusedIndex = 0 }
        store.save()
        delegate?.coordinatorDidChange(.structure)
    }

    func killWorkspace(_ wsId: UUID) {
        guard let workspace = store?.workspaces.first(where: { $0.id == wsId }) else { return }
        let ids = workspace.tabs.flatMap(\.panes).map {
            HostKey(workspace: wsId, pane: $0.id).runtimeId
        }
        let daemon = daemonFor?(workspace) ?? .shared
        DispatchQueue.global(qos: .userInitiated).async {
            for id in ids { daemon.killPane(id: id) }
        }
    }

    func newAgentTab(command: String = "claude") {
        appendTab(name: "agent", command: command, cwd: activeCwd())
    }

    func newTab() {
        appendTab(name: nil, command: nil, cwd: activeCwd())
    }

    /// A new space opened directly into a directory (the sidebar's
    /// per-space "+").
    func newTab(cwd: String?) {
        appendTab(name: nil, command: nil, cwd: cwd)
    }

    /// Space "+" → New Worktree (design: docs/specs/2026-08-23): create
    /// `<repo>-<name>` BESIDE the repo root with branch `<name>` from
    /// HEAD, then jump — the new space opens straight into the worktree
    /// directory. Root resolution rides `ScmStore` (cached, one round
    /// trip when cold); argv is pure in `WorktreeOp`.
    func createWorktree(name: String, cwd: String, host: String?,
                        completion: ((Result<String, ScmOpFailure>) -> Void)? = nil) {
        func create(root: String) {
            let target = WorktreePlan.target(root: root, name: name)
            ScmStore.shared.run(op: WorktreeOp.create(path: target, branch: name),
                                root: root, host: host) { [weak self] result in
                if case .success = result { self?.newTab(cwd: target) }
                completion?(result.map { _ in target })
            }
        }
        if let root = ScmStore.shared.repoRoot(cwd: cwd, host: host) {
            create(root: root)
        } else {
            ScmStore.shared.refreshStatus(cwd: cwd, host: host, force: true) { st in
                guard let root = st?.root else {
                    completion?(.failure(ScmOpFailure(op: "worktree",
                                                       detail: "not a git repository")))
                    return
                }
                create(root: root)
            }
        }
    }

    private func activeCwd() -> String? {
        guard let workspace = store?.focused else { return nil }
        return activePane(of: workspace)?.cwd
    }

    private func appendTab(name: String?, command: String?, cwd: String?) {
        guard let store, store.workspaces.indices.contains(store.focusedIndex) else { return }
        let wi = store.focusedIndex
        let pane = PaneState(id: UUID().uuidString, cwd: cwd)
        let number = store.workspaces[wi].tabs.count + 1
        store.workspaces[wi].tabs.append(TabState(
            id: UUID().uuidString, name: name ?? String(number), panes: [pane],
            paneCommand: command))
        store.workspaces[wi].focusedTabIndex = store.workspaces[wi].tabs.count - 1
        runtime[store.workspaces[wi].id, default: Runtime()].activePaneId = pane.id
        store.save()
        delegate?.coordinatorDidChange(.structure)
    }


    func splitPane(vertical: Bool, after: Bool = true) {
        guard let store, store.workspaces.indices.contains(store.focusedIndex) else { return }
        let wi = store.focusedIndex
        let ti = store.workspaces[wi].focusedTabIndex
        guard store.workspaces[wi].tabs.indices.contains(ti),
              !store.workspaces[wi].tabs[ti].panes.isEmpty else { return }
        let wsId = store.workspaces[wi].id
        let targetId = runtime[wsId]?.activePaneId
            ?? store.workspaces[wi].tabs[ti].panes[0].id
        guard let target = store.workspaces[wi].tabs[ti].panes.firstIndex(where: { $0.id == targetId }),
              let split = Self.splitCells(store.workspaces[wi].tabs[ti].panes,
                                          target: target, vertical: vertical, after: after)
        else { return }
        store.workspaces[wi].tabs[ti].panes = split.cells
        let frame = split.newFrame
        let pane = PaneState(id: UUID().uuidString, cwd: split.cells[target].cwd,
                             left: frame.left, top: frame.top,
                             width: frame.width, height: frame.height)
        store.workspaces[wi].tabs[ti].panes.append(pane)
        runtime[wsId, default: Runtime()].activePaneId = pane.id
        store.save()
        delegate?.coordinatorDidChange(.structure)
    }

    /// The split's geometry half: every cell doubles, the target is cut
    /// in half, and `after` picks which half the NEW pane takes (false =
    /// left/top — ghostty's Split Left/Up directions). Pure so the
    /// headless suite can pin all four directions.
    static func splitCells(_ cells: [PaneState], target: Int,
                           vertical: Bool, after: Bool)
        -> (cells: [PaneState], newFrame: (left: Int, top: Int, width: Int, height: Int))? {
        guard cells.indices.contains(target) else { return nil }
        var cells = cells
        for i in cells.indices {
            if vertical { cells[i].top *= 2; cells[i].height *= 2 }
            else { cells[i].left *= 2; cells[i].width *= 2 }
        }
        let old = cells[target]
        if vertical {
            let half = old.height / 2
            if after { cells[target].height = half }
            else { cells[target].top = old.top + half; cells[target].height = half }
            return (cells, (old.left, after ? old.top + half : old.top,
                            old.width, half))
        } else {
            let half = old.width / 2
            if after { cells[target].width = half }
            else { cells[target].left = old.left + half; cells[target].width = half }
            return (cells, (after ? old.left + half : old.left, old.top,
                            half, old.height))
        }
    }

    func paneExited(wsId: UUID, paneId: String) {
        guard let store,
              let wi = store.workspaces.firstIndex(where: { $0.id == wsId }) else { return }
        let runtimeId = HostKey(workspace: wsId, pane: paneId).runtimeId
        let daemon = daemonFor?(store.workspaces[wi]) ?? .shared
        DispatchQueue.global(qos: .utility).async {
            daemon.killPane(id: runtimeId)
        }
        delegate?.retireHost(HostKey(workspace: wsId, pane: paneId))
        runtime[wsId]?.agents[paneId] = nil
        guard let ti = store.workspaces[wi].tabs.firstIndex(where: {
            $0.panes.contains(where: { $0.id == paneId })
        }), let pi = store.workspaces[wi].tabs[ti].panes.firstIndex(where: { $0.id == paneId })
        else { return }
        store.workspaces[wi].tabs[ti].panes.remove(at: pi)
        if store.workspaces[wi].tabs[ti].panes.isEmpty {
            store.workspaces[wi].tabs.remove(at: ti)
        }
        ensureWorkspaceHasTab(index: wi)
        store.save()
        delegate?.coordinatorDidChange(.structure)
    }

    func closeTab() {
        guard let workspace = store?.focused else { return }
        closeTab(index: workspace.focusedTabIndex)
    }

    func closeTab(index: Int) {
        guard let store, store.workspaces.indices.contains(store.focusedIndex),
              store.workspaces[store.focusedIndex].tabs.indices.contains(index) else { return }
        let wi = store.focusedIndex
        let workspace = store.workspaces[wi]
        let paneIds = workspace.tabs[index].panes.map {
            HostKey(workspace: workspace.id, pane: $0.id).runtimeId
        }
        for pane in workspace.tabs[index].panes {
            runtime[workspace.id]?.agents[pane.id] = nil
        }
        store.workspaces[wi].tabs.remove(at: index)
        ensureWorkspaceHasTab(index: wi)
        store.workspaces[wi].focusedTabIndex = min(index, store.workspaces[wi].tabs.count - 1)
        store.save()
        delegate?.coordinatorDidChange(.structure)
        let daemon = daemonFor?(workspace) ?? .shared
        DispatchQueue.global(qos: .userInitiated).async {
            for id in paneIds { daemon.killPane(id: id) }
        }
    }

    private func ensureWorkspaceHasTab(index: Int) {
        guard let store, store.workspaces.indices.contains(index),
              store.workspaces[index].tabs.isEmpty else { return }
        let pane = PaneState(id: UUID().uuidString, cwd: nil)
        store.workspaces[index].tabs = [TabState(
            id: UUID().uuidString, name: "1", panes: [pane])]
        store.workspaces[index].focusedTabIndex = 0
        runtime[store.workspaces[index].id, default: Runtime()].activePaneId = pane.id
    }

    /// Rename sets the USER title (ghostty rule): it outranks the
    /// program's OSC title until cleared. Empty string = clear, back to
    /// the program's own title. `name` stays the default counter.
    func renameTab(index: Int, name: String) {
        guard let store, store.workspaces.indices.contains(store.focusedIndex),
              store.workspaces[store.focusedIndex].tabs.indices.contains(index) else { return }
        store.workspaces[store.focusedIndex].tabs[index].userTitle =
            name.isEmpty ? nil : name
        store.save()
        delegate?.coordinatorDidChange(.title)
    }

    func setTabIcon(index: Int, symbol: String?) {
        guard let store, store.workspaces.indices.contains(store.focusedIndex),
              store.workspaces[store.focusedIndex].tabs.indices.contains(index) else { return }
        store.workspaces[store.focusedIndex].tabs[index].icon = symbol
        store.save()
        delegate?.coordinatorDidChange(.structure)
    }

    func setTabColor(index: Int, hex: String?) {
        guard let store, store.workspaces.indices.contains(store.focusedIndex),
              store.workspaces[store.focusedIndex].tabs.indices.contains(index) else { return }
        store.workspaces[store.focusedIndex].tabs[index].color = hex
        store.save()
        delegate?.coordinatorDidChange(.structure)
    }
}

protocol WorkspaceCoordinatorDelegate: AnyObject {
    /// What changed — the UI re-renders only that domain.
    func coordinatorDidChange(_ domain: WorkspaceCoordinator.ChangeDomain)
    /// Every PaneHost of a workspace (workspace torn down / disconnected).
    func retireHosts(workspace: UUID)
    /// One PaneHost (its pane died).
    func retireHost(_ key: HostKey)
}
