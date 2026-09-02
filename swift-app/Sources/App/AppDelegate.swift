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
    let prefs = AppPreferences.shared
    var hostPool: [HostKey: any PaneHosting] = [:]
    /// One ssh-installed daemon per remote workspace; survives GUI restart
    /// by design (the remote side keeps running when a link goes away).
    var remoteLinks: [UUID: RemoteDaemonLink] = [:]
    /// Session-level loop guard: one upgrade prompt per (workspace,
    /// capability). An upgrade that STILL lands on the same capability
    /// degrades silently instead of re-prompting forever (2026-08-31
    /// upgrade-dialog storm on host 5090).
    var outdatedPrompted: [UUID: Int] = [:]
    /// Local event monitors must be retained: the returned token is an
    /// object — dropping it releases the monitor (events then never reach us).
    private var clickMonitor: Any?
    /// Foreground-process poll (agent identity for typed-in agents).
    private var editorPanelBacking: EditorPanelView?
    private var sshWindowBacking: SSHConfigWindowController?
    var settingsWindowBacking: SettingsWindowController?
    /// Sparkle auto-updates — created here (before launch finishes,
    /// its contract), started once the window is up.
    private let updaterManager = UpdaterManager.shared

    // AI tasks (@ai): the coordinator is rebuilt when the provider
    // config changes (token compare per start — no notification
    // plumbing); task id → pane routes coordinator updates back.
    var aiCoordinatorBox: (token: String, coordinator: AITaskCoordinator)?
    var activeAIPane: [UUID: HostKey] = [:]
    /// The coordinator a running task lives in — card callbacks must
    /// reach it, not whichever coordinator `aiCoordinator()` would
    /// rebuild after a mid-task provider-settings change.
    var aiTaskOwner: [UUID: AITaskCoordinator] = [:]

    func applicationWillTerminate(_ notification: Notification) {
        // Detach GUI clients only. goty-sessiond owns the PTYs and must
        // outlive this process so sessions survive app restarts.
        hostPool.values.forEach { $0.retire() }
        // The forwards are OURS though: quit without this leaked one
        // ssh -N per app launch (12 orphans accumulated across a
        // crashy evening — each still holding its unlinked socket).
        remoteLinks.values.forEach { $0.stopAndWait() }
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
        if !fm.fileExists(atPath: ownHome + "/config") {
            if fm.fileExists(atPath: liveConfig) {
                try? fm.copyItem(atPath: liveConfig, toPath: ownHome + "/config")
            }
            // First run only: back every appearance key the (copied or
            // absent) config doesn't set with goty's shipped defaults —
            // an empty home gets the whole block, a copied live config
            // keeps its explicit choices (GhosttyConfigDefaults).
            let store = GhosttyConfigStore(url: URL(fileURLWithPath: ownHome + "/config"))
            var doc = store.load()
            if doc.fillAppearanceDefaults() {
                try? store.save(doc)
            }
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

        if ProcessInfo.processInfo.environment["GOTY_DUMP_VIEWS"] == "1" {
            // Translucency diagnosis: the full view tree once surfaces
            // are up — a stray fill/alpha behind the ghostty surface is
            // invisible in review but obvious in this dump.
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                self?.dumpViewTree()
            }
        }
        // GOTY_AUTOLOAD_SESSION: diagnostic — open an agent pane and
        // resume the newest persisted session, dumping the page store.
        if ProcessInfo.processInfo.environment["GOTY_AUTOLOAD_SESSION"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                print("GOTY_DEBUG: creating agent pane")
                self?.coordinator.newAgentSessionTab(
                    agent: "omp",
                    cwd: FileManager.default.currentDirectoryPath)
            }
        }
        app.delegate = self

        // Window shell + the three regions (sidebar / terminal / right
        // panel). All cross-region layout lives in AppWindowController.
        let wc = AppWindowController()
        self.wc = wc
        // Launch config may already ask for translucency/blur — apply the
        // window-level treatment once before any surface shows.
        wc.applyChromeTheme()
        let rightPanel = wc.rightPanel
        wc.window.makeKeyAndOrderFront(nil)
        // Sparkle: automatic version checks from here on; the Goty ▸
        // "Check for Updates…" item enables once the updater is up.
        updaterManager.start()

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
        rightPanel.onWidthChange = { [weak self] tab, w in
            guard let self else { return }
            // Per-tab width memory (spec 2026-08-30): the Terminal
            // slot must not ride drags made while another tab shows.
            if tab == .terminal { self.prefs.terminalPanelWidth = w }
            else { self.prefs.rightPanelWidth = w }
        }
        rightPanel.onCollapseViaTabs = { [weak self] in
            self?.wc.toggleRightPanel()
        }
        rightPanel.onTabChange = { [weak self] tab in
            guard let self else { return }
            self.prefs.rightPanelTab = tab
            // Showing the Terminal tab is creation INTENT — re-run the
            // gate (updateRightPanel refreshes the side terminal).
            self.updateRightPanel()
        }
        rightPanel.onReveal = { [weak self] in
            self?.updateRightPanel()   // panel re-shown: the gate re-runs
        }
        rightPanel.onNewSideTerminal = { [weak self] in
            guard let self else { return }
            // An idempotent ensure (the pane already exists) fires no
            // structure event — mount here so the button always ends
            // with a host on screen.
            if self.coordinator.ensureAuxTerminal() != nil {
                self.updateRightPanel()
            }
        }
        rightPanel.onCloseSideTerminal = { [weak self] in
            guard let self, let ws = self.coordinator.store?.focused else { return }
            if Dialog.confirm(title: "关闭侧边终端？",
                              detail: "结束该服务器上的侧边终端会话（包含所有分屏）。",
                              action: "关闭") {
                self.coordinator.closeAuxTerminal(wsId: ws.id)
            }
        }
        // cd chip: inject into the FOCUSED side pane (prompt-gated on
        // the coordinator side; the chip renders disabled otherwise).
        rightPanel.onCdSideTerminal = { [weak self] in
            self?.cdSideTerminalToCurrentSpace()
        }

        startPollingAndWatchers()

        // Backing changes are handled per surface. PaneHost re-reads the
        // resulting Ghostty grid during layout and emits one ordered Resize
        // marker to its daemon stream.

        wireSidebarActions()
        // The interactive-shell env capture takes seconds; warm it off
        // main so the first agent pane doesn't stall or miss the cache.
        UserShellEnv.warmUp()
        wireTabStripActions()

        wireRightPanelActions()

        // Real keyboard ⌘-combos take the performKeyEquivalent path, so the
        // shortcuts live in the main menu (standard terminal-app practice).
        buildMainMenu()

        // Click-to-focus.
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, let window = self.window, event.window === window else { return event }
            let location = event.locationInWindow
            func hit(in hosts: [any PaneHosting]) -> (any PaneHosting)? {
                hosts.first {
                    $0.frame.contains($0.superview?.convert(location, from: nil) ?? .zero)
                }
            }
            // The side panes keep their own focus field (center
            // focusPane would point the center's active-pane resolvers
            // at a pane no tab owns).
            if let host = hit(in: self.wc?.terminalArea.paneGrid.visibleHosts ?? []) {
                host.focusAsPane()
                self.coordinator.focusPane(wsId: host.hostKey.workspace,
                                           paneId: host.hostKey.pane)
            } else if let host = hit(in: self.wc?.rightPanel.sideTerminalHosts ?? []) {
                host.focusAsPane()
                self.coordinator.focusAuxPane(wsId: host.hostKey.workspace,
                                              paneId: host.hostKey.pane)
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
        wireAgentAttention()
        // Files tab "Send Path to Terminal" (and anything else that
        // types into a pane): route to the focused pane's host. Was
        // declared but never wired — the menu verb did nothing.
        coordinator.onSendText = { [weak self] key, text in
            guard let self else { return }
            self.wc.terminalArea.paneGrid.visibleHosts
                .compactMap({ $0 as? PaneHost })
                .first(where: { $0.hostKey == key })?
                .sendText(text)
        }
        observeGhosttyNotifications()

        NSApp.activate(ignoringOtherApps: true)
        // Boot focus (responder side): the ACTIVE pane takes the
        // keyboard — visibleHosts.first would deafen every restored
        // pane that is not the first grid item. The page focuses its
        // composer on mount (DOM side); both layers are needed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, let area = self.wc?.terminalArea else { return }
            let hosts = area.paneGrid.visibleHosts
            let activeId = self.coordinator.store?.focused.flatMap {
                self.coordinator.activePane(of: $0)?.id
            }
            let target = hosts.first(where: { $0.hostKey.pane == activeId }) ?? hosts.first
            target?.focusAsPane()
        }

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
                area.presentOverlay(panel, kind: .editor)   // flush to the window top
            } else {
                area.dismissOverlay(kind: .editor)
                // Back to the terminal — the user just left the editor.
                if let first = area.paneGrid.visibleHosts.first {
                    first.focusAsPane()
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
    func settingsWindow() -> SettingsWindowController {
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
    /// GOTY_DUMP_VIEWS=1: the main window's view tree with layer state —
    /// every fill, alpha, and opacity that participates in compositing.
    private func dumpViewTree() {
        guard let content = wc?.window.contentView else { return }
        print("=== VIEW TREE ===")
        func dump(_ v: NSView, _ depth: Int) {
            let pad = String(repeating: "  ", count: depth)
            let f = v.frame
            var line = "\(pad)\(type(of: v)) frame=\(Int(f.origin.x)),\(Int(f.origin.y)) \(Int(f.width))x\(Int(f.height))"
            if v.isHidden { line += " HIDDEN" }
            if v.alphaValue < 1 { line += String(format: " alpha=%.2f", v.alphaValue) }
            if let l = v.layer {
                line += " layer"
                if let bg = l.backgroundColor {
                    let c = NSColor(cgColor: bg)?.usingColorSpace(.sRGB)
                    line += String(format: " bg=(%.0f,%.0f,%.0f,%.2f)",
                                   c?.redComponent ?? -1, c?.greenComponent ?? -1,
                                   c?.blueComponent ?? -1, c?.alphaComponent ?? -1)
                }
                if l.isOpaque { line += " OPAQUE" }
                if l.opacity < 1 { line += String(format: " lopacity=%.2f", l.opacity) }
                if l.contents != nil { line += " contents" }
                if l.masksToBounds { line += " clipped" }
            }
            print(line)
            for sub in v.subviews { dump(sub, depth + 1) }
        }
        dump(content, 0)
        if let win = wc?.window {
            print(String(format: "window isOpaque=%@ bg=%@ hasShadow=%@",
                         win.isOpaque ? "Y" : "N",
                         String(describing: win.backgroundColor), win.hasShadow ? "Y" : "N"))
        }
        print("=== END ===")
        fflush(stdout)
    }

    private func pushConfigToSurfaces() {
        let fresh = Ghostty.Config(at: GhosttyConfigStore.path)
        guard let cfg = fresh.config, let gapp = ghostty?.app else { return }
        _ = gapp
        for case let host as PaneHost in hostPool.values {
            if let surface = host.surfaceView?.surface {
                ghostty_surface_update_config(surface, cfg)
            }
        }
    }
    /// Returns the persistent host for one daemon-owned pane.
    func makePaneHost(pane: PaneState, ws: WorkspaceState,
                      gapp: ghostty_app_t) -> (any PaneHosting)? {
        let key = HostKey(workspace: ws.id, pane: pane.id)
        if let existing = hostPool[key] { return existing }
        print("GOTY_DEBUG: makePaneHost kind=\(pane.kind)")
        if case .agent(let agentKey) = pane.kind {
            guard let agentHost = makeAgentPaneHost(pane: pane, ws: ws, key: key, agentKey: agentKey) else {
                // No daemon/env for this agent pane (remote link down,
                // unknown agent key): NO host beats a wrong host — a
                // plain shell here was the M1 "silent degradation". The
                // layout retries on link-ready; a disconnected remote
                // shows the server overlay instead.
                return nil
            }
            agentHost.initialPrompt = coordinator.takeInitialPrompt(paneId: pane.id)
        let paneCwd = coordinator.cwd(ofPane: pane.id, in: ws.id) ?? pane.cwd
            ?? (ws.focusedTab?.panes.first(where: { $0.id == pane.id })?.cwd)
        agentHost.metaProvider = { [weak self] in
            guard let self else { return (nil, nil, nil, nil) }
            let name = self.coordinator.store?.workspaces.first(where: { $0.id == ws.id })?.name
            let dir = paneCwd.map { ($0 as NSString).lastPathComponent }
            // A pane at the space root repeats the space name
            // ("goty/goty") — the tail adds nothing there; subdirs and
            // worktrees still show their own segment.
            let dirTail = dir == name ? nil : dir
            let branch = paneCwd.flatMap {
                GitStatusStore.shared.summary(for: $0, host: ws.sshHost)?.branch
            }
            // Brand icon with the sidebar's template treatment, tinted
            // to the live theme (re-pushed on every theme flip).
            let icon = AgentBrandIcons.tintedDataURL(for: agentKey,
                                                     color: Chrome.theme.iconTint)
            return (name, dirTail, branch, icon)
        }
        if let paneCwd {
            // Populate the git cache for the composer's branch read; the
            // onChange pass re-pushes meta once a summary lands.
            GitStatusStore.shared.refresh(cwds: [paneCwd], host: ws.sshHost) { [weak self] in
                self?.gitSurfacesStale()
            }
        }
            hostPool[key] = agentHost
            return agentHost
        }
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
        wireTerminalTriggers(host: host, ws: ws)
        hostPool[key] = host
        return host
    }

    /// One side-terminal pane's host (right panel; spec 2026-08-30): a
    /// plain PaneHost — same attach/replay/reconnect story as any center
    /// pane — just addressed by its aux pane id and fed to the panel's
    /// grid by updateRightPanel instead of the center grid. No link-nil
    /// guard: parity with center terminal panes (a nil target defers the
    /// session start; the reconnect flow retries when the link lands).
    func makeAuxTerminalHost(ws: WorkspaceState, paneId: String,
                             spawnCwd: String?, gapp: ghostty_app_t) -> PaneHost? {
        let key = HostKey(workspace: ws.id, pane: paneId)
        if let existing = hostPool[key] as? PaneHost { return existing }
        let wsId = ws.id
        let host = PaneHost(app: gapp, paneId: paneId, hostKey: key, cwd: spawnCwd,
                            command: nil) { [weak self] in
            self?.paneDaemonTarget(wsId: wsId, command: nil)
        }
        host.onConnected = { [weak self] _ in
            self?.coordinator.workspaceConnected(ws.id)
        }
        host.onDisconnected = { [weak self] _ in
            guard ws.isRemote else { return }
            self?.coordinator.workspaceDisconnected(ws.id)
        }
        // The pane belongs to no TabState — exit reports route straight
        // to the aux teardown (what paneExited's aux branch does).
        host.onExited = { [weak self] _ in
            self?.coordinator.auxTerminalExited(wsId: wsId, paneId: paneId)
        }
        host.onPaneGone = { [weak self] _ in
            self?.coordinator.auxTerminalExited(wsId: wsId, paneId: paneId)
        }
        // Same @ai / @omp story as a center terminal pane (spec §4): the
        // side terminal was the one pane family without it — the feed
        // resolving nil left @ai unarmed and @omp firing into nothing.
        wireTerminalTriggers(host: host, ws: ws)
        hostPool[key] = host
        return host
    }

    /// The @ai / @omp / @tty wiring every terminal PaneHost needs,
    /// center or side: the execution-target feed (updateAITrigger
    /// requires it non-nil to arm @ai), the AI card's task start, and
    /// the spawn triggers' launches (an agent space or a terminal tab
    /// in the center, both at the pane's live cwd).
    private func wireTerminalTriggers(host: PaneHost, ws: WorkspaceState) {
        let key = host.hostKey
        host.coordinatorFeed = { [weak self] in
            self?.coordinator.aiTarget(for: key)
        }
        host.onAITask = { [weak self] host, text in
            self?.startAITask(host: host, text: text)
        }
        host.onAgentSessionTrigger = { [weak self] host, agent, prompt in
            guard let self else { return }
            let cwd = self.coordinator.cwd(ofPane: host.hostKey.pane,
                                           in: host.hostKey.workspace)
                ?? host.initialCwd
            self.openAgentSession(agent: agent, cwd: cwd, initialPrompt: prompt)
        }
        host.onTTYTrigger = { [weak self] host in
            guard let self else { return }
            let cwd = self.coordinator.cwd(ofPane: host.hostKey.pane,
                                           in: host.hostKey.workspace)
                ?? host.initialCwd
            self.coordinator.newTab(cwd: cwd)
        }
        host.refreshAITrigger()
    }

    /// Persistent host for one GUI agent session pane (ACP over sessiond).
    func makeAgentPaneHost(pane: PaneState, ws: WorkspaceState,
                           key: HostKey, agentKey: String) -> AgentPaneHost? {
        guard let descriptor = AgentRegistry.descriptor(for: agentKey),
              let environment = agentEnvironment(wsId: ws.id) else { return nil }
        // M2: the pane lives in the workspace's daemon — the ssh-forwarded
        // one for remote workspaces, the local singleton otherwise. A nil
        // remote daemon (link down) means NO host: the layout retries on
        // link-ready, and the server overlay covers the pane meanwhile.
        let daemon: SessionDaemon
        if ws.isRemote {
            guard let link = remoteLinks[ws.id], let forwarded = link.daemon else {
                return nil
            }
            daemon = forwarded
        } else {
            daemon = .shared
        }
        let session = descriptor.make(AgentPaneParams(paneId: key.runtimeId,
                                                      cwd: pane.cwd,
                                                      environment: environment,
                                                      daemon: daemon,
                                                      restoredSessionId: pane.agentSessionId))
        let host = AgentPaneHost(key: key, session: session, agentLabel: descriptor.label)
        host.daemonRef = daemon
        host.initialQueuedOutbox = pane.agentQueuedOutbox ?? []
        host.onQueuedOutboxChange = { [weak self] texts in
            self?.coordinator.setAgentQueuedOutbox(paneId: pane.id, texts: texts)
        }
        host.onSessionId = { [weak self] sid in
            self?.coordinator.setAgentSessionId(paneId: pane.id, sessionId: sid)
        }
        host.onTurnState = { [weak self] state in
            guard let self else { return }
            let activity: AgentActivity
            switch state {
            case .thinking, .executing: activity = .working
            case .awaitingPermission: activity = .blocked
            case .errored: activity = .error
            case .starting, .idle: activity = .idle
            }
            self.coordinator.agentStateUpdated(wsId: ws.id, paneId: pane.id,
                                               state: activity)
        }
        // Live session title → the tab's display name (manual renames
        // still outrank it — see TabState.agentTitle).
        host.onSessionTitle = { [weak self] title in
            self?.coordinator.setAgentTabTitle(paneId: pane.id, name: title)
        }
        // Branch-to-new-pane: the forked session file opens as its own
        // tab (same agent, same cwd); the source pane reloads the
        // original conversation.
        host.onBranchNewPane = { [weak self] forkSessionId in
            self?.coordinator.openAgentBranchTab(agent: agentKey,
                                                 cwd: pane.cwd,
                                                 sessionId: forkSessionId)
        }
        return host
    }

    /// A turn finished where nobody was looking: bounce the dock when
    /// the app is inactive (never while the user IS in the app).
    private func wireAgentAttention() {
        coordinator.turnCompletedUnseen = { [weak self] _, _ in
            guard self != nil, !NSApp.isActive else { return }
            NSApp.requestUserAttention(.informationalRequest)
        }
    }

    func updateRightPanel() {
        guard let store = coordinator.store,
              let ws = store.focused else { return }
        let cwd = coordinator.activePane(of: ws)?.cwd
        let spaceRoot = currentSpaceRoot()
        wc.rightPanel.setSystemTarget(host: ws.isRemote ? ws.sshHost : nil)
        wc.rightPanel.setDirectory(spaceRoot, source: FileSources.source(for: ws))
        wc.rightPanel.setScmTarget(cwd: cwd, host: ws.sshHost)
        refreshSideTerminal(ws: ws, spaceRoot: spaceRoot)
    }

    // MARK: Side terminal (right panel; spec 2026-08-30)

    /// Mount the focused workspace's side terminal into the panel. The
    /// ONLY intent-gated step is creation — no pane exists until the
    /// user actually shows the Terminal tab (a shell per server is a
    /// real process; flipping past the tab must not materialize one),
    /// and an explicitly closed terminal stays closed until the user
    /// reopens it. Once created, the hosts ride every panel refresh:
    /// focus switches, reconnects, cwd/prompt reports, splits all
    /// re-run here.
    func refreshSideTerminal(ws: WorkspaceState, spaceRoot: String?) {
        if prefs.rightPanelTab == .terminal, prefs.rightPanelVisible,
           ws.auxTerminalPanes.isEmpty,
           !coordinator.auxTerminalClosed(wsId: ws.id) {
            _ = coordinator.ensureAuxTerminal()   // .structure → refresh → here
        }
        // `ws` is a VALUE copy taken before ensureAuxTerminal wrote the
        // field — re-read the store, or this frame unmounts the host the
        // .structure pass just mounted (the "terminal never opens" bug).
        guard let live = coordinator.store?.workspaces
                  .first(where: { $0.id == ws.id }),
              let gapp = ghostty.app else {
            wc.rightPanel.setTerminalPanes([])
            return
        }
        // Same normalization as the center grid: persisted split cells →
        // layout fractions. A single full-rect pane lands on (0,0,1,1).
        let panes = live.auxTerminalPanes
        let gridW = max(panes.map { $0.left + $0.width }.max() ?? 1, 1)
        let gridH = max(panes.map { $0.top + $0.height }.max() ?? 1, 1)
        var entries: [(paneKey: HostKey, host: any PaneHosting,
                       fraction: NSRect)] = []
        for pane in panes {
            if let host = makeAuxTerminalHost(ws: live, paneId: pane.id,
                                              spawnCwd: pane.cwd ?? spaceRoot,
                                              gapp: gapp) {
                entries.append((paneKey: host.hostKey, host: host, fraction: NSRect(
                    x: CGFloat(pane.left) / CGFloat(gridW),
                    y: CGFloat(pane.top) / CGFloat(gridH),
                    width: CGFloat(pane.width) / CGFloat(gridW),
                    height: CGFloat(pane.height) / CGFloat(gridH)
                )))
            }
        }
        // setVisiblePanes re-pushes every host's core visibility each
        // pass — the tab switch and panel reveal land here right after
        // the ancestor unhide (the panel's equivalent of the center
        // grid's syncAllCoreVisibility; the "mounted but blank" bug).
        wc.rightPanel.setTerminalPanes(entries)
        // Header: the focused pane's cwd + the cd chip's prompt gate.
        wc.rightPanel.setTerminalCwd(coordinator.focusedAuxPane(of: live)?.cwd)
        wc.rightPanel.setTerminalCd(enabled: coordinator.auxTerminalAtPrompt(wsId: live.id))
    }

    /// The cd chip: type `cd <current space root>` into the FOCUSED
    /// side pane. Same target the Files tab resolves — the center's
    /// active pane's repo root.
    private func cdSideTerminalToCurrentSpace() {
        guard let ws = coordinator.store?.focused,
              let pane = coordinator.focusedAuxPane(of: ws),
              coordinator.auxTerminalAtPrompt(wsId: ws.id),
              let root = currentSpaceRoot() else { return }
        (hostPool[HostKey(workspace: ws.id, pane: pane.id)] as? PaneHost)?
            .sendText(WorkspaceCoordinator.auxCdInjection(to: root))
    }

    /// The center's current space root (Files, the cd chip, one
    /// resolver): the active pane's cwd resolved to its repo root.
    private func currentSpaceRoot() -> String? {
        guard let ws = coordinator.store?.focused else { return nil }
        let cwd = coordinator.activePane(of: ws)?.cwd
        return cwd.flatMap {
            GitStatusStore.shared.spaceRoot(for: $0, host: ws.sshHost)
        } ?? cwd
    }
    /// The one recurring timer + kernel-event watchers (see inline audit).
    private func startPollingAndWatchers() {
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
            // Open diff documents follow git's truth (only while the
            // editor overlay is actually showing them).
            if self?.editorPanelBacking?.visible == true {
                self?.editorPanelBacking?.refreshDiffs()
            }
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
                (self?.hostPool[key] as? PaneHost)?.updateAgentCommand(command)
            }
        }

        // Daemon-side fills (LIST-mined OSC titles, store session
        // titles) only target panes no host is serving: the host's own
        // live parse stays the authority where one exists.
        coordinator.hasLiveHost = { [weak self] key in
            self?.hostPool[key] != nil
        }
    }

    /// Sidebar rows/server header → coordinator actions (launch wiring).
    private func wireSidebarActions() {
        let sidebar = wc.sidebar
        sidebar.onTabSelected = { [weak self] idx in
            guard let self else { return }
            self.coordinator.selectTab(index: idx)
        }
        sidebar.onNewTab = { [weak self] in self?.coordinator.newTab() }
        sidebar.onNewTabInDir = { [weak self] cwd in
            self?.coordinator.newTab(cwd: cwd)
        }
        sidebar.onNewAgentSessionInDir = { [weak self] key, cwd in
            self?.openAgentSession(agent: key, cwd: cwd)
        }
        sidebar.agentAvailable = { [weak self] key in
            self?.agentAvailable(key: key) ?? false
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
        sidebar.onServersExpandChange = { [weak self] expanded in
            self?.prefs.serversCollapsed = !expanded
        }
        sidebar.onSpaceFoldsChange = { [weak self] names in
            self?.prefs.foldedSpaces = names
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
        sidebar.onReorderTab = { [weak self] from, to in
            self?.coordinator.moveTab(from: from, to: to)
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
        sidebar.onUpgradeDaemonWorkspace = { [weak self] idx in
            guard let self, let store = self.coordinator.store,
                  store.workspaces.indices.contains(idx),
                  store.workspaces[idx].isRemote else { return }
            let ws = store.workspaces[idx]
            guard let link = self.remoteLinks[ws.id], link.daemon != nil else { return }
            let sessions = ws.tabs.count
            let host = ws.displayName
            if Dialog.confirm(
                title: "升级 \(host) 上的 Goty daemon？",
                detail: "该主机仍在运行旧版 goty-sessiond（会话跨 GUI 重启存活，所以一直没被替换）。"
                    + "升级后 agent 标识、实时状态与历史记录读取才会生效。"
                    + "重启它会结束该主机上正在运行的 \(sessions) 个会话。",
                action: "重启 Daemon") {
                link.upgradeDaemon()
            }
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
    }

    /// Terminal-region tab strip — the tab surface while the sidebar is a rail.
    private func wireTabStripActions() {
        // The terminal region's top tab strip — the tab surface while
        // the sidebar is collapsed to a rail. Same coordinator actions
        // as the sidebar rows; rename goes through a prompt because
        // the strip has no inline field.
        let strip = wc.terminalArea.tabStrip
        strip.onTabSelected = { [weak self] idx in
            self?.coordinator.selectTab(index: idx)
        }
        strip.onNewTab = { [weak self] in self?.coordinator.newTab() }
        strip.onNewAgentSession = { [weak self] key in
            self?.openAgentSession(agent: key)
        }
        strip.agentAvailable = { [weak self] key in
            self?.agentAvailable(key: key) ?? false
        }
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
    }

    /// Right panel verbs (open file, worktree, remote download).
    private func wireRightPanelActions() {
        let rightPanel = wc.rightPanel
        // Built-in editor: a terminal-REGION overlay (tty7 code panel).
        // Built lazily on first use; visibility maps to
        // terminalArea.presentOverlay/dismissOverlay, so the editor can
        // never touch the window's region constraints (see CLAUDE.md).
        rightPanel.onOpenFile = { [weak self] path in
            guard let self, let ws = self.coordinator.store?.focused else { return }
            self.editorPanel().open(path: path, source: FileSources.source(for: ws))
        }

        rightPanel.onOpenDiff = { [weak self] path, staged, untracked in
            guard let self, let ws = self.coordinator.store?.focused else { return }
            let host = ws.isRemote ? ws.sshHost : nil
            let cwd = self.coordinator.activePane(of: ws)?.cwd
            guard let root = cwd.flatMap({ ScmStore.shared.repoRoot(cwd: $0, host: host) })
                  ?? cwd.flatMap({ ScmStore.shared.cachedStatus(cwd: $0, host: host)?.root })
            else { return }
            self.editorPanel().openDiff(root: root, host: host, path: path,
                                        staged: staged, untracked: untracked,
                                        source: FileSources.source(for: ws))
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

        // Remote Files tab → drag-to-upload: scp -r push over the same
        // ControlMaster. Had the same never-wired hole download did:
        // the drop started a transfer that never ran — the bar sat at
        // "0 bytes · 0%" forever (and survived server switches, since
        // one FilesView serves every workspace).
        rightPanel.onUpload = { [weak self] urls, dir, progress, completion in
            guard let self, let ws = self.coordinator.store?.focused,
                  ws.isRemote, let host = ws.sshHost else {
                DispatchQueue.main.async {
                    completion(.failure(CocoaError(.fileReadUnknown, userInfo: [
                        NSLocalizedDescriptionKey: "upload: no remote workspace"])))
                }
                return
            }
            RemoteFileSource(host: host).upload(urls: urls, into: dir,
                                                progress: progress,
                                                completion: completion)
        }
    }

    /// libghostty relays: splits, paste confirmation, config/theme changes.
    private func observeGhosttyNotifications() {

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
    @objc func menuToggleEditor() {
        editorPanel().toggle()
    }
}

extension AppDelegate: GhosttyAppDelegate {
    func findSurface(forUUID uuid: UUID) -> Ghostty.SurfaceView? {
        hostPool.values.compactMap { $0 as? PaneHost }.first { $0.surfaceView?.id == uuid }?.surfaceView
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
