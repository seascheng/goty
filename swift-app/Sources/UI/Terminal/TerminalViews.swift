// goty — see CLAUDE.md for the working principles.
import AppKit
import Combine
import GhosttyKit

// MARK: - Pane host

/// Everything a PaneHost needs to reach its sessiond endpoint: which daemon
struct PaneDaemonTarget {
    let daemon: SessionDaemon
    let shell: String
    let args: [String]
    let environment: [String: String]
}

/// One terminal pane: a libghostty EXEC surface fed by a sessiond stream.
final class PaneHost: NSView {
    let paneId: String
    let hostKey: HostKey
    private(set) var surfaceView: Ghostty.SurfaceView?
    private var scrollView: SurfaceScrollView?
    private var session: PaneSession?
    private var surfaceCreated = false
    /// `rebuild_renderer` is destructive, not a health query. Run it once,
    /// while the opaque first-frame cover still hides the surface.
    private var rendererPrepared = false
    private var backingSyncedAtLayout = false
    private var contentRevealed = false
    private var coverView: NSView?
    /// Cross-thread retirement flag: written by retire() on main, read by
    /// every stream frame's guard (and main-side guards). Lock-guarded,
    /// NOT streamQueue.sync — see retire().
    private var retiredFlag = false
    private var retired: Bool {
        get { sharedStateLock.lock(); defer { sharedStateLock.unlock() }
              return retiredFlag }
        set { sharedStateLock.lock(); defer { sharedStateLock.unlock() }
              retiredFlag = newValue }
    }
    private var sessionStarting = false
    private var attached = false
    /// streamQueue only: the reveal hop to main is scheduled once —
    /// revealContent is idempotent and the cover never comes back, so a
    /// frame burst (cat, build output) must not enqueue one closure per
    /// frame.
    private var revealScheduled = false
    /// Grid currently installed in the core; equal-size updates are skipped
    /// so a resize that lands on the live geometry causes no reflow at all.
    private var installedGrid: (columns: UInt16, rows: UInt16)?
    /// Last geometry received from sessiond. At ATTACHED this is the
    /// daemon's live PTY size, so an equal resize would only emit SIGWINCH
    /// and make a full-screen TUI redraw an already-correct screen.
    private var streamGrid: SessionGrid?
    private var targetGrid: SessionGrid?
    private var lastRequestedGrid: SessionGrid?

    /// The pane's byte stream is processed OFF the main thread. libghostty
    /// parses here and pushes apprt actions into the 64-slot app mailbox;
    /// when a burst fills it, the push blocks until `ghostty_app_tick`
    /// drains it — and the vendored app ticks on the MAIN queue. Feeding
    /// from the main thread deadlocks the moment a replay burst outruns a
    /// tick (sampled live: main parked in `__ulock_wait2` inside
    /// ghostty_surface_process_output). Upstream ghostty parses on its IO
    /// read thread for exactly this reason; this queue is our equivalent.
    /// Everything confined to it: receive/processOutput/installGrid, the
    /// grid bookkeeping above, pendingFrames, `attached`/`retired` writes.
    private let streamQueue = DispatchQueue(label: "goty.pane.stream",
                                            qos: .userInitiated)
    /// Geometry last computed on the main thread (layout pass); read on
    /// streamQueue at ATTACHED. Struct value — guarded for torn reads.
    private var lastLayoutGrid: SessionGrid?
    private let sharedStateLock = NSLock()
    private let gapp: ghostty_app_t
    private let initialCwd: String?
    private let launchCommand: String?
    private let daemonTarget: () -> PaneDaemonTarget?


    // Passive agent status (AgentDetect). The OSC tracker always runs
    // (tight byte loop, no allocs); the detection timer only exists while
    // the pane's effective identity has a manifest — that identity is
    // live: the spawn command at first, then whatever agent the user runs
    // in the shell (sessiond's foreground report).
    var onAgentState: ((PaneHost, AgentActivity) -> Void)?
    /// Live surface title (ghostty's OSC 0/2 title, debounced by the
    /// vendored view) — drives the tab's display name.
    var onTitle: ((PaneHost, String) -> Void)?
    private var titleCancellable: Any?
    private var agentCommand: String?
    private let agentOsc = AgentOscTracker()
    private let agentStatus = AgentStatusTracker()
    private var agentContentSeq: UInt64 = 0
    private var detectTimer: Timer?
    var onExited: ((PaneHost) -> Void)?
    var onPaneGone: ((PaneHost) -> Void)?
    var onConnected: ((PaneHost) -> Void)?
    var onDisconnected: ((PaneHost) -> Void)?

    init(app: ghostty_app_t, paneId: String, hostKey: HostKey,
         cwd: String? = nil, command: String? = nil,
         daemonTarget: @escaping () -> PaneDaemonTarget?) {
        self.paneId = paneId
        self.hostKey = hostKey
        self.gapp = app
        self.initialCwd = cwd
        self.launchCommand = command
        self.daemonTarget = daemonTarget
        agentCommand = AgentDetect.hasRules(for: command) ? command : nil
        super.init(frame: .zero)
        agentStatus.onPublish = { [weak self] state, _ in
            guard let self else { return }
            self.onAgentState?(self, state)
        }
        wantsLayer = true
        layer?.backgroundColor = Self.backdropColorForNewHost()?.cgColor
        createSurfaceIfNeeded()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    /// Terminal backdrop follows window transparency (background-opacity/
    /// background-blur): an opaque pane layer would swallow the surface's
    /// alpha behind the terminal — clear both panes of it when the
    /// window composites translucency. applyChromeTheme() re-drives every
    /// live host on config change; the init path reads the live config.
    func setSurfaceBackdrop(_ color: NSColor?) {
        layer?.backgroundColor = color?.cgColor
        coverView?.layer?.backgroundColor = color?.cgColor
    }

    /// The backdrop color for NEW hosts: clear whenever the resolved
    /// config asks for a translucent window, else the theme background.
    static func backdropColorForNewHost() -> NSColor? {
        let conf = liveGhostty?.config
        let translucent = (conf?.backgroundOpacity ?? 1) < 0.999
            || (conf?.backgroundBlur.isEnabled ?? false)
        // CLEAR when translucent — the surface renders its own tint;
        // any fill here double-composites (the mismatched-strip bug).
        return translucent ? nil : Chrome.theme.background
    }

    func createSurfaceIfNeeded() {
        guard !surfaceCreated else { return }
        surfaceCreated = true

        var config = Ghostty.SurfaceConfiguration()
        // MANUAL, not MANUAL_MIRROR: this surface is the ONLY terminal core
        // on the pane's byte stream (sessiond is a raw PTY relay, it answers
        // no protocol queries), so parser-generated terminal replies (CPR,
        // DA1/DA2, XTWINOPS, OSC color/theme queries, focus reports) MUST
        // flow back through onWrite → sendInput → sessiond → PTY. The
        // MIRROR mode exists for a second surface duplicating a stream whose
        // primary core already replies; it suppresses every reply class, and
        // a TUI that probes the terminal on repaint (omp resume's
        // cursor-position sync) blocks forever with no input box drawn and
        // a dead input loop.
        config.ioMode = GHOSTTY_SURFACE_IO_MANUAL
        config.onWrite = { [weak self] bytes in
            self?.session?.sendInput(bytes)
        }
        let view = Ghostty.SurfaceView(gapp, baseConfig: config)
        surfaceView = view
        titleCancellable = view.$title.sink { [weak self] title in
            guard let self else { return }
            self.onTitle?(self, title)
        }
        let scroll = SurfaceScrollView(contentSize: bounds.size, surfaceView: view)
        scroll.synchronizesCoreSurface = false
        scrollView = scroll
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        let cover = NSView()
        cover.wantsLayer = true
        cover.layer?.backgroundColor = Self.backdropColorForNewHost()?.cgColor
        cover.translatesAutoresizingMaskIntoConstraints = false
        addSubview(cover)
        NSLayoutConstraint.activate([
            cover.leadingAnchor.constraint(equalTo: leadingAnchor),
            cover.trailingAnchor.constraint(equalTo: trailingAnchor),
            cover.topAnchor.constraint(equalTo: topAnchor),
            cover.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        coverView = cover

    }
    private func startSessionIfNeeded() {
        guard !retired, !sessionStarting, session == nil,
              !isHidden, window != nil, let grid = currentGrid(),
              let target = daemonTarget() else { return }
        sessionStarting = true
        streamQueue.async { [weak self] in self?.targetGrid = grid }
        let runtimeId = hostKey.runtimeId
        let cwd = initialCwd
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let newSession = target.daemon.openPane(
                id: runtimeId, cwd: cwd, shell: target.shell, args: target.args,
                environment: target.environment, grid: grid,
                // Called on the session's read thread; the stream queue
                // restores per-pane FIFO and keeps parsing off main.
                onFrame: { [weak self] kind, data in
                    guard let self else { return }
                    self.streamQueue.async { self.receive(kind: kind, data: data) }
                },
                onDisconnect: { [weak self] in self?.sessionDisconnected() })
            DispatchQueue.main.async { [weak self] in
                guard let self else { newSession?.close(); return }
                self.sessionStarting = false
                guard !self.retired else { newSession?.close(); return }
                if let newSession {
                    self.session = newSession
                    newSession.start()
                } else {
                    // Session establishment failed (daemon cold-start race,
                    // transient socket refusal) — the pane is NOT gone.
                    // Killing it here would destroy a live session (the
                    // old path fired onPaneGone → killPane + state wipe →
                    // fresh tab at the initial directory). Retry until the
                    // daemon accepts; real exits arrive as EXITED frames.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        [weak self] in self?.startSessionIfNeeded()
                    }
                }
            }
        }
    }
    /// Frames that arrived before the ghostty surface existed. The replay
    /// burst lands within milliseconds of openPane — sometimes before the
    /// vendored view instantiates its surface — and dropping them erased
    /// the restored session (blank screen / "fresh" tab). Flushed on
    /// layout once the surface is live. streamQueue-confined.
    private var pendingFrames: [(UInt8, Data)] = []

    /// streamQueue only. All UI/coordinator side effects hop to main; the
    /// geometry bookkeeping stays inline so Size markers keep their place
    /// in the byte order.
    private func receive(kind: UInt8, data: Data) {
        guard !retired, let view = surfaceView else { return }
        guard let surface = view.surface else {
            pendingFrames.append((kind, data))
            return
        }
        flushPendingFrames()
        switch kind {
        case SessionOutputKind.size:
            guard let grid = SessionGrid(wire: data) else { return }
            streamGrid = grid
            installGrid(grid, in: view)
        case SessionOutputKind.snapshot:
            // Replay is history under possibly several old geometries.
            // Feed the core, but do not present: intermediate grids are not
            // the final state, and painting each one is the flicker. The
            // history also holds the prompt theme's terminal queries —
            // strip them, or the parser regenerates their replies into
            // the PTY as garbage input (see ReplaySanitizer).
            processOutput(ReplaySanitizer.stripQueries(from: data),
                          surface: surface, present: attached)
        case SessionOutputKind.output:
            processOutput(data, surface: surface, present: true)
        case SessionOutputKind.attached:
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.onConnected?(self)
            }
            attached = true
            if let grid = lastLayoutGrid ?? targetGrid {
                targetGrid = grid
                lastRequestedGrid = grid
                installGrid(grid, in: view)
                if grid != streamGrid {
                    session?.resize(grid)
                }
            }
            // One present for the whole replay: the core already holds all
            // replayed bytes reflowed to the final geometry.
            ghostty_surface_refresh(surface)
            DispatchQueue.main.async { [weak self] in self?.revealContent() }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.agentCommand != nil else { return }
                self.startAgentDetection()
            }
        case SessionOutputKind.exited:
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.onExited?(self)
            }
        case SessionOutputKind.error:
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.onPaneGone?(self)
            }
        default:
            break
        }
    }


    private func flushPendingFrames() {
        guard !pendingFrames.isEmpty else { return }
        let frames = pendingFrames
        pendingFrames.removeAll()
        for (kind, data) in frames { receive(kind: kind, data: data) }
    }

    private func installGrid(_ grid: SessionGrid, in view: Ghostty.SurfaceView) {
        if let installed = installedGrid,
           installed.columns == grid.columns, installed.rows == grid.rows {
            return
        }
        if view.setGridSize(columns: grid.columns, rows: grid.rows) != nil {
            installedGrid = (grid.columns, grid.rows)
        }
    }

    /// Debug grid dump (GOTY_DUMP_SCREEN=1): the surface's visible screen
    /// text after output settles — text-level verification, no screenshots.
    private var screenDumpAt = Date.distantPast
    private func dumpScreenIfEnabled() {
        guard ProcessInfo.processInfo.environment["GOTY_DUMP_SCREEN"] == "1",
              let view = surfaceView else { return }
        let now = Date()
        guard now.timeIntervalSince(screenDumpAt) > 1 else { return }
        screenDumpAt = now
        let text = "=== \(Date()) pane \(paneId) attached=\(attached) retired=\(retired) ===\n"
            + view.cachedScreenContents.get()
        try? text.write(to: URL(fileURLWithPath: "/tmp/goty-screen.log"),
                        atomically: true, encoding: .utf8)
    }

    /// streamQueue only. `agentContentSeq` is also read by the main-thread
    /// detect tick — sharedStateLock covers that pair.
    private func processOutput(_ data: Data, surface: ghostty_surface_t, present: Bool) {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress, !raw.isEmpty else { return }
            sharedStateLock.lock()
            agentContentSeq &+= 1
            sharedStateLock.unlock()
            agentOsc.observe(UnsafeBufferPointer(
                start: base.assumingMemoryBound(to: UInt8.self), count: raw.count))
            ghostty_surface_process_output(
                surface, base.assumingMemoryBound(to: UInt8.self), UInt(raw.count))
        }
        if present {
            ghostty_surface_refresh(surface)
            if !revealScheduled {
                revealScheduled = true
                DispatchQueue.main.async { [weak self] in self?.revealContent() }
            }
        }
        dumpScreenIfEnabled()
    }


    @objc private func agentDetectTick() {
        guard attached, !retired, let command = agentCommand else { return }
        guard let view = surfaceView else { return }
        sharedStateLock.lock()
        let seq = agentContentSeq
        sharedStateLock.unlock()
        guard agentStatus.shouldReadScreen(contentSeq: seq) else { return }
        agentStatus.tick(command: command, contentSeq: seq,
                         screen: { [weak view] in view?.cachedScreenContents.get() ?? "" },
                         title: agentOsc.title, progress: agentOsc.progress)
    }

    /// The pane's live foreground command changed (sessiond report). The
    /// detection identity follows it: an agent typed into the shell gets a
    /// fresh grace window and a clean OSC slate, exactly like goty's
    /// agent-change handling.
    func updateAgentCommand(_ fg: String?) {
        let next: String?
        if let fg, AgentCatalog.spec(for: fg) != nil {
            next = fg
        } else {
            next = AgentDetect.hasRules(for: launchCommand) ? launchCommand : nil
        }
        guard next != agentCommand else { return }
        agentCommand = next
        if next != nil {
            agentOsc.clearRetained()
            agentStatus.restartGrace()
            if attached, !retired { startAgentDetection() }
        } else {
            stopAgentDetection()
        }
    }

    private func startAgentDetection() {
        agentStatus.restartGrace()
        guard detectTimer == nil else { return }
        detectTimer = Timer.scheduledTimer(withTimeInterval: AgentStatusTracker.tickInterval,
                                           repeats: true) { [weak self] _ in
            self?.agentDetectTick()
        }
        detectTimer?.tolerance = 0.05
    }

    private func stopAgentDetection() {
        detectTimer?.invalidate()
        detectTimer = nil
    }

    /// Main thread (PaneSession hops the disconnect here). `attached` is
    /// streamQueue-confined, so clear it there.
    private func sessionDisconnected() {
        guard !retired else { return }
        session = nil
        streamQueue.async { [weak self] in self?.attached = false }
        stopAgentDetection()
        onDisconnected?(self)
    }

    private func currentGrid() -> SessionGrid? {
        guard let view = surfaceView, let surface = view.surface,
              bounds.width > 0, bounds.height > 0 else { return nil }
        var metrics = ghostty_surface_grid_metrics_s()
        guard ghostty_surface_grid_metrics(surface, &metrics),
              metrics.cell_width > 0, metrics.cell_height > 0 else { return nil }
        let columns = max(1, Int((bounds.width - metrics.padding_left * 2)
            / metrics.cell_width))
        let rows = max(1, Int((bounds.height - metrics.padding_top * 2)
            / metrics.cell_height))
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        return SessionGrid(
            columns: UInt16(clamping: columns), rows: UInt16(clamping: rows),
            cellWidth: UInt16(clamping: Int((metrics.cell_width * scale).rounded())),
            cellHeight: UInt16(clamping: Int((metrics.cell_height * scale).rounded())))
    }

    func sendText(_ text: String) {
        session?.sendInput(Array(text.utf8))
    }

    func revealContent() {
        guard !contentRevealed else { return }
        contentRevealed = true
        coverView?.removeFromSuperview()
        coverView = nil
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        createSurfaceIfNeeded()
        surfaceView?.viewDidChangeBackingProperties()
        startSessionIfNeeded()
    }

    public override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        createSurfaceIfNeeded()
        guard let surface = surfaceView?.surface else { return }
        let visible = superview != nil && window != nil
        ghostty_surface_set_occlusion(surface, !visible)
        if visible {
            surfaceView?.viewDidChangeBackingProperties()
            startSessionIfNeeded()
        }
    }

    public override func layout() {
        super.layout()
        createSurfaceIfNeeded()
        if !backingSyncedAtLayout, window != nil, bounds.width > 0, bounds.height > 0 {
            backingSyncedAtLayout = true
            surfaceView?.viewDidChangeBackingProperties()
        }
        prepareRendererIfNeeded()
        scrollView?.layoutSubtreeIfNeeded()
        startSessionIfNeeded()
        if let grid = currentGrid() {
            sharedStateLock.lock()
            lastLayoutGrid = grid
            sharedStateLock.unlock()
        }
        if surfaceView?.surface != nil {
            streamQueue.async { [weak self] in self?.flushPendingFrames() }
        }
        // Resize decisions compare against streamQueue-confined bookkeeping;
        // run the tail there so a live burst can't interleave a stale grid.
        if let grid = currentGrid() {
            streamQueue.async { [weak self] in self?.streamResizeIfNeeded(grid) }
        }
    }

    /// streamQueue only: the layout-driven half of the resize protocol.
    private func streamResizeIfNeeded(_ grid: SessionGrid) {
        guard attached, !retired, grid != lastRequestedGrid else { return }
        targetGrid = grid
        lastRequestedGrid = grid
        session?.resize(grid)
    }

    private func prepareRendererIfNeeded() {
        guard !rendererPrepared, !contentRevealed,
              let surface = surfaceView?.surface else { return }
        rendererPrepared = true
        _ = ghostty_surface_rebuild_renderer(surface)
    }
    func retire() {
        // Close the frame source first, then flip `retired` under the
        // lock. NOT streamQueue.sync: the queue can be parked inside
        // libghostty pushing to a full app mailbox that only a
        // MAIN-thread ghostty_app_tick drains — syncing from main
        // deadlocks both queues (the close-server beachball: killPane's
        // final frame burst fills the mailbox right as retire runs).
        // The lock publishes the flip to every in-flight frame at its
        // next guard; queued stream blocks hold strong self-captures,
        // so the surface outlives them by queue FIFO and main never
        // waits.
        session?.close()
        session = nil
        retired = true
        stopAgentDetection()
        removeFromSuperview()
    }
}

// MARK: - Pane grid: persistent hosts, hidden switching (zero flicker)

final class PaneGridView: NSView {

    private struct Item {
        let host: PaneHost
        let fraction: NSRect
        let visible: Bool
    }
    private var items: [Item] = []

    override func draw(_ dirtyRect: NSRect) {
        // Shows only through the 1px gaps between split panes.
        Chrome.theme.hairline.setFill()
        bounds.fill()
    }

    func setVisiblePanes(_ entries: [(paneKey: HostKey, host: PaneHost, fraction: NSRect)],
                         keepAlive: [PaneHost]) {
        var present = Set<HostKey>()
        var newItems: [Item] = []
        for e in entries {
            newItems.append(Item(host: e.host, fraction: e.fraction, visible: true))
            present.insert(e.paneKey)
        }
        // Old items NOT in the fresh snapshot are genuinely gone (entries
        // and keepAlive are built from the same store state) — re-adding
        // them invisibly made the retire loop dead code and leaked one
        // host + timer per closed pane.
        for h in keepAlive where !present.contains(h.hostKey) {
            newItems.append(Item(host: h, fraction: .zero, visible: false))
            present.insert(h.hostKey)
        }
        for item in items where !present.contains(item.host.hostKey) {
            item.host.retire()
        }
        items = newItems
        for item in items where item.host.superview !== self {
            item.host.translatesAutoresizingMaskIntoConstraints = true
            item.host.autoresizingMask = []
            addSubview(item.host)
        }
        for item in items { item.host.isHidden = !item.visible }
        needsLayout = true
    }

    var visibleHosts: [PaneHost] { items.filter(\.visible).map(\.host) }

    override func layout() {
        super.layout()
        let size = bounds.size
        for item in items where item.visible {
            let f = item.fraction
            var frame = NSRect(
                x: f.minX * size.width,
                y: (1.0 - f.maxY) * size.height,
                width: f.width * size.width,
                height: f.height * size.height
            )
            frame = frame.intersection(bounds)
            // Hairline gap between split panes: the grid's hairline
            // background shows through the 0.5px inset on shared edges.
            let multi = items.filter(\.visible).count > 1
            if multi {
                frame.origin.x += 0.5
                frame.origin.y += 0.5
                frame.size.width -= 1
                frame.size.height -= 1
            }
            item.host.frame = frame
            item.host.needsLayout = true
            item.host.createSurfaceIfNeeded()
        }
}
}
