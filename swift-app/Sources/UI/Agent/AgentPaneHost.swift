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
    /// Forked session to open in a NEW tab (branch-to-new-pane). Wired
    /// by makeAgentPaneHost to the coordinator's tab creation.
    var onBranchNewPane: ((String) -> Void)?
    /// Queued follow-up texts, mirrored from the web's pendingQueue for
    /// PERSISTENCE (omp reports only a count — texts must survive a
    /// restart or the dock list comes back empty while the badge shows
    /// N). Seeded at creation, reconciled against runtimeStatus counts,
    /// re-pushed to the page after the handshake.
    var initialQueuedOutbox: [String] = []
    var onQueuedOutboxChange: (([String]) -> Void)?
    private var queuedOutbox: [String] = []
    private var lastQueueCount = 0
    /// True while a worktree fork (throwaway process) is booting —
    /// both the Swift handler and every BranchButton respect it.
    private var forkInFlight = false
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

    /// Background-job dock rows (daemon LIST poll → coordinator).
    /// Deduped: the poll fires every 2s; unchanged rows must not
    /// re-render the page.
    func applyJobs(_ jobs: [AgentJobSnapshot]) {
        DispatchQueue.main.async { [weak self] in
            guard let self, jobs != self.lastJobsPushed else { return }
            self.lastJobsPushed = jobs
            self.bridge.push(AgentSessionEvent.backgroundJobs(jobs).jsRepresentation)
        }
    }
    private var lastJobsPushed: [AgentJobSnapshot] = []


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
            }
        }
        bridge.onSend = { [weak self] text, mode in
            guard let self else { return }
            switch mode {
            case "steer":
                self.session.steer(text)
            case "followUp":
                self.session.followUp(text)
                self.recordQueued(text)
            default:
                // Stale-idle composer (UI thought idle, the session is
                // actually working): omp tags these Enters "steer" too —
                // interrupt-and-inject matches the streaming-Enter and
                // the message can never evaporate in send()'s isWorking
                // guard (omp input-controller's race coverage).
                if self.session.isWorking {
                    self.session.steer(text)
                    return
                }
                self.setTurnState(.thinking)
                self.session.send(text)
                // An adapter with no live session id (attach replay rotated
                // past the handshake) refuses send() — never leave the
                // composer stuck "working".
                if !self.session.isWorking {
                    self.setTurnState(.errored("未关联到 agent 会话 — 请点重试"))
                }
            }
        }

        bridge.onSetFast = { [weak self] enabled in
            self?.session.setFastMode(enabled: enabled)
        }
        // Branch = worktree semantics: the fork runs in a THROWAWAY
        // process (see forkToNewSession) — this pane's session is never
        // swapped or reloaded, so it works mid-turn too. Both buttons
        // (user-row and agent-tail) route through the new-pane flow.
        bridge.onBranch = { [weak self] entryId in
            self?.bridge.onBranchNewPane?(entryId)
        }
        bridge.onBranchNewPane = { [weak self] entryId in
            guard let self, self.session.sessionId?.isEmpty == false
            else { return }
            // One fork at a time per pane: the throwaway process takes
            // seconds to boot — a second click during that window must
            // not spawn a second fork (the user got N tabs for N clicks).
            guard !self.forkInFlight else { return }
            self.forkInFlight = true
            self.bridge.push(["type": "branchState", "active": true])
            // The fork normally lands in ~14s (throwaway boot + branch).
            // If the process or RPC dies silently the completion would
            // never fire — the button stays dead with no feedback. A
            // one-shot ceiling re-arms it; the idempotent real
            // completion wins the race.
            var settled = false
            func settle(_ forkId: String?) {
                guard !settled else { return }
                settled = true
                self.forkInFlight = false
                self.bridge.push(["type": "branchState", "active": false])
                guard let forkId else {
                    self.bridge.push(AgentSessionEvent.notice(
                        "分支失败：无法从该条目创建分叉会话").jsRepresentation)
                    return
                }
                self.onBranchNewPane?(forkId)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 75) { [weak self] in
                guard let self, self.forkInFlight else { return }
                settle(nil)
            }
            self.session.forkToNewSession(entryId: entryId) { forkId in
                DispatchQueue.main.async {
                    settle(forkId)
                }
            }
        }
        bridge.onExport = { [weak self] in
            guard let self else { return }
            self.session.exportHTML { [weak self] path in
                DispatchQueue.main.async {
                    guard let self else { return }
                    guard let path else {
                        self.bridge.push(AgentSessionEvent.notice("导出失败：agent 未返回文件路径").jsRepresentation)
                        return
                    }
                    // The export lands on the AGENT's host. A remote
                    // agent's file is not a Mac path — never probe the
                    // local filesystem for it (2026-09-01 layering fix).
                    guard self.session.runsOnThisMac else {
                        self.bridge.push(AgentSessionEvent.notice(
                            "已导出到远端主机：\(path)").jsRepresentation)
                        return
                    }
                    guard FileManager.default.fileExists(atPath: path) else {
                        self.bridge.push(AgentSessionEvent.notice("导出失败：agent 未返回文件路径").jsRepresentation)
                        return
                    }
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [URL(fileURLWithPath: path)])
                }
            }
        }

        // History pagination (tail-first loads): the page's sentinel at
        // the top of what it holds asks for older entries; they arrive
        // as ONE transcriptPrepend event the store inserts in front.
        bridge.onLoadOlder = { [weak self] in
            guard let self else { return }
            self.session.loadOlderHistory { [weak self] events in
                DispatchQueue.main.async {
                    self?.bridge.push(AgentSessionEvent
                        .transcriptPrepend(events: events ?? [])
                        .jsRepresentation)
                }
            }
        }
        bridge.onLogin = { [weak self] in
            guard let self else { return }
            self.session.loginProviders { [weak self] providers in
                DispatchQueue.main.async {
                    self?.bridge.push(["type": "loginProviders", "providers": providers])
                }
            }
        }
        bridge.onStartLogin = { [weak self] providerId in
            self?.session.startLogin(providerId: providerId)
        }
        bridge.onStats = { [weak self] in
            guard let self else { return }
            self.session.sessionStats { [weak self] stats in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if let stats {
                        self.bridge.push(AgentSessionEvent.sessionStats(stats).jsRepresentation)
                    } else {
                        self.bridge.push(AgentSessionEvent.notice("该 agent 暂不支持统计").jsRepresentation)
                    }
                }
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
        // Seed the persisted queue mirror BEFORE connect: the handshake's
        // .ready restores these rows to the page (see didEmit .ready).
        queuedOutbox = initialQueuedOutbox
        // GUI-side tools the agent may call (omp set_host_tools):
        // attention, reveal-in-Finder, open-URL. Registered before
        // connect so the handshake's registration sees them.
        session.setHostTools(AgentHostTools(tools: [
            AgentHostTools.Tool(
                name: "goty_attention",
                label: "Goty Attention",
                description: "Bounce the goty dock icon and surface a notice in the agent pane. Use when you need the user to look at the GUI.",
                parameters: ["type": "object",
                             "properties": ["message": ["type": "string",
                                                        "description": "Short reason for the attention request"]],
                             "required": []] as [String: Any],
                run: { arguments in
                    let text = (arguments["message"] as? String) ?? "agent 请求你的注意"
                    DispatchQueue.main.async {
                        NSApp.requestUserAttention(.criticalRequest)
                        self.bridge.push(AgentSessionEvent.notice("🔔 \(text)").jsRepresentation)
                    }
                    return ["content": [["type": "text",
                                         "text": "attention requested"]]]
                }),
            AgentHostTools.Tool(
                name: "goty_reveal",
                label: "Goty Reveal in Finder",
                description: "Reveal a file or directory in the Finder on the user's Mac.",
                parameters: ["type": "object",
                             "properties": ["path": ["type": "string",
                                                     "description": "Absolute path to reveal"]],
                             "required": ["path"]] as [String: Any],
                run: { arguments in
                    guard let path = arguments["path"] as? String else {
                        return ["content": [["type": "text",
                                             "text": "path required"]]]
                    }
                    // Reveal is a MAC-side action; a remote agent's
                    // paths are not Mac paths — answer honestly
                    // instead of probing this Mac's filesystem.
                    guard self.session.runsOnThisMac else {
                        return ["content": [["type": "text",
                                             "text": "\(path) is on the remote host — cannot reveal it in the Mac's Finder"]]]
                    }
                    guard FileManager.default.fileExists(atPath: path) else {
                        return ["content": [["type": "text",
                                             "text": "path not found"]]]
                    }
                    DispatchQueue.main.async {
                        NSWorkspace.shared.activateFileViewerSelecting(
                            [URL(fileURLWithPath: path)])
                    }
                    return ["content": [["type": "text",
                                         "text": "revealed \(path)"]]]
                }),
            AgentHostTools.Tool(
                name: "goty_open",
                label: "Goty Open URL",
                description: "Open a URL or file in the user's default handler (browser/Finder).",
                parameters: ["type": "object",
                             "properties": ["url": ["type": "string",
                                                    "description": "URL or file path to open"]],
                             "required": ["url"]] as [String: Any],
                run: { arguments in
                    guard let raw = arguments["url"] as? String,
                          let url = URL(string: raw),
                          url.scheme != nil else {
                        return ["content": [["type": "text",
                                             "text": "invalid url"]]]
                    }
                    // URLs open on the Mac regardless of where the
                    // agent runs; FILE paths are agent-host paths and
                    // only open when the agent is local.
                    if url.scheme == "file" || !raw.contains("://") {
                        guard self.session.runsOnThisMac else {
                            return ["content": [["type": "text",
                                                 "text": "\(raw) is on the remote host — cannot open it on the Mac"]]]
                        }
                        guard FileManager.default.fileExists(atPath: raw) else {
                            return ["content": [["type": "text",
                                                 "text": "path not found"]]]
                        }
                    }
                    DispatchQueue.main.async {
                        NSWorkspace.shared.open(url)
                    }
                    return ["content": [["type": "text",
                                         "text": "opened \(raw)"]]]
                }),
        ]))
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

    /// Mirror a queued follow-up for restart persistence (see
    /// initialQueuedOutbox). The page keeps its own pendingQueue; this
    /// copy exists only so a GUI restart can rebuild the dock rows.
    private func recordQueued(_ text: String) {
        queuedOutbox.append(text)
        onQueuedOutboxChange?(queuedOutbox)
    }

    /// Turn-state derivation — the ONE place wire events become lifecycle.
    /// Replay traffic derives identically to live (the store is cleared
    /// first, so a rebuild lands on the right state by construction).
    func session(_ session: AgentSessioning, didEmit events: [AgentSessionEvent]) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for event in events {
                switch event {
                case .ready, .configChanged, .userMessage, .userChunk, .messageChunk, .toolCallUpdate, .chunkBoundary:
                    // First handshake-complete signal cancels the
                    // watchdog (configChanged arrives even when an
                    // adapter omits ready).
                    self.handshakeDone = true
                case .turnEnded, .plan, .commandsChanged, .usageUpdate,
                     .permissionRequested, .thoughtChunk, .starting,
                     .runtimeStatus, .notice, .backgroundJobs, .subagentUpdate,
                     .entryMark, .openURL, .sessionStats,
                     .historyTruncated, .transcriptPrepend, .error,
                     .retryScheduled:
                    break
                case .transcriptReset:
                    // Adapter rebuild incoming (death healing): drop the
                    // dead ring's transcript or the fresh history load
                    // would duplicate every block.
                    self.bridge.push(["type": "clearTranscript"])
                }
                switch event {
                case .openURL(let url):
                    // Login flow: host-consumed — open the browser and
                    // skip the page push (the store would reject it).
                    if let target = URL(string: url) {
                        NSWorkspace.shared.open(target)
                    }
                    continue
                case .ready:
                    // A reattach/handshake settles every transient: a
                    // fork left in flight across a GUI restart would
                    // otherwise deadlock the branch button forever
                    // (forkInFlight never resets; the click dies
                    // silently — 2026-09-01 分支无响应 report).
                    if self.forkInFlight {
                        self.forkInFlight = false
                        self.bridge.push(["type": "branchState", "active": false])
                    }
                    // A PENDING PERMISSION outranks everything: the agent
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
                    // Restore the queued-outbox dock rows: omp reports
                    // only a count, so the persisted texts re-seed the
                    // page's pendingQueue. Delivered-while-closed texts
                    // (count 0) drop here — they are in the replay.
                    if self.lastQueueCount == 0 {
                        if !self.queuedOutbox.isEmpty {
                            self.queuedOutbox = []
                            self.onQueuedOutboxChange?([])
                        }
                    } else if !self.queuedOutbox.isEmpty {
                        // FIFO delivery ate the oldest; keep the suffix.
                        if self.queuedOutbox.count > self.lastQueueCount {
                            self.queuedOutbox = Array(
                                self.queuedOutbox.suffix(self.lastQueueCount))
                            self.onQueuedOutboxChange?(self.queuedOutbox)
                        }
                        for text in self.queuedOutbox {
                            self.bridge.push(["type": "queueMessage", "text": text])
                        }
                    }
                    // Handshake settled the session id — new sessions have
                    // no title yet, adopted ones (reattach) may.
                    self.onSessionId?(self.session.sessionId)
                    self.refreshSessionTitle()
                case .runtimeStatus(let status):
                    // Queue-count reconciliation: omp delivers FIFO, so a
                    // shrinking count retires the OLDEST mirrored texts;
                    // zero clears the mirror. Keeps persisted state true
                    // across turns (and GUI restarts).
                    let count = status.queuedMessages ?? 0
                    defer { self.lastQueueCount = count }
                    guard count != self.queuedOutbox.count else { break }
                    if count == 0 {
                        self.queuedOutbox = []
                    } else if count < self.queuedOutbox.count {
                        self.queuedOutbox = Array(
                            self.queuedOutbox.suffix(count))
                    } else { break }
                    self.onQueuedOutboxChange?(self.queuedOutbox)
                case .messageChunk, .thoughtChunk, .chunkBoundary:
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
