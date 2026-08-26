// goty — see CLAUDE.md for the working principles.
import GhosttyKit
import AppKit

// MARK: - App delegate

private var keepAliveDelegate: AppDelegate?

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    let coordinator = WorkspaceCoordinator()
    var ghostty: Ghostty.App!
    /// Owns the window shell and the three region containers; the only
    /// cross-region layout in the app lives there.
    var wc: AppWindowController!
    var window: NSWindow? { wc?.window }
    private let prefs = AppPreferences.shared
    private var hostPool: [HostKey: PaneHost] = [:]
    /// One ssh-installed daemon per remote workspace; survives GUI restart
    /// by design (the remote side keeps running when a link goes away).
    private var remoteLinks: [UUID: RemoteDaemonLink] = [:]
    /// Local event monitors must be retained: the returned token is an
    /// object — dropping it releases the monitor (events then never reach us).
    private var clickMonitor: Any?
    /// Foreground-process poll (agent identity for typed-in agents).
    private var editorPanelBacking: EditorPanelView?
    private var sshWindowBacking: SSHConfigWindowController?
    private var settingsWindowBacking: SettingsWindowController?

    // AI tasks (@ai): the coordinator is rebuilt when the provider
    // config changes (token compare per start — no notification
    // plumbing); task id → pane routes coordinator updates back.
    private var aiCoordinatorBox: (token: String, coordinator: AITaskCoordinator)?
    private var activeAIPane: [UUID: HostKey] = [:]
    /// The coordinator a running task lives in — card callbacks must
    /// reach it, not whichever coordinator `aiCoordinator()` would
    /// rebuild after a mid-task provider-settings change.
    private var aiTaskOwner: [UUID: AITaskCoordinator] = [:]

    func applicationWillTerminate(_ notification: Notification) {
        // Detach GUI clients only. goty-sessiond owns the PTYs and must
        // outlive this process so sessions survive app restarts.
        hostPool.values.forEach { $0.retire() }
        // The forwards are OURS though: quit without this leaked one
        // ssh -N per app launch (12 orphans accumulated across a
        // crashy evening — each still holding its unlinked socket).
        remoteLinks.values.forEach { $0.stop() }
    }
    func applicationShouldHandleReopen(_ application: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        // Dock-icon click after the window was closed: without this the
        // app activates but shows nothing (closed windows stay closed).
        if !flag { wc.window.makeKeyAndOrderFront(nil) }
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Uncaught NSExceptions die with no macOS crash report for GUI
        // apps in some paths; write our own evidence so "it just quit"
        // is diagnosable.
        NSSetUncaughtExceptionHandler { exception in
            let log = NSHomeDirectory() + "/Library/Logs/goty-crash.log"
            let text = "\(Date()) UNCAUGHT \(exception.name.rawValue): "
                + (exception.reason ?? "?") + "\n"
                + exception.callStackSymbols.prefix(20).joined(separator: "\n") + "\n\n"
            FileHandle(forWritingAtPath: log)?.write(text.data(using: .utf8)!)
        }
        coordinator.delegate = self
        // Our OWN ghostty home in app support: config + themes copied once
        // from the user's live Ghostty, then owned by goty. The env var
        // MUST be set before ghostty_init — libghostty captures the
        // resources dir during init; setting it after leaves theme
        // resolution on defaults (verified both ways).
        let support = NSHomeDirectory() + "/Library/Application Support/goty"
        let ownHome = support + "/ghostty"
        let fm = FileManager.default
        try? fm.createDirectory(atPath: ownHome, withIntermediateDirectories: true)
        let liveConfig = support + "/../com.mitchellh.ghostty/config.ghostty"
        if !fm.fileExists(atPath: ownHome + "/config"),
           fm.fileExists(atPath: liveConfig) {
            try? fm.copyItem(atPath: liveConfig, toPath: ownHome + "/config")
        }
        if !fm.fileExists(atPath: ownHome + "/themes/Arthur") {
            let seed = "/Applications/Ghostty.app/Contents/Resources/ghostty/themes"
            if fm.fileExists(atPath: seed) {
                try? fm.copyItem(atPath: seed, toPath: ownHome + "/themes")
            }
        }
        if fm.fileExists(atPath: ownHome + "/themes") {
            setenv("GHOSTTY_RESOURCES_DIR", ownHome, 1)
        }
        let configPath = fm.fileExists(atPath: ownHome + "/config")
            ? ownHome + "/config" : nil

        NSApp.setActivationPolicy(.regular)
        guard ghostty_init(0, nil) == 0 else {
            let alert = NSAlert(); alert.messageText = "ghostty_init failed"; alert.runModal()
            NSApp.terminate(nil); return
        }

        let app = Ghostty.App(configPath: configPath)
        guard app.readiness == .ready, app.app != nil else {
            let alert = NSAlert()
            alert.messageText = "Failed to initialize libghostty"
            alert.runModal(); NSApp.terminate(nil); return
        }
        ghostty = app
        // The chrome follows the resolved config from the very first
        // frame — before this, launch ran on .fallback until some
        // config-change event happened to fire.
        Chrome.theme = .from(app.config)
        // Prewarm App.wakeup's dispatch path on the main thread before any
        // surface exists: ghostty invokes wakeup from renderer/IO threads,
        // and its first lazy Swift/objc metadata instantiation there —
        // under the render lock — deadlocked startup against the main
        // thread feeding replay bytes (observed 2026-08-21). Running the
        if ProcessInfo.processInfo.environment["GOTY_DUMP_VIEWS"] == "1" {
            var probe = ghostty_config_color_s()
            let key = "background"
            let resolved = ghostty_config_get(app.config.config, &probe, key, UInt(key.utf8.count))
            print("theme-diag: libghostty bg resolved=\(resolved) rgb=\(probe.r),\(probe.g),\(probe.b) env=\(ProcessInfo.processInfo.environment["GHOSTTY_RESOURCES_DIR"] ?? "nil")")
        }
        app.delegate = self

        // Window shell + the three regions (sidebar / terminal / right
        // panel). All cross-region layout lives in AppWindowController.
        let wc = AppWindowController()
        self.wc = wc
        // Launch config may already ask for translucency/blur — apply the
        // window-level treatment once before any surface shows.
        wc.applyChromeTheme()
        let sidebar = wc.sidebar
        let rightPanel = wc.rightPanel
        wc.window.makeKeyAndOrderFront(nil)

        // Stale LOCAL daemon (same landmine the remote link hits): the
        // daemon outlives the app by design, so an upgraded bundle can
        // meet an instance from an older build — spawn/attach work, but
        // fg/agent never arrive and agent logos/status silently die.
        // Ask before killing: its sessions end with it. A DECLINE is
        // remembered per daemon build — the prompt fires once per
        // capability level, not on every launch (the every-launch
        // restart-dialog report).
        if let capability = SessionDaemon.sharedRunningCapability(),
           capability < SessionDaemon.expectedCapability {
            if !prefs.daemonUpgradeDeclined(key: "local", capability: capability),
               Dialog.confirm(
                   title: "Upgrade Goty daemon?",
                   detail: "The background session daemon on this Mac is an older version; "
                       + "agent logos and live status won't work until it's upgraded. "
                       + "Restarting it closes the sessions it hosts.",
                   action: "Restart Daemon") {
                SessionDaemon.terminateSharedForUpgrade()
                // Complete the upgrade NOW: kill + respawn with the
                // current binary, so one click ends the story.
                _ = SessionDaemon.shared.ensureRunning()
            } else {
                prefs.declineDaemonUpgrade(key: "local", capability: capability)
            }
        }

        rightPanel.onInsertPath = { [weak self] path in
            self?.coordinator.insertPathIntoFocusedPane(path)
        }
        // Region wiring lost in the 2bece5f refactor (collapse button
        // was dead, width/tab changes never persisted): restored.
        rightPanel.onWidthChange = { [weak self] w in
            self?.prefs.rightPanelWidth = w
        }
        rightPanel.onCollapseViaTabs = { [weak self] in
            self?.wc.toggleRightPanel()
        }
        rightPanel.onTabChange = { [weak self] tab in
            self?.prefs.rightPanelTab = tab
        }

        // The one recurring timer — every consumer here polls ONLY what
        // has no push source (2026-08-23 polling audit):
        // • cwd + foreground/agent identity: ONE list round trip per
        //   connected daemon (push would need a new sessiond frame
        //   protocol); change-detected in the appliers.
        // • git: REMOTE repos keep the TTL poll (no FS events over ssh
        //   exec); LOCAL repos are event-driven via RepoWatcher
        //   (FSEvents) — refetched on change, zero exec when idle.
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.coordinator.pollDaemonLists()
            // GitStatusStore feeds ONLY the sidebar's branch badges; a
            // collapsed sidebar displays nothing, so no fetch (on
            // re-expand the TTL has lapsed and the next tick refetches).
            if self?.wc.sidebar.isHidden == false {
                self?.coordinator.pollGitStatuses()
            }
            self?.wc.rightPanel.refreshScm()   // TTL-guarded; hidden = no-op
        }

        // Local repo changes arrive as kernel events; each store
        // refetches immediately (rate-bounded per root), and the hooks
        // below re-render the surfaces from the fresh caches — the 2s
        // tick never duplicates the fetch.
        RepoWatcher.shared.onRootChanged = { root in
            ScmStore.shared.rootChanged(root: root)
            GitStatusStore.shared.rootChanged(root: root)
        }
        ScmStore.shared.onRepoUpdated = { [weak self] _ in
            self?.gitSurfacesStale()
        }
        GitStatusStore.shared.onSummaryChanged = { [weak self] in
            self?.gitSurfacesStale()
        }

        // A pane's foreground command changed: its PaneHost retargets
        // agent detection (start watching the new agent's TUI, or stop
        // when it exited). The sidebar row re-renders via `.agent`.
        coordinator.onForegroundChange = { [weak self] changes in
            for (key, command) in changes {
                self?.hostPool[key]?.updateAgentCommand(command)
            }
        }

        // Backing changes are handled per surface. PaneHost re-reads the
        // resulting Ghostty grid during layout and emits one ordered Resize
        // marker to its daemon stream.

        sidebar.onTabSelected = { [weak self] idx in
            guard let self else { return }
            self.coordinator.selectTab(index: idx)
        }
        sidebar.onNewTab = { [weak self] in self?.coordinator.newTab() }
        sidebar.onNewTabInDir = { [weak self] cwd in
            self?.coordinator.newTab(cwd: cwd)
        }
        sidebar.onNewWorktreeInDir = { [weak self] cwd in
            self?.startWorktreeFlow(cwd: cwd)
        }
        sidebar.onWorkspaceSelected = { [weak self] idx in
            self?.coordinator.selectWorkspace(idx)
        }
        sidebar.onManageSSHConfig = { [weak self] in
            // The '+' flyout's NSMenu tracking session is still
            // unwinding when the action fires (the old synchronous
            // dialog inside it is what deadlocked the app); present on
            // the next tick, after the session fully tears down.
            DispatchQueue.main.async {
                self?.sshConfigWindow().show(over: self?.window)
            }
        }
        // Titlebar band: settings entry (⌘,'s mouse twin) — the sidebar
        // toggle and right-panel toggle are wired by the window
        // controller itself (it owns those state machines).
        wc.titlebar.onOpenSettings = { [weak self] in
            self?.settingsWindow().show(over: self?.window)
        }
        sidebar.onWidthChange = { [weak self] width in
            self?.wc.setSidebarWidth(width)
        }
        sidebar.onCloseTab = { [weak self] idx in
            self?.coordinator.closeTab(index: idx)
        }
        sidebar.onRenameTab = { [weak self] idx in
            self?.renameTabFocusField(index: idx)
        }
        sidebar.onRenameTabTo = { [weak self] idx, name in
            self?.coordinator.renameTab(index: idx, name: name)
        }
        sidebar.onTabColor = { [weak self] idx, hex in
            self?.coordinator.setTabColor(index: idx, hex: hex)
        }
        sidebar.onTabIcon = { [weak self] idx, symbol in
            self?.coordinator.setTabIcon(index: idx, symbol: symbol)
        }
        sidebar.onAddWorkspace = { [weak self] host in
            self?.coordinator.addWorkspace(host: host)
            if let ws = self?.coordinator.store?.workspaces.last, ws.isRemote {
                self?.startRemoteLink(ws)
            }
        }
        sidebar.onReconnectWorkspace = { [weak self] idx in
            guard let self, let store = self.coordinator.store,
                  store.workspaces.indices.contains(idx) else { return }
            self.reconnectRemote(wsId: store.workspaces[idx].id)
        }
        sidebar.onDisconnectWorkspace = { [weak self] idx in
            self?.disconnectWorkspace(at: idx)
        }
        sidebar.onDeleteWorkspace = { [weak self] idx, destructive in
            if destructive {
                self?.closeWorkspaceDialog(at: idx)
            } else {
                self?.removeWorkspaceDialog(at: idx)
            }
        }
        // The terminal region's top tab strip — the tab surface while
        // the sidebar is collapsed to a rail. Same coordinator actions
        // as the sidebar rows; rename goes through a prompt because
        // the strip has no inline field.
        let strip = wc.terminalArea.tabStrip
        strip.onTabSelected = { [weak self] idx in
            self?.coordinator.selectTab(index: idx)
        }
        strip.onNewTab = { [weak self] in self?.coordinator.newTab() }
        strip.onCloseTab = { [weak self] idx in
            self?.coordinator.closeTab(index: idx)
        }
        strip.onRenameTab = { [weak self] idx in
            self?.renameTabPrompt(index: idx)
        }
        strip.onTabColor = { [weak self] idx, hex in
            self?.coordinator.setTabColor(index: idx, hex: hex)
        }
        strip.onTabIcon = { [weak self] idx, symbol in
            self?.coordinator.setTabIcon(index: idx, symbol: symbol)
        }

        // Built-in editor: a terminal-REGION overlay (tty7 code panel).
        // Built lazily on first use; visibility maps to
        // terminalArea.presentOverlay/dismissOverlay, so the editor can
        // never touch the window's region constraints (see CLAUDE.md).
        rightPanel.onOpenFile = { [weak self] path in
            guard let self, let ws = self.coordinator.store?.focused else { return }
            self.editorPanel().open(path: path, source: FileSources.source(for: ws))
        }

        // Worktrees group → Open: a terminal straight into that
        // worktree, same routing as the sidebar's per-space "+".
        rightPanel.onOpenWorktree = { [weak self] path in
            self?.coordinator.newTab(cwd: path)
        }

        // Remote Files tab → Download: scp -r through the same
        // ControlMaster the listings ride. Was declared but never
        // wired — the menu started a transfer that never ran (stuck at
        // 0 bytes forever).
        rightPanel.onDownload = { [weak self] path, isDirectory, dest, progress, completion in
            guard let self, let ws = self.coordinator.store?.focused,
                  ws.isRemote, let host = ws.sshHost else {
                DispatchQueue.main.async {
                    completion(.failure(CocoaError(.fileReadUnknown, userInfo: [
                        NSLocalizedDescriptionKey: "download: no remote workspace"])))
                }
                return
            }
            RemoteFileSource(host: host).download(
                path: path, isDirectory: isDirectory, into: dest,
                progress: progress, completion: completion)
        }

        // Real keyboard ⌘-combos take the performKeyEquivalent path, so the
        // shortcuts live in the main menu (standard terminal-app practice).
        buildMainMenu()

        // Click-to-focus.
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, let window = self.window, event.window === window else { return event }
            let location = event.locationInWindow
            if let host = self.wc?.terminalArea.paneGrid.visibleHosts.first(where: {
                $0.frame.contains($0.superview?.convert(location, from: nil) ?? .zero)
            }) {
                window.makeFirstResponder(host.surfaceView)
                self.coordinator.focusPane(wsId: host.hostKey.workspace,
                                           paneId: host.paneId)
            }
            return event
        }
        coordinator.store = WorkspaceStore(sessionName: "Local")

        // State is immediately authoritative. Local panes attach/spawn through
        // goty-sessiond; remote pane hosts attach through their
        // ssh-forwarded sessiond when rendered.
        refresh()
        if let store = coordinator.store {
            for workspace in store.workspaces { coordinator.bootWorkspace(workspace) }
        }
        for workspace in coordinator.store?.workspaces ?? [] where workspace.isRemote {
            startRemoteLink(workspace)
        }
        // Forward sockets from a hard crash: per-host openForward
        // self-heals on next use, but a host never used again would
        // keep its file forever. No link is up yet — sweep is safe.
        let fwdDir = NSHomeDirectory() + "/Library/Application Support/goty/fwd"
        for stale in (try? FileManager.default.contentsOfDirectory(atPath: fwdDir)) ?? [] {
            try? FileManager.default.removeItem(atPath: fwdDir + "/" + stale)
        }
        coordinator.daemonFor = { [weak self] workspace in
            workspace.isRemote
                ? self?.remoteLinks[workspace.id]?.daemon
                : SessionDaemon.shared
        }
        // Files tab "Send Path to Terminal" (and anything else that
        // types into a pane): route to the focused pane's host. Was
        // declared but never wired — the menu verb did nothing.
        coordinator.onSendText = { [weak self] key, text in
            guard let self else { return }
            self.wc.terminalArea.paneGrid.visibleHosts
                .first(where: { $0.hostKey == key })?
                .sendText(text)
        }

        // The vendored terminal's right-click menu (and any user Ghostty
        // keybinds) request splits through libghostty's apprt action,
        // which the vendored app relays as this notification — the
        // embedder's documented hook. Route it to the same coordinator
        // path as the menu bar so the two can never drift.
        NotificationCenter.default.addObserver(
            self, selector: #selector(themeFanout),
            name: Chrome.themeDidChange, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(ghosttySplitRequested(_:)),
            name: Ghostty.Notification.ghosttyNewSplit, object: nil)

        // Paste protection (ghostty default): multi-line pastes and
        // OSC 52 clipboard requests must be CONFIRMED by the app —
        // libghostty relays them as this notification and waits. We
        // never listened, so every multi-line paste silently died
        // (single-line pastes skip protection, which is why those
        // worked and native Ghostty, which shows the dialog, was fine).
        NotificationCenter.default.addObserver(
            self, selector: #selector(ghosttyConfirmClipboard(_:)),
            name: Ghostty.Notification.confirmClipboard, object: nil)

        // The chrome-follows-theme design (Chrome.swift) finally has a
        // switcher: Settings reloads the config, libghostty posts this
        // with the new resolved config, and the shell repaints.
        NotificationCenter.default.addObserver(
            self, selector: #selector(ghosttyConfigChanged(_:)),
            name: .ghosttyConfigDidChange, object: nil)

        NSApp.activate(ignoringOtherApps: true)

    }




    /// First use builds the editor overlay and wires it to the terminal
    /// region. While hidden it is OUT of the view tree entirely — a
    /// hidden zero-size container still solves its children's
    /// constraints, and that fight is what once broke the window.
    private func editorPanel() -> EditorPanelView {
        if let panel = editorPanelBacking { return panel }
        let panel = EditorPanelView()
        panel.onVisibilityChange = { [weak self] visible in
            guard let self, let area = self.wc?.terminalArea else { return }
            if visible {
                area.presentOverlay(panel, kind: .editor, fullBleed: true)   // flush to the window top
            } else {
                area.dismissOverlay(kind: .editor)
                // Back to the terminal — the user just left the editor.
                if let first = area.paneGrid.visibleHosts.first, let window {
                    window.makeFirstResponder(first.surfaceView)
                }
            }
        }
        editorPanelBacking = panel
        return panel
    }

    /// The SSH config manager: a STANDALONE window (nothing in the main
    /// window), built lazily. Non-modal — no nested runloop, no overlay.
    private func sshConfigWindow() -> SSHConfigWindowController {
        if let w = sshWindowBacking { return w }
        let w = SSHConfigWindowController()
        sshWindowBacking = w
        return w
    }

    /// Settings: the same standalone-window pattern (tty7's left
    /// sections / right rows); writes goty's ghostty config live.
    private func settingsWindow() -> SettingsWindowController {
        if let w = settingsWindowBacking { return w }
        let w = SettingsWindowController(app: ghostty)
        w.root.liveAppForTranslucency = { [weak self] in self?.ghostty.app }
        // Every settings write reloads the app AND pushes the fresh
        // config into every live surface — ghostty_surface_update_config
        // is the documented hot-reload path (SettingsWindow.commit).
        w.root.onCommitAll = { [weak self] in self?.pushConfigToSurfaces() }
        settingsWindowBacking = w
        return w
    }

    /// Reload + per-surface config push. ghostty_app_update_config
    /// should propagate alone, but the observed reality (only
    /// file-read paths like theme responded) says surfaces also need
    /// the explicit push — belt and braces, both documented APIs.
    private func pushConfigToSurfaces() {
        let fresh = Ghostty.Config(at: GhosttyConfigStore.path)
        guard let cfg = fresh.config, let gapp = ghostty?.app else { return }
        _ = gapp
        for host in hostPool.values {
            if let surface = host.surfaceView?.surface {
                ghostty_surface_update_config(surface, cfg)
            }
        }
    }
    /// Returns the persistent host for one daemon-owned pane.
    private func makePaneHost(pane: PaneState, ws: WorkspaceState,
                              gapp: ghostty_app_t) -> PaneHost? {
        let key = HostKey(workspace: ws.id, pane: pane.id)
        if let existing = hostPool[key] { return existing }
        let command = ws.focusedTab?.panes.first?.id == pane.id
            ? ws.focusedTab?.paneCommand : nil
        let wsId = ws.id
        let host = PaneHost(app: gapp, paneId: pane.id, hostKey: key, cwd: pane.cwd,
                            command: command) { [weak self] in
            self?.paneDaemonTarget(wsId: wsId, command: command)
        }
        host.onConnected = { [weak self] _ in
            self?.coordinator.workspaceConnected(ws.id)
        }
        host.onDisconnected = { [weak self] _ in
            guard ws.isRemote else { return }
            self?.coordinator.workspaceDisconnected(ws.id)
        }
        host.onExited = { [weak self] exited in
            self?.coordinator.paneExited(wsId: ws.id, paneId: exited.paneId)
        }
        host.onTitle = { [weak self] host, title in
            self?.coordinator.paneTitleUpdated(wsId: ws.id, paneId: host.paneId, title: title)
        }
        host.onPaneGone = { [weak self] gone in
            self?.coordinator.paneExited(wsId: ws.id, paneId: gone.paneId)
        }
        host.onAgentState = { [weak self] host, state in
            self?.coordinator.agentStateUpdated(wsId: ws.id, paneId: host.paneId, state: state)
        }
        host.coordinatorFeed = { [weak self] in
            self?.coordinator.aiTarget(for: key)
        }
        host.onAITask = { [weak self] host, text in
            self?.startAITask(host: host, text: text)
        }
        host.refreshAITrigger()
        hostPool[key] = host
        return host
    }

    // MARK: AI tasks (@ai)

    /// The live coordinator, rebuilt when the AI provider settings
    /// (base URL / model) change. Running tasks live in the coordinator
    /// they started with; both stay wired to onUpdate.
    private func aiCoordinator() -> AITaskCoordinator {
        let p = AppPreferences.shared
        // The key is part of the token: changing only the API key must
        // rebuild the client too, or tasks keep firing 401s on the
        // stale key until restart (plan Task 8: prefs re-read per start).
        let key = Keychain.secret(for: "aiApiKey") ?? ""
        let token = p.aiBaseUrl + "\n" + p.aiModel + "\n" + key + "\n" + p.aiApiType
        if let box = aiCoordinatorBox, box.token == token { return box.coordinator }
        let client = OpenAICompatibleClient(
            baseUrl: p.aiBaseUrl,
            apiKey: key,
            model: p.aiModel,
            apiType: OpenAICompatibleClient.APIType(rawValue: p.aiApiType) ?? .openai)
        let coord = AITaskCoordinator(
            model: client,
            executorFor: { target in
                switch target.transport {
                case .local: return LocalExecutor()
                case .ssh(let host): return SSHExecutor(host: host)
                }
            })
        coord.onUpdate = { [weak self] task in
            DispatchQueue.main.async {
                guard let self, let key = self.activeAIPane[task.id] else {
                    if ProcessInfo.processInfo.environment["GOTY_AI_DEBUG"] == "1" {
                        FileHandle.standardError.write("AICARD drop: no activeAIPane for \(task.id)\n".data(using: .utf8)!)
                    }
                    return
                }
                let host = self.hostPool[key]
                if ProcessInfo.processInfo.environment["GOTY_AI_DEBUG"] == "1" {
                    FileHandle.standardError.write("AICARD phase=\(task.phase) host=\(host != nil) frame=\(host?.currentAITaskCard?.frame ?? .zero)\n".data(using: .utf8)!)
                }
                host?.showAITask(task)
                // A task card showing clears stale ask cards on OTHER
                // panes (one AI surface at a time — tasks win).
                for other in self.hostPool.values where other !== host {
                    other.hideAITaskIfInputMode()
                }
                if let host { self.wireAICard(host, task: task) }
            }
        }
        aiCoordinatorBox = (token, coord)
        return coord
    }

    private func startAITask(host: PaneHost, text: String) {
        // A leftover ⌘⇧A card on this pane would freeze and block the
        // task render (the inputMode guard) — the "two panels" bug.
        host.hideAITaskIfInputMode()
        guard let target = host.coordinatorFeed?()
            ?? coordinator.aiTarget(for: host.hostKey) else { return }
        let context = AIContext(request: text, target: target,
                                visibleOutput: host.aiTail.snapshot, hostFacts: "")
        let coord = aiCoordinator()
        let id = coord.start(context: context)
        activeAIPane[id] = host.hostKey
        aiTaskOwner[id] = coord
        if ProcessInfo.processInfo.environment["GOTY_AI_DEBUG"] == "1" {
            FileHandle.standardError.write("AISTART id=\(id) mapped to pane=\(host.hostKey.pane)\n".data(using: .utf8)!)
        }
    }

    private func wireAICard(_ host: PaneHost, task: AITask) {
        guard let card = host.currentAITaskCard else { return }
        let id = task.id
        // Route to the coordinator that owns the task: a settings change
        // mid-task builds a new coordinator that doesn't know this id.
        let owner = aiTaskOwner[id] ?? aiCoordinator()
        card.onConfirm = { [weak owner] in owner?.confirm(taskId: id) }
        card.onEdit = { [weak owner] proposal in
            owner?.edit(taskId: id, to: proposal)
        }
        card.onCancel = { [weak owner] in
            owner?.cancel(taskId: id)
            host.hideAITask()
        }
        card.onContinue = { [weak owner] in owner?.continueBudget(taskId: id) }
        // Top-right close: always available; closing a still-running
        // agent cancels it first (cancel is inert on terminal phases).
        card.onClose = { [weak owner] in
            owner?.cancel(taskId: id)
            host.hideAITask()
        }
        // Spec: fill never auto-runs — command + trailing space, the
        // user presses Enter themselves.
        card.onFill = { [weak host] command in host?.sendText(command + " ") }
    }

    /// Local panes: the shared daemon, the user's login shell, the user's
    /// environment. Remote panes: the workspace's forwarded daemon and the
    /// remote login shell — never the Mac's environment.
    private func paneDaemonTarget(wsId: UUID, command: String?) -> PaneDaemonTarget? {
        guard let store = coordinator.store,
              let ws = store.workspaces.first(where: { $0.id == wsId }) else { return nil }
        if !ws.isRemote {
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            let args = (command?.isEmpty == false) ? ["-l", "-c", "exec " + command!] : ["-l"]
            return PaneDaemonTarget(daemon: .shared, shell: shell, args: args,
                                    environment: UserShellEnv.asDictionary)
        }
        guard let link = remoteLinks[wsId], link.state == .ready,
              let daemon = link.daemon else { return nil }
        let args = (command?.isEmpty == false)
            ? ["-l", "-c", "exec " + command!] : ["-l"]
        return PaneDaemonTarget(daemon: daemon, shell: link.remoteShell, args: args,
                                environment: [:])
    }

    private func startRemoteLink(_ workspace: WorkspaceState) {
        guard let host = workspace.sshHost else { return }
        let link = RemoteDaemonLink(host: host)
        link.onStateChange = { [weak self] state in
            DispatchQueue.main.async {
                guard let self else { return }
                switch state {
                case .ready:
                    self.coordinator.workspaceConnected(workspace.id)
                    self.refresh()
                case .outdated:
                    // Old daemon instance still serving (fixed socket +
                    // singleton): panes work, agent logo/status don't.
                    // Restarting ends the remote sessions — the user
                    // decides; declining proceeds degraded (2026-08-24
                    // silent-remote-degradation root cause) and is
                    // REMEMBERED per host, so the prompt is one nag per
                    // daemon build, not one per launch.
                    if let capability = link.reportedCapability,
                       self.prefs.daemonUpgradeDeclined(key: workspace.name,
                                                        capability: capability) {
                        link.acceptOutdated()
                        break
                    }
                    let sessions = self.coordinator.store?.workspaces
                        .first(where: { $0.id == workspace.id })?.tabs.count ?? 0
                    if Dialog.confirm(
                        title: "Upgrade Goty daemon on \(workspace.name)?",
                        detail: "This server keeps running an older goty-sessiond — sessions "
                            + "survive GUI restarts, so it was never replaced. Agent logos and "
                            + "live status won't work until it's upgraded. Restarting it closes "
                            + "the \(sessions) session(s) currently running there.",
                        action: "Restart Daemon") {
                        link.upgradeDaemon()
                    } else {
                        self.prefs.declineDaemonUpgrade(key: workspace.name,
                                                        capability: link.reportedCapability ?? 0)
                        link.acceptOutdated()
                    }
                case .failed:
                    self.coordinator.workspaceDisconnected(workspace.id)
                case .connecting:
                    break
                }
            }
        }
        remoteLinks[workspace.id] = link
        link.start()
    }

    // MARK: Worktree creation (space "+" → "New Worktree…")

    /// Prompt for a name, create the worktree beside the repo, jump
    /// into it (design: docs/specs/2026-08-23-worktree-design.md).
    /// One tick after the menu action so the menu finishes closing
    /// first (same sequencing as the SSH manager entry; the dialog is
    /// a real modal session since 2026-08-23 and needs no such
    /// deferral to be safe).
    private func startWorktreeFlow(cwd: String?) {
        guard let cwd, !cwd.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // The space's workspace is the focused one — the sidebar
            // renders only its sections.
            let host = self.coordinator.store?.focused?.sshHost
            func present(root: String) {
                // The designed card (2026-08-24) in its OWN window —
                // the SSH-manager recipe; live target preview + inline
                // validation, no post-hoc "Invalid name" round trip.
                WorktreeWindow.present(root: root, over: self.window) {
                    [weak self] name in
                    guard let self else { return }
                    self.coordinator.createWorktree(
                        name: name, cwd: cwd, host: host) { result in
                        if case .failure(let f) = result {
                            Dialog.error(title: "Git worktree failed",
                                         detail: f.detail)
                        }
                    }
                }
            }
            if let root = ScmStore.shared.repoRoot(cwd: cwd, host: host) {
                present(root: root)
                return
            }
            ScmStore.shared.refreshStatus(cwd: cwd, host: host, force: true) { st in
                guard let root = st?.root else {
                    Dialog.error(title: "Not a git repository",
                                 detail: "Worktrees need a git repository.")
                    return
                }
                present(root: root)
            }
        }
    }

    /// Rebuild the panel from the focused workspace (Info target + Files
    /// + Git roots). The Files tab follows the SPACE, not the pane cwd:
    /// one git repo is one space, so the tree roots at the repo's main
    /// worktree wherever the pane sits (subdir or linked worktree); the
    /// Git tab still follows the pane's own repo state. The space root
    /// arrives with the first git fetch for a new cwd — `gitSurfacesStale`
    /// re-runs this pass when it lands.
    private func updateRightPanel() {
        guard let store = coordinator.store,
              let ws = store.focused else { return }
        let pane = coordinator.activePane(of: ws)
        let cwd = pane?.cwd
        let host = ws.sshHost
        let spaceRoot = cwd.flatMap { GitStatusStore.shared.spaceRoot(for: $0, host: host) } ?? cwd
        wc.rightPanel.setSystemTarget(host: ws.isRemote ? ws.sshHost : nil)
        wc.rightPanel.setDirectory(spaceRoot, source: FileSources.source(for: ws))
        wc.rightPanel.setScmTarget(cwd: cwd, host: ws.sshHost)
    }
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

    private func refresh() {
        guard let store = coordinator.store, let ws = store.focused,
              let gapp = ghostty.app else { return }
        // Panes created before the store knew about them armed with a nil
        // target; every store pass is a free re-arm (idle panes never see
        // another foreground report, so the stale unarmed state stuck —
        // "@ai works in one pane, not another").
        for host in hostPool.values { host.refreshAITrigger() }
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
        var entries: [(paneKey: HostKey, host: PaneHost, fraction: NSRect)] = []
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
    private func refreshConnectionChrome() {
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
    private func gitSurfacesStale() {
        refreshSidebarSpaces()
        updateRightPanel()
        wc?.rightPanel.refreshScm()
    }

    private func refreshSidebarSpaces() {
        guard let ws = coordinator.store?.focused else { return }
        let state = coordinator.wsStates[ws.id] ?? .connecting
        renderTabSurfaces(ws: ws, offline: state == .disconnected)
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
        return SpaceStatus(activity: status.state, seen: status.seen, spinner: spinner)
    }


    // MARK: workspace lifecycle (tty7 model: create + restore)

    /// Mode 1 close: drop the connection AND remove the server from the
    /// sidebar — every session keeps running on the machine (the remote
    /// daemon persists panes); teardown falls focus back to the local
    /// workspace. Re-adding the host reattaches them.
    private func disconnectWorkspace(at index: Int) {
        guard let store = coordinator.store,
              store.workspaces.indices.contains(index) else { return }
        let ws = store.workspaces[index]
        guard ws.isRemote else { return }
        remoteLinks.removeValue(forKey: ws.id)?.stop()
        // Park: pane ids survive in state.json, so re-adding the host
        // reattaches the still-running sessions.
        coordinator.teardownWorkspace(ws.id, park: true)
    }

    /// Manual reconnect: coordinator state + immediate two-step link probe
    /// (1s TCP reachability first; ssh only when the host answers).
    private func reconnectRemote(wsId: UUID) {
        coordinator.reconnectWorkspace(wsId)
        remoteLinks[wsId]?.reconnectNow()
    }

    private func closeWorkspaceDialog(at index: Int) {
        guard let store = coordinator.store,
              store.workspaces.indices.contains(index) else { return }
        let workspace = store.workspaces[index]
        guard Dialog.confirm(
            title: "Close server \(workspace.displayName)?",
            detail: "Terminates its \(workspace.tabs.count) space(s) on "
                + (workspace.isRemote ? (workspace.sshHost ?? "?") : "this Mac") + ".",
            action: "Close & Remove") else { return }
        // Kill FIRST, drop the link after: killWorkspace resolves the
        // daemon from the still-live remote link — stopping first sent
        // the kills to the LOCAL daemon under remote pane ids (remote
        // sessions survived their own "Close").
        coordinator.killWorkspace(workspace.id)
        remoteLinks[workspace.id]?.stopRemoteDaemon()
        remoteLinks.removeValue(forKey: workspace.id)?.stop()
        coordinator.teardownWorkspace(workspace.id)
    }

    private func removeWorkspaceDialog(at index: Int) {
        guard let store = coordinator.store,
              store.workspaces.indices.contains(index) else { return }
        let ws = store.workspaces[index]
        guard Dialog.confirm(
            title: "Remove server \(ws.displayName)?",
            detail: ws.isRemote
                ? "Unreachable, so nothing can be closed on \(ws.sshHost ?? "?"). "
                    + "The Goty session there KEEPS RUNNING — add the host again later to reattach."
                : "The local Goty session keeps running and can be reattached on next launch.",
            action: "Remove") else { return }

        // No workspace-local client remains; PaneHost/daemon teardown is below.
        // Park like Mode 1: the unreachable server's sessions keep running;
        // re-adding the host reattaches them.
        remoteLinks.removeValue(forKey: ws.id)?.stop()
        coordinator.teardownWorkspace(ws.id, park: true)
    }

    private func buildMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(title: "Goty", action: nil, keyEquivalent: "")
        let appMenu = NSMenu()
        let settingsItem = NSMenuItem(title: "Settings…",
                                      action: #selector(menuOpenSettings),
                                      keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let shellItem = NSMenuItem(title: "Shell", action: nil, keyEquivalent: "")
        let shellMenu = NSMenu()
        shellMenu.addItem(withTitle: "New Space", action: #selector(menuNewTab), keyEquivalent: "t")
        shellMenu.addItem(withTitle: "New Claude Code Space", action: #selector(menuNewAgentTab), keyEquivalent: "n")
        let askAI = NSMenuItem(title: "Ask AI…", action: #selector(menuAskAI), keyEquivalent: "a")
        askAI.keyEquivalentModifierMask = [.command, .shift]
        askAI.target = self
        shellMenu.addItem(askAI)
        let agentMenu = NSMenu()
        for (command, spec) in AgentCatalog.pickerOrder {
            let item = NSMenuItem(title: spec.label, action: #selector(menuNewAgentTabFrom(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = command
            // Official brand logo when the asset exists (AgentIcons.swift),
            // SF Symbol otherwise.
            item.image = AgentBrandIcons.image(for: command)
                ?? menuItemIcon(spec.icon, pointSize: 11)
            agentMenu.addItem(item)
        }
        let agentItem = NSMenuItem(title: "New Agent Space", action: nil, keyEquivalent: "")
        agentItem.submenu = agentMenu
        shellMenu.addItem(agentItem)
        shellMenu.addItem(withTitle: "Close Space", action: #selector(menuCloseTab), keyEquivalent: "w")
        shellMenu.addItem(.separator())
        shellMenu.addItem(withTitle: "Split Right", action: #selector(menuSplitRight), keyEquivalent: "d")
        let splitDown = NSMenuItem(title: "Split Down", action: #selector(menuSplitDown), keyEquivalent: "D")
        splitDown.keyEquivalentModifierMask = [.command, .shift]
        shellMenu.addItem(splitDown)
        shellItem.submenu = shellMenu
        main.addItem(shellItem)

        let viewItem = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
        let viewMenu = NSMenu()
        viewMenu.addItem(withTitle: "Toggle Sidebar", action: #selector(menuToggleSidebarRegion),
                         keyEquivalent: "b")
        viewMenu.addItem(withTitle: "Toggle Right Panel", action: #selector(menuToggleRightPanelRegion),
                         keyEquivalent: "j")
        let editorToggle = NSMenuItem(title: "Toggle Editor", action: #selector(menuToggleEditor),
                                      keyEquivalent: "E")
        editorToggle.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(editorToggle)
        viewItem.submenu = viewMenu
        main.addItem(viewItem)
        NSApp.mainMenu = main
    }
    @objc private func menuToggleSidebarRegion() { wc?.toggleSidebar() }
    @objc private func menuToggleRightPanelRegion() { wc?.toggleRightPanel() }
    @objc private func menuOpenSettings() {
        settingsWindow().show(over: window)
    }
    @objc private func menuNewTab() { coordinator.newTab() }
    @objc private func menuNewAgentTab() { coordinator.newAgentTab() }
    @objc private func menuNewAgentTabFrom(_ sender: NSMenuItem) {
        if let command = sender.representedObject as? String {
            coordinator.newAgentTab(command: command)
        }
    }
    @objc private func menuCloseTab() { coordinator.closeTab() }
    @objc private func menuSplitRight() { coordinator.splitPane(vertical: false) }
    @objc private func menuSplitDown() { coordinator.splitPane(vertical: true) }

    /// ⌘⇧A: the focused pane's AI card in request-input mode. Falls back
    /// to the focused tab's active pane when the host pool holds no hit.
    @objc private func menuAskAI() {
        guard let store = coordinator.store, let ws = store.focused,
              let pane = coordinator.activePane(of: ws) else { return }
        // The ask is app-global: clear any other pane's ask card first.
        for host in hostPool.values { host.hideAITaskIfInputMode() }
        hostPool[HostKey(workspace: ws.id, pane: pane.id)]?.openAIInputMode()
    }

    /// App-level config change (Settings writes, or a reload from the
    /// config page): the resolved config is the chrome's source of
    /// truth (Chrome.swift). Window-level surfaces flip now; row-level
    /// fills painted at construction repaint when their view rebuilds
    /// (the viewDidMoveToWindow rule).
    // ponytail: partial live repaint — a retheme broadcast is the
    // upgrade path if stale rows ever read wrong.
    /// One walk covers every chrome surface in every window: views
    /// that bake colors at build time conform to ThemeRefreshable;
    /// no per-surface observers, no rebuild paths to remember.
    @objc private func themeFanout() {
        for w in NSApp.windows { w.contentView?.rethemeSubtree() }
    }

    @objc private func ghosttyConfigChanged(_ note: Notification) {
        guard note.object == nil,
              let cfg = note.userInfo?[Notification.Name.GhosttyConfigChangeKey]
                  as? Ghostty.Config
        else { return }
        let old = Chrome.theme.background.usingColorSpace(.deviceRGB)
        let candidate = ChromeTheme.from(cfg)
        let new = candidate.background.usingColorSpace(.deviceRGB)
        if ProcessInfo.processInfo.environment["GOTY_AI_DEBUG"] == "1" {
            let name = ChromeTheme.configuredThemeName(cfg) ?? "nil"
            FileHandle.standardError.write("THEME change old=\(old.map { String(format: "%.2f", $0.redComponent) } ?? "?") new=\(new.map { String(format: "%.2f", $0.redComponent) } ?? "?") theme=\(name)\n".data(using: .utf8)!)
        }
        wc?.applyChromeTheme(cfg: cfg)

        // Re-color work on a REAL change — colors (theme switch) or
        // opacity (slider: topBarBackground and every chromeSurface
        // fill depend on it). Font-size-style writes change neither
        // and skip straight through; the settings page rebuilds
        // WITHOUT rebuilding its page when IT wrote the change (the
        // rebuild swaps the slider mid-drag — the thumb-snap report).
        guard old != new || candidate.backgroundOpacity != Chrome.theme.backgroundOpacity else { return }
        Chrome.theme = candidate
        // OUR chrome follows the terminal theme too (the tty7 rule): the
        // render paths rebuild rows/headers with fresh colors — the
        // generation salt makes same-data renders rebuild anyway.
        wc?.sidebar.retheme()
        wc?.terminalArea.tabStrip.retheme()
        wc?.rightPanel.needsDisplay = true
        refresh()
        refreshConnectionChrome()
        settingsWindowBacking?.rethemeNow()
    }

    /// Split requested by the terminal itself (right-click menu's
    /// Split Right/Left/Down/Up, or a user Ghostty keybind): map the
    /// surface back to its pane — the clicked pane becomes the split
    /// target (the click monitor focused it on right-mouse-down).
    @objc private func ghosttySplitRequested(_ note: Notification) {
        guard let view = note.object as? Ghostty.SurfaceView,
              let host = hostPool.values.first(where: { $0.surfaceView === view })
        else { return }
        coordinator.focusPane(wsId: host.hostKey.workspace, paneId: host.paneId)
        let vertical: Bool, after: Bool
        switch note.userInfo?["direction"] as? ghostty_action_split_direction_e {
        case GHOSTTY_SPLIT_DIRECTION_DOWN: (vertical, after) = (true, true)
        case GHOSTTY_SPLIT_DIRECTION_UP: (vertical, after) = (true, false)
        case GHOSTTY_SPLIT_DIRECTION_LEFT: (vertical, after) = (false, false)
        default: (vertical, after) = (false, true)   // RIGHT
        }
        coordinator.splitPane(vertical: vertical, after: after)
    }

    /// Paste protection: libghostty holds the clipboard request until
    /// the embedder answers. Ask through the standard dialog, then
    /// complete the pending request either way — a dropped request is
    /// a paste that goes nowhere.
    @objc private func ghosttyConfirmClipboard(_ note: Notification) {
        guard let view = note.object as? Ghostty.SurfaceView,
              let str = note.userInfo?[Ghostty.Notification.ConfirmClipboardStrKey] as? String,
              let request = note.userInfo?[Ghostty.Notification.ConfirmClipboardRequestKey]
                  as? Ghostty.ClipboardRequest
        else { return }
        let state = note.userInfo?[Ghostty.Notification.ConfirmClipboardStateKey]
            as? UnsafeMutableRawPointer

        let title: String
        if case .paste = request {
            let lines = str.components(separatedBy: .newlines).count
            title = "Paste \(lines) lines?"
        } else {
            title = "Clipboard Access"
        }
        let preview = str.count > 160 ? String(str.prefix(160)) + "…" : str
        let ok = Dialog.confirm(title: title,
                                detail: request.text() + "\n\n" + preview,
                                action: "Confirm")

        switch request {
        case .paste, .osc_52_read:
            guard let surface = view.surface else { return }
            Ghostty.App.completeClipboardRequest(
                surface, data: str, state: state, confirmed: ok)
        case .osc_52_write(let pb):
            guard let pb, ok else { return }
            pb.clearContents()
            pb.setString(str, forType: .string)
        }
    }

    /// Focuses the sidebar row so its inline editor can begin (the row
    /// itself owns the field swap).
    private func renameTabFocusField(index: Int) {
        wc.sidebar.beginRename(index: index)
    }

    /// Rename from a surface with no inline field (the collapsed-mode
    /// tab strip): the prompt carries the current title; an emptied
    /// answer CLEARS the override (the inline rule, same channel).
    private func renameTabPrompt(index: Int) {
        guard let ws = coordinator.store?.focused,
              ws.tabs.indices.contains(index) else { return }
        let tab = ws.tabs[index]
        let current = tab.userTitle
            ?? coordinator.surfaceTitle(for: tab)
            ?? tab.name
        guard let name = Dialog.promptText(title: "Rename Tab",
                                           placeholder: "tab title",
                                           initial: current) else { return }
        coordinator.renameTab(index: index,
                              name: name.trimmingCharacters(in: .whitespaces))
    }
}

extension AppDelegate {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        keepAliveDelegate = delegate
        app.run()
    }
}

extension AppDelegate {
    @objc private func menuToggleEditor() {
        editorPanel().toggle()
    }
}

extension AppDelegate: GhosttyAppDelegate {
    func findSurface(forUUID uuid: UUID) -> Ghostty.SurfaceView? {
        hostPool.values.first { $0.surfaceView?.id == uuid }?.surfaceView
    }

    /// The user's Ghostty config binds ⌘T/⌘W/⌘D as terminal keybinds, so the
    /// surface's performKeyEquivalent claims them before the main menu. This
    /// hook is the embedder's documented interception point: claim our
    /// workspace shortcuts here so they never reach the PTY.
    func performGhosttyBindingMenuKeyEquivalent(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              event.modifierFlags.contains(.command) else { return false }
        let shift = event.modifierFlags.contains(.shift)
        switch event.charactersIgnoringModifiers ?? "" {
        case "t":
            menuNewTab()
            return true
        case "n":
            menuNewAgentTab()
            return true
        case "w":
            menuCloseTab()
            return true
        case "b":
            wc?.toggleSidebar()
            return true
        case "j":
            wc?.toggleRightPanel()
            return true
        case "d":
            if shift { menuSplitDown() } else { menuSplitRight() }
            return true
        default:
            return false
        }
    }
}


extension AppDelegate: WorkspaceCoordinatorDelegate {}
