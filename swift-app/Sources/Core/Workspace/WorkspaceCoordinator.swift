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
        /// The side pane the user last clicked — its cwd drives the
        /// panel header and the cd chip targets it. Falls back to the
        /// first pane; volatile.
        var auxFocusedPaneId: String?
        /// The side terminal was explicitly closed (strip button or the
        /// last pane's exit): the auto-create gate stays closed until
        /// the user asks again — "空态不自动重生" (spec §2). An empty
        /// array alone cannot tell "never opened" from "closed".
        var auxClosed = false
    }
    private var runtime: [UUID: Runtime] = [:]
    var onSendText: ((HostKey, String) -> Void)?

    /// Agent status of one pane, with the "done until seen" bit:
    /// an agent that finished while its tab was not focused stays green
    /// until the user opens it.
    struct AgentPaneRuntime: Equatable {
        var state: AgentActivity = .unknown
        /// The agent process's OWN report ("working"/"blocked"/"idle"
        /// via its extension to the daemon) — the authority. Survives
        /// client restarts and never guesses. nil = nothing reported.
        var reported: AgentActivity? = nil
        var seen = true
        /// Live foreground command (sessiond list reply); nil = whatever
        /// the pane was spawned with is authoritative.
        var command: String?
        /// Background async-job rows (extension report, capability 6);
        /// the agent pane's jobs dock renders exactly these.
        var jobs: [AgentJobSnapshot] = []


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
            // The turn finished where nobody was looking — the app-level
            // hook decides (dock bounce when inactive). Core stays AppKit-free.
            if next.seen == false, previous.seen {
                turnCompletedUnseen?(wsId, paneId)
            }
        }
        guard next != previous else { return }
        runtime[wsId]!.agents[paneId] = next
        // The badge MUST re-render on every state change. It used to
        // freeze on "working": the sidebar only re-renders on
        // coordinatorDidChange, which the daemon list loop only fires
        // when the extension report changes — a client-derived
        // working→idle transition never repainted the row (2026-08-31).
        delegate?.coordinatorDidChange(.agent)
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

    /// The agent process's own report (extension → daemon), the
    /// authoritative working switch for the pane's composer. nil = the
    /// process never reported (older daemon, non-instrumented agent).
    func reportedActivity(wsId: UUID, paneId: String) -> AgentActivity? {
        runtime[wsId]?.agents[paneId]?.reported
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
        // Host-less agent panes whose session title is still unknown:
        // one store listing per dialect resolves them without spawning
        // anything (capability 7). Panes are remembered once attempted
        // so a title-less session costs one call per GUI run, not one
        // per poll. The store snapshot (agentSessionId) is read here on
        // the main thread; the daemon round trips run below.
        var storeTitleCalls: [(UUID, SessionDaemon,
                               [(paneId: String, storeKey: String, sessionId: String)])] = []
        for (ws, daemon) in targets {
            var gaps: [(paneId: String, storeKey: String, sessionId: String)] = []
            for pane in ws.tabs.flatMap(\.panes) {
                guard case .agent(let agentKey) = pane.kind,
                      let storeKey = AgentRegistry.descriptor(for: agentKey)?.storeListKey,
                      let sessionId = pane.agentSessionId, !sessionId.isEmpty,
                      !titlePrefetched[ws.id, default: []].contains(pane.id),
                      hasLiveHost?(HostKey(workspace: ws.id, pane: pane.id)) != true
                else { continue }
                gaps.append((paneId: pane.id, storeKey: storeKey, sessionId: sessionId))
            }
            if !gaps.isEmpty {
                storeTitleCalls.append((ws.id, daemon, gaps))
            }
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var cwdResult: (UUID, [String: String])?
            var fgResults: [(UUID, [String: String], [String: String])] = []
            var jobResults: [(UUID, [String: [AgentJobSnapshot]])] = []
            var titleResults: [(UUID, [String: String])] = []
            var storeTitles: [(UUID, String, String)] = []  // (wsId, paneId, title)
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
                var jobs: [String: [AgentJobSnapshot]] = [:]
                var titles: [String: String] = [:]
                for info in panes {
                    // Daemon ids are "<workspace>_<pane>"; keep the pane half.
                    if let pane = info.id.split(separator: "_", maxSplits: 1).last {
                        if let command = info.fg {
                            fg[String(pane)] = command
                        }
                        if let agent = info.agent {
                            agents[String(pane)] = agent
                        }
                        if let title = info.title, !title.isEmpty {
                            titles[String(pane)] = title
                        }
                        jobs[String(pane)] = info.agentJobs
                    }
                }
                if !titles.isEmpty {
                    titleResults.append((ws.id, titles))
                }
                fgResults.append((ws.id, fg, agents))
                jobResults.append((ws.id, jobs))
            }
            // Agent-store titles: one SESSION_LIST per (workspace,
            // dialect), matched by each gap pane's persisted session id.
            for (wsId, daemon, gaps) in storeTitleCalls {
                let byStore = Dictionary(grouping: gaps, by: \.storeKey)
                for (storeKey, panes) in byStore {
                    guard let (rows, _) = daemon.agentStoreSummaries(cwd: nil, store: storeKey)
                    else { continue }
                    let titlesById = Dictionary(rows.map { ($0.summary.sessionId,
                                                            $0.summary.title) },
                                                uniquingKeysWith: { a, _ in a })
                    for pane in panes {
                        if let title = titlesById[pane.sessionId],
                           let title, !title.isEmpty {
                            storeTitles.append((wsId, pane.paneId, title))
                        }
                    }
                }
            }
            DispatchQueue.main.async { [weak self] in
                if let (wsId, byRuntimeId) = cwdResult {
                    self?.applyCwds(wsId: wsId, byRuntimeId: byRuntimeId)
                }
                self?.applyForegrounds(fgResults)
                self?.applyJobs(jobResults)
                self?.applyPaneTitles(titleResults)
                for (wsId, _, gaps) in storeTitleCalls {
                    for pane in gaps {
                        self?.titlePrefetched[wsId, default: []].insert(pane.paneId)
                    }
                }
                for (_, paneId, title) in storeTitles {
                    self?.setAgentTabTitle(paneId: paneId, name: title)
                }
            }
        }
    }

    /// Pane titles mined from the daemon's LIST reply (OSC scan of the
    /// ring tail): fills the volatile title table for panes THIS GUI
    /// run has never attached a host to — after a restart every
    /// terminal tab's title is otherwise lost until reopened. A live
    /// host's own OSC parse stays the authority: daemon values never
    /// overwrite panes that have one.
    func applyPaneTitles(_ results: [(UUID, [String: String])]) {
        var changed = false
        for (wsId, titles) in results {
            guard runtime[wsId] != nil else { continue }
            for (paneId, title) in titles where !title.isEmpty {
                guard runtime[wsId]!.titles[paneId] == nil,
                      hasLiveHost?(HostKey(workspace: wsId, pane: paneId)) != true
                else { continue }
                runtime[wsId]!.titles[paneId] = title
                changed = true
            }
        }
        if changed, wsIdFocused(resultWorkspaces: results.map(\.0)) {
            delegate?.coordinatorDidChange(.title)
        }
    }

    private func wsIdFocused(resultWorkspaces: [UUID]) -> Bool {
        guard let focused = store?.focused?.id else { return false }
        return resultWorkspaces.contains(focused)
    }

    /// Jobs dock data (capability 6): per-pane background async-job
    /// rows from the same LIST reply. Separate from applyForegrounds
    /// so the headless layout tests' seeded fg calls stay valid.

    /// Whether a pane currently has a live host (the app layer owns the
    /// pool). Daemon-side fills (titles, store titles) never overwrite
    /// a pane a host is actively serving.
    var hasLiveHost: ((HostKey) -> Bool)?
    /// Agent panes whose store title was already looked up this GUI run
    /// (hit or miss — a miss costs nothing on later polls).
    private var titlePrefetched: [UUID: Set<String>] = [:]

    func applyJobs(_ results: [(UUID, [String: [AgentJobSnapshot]])]) {
        guard let store else { return }
        var changed = false
        for (wsId, jobs) in results {
            guard runtime[wsId] != nil,
                  let wi = store.workspaces.firstIndex(where: { $0.id == wsId }) else { continue }
            let paneIds = store.workspaces[wi].tabs.flatMap { $0.panes }.map(\.id)
                + store.workspaces[wi].auxTerminalPanes.map(\.id)
            for paneId in paneIds {
                guard let rows = jobs[paneId] else { continue }
                var entry = runtime[wsId]!.agents[paneId] ?? AgentPaneRuntime()
                guard entry.jobs != rows else { continue }
                entry.jobs = rows
                runtime[wsId]!.agents[paneId] = entry
                changed = true
            }
        }
        if changed {
            delegate?.coordinatorDidChange(.agent)
        }
    }

    /// The pane's live background-job rows (extension → daemon LIST).
    func agentJobs(wsId: UUID, paneId: String) -> [AgentJobSnapshot] {
        runtime[wsId]?.agents[paneId]?.jobs ?? []
    }

    // Internal (not private): the headless layout tests seed fg reports
    // straight in (spec 2026-08-30 §8) — pollDaemonLists needs a live
    // daemon, which a pure coordinator fixture doesn't have.
    func applyForegrounds(_ results: [(UUID, [String: String], [String: String])]) {
        guard let store else { return }
        var changed = false
        var identityChanges: [(HostKey, String?)] = []
        for (wsId, fg, agents) in results {
            guard runtime[wsId] != nil,
                  let wi = store.workspaces.firstIndex(where: { $0.id == wsId }) else { continue }
            // The side terminal's panes join the same identity loop
            // (their fg drives the @ai trigger arming); they are in NO
            // tab, so they are appended to the walked pane ids.
            let paneIds = store.workspaces[wi].tabs.flatMap { $0.panes }.map(\.id)
                + store.workspaces[wi].auxTerminalPanes.map(\.id)
            for paneId in paneIds {
                var entry = runtime[wsId]!.agents[paneId] ?? AgentPaneRuntime()
                let newCommand = fg[paneId]
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
                    identityChanges.append((HostKey(workspace: wsId, pane: paneId), newCommand))
                }
                // The omp/pi extension reports the authoritative TUI
                // state through its owning daemon — it outranks the
                // passive screen tracker whenever it speaks.
                if let reported = agents[paneId],
                   let activity = AgentActivity(reported),
                   entry.reported != activity {
                    // Live work is always seen (the host path's rule).
                    // A finish while nobody was looking keeps the "done"
                    // dot until the tab opens — the extension path used
                    // to mark everything seen, so background panes never
                    // surfaced their completions.
                    if activity != .idle {
                        entry.seen = true
                    } else if entry.reported == .working || entry.reported == .blocked {
                        let focused = isPaneFocused(wsId: wsId, paneId: paneId)
                        if !focused, entry.seen {
                            turnCompletedUnseen?(wsId, paneId)
                        }
                        entry.seen = focused
                    }
                    entry.reported = activity
                    entryChanged = true
                }
                guard entryChanged else { continue }
                runtime[wsId]!.agents[paneId] = entry
                changed = true
            }
        }
        guard changed else { return }
        delegate?.coordinatorDidChange(.agent)
        onForegroundChange?(identityChanges)
    }

    /// (pane, fg command) pairs whose identity changed — the delegate
    /// layer forwards them to the owning PaneHosts.
    var onForegroundChange: (([(HostKey, String?)]) -> Void)?

    /// A turn finished in an UNFOCUSED pane (seen=false transition) —
    /// the app layer decides what attention means (dock bounce when
    /// inactive). Fired at most once per completion.
    var turnCompletedUnseen: ((UUID, String) -> Void)?

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
                  .first(where: { $0.id == key.pane })
                  ?? ws.auxTerminalPanes.first(where: { $0.id == key.pane })
        else { return nil }
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


    // Internal (not private): same test seam as applyForegrounds — the
    // headless suite seeds cwd reports straight in.
    func applyCwds(wsId: UUID, byRuntimeId: [String: String]) {
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
        // The side terminal's panes track their cwd in the same store
        // field as tab panes — a split inherits the SOURCE pane's live
        // cwd, so the report must be persisted before the gesture reads
        // it. Same list reply, one more consumer.
        for pi in store.workspaces[wi].auxTerminalPanes.indices {
            let pane = store.workspaces[wi].auxTerminalPanes[pi]
            let runtimeId = HostKey(workspace: wsId, pane: pane.id).runtimeId
            guard let cwd = byRuntimeId[runtimeId], pane.cwd != cwd else { continue }
            store.workspaces[wi].auxTerminalPanes[pi].cwd = cwd
            changed = true
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

    /// Every daemon-side pane id one workspace owns: the tabs' panes
    /// plus the side terminal, which is in NO tab (spec 2026-08-30) —
    /// the kill path and the layout tests share this list.
    func paneRuntimeIds(of workspace: WorkspaceState) -> [String] {
        let tabIds = workspace.tabs.flatMap(\.panes).map {
            HostKey(workspace: workspace.id, pane: $0.id).runtimeId
        }
        return tabIds + workspace.auxTerminalPanes.map {
            HostKey(workspace: workspace.id, pane: $0.id).runtimeId
        }
    }

    func killWorkspace(_ wsId: UUID) {
        guard let workspace = store?.workspaces.first(where: { $0.id == wsId }) else { return }
        let ids = paneRuntimeIds(of: workspace)
        let daemon = daemonFor?(workspace) ?? .shared
        DispatchQueue.global(qos: .userInitiated).async {
            for id in ids { daemon.killPane(id: id) }
        }
    }

    func newAgentTab(command: String = "claude") {
        appendTab(name: "agent", command: command, cwd: activeCwd())
    }

    /// Initial prompts queued for agent panes not yet built (the host
    /// factory drains them when the pane's AgentPaneHost is created).
    private var pendingAgentPrompts: [String: String] = [:]

    /// New GUI agent session (M1: omp, local daemon only). The caller
    /// gates on SessionDaemon.supportsAgentSessions().
    func newAgentSessionTab(agent: String = "omp", cwd: String? = nil,
                            initialPrompt: String? = nil) {
        if let paneId = appendTab(name: agent, command: agent,
                                  cwd: cwd ?? activeCwd(), kind: .agent(agent)),
           let prompt = initialPrompt, !prompt.isEmpty {
            pendingAgentPrompts[paneId] = prompt
        }
    }

    /// The tracked cwd of one pane, or nil — the `@omp`-style trigger
    /// resolves the new space's directory from the pane that fired it.
    func cwd(ofPane paneId: String, in workspaceId: UUID) -> String? {
        guard let ws = store?.workspaces.first(where: { $0.id == workspaceId }) else { return nil }
        for tab in ws.tabs {
            if let pane = tab.panes.first(where: { $0.id == paneId }) { return pane.cwd }
        }
        // The side terminal's panes are in no tab — same resolution,
        // one more list (the @omp trigger's launch directory).
        return ws.auxTerminalPanes.first(where: { $0.id == paneId })?.cwd
    }

    /// The host factory takes (and clears) a queued initial prompt.
    func takeInitialPrompt(paneId: String) -> String? {
        pendingAgentPrompts.removeValue(forKey: paneId)
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

    @discardableResult
    private func appendTab(name: String?, command: String?, cwd: String?,
                           kind: PaneKind = .terminal,
                           agentSessionId: String? = nil) -> String? {
        guard let store, store.workspaces.indices.contains(store.focusedIndex) else { return nil }
        let wi = store.focusedIndex
        var pane = PaneState(id: UUID().uuidString, cwd: cwd, kind: kind)
        // Seed BEFORE the structure change: the delegate builds the
        // agent host synchronously on that notify, and the host reads
        // agentSessionId to pick its restore target.
        pane.agentSessionId = agentSessionId
        let number = store.workspaces[wi].tabs.count + 1
        store.workspaces[wi].tabs.append(TabState(
            id: UUID().uuidString, name: name ?? String(number), panes: [pane],
            paneCommand: command))
        store.workspaces[wi].focusedTabIndex = store.workspaces[wi].tabs.count - 1
        runtime[store.workspaces[wi].id, default: Runtime()].activePaneId = pane.id
        store.save()
        delegate?.coordinatorDidChange(.structure)
        return pane.id
    }

    /// gooey-pi-style branch landing: a NEW agent tab restored onto a
    /// forked session file. The originating pane stays on its original
    /// conversation.
    @discardableResult
    func openAgentBranchTab(agent: String, cwd: String?, sessionId: String) -> String? {
        appendTab(name: agent, command: agent, cwd: cwd ?? activeCwd(),
                  kind: .agent(agent), agentSessionId: sessionId)
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
        // The side terminal's panes never live in a tab — route them to
        // their own teardown first; the tab walk below would silently
        // no-op on them.
        if store.workspaces[wi].auxTerminalPanes.contains(where: { $0.id == paneId }) {
            auxTerminalExited(wsId: wsId, paneId: paneId)
            return
        }
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

    // MARK: Side terminal (right panel; spec 2026-08-30)

    /// Materialize the FOCUSED workspace's first side-terminal pane.
    /// Splits never land here (splitAuxTerminal appends); an existing
    /// terminal is returned untouched — the daemon owns the sessions,
    /// "ensure" never respawns. The spawn cwd is resolved by the delegate
    /// layer when it builds the host (same structure pass); only the pane
    /// is persisted.
    @discardableResult
    func ensureAuxTerminal() -> String? {
        guard let store, store.workspaces.indices.contains(store.focusedIndex) else { return nil }
        let wi = store.focusedIndex
        // Reopening always un-gates auto-create — the closed flag marks
        // "the user said no"; an explicit ensure IS the user saying yes.
        runtime[store.workspaces[wi].id, default: Runtime()].auxClosed = false
        if let existing = store.workspaces[wi].auxTerminalPanes.first { return existing.id }
        let pane = PaneState(id: UUID().uuidString, cwd: nil)
        store.workspaces[wi].auxTerminalPanes = [pane]
        store.save()
        delegate?.coordinatorDidChange(.structure)
        return pane.id
    }

    /// The auto-create gate's other half (spec §2): a closed terminal
    /// stays closed — only "never opened" (or reopened) auto-creates.
    func auxTerminalClosed(wsId: UUID) -> Bool {
        runtime[wsId]?.auxClosed ?? false
    }

    /// A click landed in one of the panel's panes: it becomes the pane
    /// the header speaks for (cwd label + cd chip target).
    func focusAuxPane(wsId: UUID, paneId: String) {
        runtime[wsId, default: Runtime()].auxFocusedPaneId = paneId
        delegate?.coordinatorDidChange(.cwd)
    }

    /// The side pane the header speaks for: the last clicked one,
    /// falling back to the first (fresh terminal, nothing focused yet).
    func focusedAuxPane(of ws: WorkspaceState) -> PaneState? {
        if let id = runtime[ws.id]?.auxFocusedPaneId,
           let pane = ws.auxTerminalPanes.first(where: { $0.id == id }) { return pane }
        return ws.auxTerminalPanes.first
    }

    /// cd chip gate: the focused side pane sits at a shell prompt — the
    /// injection types into the user's command line, which must not be
    /// mid-vim/mid-run. Same predicate as PaneHost's @ai arming.
    func auxTerminalAtPrompt(wsId: UUID) -> Bool {
        guard let ws = store?.workspaces.first(where: { $0.id == wsId }),
              let pane = focusedAuxPane(of: ws) else { return false }
        return Shell.isShellPromptCommand(runtime[wsId]?.agents[pane.id]?.command)
    }

    /// The cd chip's payload: clear-line + quoted cd + enter — the
    /// same clear-then-inject shape as handleAITrigger (a half-typed
    /// line must never absorb the injection). Pure for the headless
    /// suite to pin byte-for-byte.
    static func auxCdInjection(to path: String) -> String {
        "\u{15}cd \(Shell.forceQuoted(path))\r"
    }

    /// A ghostty split request from one of the side terminal's panes:
    /// same geometry math as a center split, but on the aux pane array.
    /// The new pane inherits the SOURCE pane's live cwd (applyCwds
    /// keeps it current), so the split opens right beside its origin.
    func splitAuxTerminal(wsId: UUID, paneId: String, vertical: Bool, after: Bool) {
        guard let store,
              let wi = store.workspaces.firstIndex(where: { $0.id == wsId }),
              let target = store.workspaces[wi].auxTerminalPanes
                  .firstIndex(where: { $0.id == paneId }),
              let split = Self.splitCells(store.workspaces[wi].auxTerminalPanes,
                                          target: target, vertical: vertical, after: after)
        else { return }
        store.workspaces[wi].auxTerminalPanes = split.cells
        let frame = split.newFrame
        store.workspaces[wi].auxTerminalPanes.append(
            PaneState(id: UUID().uuidString, cwd: split.cells[target].cwd,
                      left: frame.left, top: frame.top,
                      width: frame.width, height: frame.height))
        store.save()
        delegate?.coordinatorDidChange(.structure)
    }

    /// One side-terminal pane died (EXITED frame, error path). Removed
    /// from the array — siblings keep running; an emptied array is the
    /// panel's empty state. Nothing else in the workspace is touched.
    func auxTerminalExited(wsId: UUID, paneId: String) {
        guard let store,
              let wi = store.workspaces.firstIndex(where: { $0.id == wsId }),
              let pi = store.workspaces[wi].auxTerminalPanes
                  .firstIndex(where: { $0.id == paneId }) else { return }
        let runtimeId = HostKey(workspace: wsId, pane: paneId).runtimeId
        let daemon = daemonFor?(store.workspaces[wi]) ?? .shared
        DispatchQueue.global(qos: .utility).async {
            daemon.killPane(id: runtimeId)
        }
        delegate?.retireHost(HostKey(workspace: wsId, pane: paneId))
        runtime[wsId]?.agents[paneId] = nil
        if runtime[wsId]?.auxFocusedPaneId == paneId {
            runtime[wsId]?.auxFocusedPaneId = nil   // header falls back to pane 0
        }
        store.workspaces[wi].auxTerminalPanes.remove(at: pi)
        if store.workspaces[wi].auxTerminalPanes.isEmpty {
            // The last pane's exit IS a close (spec §2): empty state,
            // no auto-respawn.
            runtime[wsId]?.auxClosed = true
        }
        store.save()
        delegate?.coordinatorDidChange(.structure)
    }

    /// The panel's close button: the whole side terminal (every pane)
    /// goes, with one confirm at the delegate layer.
    func closeAuxTerminal(wsId: UUID) {
        guard let ws = store?.workspaces.first(where: { $0.id == wsId }) else { return }
        for pane in ws.auxTerminalPanes {
            auxTerminalExited(wsId: wsId, paneId: pane.id)
        }
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

    /// Live agent-session title for the tab that hosts `paneId`. Unlike
    /// renameTab (user override), this follows the session automatically
    /// — new session, history load, omp's post-turn auto-naming — and
    /// never touches userTitle. Searches every workspace: the pane's
    /// tab need not be focused for its title to stay current.
    func setAgentTabTitle(paneId: String, name: String?) {
        guard let store else { return }
        let clean = name?.trimmingCharacters(in: .whitespaces)
        let value = (clean?.isEmpty == false) ? clean : nil
        for wi in store.workspaces.indices {
            guard let ti = store.workspaces[wi].tabs.firstIndex(where: {
                $0.panes.contains { $0.id == paneId }
            }) else { continue }
            guard store.workspaces[wi].tabs[ti].agentTitle != value else { return }
            store.workspaces[wi].tabs[ti].agentTitle = value
            store.save()
            delegate?.coordinatorDidChange(.title)
            return
        }
    }


    /// Agent pane: persist the session the user last had loaded here so
    /// reopening the app re-loads the SAME conversation. Same walk as
    /// setAgentTabTitle — the pane's tab need not be focused.
    func setAgentSessionId(paneId: String, sessionId: String?) {
        guard let store else { return }
        for wi in store.workspaces.indices {
            guard let ti = store.workspaces[wi].tabs.firstIndex(where: {
                $0.panes.contains { $0.id == paneId }
            }) else { continue }
            guard let pi = store.workspaces[wi].tabs[ti].panes.firstIndex(where: { $0.id == paneId })
            else { continue }
            guard store.workspaces[wi].tabs[ti].panes[pi].agentSessionId != sessionId else { return }
            store.workspaces[wi].tabs[ti].panes[pi].agentSessionId = sessionId
            store.save()
            return
        }
    }

    /// Agent pane: persist the queued-outbox texts (dock queue list) so
    /// a restart can rebuild what omp only reports as a count. Same
    /// walk as setAgentSessionId; empty list stores nil (lean state).
    func setAgentQueuedOutbox(paneId: String, texts: [String]) {
        guard let store else { return }
        let value = texts.isEmpty ? nil : texts
        for wi in store.workspaces.indices {
            guard let ti = store.workspaces[wi].tabs.firstIndex(where: {
                $0.panes.contains { $0.id == paneId }
            }) else { continue }
            guard let pi = store.workspaces[wi].tabs[ti].panes.firstIndex(where: { $0.id == paneId })
            else { continue }
            guard store.workspaces[wi].tabs[ti].panes[pi].agentQueuedOutbox != value else { return }
            store.workspaces[wi].tabs[ti].panes[pi].agentQueuedOutbox = value
            store.save()
            return
        }
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
