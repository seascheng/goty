// goty — see CLAUDE.md for the working principles.
import AppKit
import WebKit

/// One GUI agent session pane — the Tauri model. The WKWebView is the
/// pane's entire UI (transcript, cards, composer), served from the
/// bundled assets under `goty://`; Swift is the backend: AgentSession
/// drives the ACP agent, the bridge shuttles commands and events.
final class AgentPaneHost: NSView, PaneHosting, AgentSessionDelegate, ThemeRefreshable {
    let hostKey: HostKey

    /// `@gui omp <prompt>` queued prompt: sent once the session is up.
    var initialPrompt: String?
    /// Composer statusbar metadata (agent icon + workspace/folder ·
    /// branch), resolved by the AppDelegate — it can see the store, the
    /// git cache and the brand icon table.
    var metaProvider: (() -> (workspace: String?, directory: String?,
                              branch: String?, icon: String?))?

    /// Push the current meta snapshot; re-run on git changes.
    func pushMeta() {
        guard let m = metaProvider?() else { return }
        func nz(_ s: String?) -> Any { (s?.isEmpty == false) ? s! : NSNull() }
        bridge.push(["type": "meta",
                     "workspace": nz(m.workspace),
                     "directory": nz(m.directory),
                     "branch": nz(m.branch),
                     "icon": nz(m.icon)])
    }

    /// The turn lifecycle as THIS pane sees it. Derived in
    /// session(_:didEmit:) — adapters stay dialect-shaped, the host owns
    /// the machine (paseo's rule: one derivation serves live and replay).
    private(set) var turnState: AgentTurnState = .starting
    /// Sidebar 状态接线（由 AppDelegate 桥到 coordinator）。Every turn
    /// transition funnels through here — the sidebar badge, the composer
    /// chips and the dock attention are all downstream of one source.
    var onTurnState: ((AgentTurnState) -> Void)?
    /// Current session title (main thread). Fires on change only —
    /// handshake, history load, and omp's post-turn auto-naming.
    var onSessionTitle: ((String?) -> Void)?
    /// The pane's live session id — persisted per pane so reopening the
    /// app re-loads the SAME conversation. Fires when it settles.
    var onSessionId: ((String?) -> Void)?
    /// The daemon this pane lives in — the authority for the agent's
    /// REAL state (the omp extension reports working/blocked/idle to
    /// it, surviving client restarts). The composer's working switch is
    /// seeded and corrected from here; client-side isWorking is only a
    /// refinement (thinking vs executing) while the authority says on.
    var daemonRef: SessionDaemon?
    /// Session to re-load after the initial connect (from PaneState) —
    /// for adapters that don't self-manage restore (claude).
    var restoredSessionId: String?
    /// Last title pushed to the page / sidebar; dedups list refreshes.
    private var lastSessionTitle: String?

    /// Look up the live session's title via the adapter's session
    /// directory and push it to the page + host owner. omp names a
    /// session itself seconds AFTER the first turn ends, so callers
    /// re-run this once more past that delay.
    private func refreshSessionTitle() {
        guard let sid = session.sessionId else { return }
        session.listSessions { [weak self] summaries in
            DispatchQueue.main.async {
                guard let self else { return }
                // The session may have been swapped while the listing
                // was in flight — only a title for the CURRENT id lands.
                guard self.session.sessionId == sid else { return }
                let title = summaries.first { $0.sessionId == sid }?.title
                guard title != self.lastSessionTitle else { return }
                self.lastSessionTitle = title
                self.bridge.push(["type": "sessionTitle",
                                  "title": title ?? NSNull()])
                self.onSessionTitle?(title)
            }
        }
    }
    /// True while the reconnect backoff runs (didDisconnect → success).
    private var isReconnecting = false
    private var reconnectAttempt = 0
    private var reconnectWorkItem: DispatchWorkItem?

    private func setTurnState(_ state: AgentTurnState) {
        turnState = state
        switch state {
        case .starting:
            break // pushed explicitly at init, before the page exists
        case .idle:
            bridge.push(["type": "working", "value": false])
            bridge.push(["type": "phase", "value": NSNull()])
        case .thinking:
            bridge.push(["type": "working", "value": true])
            bridge.push(["type": "phase", "value": "thinking"])
        case .executing:
            bridge.push(["type": "working", "value": true])
            bridge.push(["type": "phase", "value": "executing"])
        case .awaitingPermission:
            bridge.push(["type": "working", "value": true])
            bridge.push(["type": "phase", "value": "awaitingPermission"])
        case .errored(let reason):
            bridge.push(["type": "working", "value": false])
            bridge.push(["type": "phase", "value": NSNull()])
            bridge.push(["type": "error", "text": reason])
        }
        onTurnState?(state)
    }

    /// THE working switch, fed by the daemon's extension report — the
    /// same value the tab badge reads, reported by the agent process
    /// itself and immune to client restarts. Rules: a working report
    /// lifts only a pane still STARTING (attach settle owns the rest);
    /// idle stops a working pane; blocked shows the permission card.
    /// Stale reports can't resurrect a stopped agent — the user's stop
    /// is authoritative (2026-08-31 upgrade-dialog storm lesson).
    func applyReportedState(_ activity: AgentActivity?) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isReconnecting else { return }
            switch activity {
            case .working:
                if self.turnState == .starting {
                    self.setTurnState(.thinking)
                }
            case .idle:
                // A stale idle report must not kill a turn the adapter
                // KNOWS is live (isWorking) — e.g. the report lags the
                // user's next prompt and clobbered 思考中 until the
                // model's first token arrived (2026-08-31).
                if (self.turnState == .thinking || self.turnState == .executing),
                   !self.session.isWorking {
                    self.setTurnState(.idle)
                }
            case .blocked:
                if self.session.isWorking, self.turnState != .awaitingPermission {
                    self.setTurnState(.awaitingPermission)
                }
            case .unknown, .error, nil:
                break // no report — nothing authoritative to apply
            }
        }
    }

    /// One authoritative seed right after connect: the daemon holds the
    /// extension's last report for this pane, so a reattach mid-turn
    /// lands on the stop button immediately and an attach to an idle
    /// pane never fakes working while the first chunks are in flight.
    private func seedReportedState() {
        guard let daemon = daemonRef else { return }
        let paneRuntimeId = hostKey.runtimeId
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let reported = daemon.listPanes().first { $0.id == paneRuntimeId }?
                .agent.flatMap(AgentActivity.init)
            DispatchQueue.main.async {
                self?.applyReportedState(reported)
            }
        }
    }

    /// Transport dropped: the process may still be mid-turn (the daemon
    /// keeps it) — show reconnecting and ride the backoff until the
    /// transport reattaches, then let the ring replay rebuild the page.
    func session(_ session: AgentSessioning, didDisconnectBecause reason: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isReconnecting else { return }
            self.setReconnecting()
        }
    }

    private func setReconnecting() {
        isReconnecting = true
        bridge.push(["type": "working", "value": false])
        bridge.push(["type": "phase", "value": NSNull()])
        bridge.push(["type": "reconnecting", "value": true])
        onTurnState?(.starting) // sidebar stays neutral while retrying
        scheduleReconnect()
    }

    /// Backoff 1→2→4→8→10s cap with ±20% jitter (happier's supervisor
    /// shape): fast on a blip, patient on a down host, never a storm.
    private func scheduleReconnect() {
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.session.reconnect { [weak self] ok in
                DispatchQueue.main.async {
                    guard let self else { return }
                    guard ok else {
                        self.scheduleReconnect()
                        return
                    }
                    self.reconnectAttempt = 0
                    self.isReconnecting = false
                    self.bridge.push(["type": "reconnecting", "value": false])
                    // Replay rebuilds the transcript; the page must start
                    // empty or the ring would duplicate every block.
                    self.bridge.push(["type": "clearTranscript"])
                    self.setTurnState(.idle)
                }
            }
        }
        reconnectWorkItem = item
        let base = min(pow(2.0, Double(reconnectAttempt)), 10)
        let delay = base * (0.8 + Double.random(in: 0...0.4))
        reconnectAttempt += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private let session: any AgentSessioning
    private let webView: WKWebView
    private let bridge: AgentWebBridge
    private var pendingPrompt: AgentPermissionPrompt?
    /// Registry label ("Claude Code", "omp (GUI)" …) for the starting
    /// chip and timeout diagnostics.
    private let agentLabel: String
    /// Composer `@` file index: nil = the Mac; an ssh host routes the
    /// listing through the remote transport. Set by makeAgentPaneHost.
    var fileIndexHost: String?
    /// Flips on the first handshake-complete signal (configChanged /
    /// ready / transcript events). Until then the composer shows an
    /// explicit starting chip — a hung MCP server must read as
    /// "starting", never as silent nothing (the claude+serena hang).
    private var handshakeDone = false
    /// Themed cover ABOVE the webview until the page has painted; see
    /// the setup comment for why a fill below cannot work.
    private let coverView = NSView()


    init(key: HostKey, session: any AgentSessioning, agentLabel: String) {
        self.hostKey = key
        self.session = session
        self.agentLabel = agentLabel

        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(
            AgentSchemeHandler(root: Self.webAppDirectory()),
            forURLScheme: "goty")
        // Ephemeral store: asset caches must never outlive a build.
        config.websiteDataStore = WKWebsiteDataStore.nonPersistent()
        webView = WKWebView(frame: .zero, configuration: config)
        // The page paints its own themed background; without this the
        // pane flashes white until first paint.
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .clear
        bridge = AgentWebBridge(webView: webView)

        super.init(frame: .zero)
        wantsLayer = true
        // Themed placeholder behind the transparent webview — OPAQUE,
        // the terminal pane's pre-paint convention (PaneHost). The
        // steady-state fill is set when the cover drops: the page's
        // bg-alpha must be the pane's ONLY alpha layer, and a
        // chromeSurface host under it double-composited the pane to
        // ~0.96 while terminals sat at 0.8 (the "agent pane opacity
        // doesn't match" report).
        layer?.backgroundColor = PaneHost.backdropPlaceholder().cgColor

        webView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        // …and ABOVE it: WKWebView's own compositing layer paints black
        // until the content process renders (verified live — a fill
        // UNDER the webview never shows), so the placeholder has to
        // cover it. Dropped one beat after the page's ready signal
        // (React 18 commit is scheduled, not synchronous).
        coverView.wantsLayer = true
        coverView.layer?.backgroundColor = PaneHost.backdropPlaceholder().cgColor
        coverView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(coverView)
        NSLayoutConstraint.activate([
            coverView.topAnchor.constraint(equalTo: topAnchor),
            coverView.leadingAnchor.constraint(equalTo: leadingAnchor),
            coverView.trailingAnchor.constraint(equalTo: trailingAnchor),
            coverView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        session.delegate = self
        // Theme first: the page's palette lands before any queued
        // transcript events (push order is preserved).
        bridge.onReady = { [weak self] in
            self?.pushTheme()
            self?.pushMeta()
            // Drop the cover one beat after the ready signal: React's
            // first commit is scheduled, not synchronous.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                self?.coverView.removeFromSuperview()
                // Settle like a terminal pane post-first-paint: clear
                // when the window is translucent (the page body at
                // bg-alpha is the single composite), theme background
                // when opaque.
                self?.layer?.backgroundColor = PaneHost.backdropTarget()?.cgColor
            }
            if ProcessInfo.processInfo.environment["GOTY_FOCUS_DEBUG"] != nil {
                self?.dumpFocusState("pageReady")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    self?.dumpFocusState("t+1.5s")
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                    self?.dumpFocusState("t+5s")
                }
            }
        }
        bridge.onSend = { [weak self] text in
            guard let self else { return }
            self.setTurnState(.thinking)
            self.session.send(text)
            // An adapter with no live session id (attach replay rotated
            // past the handshake) refuses send() — never leave the
            // composer stuck on "working" for a turn that never started.
            if !self.session.isWorking {
                self.setTurnState(.errored("未关联到 agent 会话 — 请点重试"))
            }
        }
        bridge.onStop = { [weak self] in self?.session.cancel() }
        bridge.onReconnect = { [weak self] in
            guard let self, !self.isReconnecting else { return }
            // User-invoked (重试 after an errored pane): run the same
            // attach-or-respawn path the automatic loop uses.
            self.session.reconnect { [weak self] ok in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if ok {
                        self.bridge.push(["type": "clearTranscript"])
                        self.setTurnState(.idle)
                    } else {
                        self.setTurnState(.errored("重连失败"))
                    }
                }
            }
        }
        bridge.onSetConfig = { [weak self] configId, value in
            self?.session.setConfigOption(id: configId, value: value)
        }
        bridge.onListSessions = { [weak self] in
            guard let self else { return }
            self.session.listSessions { summaries in
                DispatchQueue.main.async {
                    self.bridge.push(["type": "sessions", "sessions": summaries.map { summary in
                        ["sessionId": summary.sessionId,
                         "cwd": summary.cwd ?? NSNull(),
                         "title": summary.title ?? NSNull(),
                         "updatedAt": summary.updatedAt ?? NSNull(),
                         "messageCount": summary.messageCount ?? NSNull()] as [String: Any]
                    }])
                }
            }
        }
        bridge.onLoadSession = { [weak self] sessionId in
            guard let self else { return }
            // A load swaps the conversation under the pane: the page
            // starts from the replayed history alone.
            self.bridge.push(["type": "clearTranscript"])
            self.session.load(sessionId: sessionId) { [weak self] _ in
                DispatchQueue.main.async { self?.refreshSessionTitle() }
            }
        }
        bridge.onListFiles = { [weak self] reply in
            guard let self, let cwd = self.session.cwd else { return reply([]) }
            DispatchQueue.global(qos: .userInitiated).async {
                let files = AgentFileIndex.list(root: cwd, host: self.fileIndexHost)
                DispatchQueue.main.async { reply(files) }
            }
        }
        bridge.onPermissionOption = { [weak self] optionId in
            guard let self, let prompt = self.pendingPrompt else { return }
            self.session.respondPermission(requestID: prompt.requestID, optionId: optionId)
            self.pendingPrompt = nil
            // The tool that asked is about to run; the next transcript
            // event re-derives from there.
            self.setTurnState(.executing)
        }

        webView.load(URLRequest(url: URL(string: "goty://app/index.html")!))
        // Phase 1 — starting: the bridge queues pushes until the page
        // is ready, so this lands as the first chip the composer shows;
        // it clears on the first handshake-complete event.
        bridge.push(AgentSessionEvent.starting(agent: agentLabel).jsRepresentation)
        // Handshake watchdog: every adapter signals completion with
        // configChanged/ready (omp session/new, claude system/init,
        // codex thread/start, pi get_state). A pane stuck before that —
        // claude's serena MCP indexing a huge repo for 10+ minutes —
        // must surface as an explicit timeout, not silent nothing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 90) { [weak self] in
            guard let self, !self.handshakeDone else { return }
            self.setTurnState(.errored(
                "\(self.agentLabel) 启动超时（90 秒未完成握手）。"
                + "常见原因：该 agent 的 MCP/hooks 启动慢（项目索引、网络拉取）。"
                + "面板已保留，可重试或关闭后重开。"))
        }
        session.connect { [weak self] ok in
            if ProcessInfo.processInfo.environment["GOTY_AUTOLOAD_SESSION"] != nil {
                print("GOTY_DEBUG: connect ok=\(ok)")
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if !ok {
                    self.setTurnState(.errored("连接失败"))
                }
                // Restored pane: re-load the session the user last had
                // here (omp session/load). Adapters that self-manage
                // restore (claude: store replay + --resume respawn)
                // already handled it inside connect.
                if ok, let restore = self.restoredSessionId,
                   !self.session.selfManagesRestore {
                    self.session.load(sessionId: restore) { _ in }
                }
                if ok, let prompt = self.initialPrompt {
                    self.initialPrompt = nil
                    self.setTurnState(.thinking)
                    self.session.send(prompt)
                }
                // Authority seed: align the composer with the process's
                // real state before the first live frames decide it.
                if ok {
                    self.seedReportedState()
                }
                // resume a persisted session right after connect and dump
                // the page store. Set only when launching from a terminal.
                if ok, let target = ProcessInfo.processInfo.environment["GOTY_AUTOLOAD_SESSION"] {
                    self.debugAutoload(target: target)
                }
            }
        }
    }

    /// Diagnostic reproduction path for large-session resume; requires
    /// the GOTY_AUTOLOAD_SESSION environment variable.
    private func debugAutoload(target: String) {
        print("GOTY_DEBUG: autoload entry connected")
        // Early phase snapshots: taken once the page can answer (the
        // bundle takes seconds to boot), while the agent handshake may
        // still be in flight. Shows the starting chip coming and going.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            self.webView.evaluateJavaScript(
                "JSON.stringify({starting: window.__gotyStore ? window.__gotyStore.starting : 'no-store'})"
            ) { r, err in
                print("GOTY_DEBUG EARLY:", err.map { "ERR \($0)" } ?? (r as? String ?? "nil"))
            }
        }
        if target != "newest" {
            runAutoload(sessionId: target, t0: Date())
            return
        }
        session.listSessions { [weak self] list in
            DispatchQueue.main.async {
                guard let self, let sid = list.first?.sessionId else {
                    print("GOTY_DEBUG: no session to autoload")
                    return
                }
                self.runAutoload(sessionId: sid, t0: Date())
            }
        }
    }

    private func runAutoload(sessionId sid: String, t0: Date) {
        print("GOTY_DEBUG: loading", sid)
        session.load(sessionId: sid) { ok in
            DispatchQueue.main.async {
                print("GOTY_DEBUG: load ok=\(ok) in \(Date().timeIntervalSince(t0))s replayBytes=\(self.session.debugReplayBytes) frames=\(self.session.debugReplayFrames)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                    self.webView.evaluateJavaScript("""
                        JSON.stringify({
                          revision: window.__gotyStore.revision,
                          starting: window.__gotyStore.starting,
                          blocks: window.__gotyStore.blocks.length,
                          users: window.__gotyStore.blocks.filter(b => b.kind === 'user').length,
                          tailKind: window.__gotyStore.blocks[window.__gotyStore.blocks.length-1]?.kind ?? 'none',
                          tailText: ((window.__gotyStore.blocks[window.__gotyStore.blocks.length-1]?.text) ?? '').slice(-100),
                        })
                        """) { r, err in
                        print("GOTY_DEBUG STORE:", err.map { "ERR \($0)" } ?? (r as? String ?? "nil"))
                    }
                }
            }
        }
    }

    /// The webview joins the app-wide theme fan-out: ThemeRefreshable
    /// walk → fresh CSS vars → live restyle, no rebuild.
    func pushTheme() {
        AgentTheme.push(to: bridge)
    }

    func retheme() {
        layer?.backgroundColor = PaneHost.backdropTarget()?.cgColor
        coverView.layer?.backgroundColor = PaneHost.backdropPlaceholder().cgColor
        pushTheme()
        pushMeta()   // the icon tint is theme-derived
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }

    /// Packaged bundle first; repo fallback for run-tests/dev tools.
    static func webAppDirectory() -> URL {
        if let bundled = Bundle.main.url(forResource: "index", withExtension: "html",
                                         subdirectory: "agent-web") {
            return bundled.deletingLastPathComponent()
        }
        // #filePath is relative when run-tests compiles from swift-app/ —
        // complete it with the process cwd (filestest's rule), or the
        // deletions below fall through "" into "/".
        var sourcePath = #filePath
        if !sourcePath.hasPrefix("/") {
            sourcePath = FileManager.default.currentDirectoryPath + "/" + sourcePath
        }
        let repo = URL(fileURLWithPath: sourcePath) // Sources/UI/Agent/AgentPaneHost.swift
            .deletingLastPathComponent().deletingLastPathComponent() // UI/Agent
            .deletingLastPathComponent() // Sources
            .deletingLastPathComponent() // swift-app
        return repo.appendingPathComponent("agent-web/dist")
    }

    // MARK: PaneHosting

    func setVisible(_ visible: Bool) { isHidden = !visible }
    func focusAsPane() {
        window?.makeFirstResponder(webView)
    }
    func syncCoreVisibility() {} // webview 自管生命周期，无需 occlusion 联动
    func createSurfaceIfNeeded() {}
    var windowVisible = true
    func retire() {
        reconnectWorkItem?.cancel()
        session.shutdown()
        webView.stopLoading()
        // Contract parity with PaneHost.retire: a retired host leaves
        // the view tree — the grid drops it from its item list, and a
        // view left behind kept painting (the ghost agent pane).
        removeFromSuperview()
    }

    // MARK: AgentSessionDelegate（Core 回调，切主线程再碰 UI）

    /// GOTY_FOCUS_DEBUG: dump every link of the focus chain for this
    /// pane — window responder, webview responder, page activeElement.
    func dumpFocusState(_ tag: String) {
        guard ProcessInfo.processInfo.environment["GOTY_FOCUS_DEBUG"] != nil else { return }
        let fr = window?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        print("FOCUS[\(agentLabel)] \(tag): windowFR=\(fr) webViewIsFR=\(window?.firstResponder === webView)")
        webView.evaluateJavaScript(
            "document.activeElement ? document.activeElement.tagName + '.' + (document.activeElement.className || '') : 'none'"
        ) { r, err in
            print("FOCUS[\(self.agentLabel)] \(tag): pageActive=\(err.map { "ERR \($0)" } ?? (r as? String ?? "nil"))")
        }
    }

    /// Turn-state derivation — the ONE place wire events become lifecycle.
    /// Replay traffic derives identically to live (the store is cleared
    /// first, so a rebuild lands on the right state by construction).
    func session(_ session: AgentSessioning, didEmit events: [AgentSessionEvent]) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for event in events {
                switch event {
                case .ready, .configChanged, .userMessage, .userChunk, .messageChunk, .toolCallUpdate:
                    // First handshake-complete signal cancels the
                    // watchdog (configChanged arrives even when an
                    // adapter omits ready).
                    self.handshakeDone = true
                case .turnEnded, .plan, .commandsChanged, .usageUpdate,
                     .permissionRequested, .thoughtChunk, .starting:
                    break
                case .transcriptReset:
                    // Adapter rebuild incoming (death healing): drop the
                    // dead ring's transcript or the fresh history load
                    // would duplicate every block.
                    self.bridge.push(["type": "clearTranscript"])
                }
                switch event {
                case .ready:
                    // A PENDING PERMISSION outranks everything: the agent
                    // is blocked waiting for the user's answer. Overriding
                    // awaitingPermission with thinking/idle (2026-08-31)
                    // hid the revival card on reattach and left the agent
                    // blocked forever behind a lying "思考中".
                    if self.pendingPrompt != nil {
                        self.setTurnState(.awaitingPermission)
                    } else if self.session.isWorking {
                        // claude's SDK `init` frame re-fires at EVERY turn
                        // start; a ready with isWorking set is the attach
                        // settle for a live turn — stop button, not idle.
                        self.setTurnState(.thinking)
                    } else {
                        self.setTurnState(.idle)
                    }
                    // Handshake settled the session id — new sessions have
                    // no title yet, adopted ones (reattach) may.
                    self.onSessionId?(self.session.sessionId)
                    self.refreshSessionTitle()
                case .messageChunk, .thoughtChunk:
                    // Replay/history chunks also arrive as these events
                    // (ring reattach, session load). Only a LIVE turn
                    // (the adapter's isWorking) means 思考中 — history
                    // must leave the pane idle, never stuck thinking.
                    if self.session.isWorking {
                        self.setTurnState(.thinking)
                    }
                case .toolCallUpdate(_, _, _, let status, _, _, _, _):
                    // Same replay rule as the chunk cases above: a
                    // settled replayed tool (ring reattach) used to flip
                    // the pane back to thinking forever.
                    guard self.session.isWorking else { break }
                    // pending/in_progress = a tool runs; a settled tool
                    // hands the floor back to the model (until turn end).
                    self.setTurnState(
                        (status == "pending" || status == "in_progress")
                        ? .executing : .thinking)
                case .turnEnded:
                    self.setTurnState(.idle)
                    self.onSessionId?(self.session.sessionId)
                    // omp's title-generator lands the name seconds after
                    // the turn; query now and once more past the delay.
                    self.refreshSessionTitle()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                        self?.refreshSessionTitle()
                    }
                case .permissionRequested(let prompt):
                    self.pendingPrompt = prompt
                    // NO isWorking gate: a reattach replays the pending
                    // permission request BEFORE the ready event settles
                    // isWorking — gating it silently dropped the revival
                    // card and left the agent blocked forever.
                    self.setTurnState(.awaitingPermission)
                default:
                    break
                }
                self.bridge.push(event.jsRepresentation)
            }
        }
    }

    func sessionDidFail(_ session: AgentSessioning, reason: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // A failure inside the reconnect loop (handshake against a
            // half-up daemon…) must not fight the loop — it already
            // schedules the next attempt.
            guard !self.isReconnecting else { return }
            self.setTurnState(.errored(reason))
        }
    }
}
