// goty — see CLAUDE.md for the working principles.
import AppKit
import WebKit

/// One GUI agent session pane — the Tauri model. The WKWebView is the
/// pane's entire UI (transcript, cards, composer), served from the
/// bundled assets under `goty://`; Swift is the backend: AgentSession
/// drives the ACP agent, the bridge shuttles commands and events.
final class AgentPaneHost: NSView, PaneHosting, AgentSessionDelegate, ThemeRefreshable {
    let hostKey: HostKey

    /// Sidebar 状态接线（由 AppDelegate 桥到 coordinator）
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
    var onWorkingChange: ((Bool) -> Void)?
    var onPermissionPending: ((Bool) -> Void)?

    private let session: any AgentSessioning
    private let webView: WKWebView
    private let bridge: AgentWebBridge
    private var pendingPrompt: AgentPermissionPrompt?
    /// Registry label ("Claude Code", "omp (GUI)" …) for the starting
    /// chip and timeout diagnostics.
    private let agentLabel: String
    /// Flips on the first handshake-complete signal (configChanged /
    /// ready / transcript events). Until then the composer shows an
    /// explicit starting chip — a hung MCP server must read as
    /// "starting", never as silent nothing (the claude+serena hang).
    private var handshakeDone = false

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
        // Themed placeholder behind the transparent webview: without it
        // the pane is clear until first paint — the full-black agent
        // pane flash. The page paints the same family of color over it.
        layer?.backgroundColor = chromeSurface(Chrome.theme.background).cgColor

        webView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        session.delegate = self
        // Theme first: the page's palette lands before any queued
        // transcript events (push order is preserved).
        bridge.onReady = { [weak self] in
            self?.pushTheme()
            self?.pushMeta()
        }
        bridge.onSend = { [weak self] text in
            guard let self else { return }
            self.bridge.push(["type": "working", "value": true])
            self.session.send(text)
        }
        bridge.onStop = { [weak self] in self?.session.cancel() }
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
            self?.session.load(sessionId: sessionId) { _ in }
        }
        bridge.onListFiles = { [weak self] reply in
            guard let self, let cwd = self.session.cwd else { return reply([]) }
            DispatchQueue.global(qos: .userInitiated).async {
                let files = AgentFileIndex.list(root: cwd)
                DispatchQueue.main.async { reply(files) }
            }
        }
        bridge.onPermissionOption = { [weak self] optionId in
            guard let self, let prompt = self.pendingPrompt else { return }
            self.session.respondPermission(requestID: prompt.requestID, optionId: optionId)
            self.pendingPrompt = nil
            self.onPermissionPending?(false)
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
            self.bridge.push(["type": "status",
                              "text": "\\(self.agentLabel) 启动超时（90 秒未完成握手）。"
                                   + "常见原因：该 agent 的 MCP/hooks 启动慢（项目索引、网络拉取）。"
                                   + "面板已保留，可关闭后重开重试。"])
            self.bridge.push(["type": "working", "value": false])
        }
        session.connect { [weak self] ok in
            if ProcessInfo.processInfo.environment["GOTY_AUTOLOAD_SESSION"] != nil {
                print("GOTY_DEBUG: connect ok=\(ok)")
            }
            DispatchQueue.main.async {
                guard let self else { return }
                // NOT "就绪" here: connect ok only means the pane is up
                // for the non-omp adapters. Readiness is the adapter's
                // .ready event (status "就绪"), which also clears the
                // starting chip — the two must not race apart.
                if !ok {
                    self.bridge.push(["type": "status", "text": "连接失败"])
                }
                if ok, let prompt = self.initialPrompt {
                    self.initialPrompt = nil
                    self.bridge.push(["type": "working", "value": true])
                    self.session.send(prompt)
                }
                // GOTY_AUTOLOAD_SESSION=newest|<sessionId>: diagnostic —
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
        layer?.backgroundColor = chromeSurface(Chrome.theme.background).cgColor
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
        let repo = URL(fileURLWithPath: #filePath) // Sources/UI/Agent/AgentPaneHost.swift
            .deletingLastPathComponent().deletingLastPathComponent() // UI
            .deletingLastPathComponent().deletingLastPathComponent() // Sources
            .deletingLastPathComponent().deletingLastPathComponent() // swift-app
        return repo.appendingPathComponent("agent-web/dist")
    }

    // MARK: PaneHosting

    func setVisible(_ visible: Bool) { isHidden = !visible }
    func syncCoreVisibility() {} // webview 自管生命周期，无需 occlusion 联动
    func createSurfaceIfNeeded() {}
    var windowVisible = true
    func retire() {
        session.shutdown()
        webView.stopLoading()
        // Contract parity with PaneHost.retire: a retired host leaves
        // the view tree — the grid drops it from its item list, and a
        // view left behind kept painting (the ghost agent pane).
        removeFromSuperview()
    }

    // MARK: AgentSessionDelegate（Core 回调，切主线程再碰 UI）

    func session(_ session: AgentSessioning, didEmit events: [AgentSessionEvent]) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for event in events {
                switch event {
                case .ready, .configChanged, .userChunk, .messageChunk:
                    // First handshake-complete signal cancels the
                    // watchdog (configChanged arrives even when an
                    // adapter omits ready).
                    self.handshakeDone = true
                default:
                    break
                }
                if case .permissionRequested(let prompt) = event {
                    self.pendingPrompt = prompt
                    self.onPermissionPending?(true)
                }
                self.bridge.push(event.jsRepresentation)
            }
        }
    }

    func sessionDidFail(_ session: AgentSessioning, reason: String) {
        DispatchQueue.main.async { [weak self] in
            self?.bridge.push(["type": "working", "value": false])
            self?.bridge.push(["type": "status", "text": reason])
        }
    }
}
