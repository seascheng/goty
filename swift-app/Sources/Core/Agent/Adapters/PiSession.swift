// goty - see CLAUDE.md for the working principles.
import Foundation

/// One harness of the pi-mono family over `--mode rpc` — JSONL frames
/// on a LineChannel pane. Commands carry optional ids; responses match
/// by id. Events stream as id-less frames; PiFrameMapper shapes them.
///
/// This is the TRANSPORT CORE: framing, request/response, the replay
/// gate, state polling and the event choke point. The two dialects of
/// the family diverge through overridable hooks, NOT branches:
///
/// - `PiLegacySession` — pi 0.8x: immediate get_state handshake,
///   get_messages replay, PiSessionStore;
/// - `OmpSession` — omp 18: negotiate_protocol v2 + ready-gated
///   handshake, session-store replay, host tools, branch, fast mode,
///   login, export/stats, pushed command directory.
///
/// Probed live on omp 18.0.11 / pi 0.84.3.
class PiSession: AgentSessioning {
    weak var delegate: AgentSessionDelegate?

    let cwd: String?
    private(set) var sessionId: String?
    var isWorking = false
    /// When the last user `send` went out (optimistic working window).
    private var lastSendAt: Date?
    /// Consecutive get_state reads reporting a fully idle agent while
    /// `isWorking` is still true (missed agent_settled — e.g. /compact
    /// runs no ordinary turn). Two in a row confirm it is not a
    /// slow-to-start model or a one-off glitch.
    private var idlePollStreak = 0
    /// Previous poll's RAW isCompacting read — debounce input for
    /// effectiveCompacting (see applyLiveState).
    private var lastPollCompacting = false
    /// A builtin slash command parked while a turn runs: pi-mono parses
    /// builtins ONLY on the prompt path — steer frames inject the text
    /// into the model's turn where it is never parsed — and (omp
    /// 18.0.11, probed 2026-09-01) a prompt mid-stream kills the
    /// running turn. Flushed by turnSettled(); last command wins.
    private var pendingCommandText: String?

    /// True when the handshake attached onto a turn already in flight
    /// (omp attach). The store replay freezes that turn's tool cards at
    /// their in-flight statuses; when the turn settles we rebuild the
    /// transcript from the settled store once — see emit().
    var reattachedMidTurn = false
    private var staleTailRereadDone = false
    /// Deferred ring-mined command directory (omp) awaiting the
    /// handshake's sessionId; flushed in handleStateResponse.
    var pendingCommandsCache: [AgentSlashCommand]?
    /// Live tool calls in pending/in_progress. Long tool executions
    /// read isStreaming=false on some agents; an open tool call vetoes
    /// the missed-settle heal.
    private var activeToolIds: Set<String> = []
    private(set) var configOptions: [AgentConfigOption] = []
    private(set) var commands: [AgentSlashCommand] = []
    let paneId: String
    let environment: [String: String]
    let daemon: SessionDaemon
    private let grid: SessionGrid
    let channel = LineChannel()

    /// get_state's model descriptor — the thinking-level ladder is
    /// model-specific (thinking.efforts), so applyState needs it when
    /// get_available_models lands.
    var currentModelDescriptor: [String: Any]?
    var thinkingLevelCache: String?
    var cachedModelCatalog: [[String: Any]] = []
    let mapper: PiFrameMapper
    var pane: PaneSession?
    /// omp handshake gate: the ready frame (not spawn) starts
    /// negotiate+get_state — see OmpSession.interceptProtocolFrame.
    var handshakeStarted = false
    var readyCompletion: ((Bool) -> Void)?
    private var connected = false
    var lastSessionId: String?
    /// Replay gate: on a resume spawn every event is buffered until the
    /// authoritative store replay lands, then released in order —
    /// clearTranscript → store history → buffered live frames. Without
    /// the gate, live chunks of a CONTINUED turn render first, get wiped
    /// by the later transcriptReset, and turn stats rendered before the
    /// reset are lost outright (2026-08-31 restart-mid-stream report).
    private var replayGateActive = false
    private var gatedEvents: [AgentSessionEvent] = []
    private var replayGateTimeout: DispatchWorkItem?
    private var resumeSessionId: String?
    var nextRequestID = 1
    let responseLock = NSLock()
    private var pendingResponses: [String: ([String: Any]) -> Void] = [:]

    /// omp attach: ring frames are SIGNAL-ONLY while the authoritative
    /// transcript is read from the session store (the ring's callback
    /// order is not chronological; rendering it scrambled transcripts).
    private var suppressReplay = false

    /// v2 chunked frames (omp): base64 rpc_chunk sequences reassembled
    /// per chunkId (≤64 MiB, ≤4096 parts — omp's ready-frame caps).
    /// Inert for pi — it never emits rpc_chunk.
    private struct ChunkAssembly {
        var count: Int
        var parts: [Int: Data]
        var bytes: Int
    }
    private var chunkAssemblies: [String: ChunkAssembly] = [:]

    /// Integrity accounting.
    private(set) var framesRouted = 0
    /// Extension dialog frames awaiting an answer: rpc frame id →
    /// method ("select"/"confirm"/"input"/"editor"/"open_url").
    private var pendingDialogs: [Int: String] = [:]
    /// Host-owned tools (set_host_tools), registered once after the
    /// first successful handshake (omp; OmpSession.registerExtras).
    var hostTools: AgentHostTools?
    /// 2s get_state poll: the status strip's context/throughput/queue
    /// numbers move mid-turn and todoPhases need post-tool refreshes.
    private var stateTimer: DispatchSourceTimer?

    /// The mapper's terminal-frame flag rides the initializer instead
    /// of an open hook: Swift's two-phase init forbids self dispatch
    /// before every stored property is initialized (the mapper
    /// included). omp passes true; the pi default stays false.
    init(params: AgentPaneParams, mapperTerminalOnAgentEnd: Bool = false) {
        self.paneId = params.paneId
        self.cwd = params.cwd
        self.environment = params.environment
        self.daemon = params.daemon
        self.grid = AgentPaneDefaults.grid
        self.mapper = PiFrameMapper(terminalOnAgentEnd: mapperTerminalOnAgentEnd)
        self.resumeSessionId = params.restoredSessionId
        channel.onOutbound = { [weak self] in self?.pane?.sendInput($0) }
        channel.onFrame = { [weak self] frame, _ in
            self?.handleFrame(frame)
        }
    }

    // MARK: - dialect hooks

    /// Process name for argv, diagnostics and failure messages.
    var shellName: String { "pi" }
    /// The pane (and its store) live on the daemon's machine.
    var runsOnThisMac: Bool { !daemon.isRemote }
    /// omp renders its transcript from the session store, not the ring.
    var suppressesRingReplay: Bool { false }
    /// Dialect resume/argv decoration (omp: --cwd/--resume + replay
    /// gate; pi: --session when the store still has it).
    func appendSpawnArgs(_ args: inout [String], resume sessionId: String?) {}
    /// Spawn handshake kickoff: omp waits for the ready frame (or its
    /// timeout probe), pi asks immediately.
    func beginHandshakeAfterSpawn(completion: ((Bool) -> Void)?) {
        handshake(completion: completion)
    }
    /// The handshake's state round-trip: omp negotiates protocol v2
    /// first, pi goes straight to get_state.
    func requestAgentState(_ completion: @escaping ([String: Any]) -> Void) {
        request("get_state", completion: completion)
    }
    /// omp: the handshake attached onto a live turn — adopt streaming
    /// as working state.
    func adoptAttachedState(_ state: [String: Any]) {}
    /// Command directory + dialect extras right after the handshake
    /// completes (pi: get_commands; omp: cache/probe + models).
    func loadCommandsAfterHandshake() {}
    /// omp-only extras after a successful handshake: host tool
    /// definitions and the subagent progress subscription.
    func registerExtras() {}
    /// Persisted-session directory filtered to the pane cwd. Async: the
    /// omp dialect answers from the DAEMON's store (remote panes), pi
    /// from the local PiSessionStore — hooks own their threading and
    /// must always call the completion.
    func sessionSummaries(_ completion: @escaping ([AgentSessionSummary]) -> Void) {
        completion([])
    }
    /// Post-load resync (pi replays get_messages; omp renders through
    /// the replay gate already opened by the spawn).
    func completeSessionLoad(_ completion: @escaping (Bool) -> Void) {
        completion(true)
    }
    /// Protocol plumbing interception (omp: the ready frame of a LIVE
    /// pane arrives only inside the ring replay and starts the
    /// handshake). true = frame consumed.
    func interceptProtocolFrame(_ frame: [String: Any]) -> Bool { false }
    /// Authoritative history for the replay gate (omp: the session
    /// store, read through the daemon on remote panes). nil = nothing
    /// stored → gate releases bare. Hooks own their threading and must
    /// always call the completion.
    func readStoredHistory(_ sid: String,
                           completion: @escaping (StoredSessionHistory?) -> Void) {
        completion(nil)
    }
    /// Persist the ring-mined command directory (omp disk cache).
    func cacheCommands(_ list: [AgentSlashCommand]) {}


    /// Authoritative history snapshot a resume/reattach rebuild renders
    /// from, dialect-neutral so the replay gate stays in the core.
    struct StoredSessionHistory {
        var events: [AgentSessionEvent]
        var openTools: Int
        var aborted: Bool
        /// Tail-first truncation anchor (omp): entry id of the first
        /// included line. nil = complete history.
        var firstEntryId: String? = nil
    }

    /// Older history for the prepend pipeline (tail-first loads): the
    /// events BEFORE the truncation anchor. nil/empty = no more.
    /// Default: the dialect loaded everything.
    func loadOlderHistory(completion: @escaping ([AgentSessionEvent]?) -> Void) {
        completion(nil)
    }

    // MARK: - AgentSessioning

    func connect(completion: ((Bool) -> Void)? = nil) {
        guard !connected else {
            completion?(true)
            return
        }
        connected = true
        openPane(resume: resumeSessionId, completion: completion)
    }

    func reconnect(completion: ((Bool) -> Void)? = nil) {
        pane?.close()
        pane = nil
        connected = true
        // A fresh spawn resumes the agent's own session natively
        // (--session / --resume); an attach re-syncs state over the
        // live process.
        openPane(resume: lastSessionId ?? resumeSessionId, completion: completion)
    }

    private func openPane(resume sessionId: String?, completion: ((Bool) -> Void)?) {
        // The resumed session's identity is known before the handshake:
        // set it up front so the host's disk-backed title lookup can
        // render the session name immediately (matching the sidebar,
        // which reads the same store).
        if let sessionId {
            self.sessionId = sessionId
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.session(self, didEmit: [.ready])
            }
        }
        // The daemon round trip (attach/spawn handshake +, on a remote
        // link, the store listing a respawn's --resume path needs) is
        // BLOCKING socket I/O — over an ssh tunnel that's tens of ms.
        // Run it off main; everything stateful below hops back or is
        // lock-guarded (PaneSession write lock, responseLock).
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            var args = ["--mode", "rpc"]
            self.appendSpawnArgs(&args, resume: sessionId)
            // omp: the handshake is gated on the ready frame (see
            // OmpSession.interceptProtocolFrame) — the process answers
            // stdin normally once its RPC loop is up; a burst written
            // before that strands all but the first line (PTY line
            // discipline, probed 2026-08-31).
            guard let opened = self.daemon.openPaneWithAttachment(
                id: self.paneId, cwd: self.cwd, shell: self.shellName, args: args,
                environment: self.environment, grid: self.grid,
                noEcho: true, ringBytes: 16_777_216,
                onFrame: { [weak self] kind, data in
                    self?.handleTransportFrame(kind: kind, data: data)
                },
                onDisconnect: { [weak self] in
                    guard let self else { return }
                    self.connected = false
                    self.delegate?.session(self, didDisconnectBecause: "daemon 连接断开")
                })
            else {
                self.connected = false
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.delegate?.sessionDidFail(self, reason: "sessiond 不可用")
                    completion?(false)
                }
                return
            }
            opened.session.start()
            self.pane = opened.session
            self.beginHandshakeAfterSpawn(completion: completion)
        }
    }

    /// Shared get_state handler: the pi immediate handshake and the omp
    /// ready-gated handshake both land here.
    private func handleStateResponse(_ response: [String: Any],
                                     completion: ((Bool) -> Void)?) {
        guard response["success"] as? Bool == true,
              let state = response["data"] as? [String: Any] else {
            delegate?.sessionDidFail(self, reason: "\(shellName) get_state 失败")
            completion?(false)
            return
        }
        handshakeStarted = true
        sessionId = state["sessionId"] as? String ?? sessionId
        // Ring-mined command directory may arrive BEFORE the handshake
        // sets sessionId (the whole boot sequence, ready frame included,
        // rides the ring) — flush the deferred cache write here.
        if let pending = pendingCommandsCache {
            pendingCommandsCache = nil
            cacheCommands(pending)
        }
        currentModelDescriptor = state["model"] as? [String: Any]
        thinkingLevelCache = state["thinkingLevel"] as? String
        applyState(state)
        adoptAttachedState(state)
        var events: [AgentSessionEvent] = [.ready]
        if !configOptions.isEmpty {
            events.append(.configChanged(configOptions))
        }
        emit(events)
        loadCommandsAfterHandshake()
        startStatePolling()
        registerExtras()
        completion?(true)
    }

    /// Publish a freshly sourced command directory.
    func adoptCommands(_ list: [AgentSlashCommand]) {
        guard !list.isEmpty else { return }
        commands = list
        emit([.commandsChanged(list)])
    }

    /// Handshake, one command in flight at a time. omp's PTY delivers
    /// ONE line per read until its reader loop spins up, so a two-line
    /// burst written at once can strand the second line forever (probed
    /// 2026-08-31: prewrite boots answered negotiate but never
    /// get_state). Sequential request→response→request is also the
    /// shape gooey-pi's runtime uses against the same protocol.
    func handshake(completion: ((Bool) -> Void)?) {
        // The host's 90s watchdog is disarmed by our early .ready (the
        // session-name render); a genuinely broken handshake must still
        // fail loudly — 20s ceiling here.
        var finished = false
        let failAfter = DispatchWorkItem { [weak self] in
            guard let self, !finished else { return }
            finished = true
            self.delegate?.sessionDidFail(self, reason: "\(self.shellName) 握手超时")
            completion?(false)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: failAfter)
        func finish(_ ok: Bool) {
            guard !finished else { return }
            finished = true
            failAfter.cancel()
            completion?(ok)
        }
        requestAgentState { [weak self] response in
            self?.handleStateResponse(response, completion: finish)
        }
    }

    /// Opens the replay gate for a resume spawn: starts reading the
    /// stored history immediately (it races the handshake, not the
    /// other way around) and buffers every emitted event until the
    /// authoritative history is in. A 5s ceiling releases the gate even
    /// if the read fails — the pane must never freeze on its own
    /// history.
    func beginReplayGate(sessionId sid: String) {
        replayGateActive = true
        gatedEvents.removeAll()
        let timeout = DispatchWorkItem { [weak self] in
            self?.releaseReplayGate()
        }
        replayGateTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: timeout)
        readStoredHistory(sid) { [weak self] stored in
            let stored = stored
                ?? StoredSessionHistory(events: [], openTools: 0, aborted: false)
            DispatchQueue.main.async {
                self?.finishReplayGate(with: stored)
            }
        }
    }

    /// Store history landed. Normal path: prepend it (behind a
    /// transcript reset) to the buffered live events and release
    /// everything in order. If the 5s ceiling already released the
    /// gate, the history still MUST land (never dropped) — it replays
    /// over whatever rendered in the meantime.
    private func finishReplayGate(with stored: StoredSessionHistory) {
        guard !stored.events.isEmpty else {
            releaseReplayGate()
            return
        }
        var events: [AgentSessionEvent]
        if replayGateActive {
            replayGateTimeout?.cancel()
            events = [.transcriptReset] + stored.events + gatedEvents
            gatedEvents = []
            replayGateActive = false
        } else {
            events = [.transcriptReset] + stored.events
        }
        // Tail-first truncation is part of the SAME batch: the page
        // must know (a) older history exists and (b) where the
        // load-older affordance points, before it can render the top.
        if stored.firstEntryId != nil {
            events.append(.historyTruncated(true))
        }
        delegate?.session(self, didEmit: events)
        // Stale-tail heal: the read can race the turn settle (restart
        // mid-tool → store write lands after our read). An idle,
        // non-aborted session showing open tools is definitionally a
        // stale read — the completion frames predated attach and will
        // never re-fire. One delayed re-read settles the tail. Skipped
        // while a turn runs (live frames close the cards) and never
        // twice (an aborted tail legitimately stays open).
        if stored.openTools > 0, !stored.aborted,
           !isWorking, !staleTailRereadDone, let sid = sessionId {
            staleTailRereadDone = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, !self.isWorking else { return }
                self.beginReplayGate(sessionId: sid)
            }
        }
    }

    /// Ceiling release (store read failed or hung): buffered events go
    /// out as-is, without the history.
    private func releaseReplayGate() {
        guard replayGateActive else { return }
        replayGateTimeout?.cancel()
        replayGateActive = false
        let events = gatedEvents
        gatedEvents = []
        delegate?.session(self, didEmit: events)
    }

    func send(_ text: String) {
        guard !isWorking else { return }
        isWorking = true
        lastSendAt = Date()
        idlePollStreak = 0
        let id = "u\(nextRequestID)"
        nextRequestID += 1
        // Builtin commands (/rename, /stats…) answer agentInvoked:false —
        // no model turn runs, so agent_settled will NEVER come. Close the
        // turn on the response itself; otherwise the composer shows 思考中
        // for the missed-settle heal's full ~8s conservative window (the
        // 7.8s fake "thinking" after /rename, 2026-09-01).
        responseLock.lock()
        pendingResponses[id] = { [weak self] response in
            let data = response["data"] as? [String: Any]
            let invoked = (data?["agentInvoked"] as? Bool) ?? true
            guard !invoked else { return }
            DispatchQueue.main.async {
                guard let self, self.isWorking else { return }
                self.emit([.turnEnded(stopReason: nil)])
            }
        }
        responseLock.unlock()
        channel.send(["id": id, "type": "prompt", "message": text])
    }

    func cancel() {
        channel.send(["type": "abort"])
    }

    func setConfigOption(id: String, value: String) {}

    func respondPermission(requestID: String, optionId: String) {
        // Every interactive prompt in rpc mode rides extension dialogs
        // (approvals = select). Answer by the recorded method shape:
        // select/input/editor → value, confirm → boolean, the rest →
        // cancelled.
        guard let id = Int(requestID),
              let method = pendingDialogs.removeValue(forKey: id) else { return }
        switch method {
        case "select", "input", "editor":
            channel.send(["type": "extension_ui_response",
                          "id": id, "value": optionId])
        case "confirm":
            channel.send(["type": "extension_ui_response",
                          "id": id, "confirmed": optionId == "confirm"])
        default:
            channel.send(["type": "extension_ui_response",
                          "id": id, "cancelled": true])
        }
    }

    func listSessions(completion: @escaping ([AgentSessionSummary]) -> Void) {
        sessionSummaries { summaries in
            DispatchQueue.main.async {
                completion(summaries)
            }
        }
    }

    func load(sessionId: String, completion: ((Bool) -> Void)? = nil) {
        // Both dialects swap sessions the same way: kill the pane (or
        // the reopen would ATTACH to the old process), respawn with the
        // resume flag, and let the handshake path render — omp from the
        // store, pi from get_messages. The kill must be ACKNOWLEDGED
        // (daemon-side registry removal) before the respawn: the plain
        // fire-and-forget kill races the new openPane's ATTACH probe,
        // which then re-attaches the very pane being killed and the
        // selected session silently never loads.
        resumeSessionId = sessionId
        self.sessionId = sessionId
        pane?.close()
        pane = nil
        daemon.killPaneAndWait(id: paneId) { [weak self] _ in
            guard let self else { return }
            self.openPane(resume: sessionId) { [weak self] ok in
                guard let self, ok else {
                    completion?(false)
                    return
                }
                self.completeSessionLoad { ok in completion?(ok) }
            }
        }
    }

    func shutdown() {
        stopStatePolling()
        pane?.close()
        pane = nil
        connected = false
    }

    // MARK: - live state (get_state poll)

    /// Runtime telemetry + plan snapshot from a get_state payload. The
    /// plan event carries the WHOLE todoPhases list (empty = clear the
    /// panel); the web store dedups unchanged snapshots.
    private func applyLiveState(_ state: [String: Any]) {
        let streaming = state["isStreaming"] as? Bool ?? false
        let queued = state["queuedMessageCount"] as? Int ?? 0
        let compactingRaw = state["isCompacting"] as? Bool ?? false
        // Missed-settle heal: some turns (notably /compact) never emit
        // agent_settled, leaving isWorking stuck. get_state is the
        // authority here — two consecutive fully-idle reads (not
        // streaming, nothing queued, not compacting), no live tool
        // call, and >4s past the optimistic send window, force the
        // turn closed. emit() clears isWorking on turnEnded itself.
        //
        // COMPACTING DEBOUNCE: a real compaction holds isCompacting
        // across polls; a turn poisoned by mid-turn set_model (omp
        // 18.0.11, probed 2026-09-01) flaps it true/false on
        // alternating reads — flickering the status line 思考中/压缩中
        // every 2s and resetting the streak so the heal never landed.
        // Count compaction only on two consecutive true reads.
        let compacting = Self.effectiveCompacting(current: compactingRaw,
                                                  previous: lastPollCompacting)
        lastPollCompacting = compactingRaw
        var status = Self.runtimeStatus(state)
        status.isCompacting = compacting
        var events: [AgentSessionEvent] = [.plan(Self.planEntries(state)),
                                           .runtimeStatus(status)]
        if Self.missedSettleHeal(isWorking: isWorking, streaming: streaming,
                                 queued: queued, compacting: compacting,
                                 activeToolCount: activeToolIds.count,
                                 secondsSinceSend: lastSendAt.map(
                                     Date().timeIntervalSince)) {
            idlePollStreak += 1
            if idlePollStreak >= 2 {
                idlePollStreak = 0
                events.append(.turnEnded(stopReason: nil))
            }
        } else if Self.strongLifeSign(streaming: streaming, queued: queued,
                                      activeToolCount: activeToolIds.count) {
            // Only strong signs of life reset the streak — a lone
            // flapping compacting=true read must not, or the heal can
            // never accumulate its two idle reads.
            idlePollStreak = 0
        }
        emit(events)
    }

    /// Compaction counts only on consecutive true reads (a real
    /// compaction holds the flag; a poisoned turn flaps it).
    static func effectiveCompacting(current: Bool, previous: Bool) -> Bool {
        current && previous
    }

    /// Unambiguous proof the turn is alive — the only reads allowed to
    /// restart the missed-settle streak. A lone compacting=true read
    /// is deliberately NOT among them.
    static func strongLifeSign(streaming: Bool, queued: Int,
                               activeToolCount: Int) -> Bool {
        streaming || queued > 0 || activeToolCount > 0
    }

    /// Pure verdict for ONE idle get_state read (streak counting stays
    /// with the poll loop): should this read count toward forcing the
    /// turn closed? Extracted static so agenttest can pin the contract.
    static func missedSettleHeal(isWorking: Bool, streaming: Bool,
                                 queued: Int, compacting: Bool,
                                 activeToolCount: Int,
                                 secondsSinceSend: Double?) -> Bool {
        // Any sign of life vetoes the heal: still streaming, queued
        // follow-ups, an open compaction, a tool mid-flight, or a send
        // so recent the agent may just not have started yet.
        guard isWorking, !streaming, queued == 0, !compacting,
              activeToolCount == 0 else { return false }
        guard let since = secondsSinceSend, since > 4 else { return false }
        return true
    }

    private static func planEntries(_ state: [String: Any]) -> [AgentPlanEntry] {
        let phases = state["todoPhases"] as? [[String: Any]] ?? []
        var entries: [AgentPlanEntry] = []
        for phase in phases {
            let phaseName = phase["name"] as? String
            let tasks = phase["tasks"] as? [[String: Any]] ?? []
            for task in tasks {
                guard let content = task["content"] as? String else { continue }
                entries.append(AgentPlanEntry(content: content,
                                              priority: phaseName,
                                              status: task["status"] as? String))
            }
        }
        return entries
    }

    private static func runtimeStatus(_ state: [String: Any]) -> AgentRuntimeStatus {
        let context = state["contextUsage"] as? [String: Any]
        var status = AgentRuntimeStatus()
        status.fastModeEnabled = state["fastModeEnabled"] as? Bool
        status.fastModeActive = state["fastModeActive"] as? Bool
        status.contextTokens = context?["tokens"] as? Int
        status.contextWindow = context?["contextWindow"] as? Int
        // omp keeps reporting the LAST turn's rate after settle; only a
        // live turn's number means anything (isStreaming is turn-level).
        status.tokensPerSecond = (state["isStreaming"] as? Bool ?? false)
            ? state["tokensPerSecond"] as? Double : nil
        status.queuedMessages = state["queuedMessageCount"] as? Int
        status.isCompacting = state["isCompacting"] as? Bool
        status.isStreaming = state["isStreaming"] as? Bool
        return status
    }

    /// Steady 2s get_state cadence (one local RPC) — covers mid-turn
    /// telemetry drift and post-tool todoPhases refreshes without
    /// event-specific bookkeeping.
    private func startStatePolling() {
        guard stateTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in self?.refreshState() }
        timer.resume()
        stateTimer = timer
    }

    private func stopStatePolling() {
        stateTimer?.cancel()
        stateTimer = nil
    }

    func refreshState(completion: ((Bool) -> Void)? = nil) {
        request("get_state") { [weak self] response in
            guard let self else {
                completion?(false)
                return
            }
            guard response["success"] as? Bool == true,
                  let state = response["data"] as? [String: Any] else {
                completion?(false)
                return
            }
            // A session switch (branch → new session file) shows up
            // here first — adopt the id so persistence and title
            // refreshes target the new conversation.
            sessionId = state["sessionId"] as? String ?? sessionId
            currentModelDescriptor = state["model"] as? [String: Any] ?? currentModelDescriptor
            thinkingLevelCache = state["thinkingLevel"] as? String ?? thinkingLevelCache
            applyLiveState(state)
            completion?(true)
        }
    }

    // MARK: - extension UI (approvals, dialogs, login URLs)

    private func handleExtensionUI(_ frame: [String: Any]) {
        guard let rawId = frame["id"] as? Int else { return }
        let method = frame["method"] as? String ?? "select"
        let title = (frame["title"] as? String) ?? (frame["message"] as? String)
        switch method {
        case "select":
            let options = ((frame["options"] as? [String]) ?? [])
                .map { AgentPermissionOption(optionId: $0, name: $0, kind: nil) }
            guard !options.isEmpty else { return }
            pendingDialogs[rawId] = method
            emit([.permissionRequested(AgentPermissionPrompt(
                requestID: String(rawId), toolCallTitle: title,
                options: options, dialog: "select"))])
        case "confirm":
            pendingDialogs[rawId] = method
            emit([.permissionRequested(AgentPermissionPrompt(
                requestID: String(rawId), toolCallTitle: title,
                options: [
                    AgentPermissionOption(optionId: "confirm",
                                          name: "确认", kind: "allow"),
                    AgentPermissionOption(optionId: "cancel",
                                          name: "取消", kind: nil),
                ], dialog: "confirm"))])
        case "input", "editor":
            pendingDialogs[rawId] = method
            emit([.permissionRequested(AgentPermissionPrompt(
                requestID: String(rawId), toolCallTitle: title,
                options: [], dialog: method,
                placeholder: frame["placeholder"] as? String,
                defaultValue: (frame["value"] as? String) ?? (frame["default"] as? String)))])
        case "notify":
            let message = (frame["message"] as? String) ?? ""
            let heading = frame["title"] as? String
            emit([.notice(heading.map { $0 + ": " + message } ?? message)])
        case "setStatus":
            if let text = (frame["message"] as? String) ?? (frame["status"] as? String) {
                emit([.notice(text)])
            }
        case "open_url":
            // Login flow: the host opens the browser; the response only
            // records the round trip.
            guard let url = frame["url"] as? String else { return }
            emit([.openURL(url)])
            channel.send(["type": "extension_ui_response",
                          "id": rawId, "value": "opened"])
        default:
            channel.send(["type": "extension_ui_response",
                          "id": rawId, "cancelled": true])
        }
    }

    // MARK: - host tools (agent → GUI callbacks)

    func setHostTools(_ tools: AgentHostTools) {
        hostTools = tools
        registerExtras()
    }

    private func handleHostToolCall(_ frame: [String: Any]) {
        guard let id = frame["id"] as? String,
              let name = frame["toolName"] as? String else { return }
        let arguments = frame["arguments"] as? [String: Any] ?? [:]
        guard let tool = hostTools?.tools.first(where: { $0.name == name }) else {
            channel.send(["type": "host_tool_result", "id": id, "isError": true,
                          "result": ["content": [["type": "text",
                                                 "text": "goty has no host tool named \(name)"]]] as [String: Any]])
            return
        }
        channel.send(["type": "host_tool_result", "id": id,
                      "result": tool.run(arguments)])
    }

    func steer(_ text: String) {
        guard isWorking else { return send(text) }
        // A mid-turn builtin (/rename …) must NOT ride a steer frame —
        // pi-mono never parses commands on the steer path, and sending
        // a prompt mid-stream kills the turn on omp 18.0.11. Park it.
        if Self.isBuiltinCommand(text, commandNames: commands.map(\.name)) {
            pendingCommandText = text
            emit([.notice("⟳ 命令将在本轮结束后执行")])
            return
        }
        channel.send(["type": "steer", "message": text])
    }

    /// Matches "/name" or "/name args" against the session's command
    /// directory (available_commands_update — omp and pi both carry it).
    /// Unknown /text steers the model as typed — only real builtins park.
    static func isBuiltinCommand(_ text: String, commandNames: [String]) -> Bool {
        guard text.hasPrefix("/"), !commandNames.isEmpty else { return false }
        let head = text.split(separator: " ", maxSplits: 1)[0]
        return commandNames.contains(String(head.dropFirst()))
    }

    func followUp(_ text: String) {
        guard isWorking else { return send(text) }
        channel.send(["type": "follow_up", "message": text])
    }

    // MARK: - protocol capabilities


    // omp-only capabilities: default implementations mirror the
    // AgentSessioning extension defaults so unsupported dialects
    // no-op identically; OmpSession overrides each with the real RPC.

    func setFastMode(enabled: Bool) {}
    func loginProviders(completion: @escaping ([[String: Any]]) -> Void) {
        completion([])
    }
    func startLogin(providerId: String) {}
    func exportHTML(completion: @escaping (String?) -> Void) { completion(nil) }
    func sessionStats(completion: @escaping ([String: Any]?) -> Void) { completion(nil) }
    func branch(entryId: String, completion: @escaping (Bool) -> Void) {
        completion(false)
    }
    func forkToNewSession(entryId: String, completion: @escaping (String?) -> Void) {
        completion(nil)
    }

    // MARK: - plumbing

    private func handleTransportFrame(kind: UInt8, data: Data) {
        switch kind {
        case SessionOutputKind.output:
            channel.feed([UInt8](data), replay: false)
        case SessionOutputKind.snapshot:
            // Ring replay (reattach). pi renders it through the mapper
            // with the user echo on; omp suppresses rendering entirely —
            // its transcript lands from the session store instead.
            if suppressesRingReplay { suppressReplay = true }
            mapper.replaying = true
            channel.feed([UInt8](data), replay: true)
            mapper.replaying = false
            suppressReplay = false
        case SessionOutputKind.exited:
            if isWorking {
                isWorking = false
                emit([.turnEnded(stopReason: nil)])
            }
            // The pane's process is gone (crash, user exit, or a pane
            // spawned by an older build's argv). Reset everything so a
            // retry reconnects and RESPAWNS — connect() used to return
            // early on the stale `connected` flag and the retry button
            // did nothing (2026-08-31).
            connected = false
            pane?.close()
            pane = nil
            daemon.killPane(id: paneId)
            delegate?.sessionDidFail(self, reason: "\(shellName) 进程已退出")
        default:
            break
        }
    }

    private func handleFrame(_ frame: [String: Any]) {
        framesRouted += 1
        guard frame["type"] as? String != "rpc_chunk" else {
            if let assembled = feedChunk(frame) {
                handleFrame(assembled)
            }
            return
        }
        // Dialect protocol plumbing intercepts first (omp's ready
        // frame); stale replayed responses match no pending id and drop.
        if interceptProtocolFrame(frame) { return }
        if frame["type"] as? String == "response",
           let id = frame["id"] as? String {
            responseLock.lock()
            let completion = pendingResponses.removeValue(forKey: id)
            responseLock.unlock()
            completion?(frame)
            return
        }
        // Transcript frames from the ring replay stay suppressed for
        // omp: the session store is the authoritative transcript. The
        // command directory is EXEMPT: omp emits available_commands_
        // update once at boot, an attach must mine it from the ring
        // replay (the process never resends), and the capture point
        // below writes the disk cache for the next attach whose ring
        // has rotated past boot.
        let frameType = frame["type"] as? String
        if suppressReplay && frameType != "available_commands_update" { return }
        if frameType == "extension_ui_request" {
            handleExtensionUI(frame)
            return
        }
        if frameType == "host_tool_call" {
            handleHostToolCall(frame)
            return
        }
        // State-affecting events the mapper has no case for: refresh
        // get_state so the plan panel, dropdowns and status strip
        // follow (todo tool ran, model switched elsewhere, todos
        // auto-cleared).
        if frameType == "todo_auto_clear" || frameType == "model_changed"
            || frameType == "thinking_level_changed" {
            refreshState()
        }
        if frameType == "tool_execution_end",
           (frame["toolName"] as? String)?.lowercased() == "todo" {
            refreshState()
        }
        let events = mapper.map(frame)
        for event in events {
            if case .commandsChanged(let list) = event {
                commands = list
                cacheCommands(list)
            }
            if case .turnEnded = event {
                isWorking = false
            }
            // LIVE content resurrects working state: a stale extension
            // idle report or an isStreaming=false reattach (get_state
            // racing a turn in progress) must not leave a streaming
            // agent reading as idle — the composer's stop button and
            // Esc routing all hang off working.
            if !mapper.replaying {
                switch event {
                case .messageChunk, .thoughtChunk:
                    isWorking = true
                    idlePollStreak = 0
                case .toolCallUpdate(let id, _, _, let status, _, _, _, _):
                    if status == "pending" || status == "in_progress" {
                        isWorking = true
                        idlePollStreak = 0
                        activeToolIds.insert(id)
                    } else {
                        activeToolIds.remove(id)
                    }
                default:
                    break
                }
            }
        }
        // Usage rides message frames (input/output token splits).
        if let usage = (frame["usage"] as? [String: Any]),
           usage["totalTokens"] != nil {
            emit([.usageUpdate(used: usage["totalTokens"] as? Int,
                               size: nil,
                               input: usage["input"] as? Int,
                               output: usage["output"] as? Int,
                               costAmount: nil, costCurrency: nil)])
        }
        emit(events)
        // Post-turn resync: queue depth, context usage and todos settle
        // right after agent_end — one get_state answers all three.
        if events.contains(where: { event in
            if case .turnEnded = event { return true }
            return false
        }) {
            refreshState()
        }
    }

    // MARK: omp v2 chunked frames

    private func feedChunk(_ frame: [String: Any]) -> [String: Any]? {
        guard let chunkId = frame["chunkId"] as? String, !chunkId.isEmpty,
              let index = frame["index"] as? Int,
              let count = frame["count"] as? Int,
              let b64 = frame["data"] as? String,
              index >= 0, count >= 1, count <= 4096,
              let decoded = Data(base64Encoded: b64) else {
            responseLock.lock()
            chunkAssemblies.removeAll()
            responseLock.unlock()
            return nil
        }
        responseLock.lock()
        defer { responseLock.unlock() }
        var assembly = chunkAssemblies[chunkId]
            ?? ChunkAssembly(count: count, parts: [:], bytes: 0)
        guard assembly.count == count else {
            chunkAssemblies[chunkId] = nil
            return nil
        }
        assembly.parts[index] = decoded
        assembly.bytes += decoded.count
        guard assembly.bytes <= 64 * 1024 * 1024 else {
            chunkAssemblies[chunkId] = nil
            return nil
        }
        guard assembly.parts.count == count else {
            chunkAssemblies[chunkId] = assembly
            return nil
        }
        chunkAssemblies[chunkId] = nil
        var joined = Data()
        joined.reserveCapacity(assembly.bytes)
        for i in 0..<count { joined.append(assembly.parts[i] ?? Data()) }
        return try? JSONSerialization.jsonObject(with: joined) as? [String: Any]
    }

    func applyState(_ state: [String: Any],
                    availableModels: [[String: Any]] = []) {
        var options: [AgentConfigOption] = []
        let modelChoices: [AgentConfigChoice] = availableModels.compactMap { raw in
            guard let id = raw["id"] as? String else { return nil }
            let provider = raw["provider"] as? String
            let value = provider.map { "\($0)/\(id)" } ?? id
            return AgentConfigChoice(value: value,
                                     name: (raw["name"] as? String) ?? id,
                                     description: nil,
                                     source: provider)
        }
        var currentModelId: String?
        if let model = state["model"] as? [String: Any] {
            let id = model["id"] as? String ?? ""
            currentModelId = id
            let provider = model["provider"] as? String
            let selector = provider.map { "\($0)/\(id)" } ?? id
            let display = (model["name"] as? String) ?? id
            options.append(AgentConfigOption(
                id: "model", name: "模型", category: nil,
                currentValue: modelChoices.isEmpty ? display : selector,
                options: modelChoices))
        }
        if let thinking = state["thinkingLevel"] as? String {
            // The ladder is per-model (thinking.efforts on the current
            // model's descriptor); fall back to the standard budget
            // ladder when the catalog has not landed yet.
            let descriptor = availableModels
                .first { ($0["id"] as? String) == currentModelId }
            let efforts = descriptor?["thinking"] as? [String: Any]
            let ladder = (efforts?["efforts"] as? [String])
                ?? ["minimal", "low", "medium", "high"]
            options.append(AgentConfigOption(
                id: "thinking", name: "思考", category: nil,
                currentValue: thinking,
                options: ladder.map { AgentConfigChoice(value: $0, name: $0, description: nil) }))
        }
        configOptions = options
    }
    /// pi-mono command with id-matched response completion. The pending
    /// entry registers BEFORE the frame hits the wire (same invariant
    /// as JSONRPCChannel).
    func request(_ command: String, _ extra: [String: Any] = [:],
                 completion: @escaping ([String: Any]) -> Void) {
        responseLock.lock()
        let id = "r\(nextRequestID)"
        nextRequestID += 1
        pendingResponses[id] = completion
        responseLock.unlock()
        var frame: [String: Any] = ["id": id, "type": command]
        for (key, value) in extra { frame[key] = value }
        channel.send(frame)
    }

    /// Single choke point for outgoing events. turnEnded side effects
    /// live HERE (not just handleFrame) — the missed-settle heal and
    /// agent_settled both route through this method.
    func emit(_ events: [AgentSessionEvent]) {
        guard !events.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for event in events {
                guard case .turnEnded = event else { continue }
                self.isWorking = false
                self.turnSettled()
                // Mid-turn reattach: the replayed transcript froze this
                // turn's tool cards at their in-flight statuses — their
                // completion frames fired during the attach gap and
                // will never re-fire. The settled store has the truth;
                // rebuild the transcript once.
                //
                // DELAYED by 1.5s on purpose: at settle, omp is still
                // writing the tail entries (queued follow-up deliveries
                // land user entries at exactly this moment — probe
                // 2026-09-01). Reading instantly raced the write and
                // the rebuilt transcript DROPPED the queued message
                // that turnEnded had already flushed for display. Let
                // the store settle first; the web keeps its live view
                // (user block included) until the rebuild replaces it.
                if self.reattachedMidTurn, let sid = self.sessionId,
                   !sid.isEmpty {
                    self.reattachedMidTurn = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        [weak self] in
                        self?.beginReplayGate(sessionId: sid)
                    }
                }
            }
            guard self.replayGateActive else {
                self.delegate?.session(self, didEmit: events)
                return
            }
            self.gatedEvents.append(contentsOf: events)
        }
    }

    /// Fired on the main queue whenever a turn settles (agent_settled,
    /// missed-settle heal, stop). Subclasses apply deferred work here —
    /// OmpSession parks model switches because omp 18.0.11 kills the
    /// running turn if set_model lands mid-run (probed 2026-09-01).
    func turnSettled() {
        // Runs on the main queue from emit()'s turnEnded branch. A
        // builtin parked by steer() goes out now — omp 18.0.11's kill
        // window is closed once the turn has settled.
        if let command = pendingCommandText {
            pendingCommandText = nil
            send(command)
        }
    }

    /// Kill a throwaway helper process (fork/probe): detach, then an
    /// ACKNOWLEDGED daemon kill (plain close() leaves it alive).
    func teardownForker() {
        stopStatePolling()
        pane?.close()
        pane = nil
        connected = false
        daemon.killPaneAndWait(id: paneId) { _ in }
    }
}
