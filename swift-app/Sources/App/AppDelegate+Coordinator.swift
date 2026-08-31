// goty — see CLAUDE.md for the working principles.
import GhosttyKit
import AppKit

extension AppDelegate {

    // MARK: Coordinator delegate — the only logic→UI seam

    func coordinatorDidChange(_ domain: WorkspaceCoordinator.ChangeDomain) {
        switch domain {
        case .structure:
            refresh()
            // Structure events rebuild the visible pane set only. Grid
            // changes flow per pane: PaneHost.layout emits a Resize marker
            // on its own sessiond stream when its settled grid changes,
            // so nothing window-level is pushed here.
        case .connection:
            // Connection-owned surfaces ONLY: the sidebar's status dots
            // and the focused workspace's offline cover. No grid
            // rebuild, no focus claim — a background retry (10s cadence
            // on an unreachable host) must not be able to touch what a
            // user is editing somewhere else in the window.
            refreshConnectionChrome()
        case .cwd:
            updateRightPanel()   // cheap path — no pane-grid rebuild
            refreshSidebarSpaces()   // grouping follows directory changes
        case .git:
            gitSurfacesStale()   // branch/counts + Git tab + tree badges
        case .agent:
            refreshSidebarSpaces()   // status dots only — no pane-grid churn
            updateRightPanel()
            pushReportedAgentStates()   // the composer follows the process
        case .title:
            refreshSidebarSpaces()   // display name only — cheapest path
        }
    }

    func retireHosts(workspace: UUID) {
        for (key, host) in hostPool where key.workspace == workspace {
            cancelAITasks(pane: key)
            host.retire()
            hostPool.removeValue(forKey: key)
        }
    }

    func retireHost(_ key: HostKey) {
        cancelAITasks(pane: key)
        hostPool[key]?.retire()
        hostPool.removeValue(forKey: key)
    }

    /// Closing a pane cancels its AI tasks — task ownership must not
    /// outlive the pane it was started from (spec acceptance #10); a
    /// leaked task would keep burning model rounds against a host key
    /// that no longer resolves to a card.
    private func cancelAITasks(pane key: HostKey) {
        for (id, paneKey) in activeAIPane where paneKey == key {
            aiTaskOwner[id]?.cancel(taskId: id)
            activeAIPane.removeValue(forKey: id)
            aiTaskOwner.removeValue(forKey: id)
        }
    }

    func refresh() {
        guard let store = coordinator.store, let ws = store.focused,
              let gapp = ghostty.app else { return }
        // Panes created before the store knew about them armed with a nil
        // target; every store pass is a free re-arm (idle panes never see
        // another foreground report, so the stale unarmed state stuck —
        // "@ai works in one pane, not another").
        for case let host as PaneHost in hostPool.values { host.refreshAITrigger() }
        let titleText = "Goty — \(ws.displayName)"
        window?.title = titleText
        wc.setChromeTitle(titleText)
        // Assigning .title resets titleVisibility on this macOS build —
        let state0 = coordinator.wsStates[ws.id] ?? .connecting
        renderTabSurfaces(ws: ws, offline: state0 == .disconnected)
        updateRightPanel()
        wc.sidebar.renderWorkspaces(store.workspaces, focusedIndex: store.focusedIndex,
                                  states: coordinator.wsStates)


        // Server status page: a remote workspace that isn't connected
        // covers the terminal region — connecting (just added or
        if ws.isRemote, state0 != .connected {
            wc.terminalArea.presentOverlay(
                ServerStatusView(wsName: ws.displayName,
                                 phase: state0 == .disconnected ? .unreachable : .connecting) { [weak self] in
                    self?.reconnectRemote(wsId: ws.id)
                })
            return
        }
        // Only OUR cover — never whatever the editor put here.
        wc.terminalArea.dismissOverlay(kind: .offline)
        guard let tab = ws.focusedTab else { return }

        // The daemon, not the view tree, keeps sessions alive. Preserve hosts
        // that have already been shown (zero-flicker tab return), but never
        // create an unseen pane at a fake 80×24 geometry: full-screen TUIs
        // repaint that placeholder frame into history before their real split
        // size arrives, producing duplicated app frames.
        let liveKeys = Set(store.workspaces.flatMap { workspace in
            workspace.tabs.flatMap { tab in
                tab.panes.map { HostKey(workspace: workspace.id, pane: $0.id) }
            }
        })
        let keepAlive = hostPool.compactMap { key, host in
            liveKeys.contains(key) ? host : nil
        }
        var entries: [(paneKey: HostKey, host: any PaneHosting, fraction: NSRect)] = []
        let panes = tab.panes.filter { !$0.id.isEmpty }
        if panes.count == 1 {
            if let host = makePaneHost(pane: panes[0], ws: ws, gapp: gapp) {
                entries.append((paneKey: host.hostKey, host: host,
                                fraction: NSRect(x: 0, y: 0, width: 1, height: 1)))
            }
        } else {
            // Normalize persisted split-cell geometry into layout fractions.
            let gridW = max(panes.map { $0.left + $0.width }.max() ?? 1, 1)
            let gridH = max(panes.map { $0.top + $0.height }.max() ?? 1, 1)
            for pane in panes {
                if let host = makePaneHost(pane: pane, ws: ws, gapp: gapp) {
                    entries.append((paneKey: host.hostKey, host: host, fraction: NSRect(
                        x: CGFloat(pane.left) / CGFloat(gridW),
                        y: CGFloat(pane.top) / CGFloat(gridH),
                        width: CGFloat(pane.width) / CGFloat(gridW),
                        height: CGFloat(pane.height) / CGFloat(gridH)
                    )))
                }
            }
        }
        wc.terminalArea.paneGrid.setVisiblePanes(entries, keepAlive: keepAlive)
        // Focus is NOT claimed here: refresh() runs for background
        // domains too (replays, reconnects). Focus follows user intent
        // only — launch, clicking a pane, closing the editor.
    }

    /// Both tab surfaces of the focused workspace — the sidebar's
    /// Spaces list and the terminal region's top strip — fed the same
    /// resolvers from one pass.
    private func renderTabSurfaces(ws: WorkspaceState, offline: Bool) {
        wc.sidebar.render(workspace: ws, offline: offline,
                          gitFor: { cwd in
                              GitStatusStore.shared.summary(for: cwd, host: ws.sshHost)
                          },
                          spaceRoot: { cwd in
                              GitStatusStore.shared.spaceRoot(for: cwd, host: ws.sshHost)
                          },
                          statusFor: spaceStatus,
                          commandFor: { [coordinator] tab in coordinator.effectiveCommand(for: tab) },
                          titleFor: { [coordinator] tab in coordinator.surfaceTitle(for: tab) })
        wc.terminalArea.tabStrip.render(
            workspace: ws, offline: offline,
            commandFor: { [coordinator] tab in coordinator.effectiveCommand(for: tab) },
            titleFor: { [coordinator] tab in coordinator.surfaceTitle(for: tab) })
    }
    func refreshConnectionChrome() {
        guard let store = coordinator.store, let ws = store.focused else { return }
        let state = coordinator.wsStates[ws.id] ?? .connecting
        wc.sidebar.renderWorkspaces(store.workspaces, focusedIndex: store.focusedIndex,
                                    states: coordinator.wsStates)
        if ws.isRemote, state != .connected {
            // Swap our own cover (unreachable → connecting on a manual
            if !wc.terminalArea.isShowingOverlay || wc.terminalArea.overlayKind == .offline {
                wc.terminalArea.presentOverlay(
                    ServerStatusView(wsName: ws.displayName,
                                     phase: state == .disconnected ? .unreachable : .connecting) { [weak self] in
                        self?.reconnectRemote(wsId: ws.id)
                    }, kind: .offline)
            }
        } else {
            wc.terminalArea.dismissOverlay(kind: .offline)
        }
    }

    /// Git data moved (SCM op, RepoWatcher refetch, poll): sidebar
    /// badges re-render, the Git tab re-reads the store caches (TTL
    /// fresh → cache read, no exec), and the Files tab re-resolves its
    /// space root (the first fetch for a new cwd carries it).
    func gitSurfacesStale() {
        refreshSidebarSpaces()
        updateRightPanel()
        wc?.rightPanel.refreshScm()
        for case let host as AgentPaneHost in hostPool.values { host.pushMeta() }
    }

    private func refreshSidebarSpaces() {
        guard let ws = coordinator.store?.focused else { return }
        let state = coordinator.wsStates[ws.id] ?? .connecting
        renderTabSurfaces(ws: ws, offline: state == .disconnected)
    }

    /// The composer's working switch follows the daemon's extension
    /// report — the SAME value the tab badge reads — so the two can
    /// never disagree again. Coarse by design (start/stop a working
    /// state); client events refine the phase between report ticks.
    private func pushReportedAgentStates() {
        guard let store = coordinator.store else { return }
        for ws in store.workspaces {
            for tab in ws.tabs {
                for pane in tab.panes {
                    guard case .agent = pane.kind,
                          let host = hostPool[HostKey(workspace: ws.id, pane: pane.id)]
                              as? AgentPaneHost else { continue }
                    host.applyReportedState(
                        coordinator.reportedActivity(wsId: ws.id, paneId: pane.id))
                }
            }
        }
    }

    /// Live TUI status for a space row's badge: activity + seen, plus
    /// the braille spinner character when the surface title (ghostty's
    /// OSC 0/2 — omp carries one while working) has one.
    private func spaceStatus(_ tab: TabState) -> SpaceStatus? {
        guard let pane = tab.panes.first,
              let status = coordinator.agentStatus(paneId: pane.id) else { return nil }
        let spinner = coordinator.surfaceTitle(for: tab)?.first { ch in
            guard let s = ch.unicodeScalars.first else { return false }
            return (0x2800...0x28FF).contains(s.value)
        }
        // The badge follows the COMPOSER's state machine (host.onTurnState
        // → agentStateUpdated) — one source for tab and input. The daemon
        // extension report is NOT consulted here: omp's extension kept
        // reporting "working" after its own turn was aborted (2026-08-31
        // storm), which is exactly the tab/composer split this reverted.
        return SpaceStatus(activity: status.state, seen: status.seen, spinner: spinner)
    }
}
