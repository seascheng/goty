// goty — see CLAUDE.md for the working principles.
import AppKit
import Combine
import GhosttyKit
import QuartzCore

// MARK: - Pane host

/// Everything a PaneHost needs to reach its sessiond endpoint: which daemon
struct PaneDaemonTarget {
    let daemon: SessionDaemon
    let shell: String
    let args: [String]
    let environment: [String: String]
}

/// One grid-hostable pane view: the terminal surface (PaneHost) or a GUI
/// agent session (AgentPaneHost). PaneGridView and the AppDelegate host
/// pool hold these indifferently.
protocol PaneHosting: NSView {
    var hostKey: HostKey { get }
    func setVisible(_ visible: Bool)
    func syncCoreVisibility()
    func retire()
    /// Terminal panes arm their ghostty surface lazily; agent panes are
    /// always live. Called from the grid's layout pass.
    func createSurfaceIfNeeded()
    var windowVisible: Bool { get set }
}
extension PaneHost: PaneHosting {
    func setVisible(_ visible: Bool) { isHidden = !visible }
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
    /// streamQueue only. OUTPUT frames coalesce here while the stream
    /// queue is backlogged; the scheduled drain block (which runs after
    /// every already-queued frame) feeds them to the core as ONE
    /// process_output + ONE refresh. Upstream ghostty batches the same
    /// way inside its gather/read pipeline (Exec.zig rotating buffers);
    /// idle-time single frames still process immediately — the drain
    /// block is the very next enqueue, adding no latency.
    private var coalescedOutput: [Data] = []
    private var coalesceDrainScheduled = false
    /// streamQueue only. While set (a moment after a resize request),
    /// the coalescing drain postpones itself: a SIGWINCH-triggered TUI
    /// repaint arrives as clear-then-redraw batches, and merging them
    /// into one present removes the first-switch flicker.
    private var holdDrainUntil: Date?
    /// How long after a resize the drain holds. Long enough to span a
    /// TUI's clear/redraw gap (tens of ms), short enough to read as a
    /// single content update, not a stall.
    private static let repaintHoldInterval: TimeInterval = 0.12
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
    /// Spawn directory; the @omp-style trigger falls back to it when
    /// no live cwd is tracked for the pane yet.
    let initialCwd: String?
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

    // AI capture (@ai). The trigger sits at the PTY chokepoint inside
    // onWrite; the tail keeps the last output as task context. Both are
    // Core types owned here, fed from the byte paths below.
    let aiTrigger = LineTrigger()
    /// `@omp [prompt]` → AppDelegate opens an Agent GUI space in this
    /// pane's cwd (capability-checked there).
    var onAgentSessionTrigger: ((PaneHost, String, String?) -> Void)?
    let aiTail = OutputTail()
    /// A trigger fires this with the request text (after the host has
    /// cleared the shell's readline copy of the line).
    var onAITask: ((PaneHost, String) -> Void)?
    /// Live AI target provider (AppDelegate): nil = AI unavailable for
    /// this pane, and the trigger stays unarmed (fail-open — an @ai line
    /// then reaches the shell like any other text).
    var coordinatorFeed: (() -> ExecutionTarget?)?
    private var aiCard: AITaskCard?
    private var lastForegroundCommand: String?

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
        aiTrigger.onTrigger = { [weak self] text in self?.handleAITrigger(text) }
        aiTrigger.onAgentTrigger = { [weak self] key, text in
            self?.handleAgentTrigger(key, text)
        }
        aiTrigger.onPendingEnter = { [weak self] in
            DispatchQueue.main.async { self?.handleAIHistoryEnter() }
        }
        updateAITrigger(nil)
        agentStatus.onPublish = { [weak self] state, _ in
            guard let self else { return }
            self.onAgentState?(self, state)
        }
        wantsLayer = true
        layer?.backgroundColor = Self.backdropPlaceholder().cgColor
        createSurfaceIfNeeded()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }
    /// Terminal backdrop follows window transparency (background-opacity/
    /// background-blur): an opaque pane layer would swallow the surface's
    /// alpha behind the terminal — clear both panes of it when the
    /// window composites translucency. Until the FIRST output byte the
    /// backdrop is an opaque theme placeholder instead: a clear layer
    /// before the surface paints is the full-black pane flash on
    /// translucent windows. applyChromeTheme() re-drives every live
    /// host on config change; the init path reads the live config.
    private var backdropSettled = false

    func setSurfaceBackdrop(_ color: NSColor?) {
        // Pre-first-frame, an explicit nil (the translucent steady
        // state) must not re-expose the pre-paint black gap.
        guard backdropSettled || color != nil else { return }
        layer?.backgroundColor = color?.cgColor
        coverView?.layer?.backgroundColor = color?.cgColor
    }

    /// Backdrop before the surface has content: ALWAYS opaque theme
    /// background — the placeholder that kills the black flash.
    static func backdropPlaceholder() -> NSColor {
        Chrome.theme.background
    }

    /// Steady-state backdrop once content exists: clear when the
    /// resolved config asks for a translucent window — the surface
    /// renders its own tint; any fill here double-composites (the
    /// mismatched-strip bug).
    static func backdropTarget() -> NSColor? {
        let conf = liveGhostty?.config
        let translucent = (conf?.backgroundOpacity ?? 1) < 0.999
            || (conf?.backgroundBlur.isEnabled ?? false)
        return translucent ? nil : Chrome.theme.background
    }

    /// First content arrived: settle the backdrop to its steady state.
    private func settleBackdropOnFirstContent() {
        guard !backdropSettled else { return }
        backdropSettled = true
        let target = Self.backdropTarget()
        DispatchQueue.main.async { [weak self] in
            self?.layer?.backgroundColor = target?.cgColor
            self?.coverView?.layer?.backgroundColor = target?.cgColor
        }
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
            guard let self else { return }
            // The AI trigger gets first refusal on every keystroke: a
            // captured @ai enter is swallowed here, never reaching the
            // PTY. Everything else flows on unchanged.
            let forward = self.aiTrigger.filter(bytes)
            if !forward.isEmpty { self.session?.sendInput(forward) }
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
        cover.layer?.backgroundColor = Self.backdropPlaceholder().cgColor
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
        if kind != SessionOutputKind.output {
            // Byte order across stream markers is absolute: any
            // size/snapshot/attached/exit marker must apply AFTER the
            // output bytes that preceded it, so pending output flushes
            // first.
            flushCoalescedOutput()
        }
        if !backdropSettled {
            switch kind {
            case SessionOutputKind.output, SessionOutputKind.snapshot:
                settleBackdropOnFirstContent()
            default:
                break
            }
        }
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
                          surface: surface, present: false)
        case SessionOutputKind.output:
            coalescedOutput.append(data)
            scheduleCoalescedDrain()
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

    /// streamQueue only. Schedules the coalescing drain: because this is
    /// the same serial queue `receive` runs on, the drain block executes
    /// after every frame already enqueued — a burst becomes exactly one
    /// core parse + one refresh. One block per burst (the flag collapses
    /// repeats).
    private func scheduleCoalescedDrain() {
        guard !coalesceDrainScheduled else { return }
        coalesceDrainScheduled = true
        streamQueue.async { [weak self] in
            self?.runCoalescedDrain()
        }
    }

    /// streamQueue only. The drain body. Inside a repaint-hold window
    /// (see holdDrainUntil) it reschedules itself past the deadline —
    /// the TUI's clear-screen batch and its repaint batch then merge
    /// into ONE process_output + present, and the empty in-between
    /// frame never gets drawn (the core has no damage to render until
    /// the merged block arrives).
    private func runCoalescedDrain() {
        if let until = holdDrainUntil, Date() < until {
            streamQueue.asyncAfter(deadline: .now() + until.timeIntervalSinceNow) { [weak self] in
                self?.runCoalescedDrain()
            }
            return
        }
        coalesceDrainScheduled = false
        holdDrainUntil = nil
        flushCoalescedOutput()
    }

    /// streamQueue only. Feed everything coalesced to the core as one
    /// block. Called by the drain block and as a barrier before stream
    /// markers (size/snapshot/attached/exited) so byte order holds.
    private func flushCoalescedOutput() {
        guard !coalescedOutput.isEmpty else { return }
        let frames = coalescedOutput
        coalescedOutput = []
        guard !retired, let surface = surfaceView?.surface else { return }
        let joined: Data
        if frames.count == 1 {
            joined = frames[0]
        } else {
            let capacity = frames.reduce(0) { $0 + $1.count }
            joined = frames.reduce(into: Data(capacity: capacity)) { $0.append($1) }
        }
        processOutput(joined, surface: surface, present: true)
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
            let buf = UnsafeBufferPointer(
                start: base.assumingMemoryBound(to: UInt8.self), count: raw.count)
            // Buffer straight into the ring: no per-frame Array copy.
            aiTail.append(buf)
            sharedStateLock.lock()
            agentContentSeq &+= 1
            sharedStateLock.unlock()
            agentOsc.observe(buf)
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
    /// fresh grace window and a clean OSC slate, exactly like the
    /// agent-change handling.
    func updateAgentCommand(_ fg: String?) {
        lastForegroundCommand = fg
        updateAITrigger(fg)
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

    // MARK: AI capture (@ai)

    /// The trigger fired on a complete @ai line. The swallowed enter
    /// left the typed characters in the shell's readline buffer — clear
    /// the line (ctrl-u) so nothing partial executes, then hand the
    /// request up. Runs on main (the ghostty app tick thread).
    private func handleAITrigger(_ text: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.sendText("\u{15}")
            self.onAITask?(self, text)
        }
    }

    /// `@omp [prompt]` fired: the agent key IS the prefix, so the rest
    /// is the optional initial prompt. Clear the shell's readline copy
    /// of the line (the swallowed enter left the typed bytes there),
    /// then hand it up.
    private func handleAgentTrigger(_ agent: String, _ text: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.sendText("\u{15}")
            let prompt = text.isEmpty ? nil : text
            self.onAgentSessionTrigger?(self, agent, prompt)
        }
    }

    /// History-recalled enter (↑/ctrl-r): the line's bytes never
    /// passed the input filter — zsh redrew it as PTY output — so read
    /// what the shell actually holds: the rendered cursor row. An @ai
    /// request follows the typed-trigger flow; anything else gets the
    /// swallowed enter re-sent, byte-identical to no interception.
    /// Runs on main, outside the onWrite callback (surface reads must
    /// not re-enter the io path).
    private func handleAIHistoryEnter() {
        guard let match = aiHistoryRowMatch() else {
            sendText("\r")
            return
        }
        sendText("\u{15}")
        switch match.kind {
        case .ai:
            onAITask?(self, match.text)
        case .agent(let key):
            onAgentSessionTrigger?(self, key, match.text.isEmpty ? nil : match.text)
        }
    }

    /// The trigger match on the cursor row, or nil. Failures return
    /// nil → the enter is forwarded (fail-open).
    private func aiHistoryRowMatch() -> LineTrigger.Match? {
        guard let view = surfaceView, let surface = view.surface else { return nil }
        var m = ghostty_surface_grid_metrics_s()
        guard ghostty_surface_grid_metrics(surface, &m) else { return nil }
        var text = ghostty_text_s()
        let sel = ghostty_selection_s(
            top_left: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT,
                                      coord: GHOSTTY_POINT_COORD_EXACT,
                                      x: 0, y: UInt32(m.cursor_row)),
            bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT,
                                          coord: GHOSTTY_POINT_COORD_EXACT,
                                          x: UInt32(m.columns) - 1, y: UInt32(m.cursor_row)),
            rectangle: false)
        guard ghostty_surface_read_text(surface, sel, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        let row = String(cString: text.text)
        if ProcessInfo.processInfo.environment["GOTY_AI_DEBUG"] == "1" {
            FileHandle.standardError.write("AIHISTORY cursor=\(m.cursor_row):\(m.cursor_column) row=\(row.prefix(60))\n".data(using: .utf8)!)
        }
        return LineTrigger.matchFromScreenRow(row)
    }

    /// @ai arms only at a shell prompt with the model provider
    /// configured and a live target — otherwise typing passes through.
    func refreshAITrigger() { updateAITrigger(lastForegroundCommand) }
    private func updateAITrigger(_ fg: String?) {
        let prompt = Self.isShellPrompt(fg)
        let configured = OpenAICompatibleClient.isConfigured
        let feed = coordinatorFeed?() != nil
        let next = prompt && configured && feed
        if ProcessInfo.processInfo.environment["GOTY_AI_DEBUG"] == "1" {
            let why = !prompt ? "fg=\(fg ?? "nil") not a shell" : !configured ? "provider unset" : !feed ? "no target" : "armed"
            FileHandle.standardError.write("AITRIGGER pane=\(paneId) \(why)\n".data(using: .utf8)!)
        }
        aiTrigger.armed = next
        aiTrigger.agentArmed = prompt
    }

    /// True for nil (spawned shell) and the shell basenames — matches
    /// what sessiond's foreground report spells at a plain prompt.
    static func isShellPrompt(_ command: String?) -> Bool {
        guard let command, !command.isEmpty else { return true }
        var base = (command as NSString).lastPathComponent
        if base.hasPrefix("-") { base = String(base.dropFirst()) }
        return ["zsh", "bash", "sh", "fish", "dash", "ash"].contains(base)
    }

    // MARK: AI task card (bottom-anchored overlay)

    /// The card currently presented over this pane (AppDelegate wires
    /// its action callbacks on every coordinator update).
    var currentAITaskCard: AITaskCard? { aiCard }

    func showAITask(_ task: AITask) {
        ensureAICard().render(task: task, target: task.context.target)
    }

    func hideAITask() {
        guard let card = aiCard else { return }
        aiCard = nil
        // Symmetric exit: the same slide+fade the card entered with
        // (apple-design-motion §7); teardown after it lands. Transform
        // only — never touches layout, so constraints stay clean.
        Chrome.animate({
            card.alphaValue = 0
            card.layer?.transform = CATransform3DMakeTranslation(0, -10, 0)
        }, completion: { card.removeFromSuperview() })
    }

    /// Close this pane's card when it's the ⌘⇧A ask: the ask is
    /// app-global (one ask card at a time — a leftover small card next
    /// to a running task card read as two panels). Task cards stay.
    func hideAITaskIfInputMode() {
        if aiCard?.isInputMode == true { hideAITask() }
    }

    /// ⌘⇧A: the card in request-input mode; submitting follows the same
    /// path as a captured @ai line.
    func openAIInputMode() {
        ensureAICard().enterInputMode(target: coordinatorFeed?())
    }

    private func ensureAICard() -> AITaskCard {
        if let aiCard { return aiCard }
        let card = AITaskCard()
        card.translatesAutoresizingMaskIntoConstraints = false
        // Added last → composites above the scroll view; height is
        // content-driven, capped at 60% of the pane (the old 40% cap
        // squeezed header + rounds + answer + buttons into a strip).
        addSubview(card)
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            card.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            card.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            card.heightAnchor.constraint(lessThanOrEqualTo: heightAnchor,
                                         multiplier: 0.6),
        ])
        card.onSubmit = { [weak self] text in
            guard let self else { return }
            self.hideAITask()
            self.onAITask?(self, text)
        }
        aiCard = card
        // Enter: rise from the bottom edge — the same path the exit
        // takes. Guarded transform: layer-less (never-rendered) cards
        // degrade to a plain fade, still symmetric with their exit.
        card.alphaValue = 0
        card.layer?.transform = CATransform3DMakeTranslation(0, -10, 0)
        Chrome.animate {
            card.alphaValue = 1
            card.layer?.transform = CATransform3DIdentity
        }
        return card
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
        // Fixed polarity: this call used to pass `!hosted` — every
        // mounted surface told the core it was INVISIBLE, disabling the
        // vsync display link, disarming the render loop, and dropping
        // the renderer thread to utility QoS. Rendering survived only
        // through the layer-callback fallback path.
        syncCoreVisibility()
        if superview != nil && window != nil {
            surfaceView?.viewDidChangeBackingProperties()
            startSessionIfNeeded()
        }
    }

    /// Window-level visibility input, driven by PaneGridView's occlusion
    /// state (which follows the window being covered/minimized). Main
    /// thread only; defaults to true until the first occlusion event.
    var windowVisible = true
    /// Push the surface's effective visibility to the core:
    /// hosted (in the grid + a window) AND shown (neither the pane nor
    /// any ancestor hidden — overlays hide the whole grid) AND its
    /// window not occluded. With correct polarity the core can run its
    /// vsync display link for the visible focused pane and fully pause
    /// hidden/occluded ones — the same contract native Ghostty enforces
    /// via windowDidChangeOcclusionState.
    func syncCoreVisibility() {
        guard let surface = surfaceView?.surface else { return }
        let hosted = superview != nil && window != nil
        ghostty_surface_set_occlusion(
            surface, hosted && !isHiddenOrHasHiddenAncestor && windowVisible)
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

    /// streamQueue only. The layout-driven half of the resize protocol.
    private func streamResizeIfNeeded(_ grid: SessionGrid) {
        guard attached, !retired, grid != lastRequestedGrid else { return }
        targetGrid = grid
        lastRequestedGrid = grid
        // Repaint-hold: when this resize actually changes the PTY size
        // the daemon emits SIGWINCH and a full-screen TUI repaints in
        // TWO batches (clear screen, then content) a few tens of ms
        // apart. Presenting them separately is the first-switch flicker
        // (text -> blank -> text). Hold the coalescing drain briefly so
        // both batches land in one frame; the old text stays on the
        // layer until then. Cost: output arriving right after a resize
        // shows ~120ms later. Same-size resizes are already a no-op in
        // sessiond (no SIGWINCH, no repaint) — but only the DAEMON
        // knows; holding here is harmless for that case.
        holdDrainUntil = Date().addingTimeInterval(Self.repaintHoldInterval)
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
        let host: any PaneHosting
        let fraction: NSRect
        let visible: Bool
    }
    private var items: [Item] = []

    override func draw(_ dirtyRect: NSRect) {
        // Hairline on the SEAMS only. The old full-bounds fill sat BEHIND
        // the surfaces — invisible at background-opacity 1, but once the
        // window is translucent the surface's bg@opacity composites over
        // black@0.35 and the whole terminal area reads darker than the
        // chrome (pixel-probed 83 vs 119 at opacity 0.6 over white; the
        // "terminal deeper than the sidebars" report). With ≥2 panes the
        // hosts are inset 0.5px on every edge, so stroking each visible
        // host's frame paints exactly the 1px seams (plus the 0.5px ring
        // at the region edge, the same ring the old fill showed). One
        // pane = no seams = nothing to paint.
        guard items.filter(\.visible).count > 1 else { return }
        Chrome.theme.hairline.setStroke()
        let seams = NSBezierPath()
        for item in items where item.visible {
            seams.append(NSBezierPath(
                rect: item.host.frame.insetBy(dx: -0.5, dy: -0.5)))
        }
        seams.lineWidth = 1
        seams.stroke()
    }

    func setVisiblePanes(_ entries: [(paneKey: HostKey, host: any PaneHosting, fraction: NSRect)],
                         keepAlive: [any PaneHosting]) {
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
            item.host.removeFromSuperview()   // ghost-view guard: the host's own retire may not detach
        }
        items = newItems
        for item in items where item.host.superview !== self {
            item.host.translatesAutoresizingMaskIntoConstraints = true
            item.host.autoresizingMask = []
            addSubview(item.host)
        }
        for item in items {
            item.host.setVisible(item.visible)
            // otherwise stays "visible" forever, keeping its renderer
            // armed (occlusionCallback(false) pauses it; true re-renders).
            item.host.syncCoreVisibility()
        }
        needsLayout = true
    }

    /// Window-level occlusion input (NSWindowDelegate path — macOS has
    /// no view-level occlusion callback). The window controller calls
    /// this on windowDidChangeOcclusionState.
    func setWindowVisible(_ visible: Bool) {
        for item in items {
            item.host.windowVisible = visible
            item.host.syncCoreVisibility()
        }
    }

    /// Re-push core visibility for every host after an ancestor's
    /// isHidden flip (overlay present/dismiss hides the whole grid
    /// without touching pane isHidden or occlusion state).
    func syncAllCoreVisibility() {
        for item in items { item.host.syncCoreVisibility() }
    }

    var visibleHosts: [any PaneHosting] { items.filter(\.visible).map(\.host) }

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
