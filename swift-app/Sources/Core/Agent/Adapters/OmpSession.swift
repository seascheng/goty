// goty - see CLAUDE.md for the working principles.
import Foundation

/// The omp dialect of the pi-mono family (omp 18.x, RPC v2):
///
/// - argv: `--cwd <dir>` (omp buckets sessions by it) and `--resume
///   <file>` (the exact session file path);
/// - handshake: negotiate_protocol v2, gated on the ready frame — live
///   on a fresh spawn, or mined from the ring when attaching; a 10s
///   timeout probes for pre-ACP panes and respawns them;
/// - transcript: the session store is authoritative (the ring is
///   signal-only) and the replay gate rebuilds from it on resume,
///   branch and mid-turn reattach;
/// - capabilities beyond the core: fast mode, OAuth login, export,
///   stats, branch/worktree fork, host tools, subagent subscription,
///   and the pushed command directory (live frame + disk cache +
///   throwaway probe).
///
/// Everything here overrides a PiSession hook or implements an
/// AgentSessioning capability the core defaults to no-op — never a
/// branch in shared code.
@MainActor
final class OmpSession: PiSession {
    // ready-frame handshake bookkeeping (spawn-gated)
    private var respawnedForReadyTimeout = false
    /// Respawn-after-probe guard: the failed probe and the 3s silence
    /// timer must not both kill the pane.
    private var readyRespawned = false
    private var registeredHostTools = false
    private var subscribedSubagents = false
    /// Session files ON THE DAEMON'S MACHINE (capability-7 store
    /// listings + get_state's sessionFile). The --resume flag and file
    /// reads must use these paths — the GUI's filesystem sees a
    /// different ~/.omp on remote panes.
    private var daemonSessionPaths: [String: String] = [:]
    private var warnedOldDaemonStore = false
    /// Throwaway command-directory probe + its sink (cold-start only).
    private var commandProbe: OmpSession?
    private var commandProbeSink: OmpCommandProbeSink?

    /// A model switch parked while a turn runs — omp 18.0.11 kills
    /// the running turn if set_model lands mid-run (probed 2026-09-01:
    /// switches answer ok, streaming stops, no agent_settled). Applied
    /// in turnSettled(); last pick wins.
    private var pendingModelSelector: String?

    /// Entry ids already on the page (replay marks included): the
    /// settle-stamp ships only NEW ones. Main-confined — reads happen
    /// in turnSettled/stampEntryMarks, writes hop through emit().
    private var markedEntryIds: Set<String> = []
    /// One store read in flight per settle burst (queued follow-ups
    /// settle turns back-to-back; a late read covers them all).
    private var entryStampPending = false

    /// Every mark the page can see flows through emit() (replay-gated
    /// events included — the gate buffers INSIDE emit). Recording here
    /// keeps the settle-stamp's known-set exact for every source.
    override func emit(_ events: [AgentSessionEvent]) {
        let marks = events.compactMap { event ->
                String? in
            if case .entryMark(_, let id) = event { return id }
            return nil
        }
        if !marks.isEmpty {
            DispatchQueue.main.async { [weak self] in
                self?.markedEntryIds.formUnion(marks)
            }
        }
        super.emit(events)
    }


    init(params: AgentPaneParams) {
        super.init(params: params, mapperTerminalOnAgentEnd: true)
        // The catalog rides the FIRST configChanged: without it the
        // models dropdown waits on a second emit that queues behind the
        // transcript replay's render — seconds of "empty models" for a
        // command that itself answers in 10ms.
        cachedModelCatalog = Self.loadCachedCatalog()
        modelsFetchInFlight = nil
    }

    /// Daemon-side resume path for a session id: the store listing's
    /// cache first (remote panes), then the LOCAL store (local panes).
    private func resumePath(for sessionId: String) -> String? {
        if let cached = daemonSessionPaths[sessionId] { return cached }
        return OmpSessionStore.fileURL(sessionId: sessionId)?.path
    }

    /// Seed a daemon-side resume path into a throwaway sibling (fork
    /// processes have no listing cache of their own).
    func seedResumePath(_ path: String, for sid: String) {
        daemonSessionPaths[sid] = path
    }

    // MARK: - dialect hooks

    override var shellName: String { "omp" }
    override var suppressesRingReplay: Bool { true }
    /// The session store is omp's transcript authority — an attach with
    /// no resume must rebuild from it (PiSession.handleStateResponse).
    override var rebuildsTranscriptOnAttach: Bool { true }
    override class var spawnMode: String { "rpc-ui" }
    override func appendSpawnArgs(_ args: inout [String], resume sessionId: String?) {
        // omp buckets its sessions by --cwd; the pane cwd alone is
        // not enough for a fresh spawn from a Finder-launched GUI.
        if let cwd, !cwd.isEmpty { args += ["--cwd", cwd] }

        // A respawn whose path we never learned (fresh GUI): ask the
        // daemon synchronously — openPane does its own blocking daemon
        // I/O right after, so the cost profile is unchanged; old
        // daemons answer nil and the local fallback below applies.
        // Host-neutral by design: local and remote take the SAME path.
        if let sessionId, resumePath(for: sessionId) == nil,
           let (_, paths) = daemon.agentStoreSummaries(cwd: nil) {
            daemonSessionPaths.merge(paths) { _, new in new }
        }
        // omp's --resume wants the exact session file path — ON THE
        // MACHINE THE PANE RUNS ON (daemon listing cache first; the
        // local store read only works when the GUI shares the
        // filesystem). The resume also opens the replay gate: the
        if let sessionId, let path = resumePath(for: sessionId) {
            args += ["--resume", path]
            // Main-thread hop: the gate's buffers (replayGateActive /
            // gatedEvents) are main-only state, and this runs on the
            // openPane worker queue now. Ordering holds — the enqueued
            // block lands before the first frame's main-async emit,
            // because the reader only starts after openPane returns.
            DispatchQueue.main.async { [weak self] in
                self?.beginReplayGate(sessionId: sessionId)
            }
        }
    }

    override func beginHandshakeAfterSpawn(attachedExisting: Bool,
                                           completion: ((Bool) -> Void)?) {
        handshakeStarted = false
        readyCompletion = completion
        // The ready frame rides the ring replay on attach. Two windows:
        //
        // - ATTACH (the pane's process booted long ago): a rolled ring
        //   has already dropped the ready frame — the probe answers in
        //   milliseconds, so a SHORT window keeps the worst-case attach
        //   near-instant (2026-09-02 slow-models-on-old-tab report;
        //   tightened 2026-09-02 again with the 1MB ring: rolling is
        //   the COMMON case now, and a probe that races a still-
        //   streaming ring-ready is harmless — first handshake wins).
        // - SPAWN: a fresh omp may legitimately take seconds before its
        //   RPC loop is up (MCP servers, network pulls) — the probe
        //   failing there would MURDER a slow-booting pane (2026-08-31
        //   lesson), so the tolerance stays 10s.
        //
        // Armed per open: a reconnect's attach needs its own window
        // (the one-shot `readyTimeoutScheduled` guard left later
        // attaches probe-less, falling to the 90s watchdog).
        let window: TimeInterval = attachedExisting ? 0.25 : 10
        DispatchQueue.main.asyncAfter(deadline: .now() + window) { [weak self] in
            self?.handleReadyTimeout()
        }
    }

    /// A handshake completed — healthy epoch: re-arm the one-shot
    /// respawn guards so a LATER death still heals instead of parking
    /// the pane at the 90s watchdog.
    override func handshakeSucceeded() {
        respawnedForReadyTimeout = false
        readyRespawned = false
    }

    override func requestAgentState(_ completion: @escaping ([String: Any]) -> Void) {
        // negotiate_protocol is an omp extension (v2 chunked frames).
        // Its failure frame flows to handleStateResponse, which fails
        // the handshake once, with the frame's error detail.
        request("negotiate_protocol", ["protocolVersion": 2]) { [weak self] response in
            guard response["success"] as? Bool == true else {
                completion(response)
                return
            }
            self?.request("get_state", completion: completion)
        }
    }

    override func adoptAttachedState(_ state: [String: Any]) {
        let streaming = state["isStreaming"] as? Bool ?? false
        isWorking = streaming
        reattachedMidTurn = streaming
        // get_state carries the session file — a daemon-side path the
        // resume flag can use directly (remote panes have no local
        // file to find).
        if let sid = state["sessionId"] as? String,
           let file = state["sessionFile"] as? String, !file.isEmpty {
            daemonSessionPaths[sid] = file
        }
        // History lands through the replay gate (see appendSpawnArgs);
        // no direct replay here — the gate owns the ordering.
    }

    override func loadCommandsAfterHandshake() {
        // omp fires available_commands_update ONCE per process —
        // an ATTACH (GUI restart onto a live pane) never sees it
        // and the fresh web store would show an empty / directory.
        // Seed from the per-session cache; a fresh spawn's live
        // frame overwrites it seconds later.
        loadCachedCommands()
        // Cold start (old process, rotated ring, no cache): pull
        // the directory with a throwaway probe so / works now.
        if commands.isEmpty { fetchCommandsViaProbe() }
        fetchAvailableModels()
    }

    override func registerExtras() {
        guard handshakeStarted else { return }
        if !registeredHostTools, let tools = hostTools {
            registeredHostTools = true
            let definitions = tools.tools.map { tool in
                ["name": tool.name, "label": tool.label,
                 "description": tool.description,
                 "parameters": tool.parameters] as [String: Any]
            }
            request("set_host_tools", ["tools": definitions]) { _ in }
        }
        if !subscribedSubagents {
            subscribedSubagents = true
            request("set_subagent_subscription", ["level": "progress"]) { _ in }
        }
    }

    override func setHostTools(_ tools: AgentHostTools) {
        // Re-registration: a tool-set swap must reach the agent even
        // after the first registration fired.
        registeredHostTools = false
        super.setHostTools(tools)
    }

    override func interceptProtocolFrame(_ frame: [String: Any]) -> Bool {
        let type = frame["type"] as? String
        // The ready frame of a LIVE pane arrives only inside the ring
        // replay (the process emitted it once at boot); gating the
        // handshake behind suppressReplay would deadlock attach.
        if type == "ready", !handshakeStarted {
            handshakeStarted = true
            let completion = readyCompletion
            readyCompletion = nil
            handshake(completion: completion)
            return true
        }
        // omp 18.2+: get_available_models answers from the registry
        // snapshot and discovery results arrive as available_models_
        // update pushes (registry refresh settles). Applying them here
        // keeps the dropdown live without a re-request; a replayed
        // boot-time push is same-machines stale at worst and the next
        // live push overwrites it. Intercepted BEFORE the replay
        // suppression so attaches mine it from the ring like the
        // commands frame.
        if type == "available_models_update",
           let models = frame["models"] as? [[String: Any]] {
            modelsFetchInFlight = nil
            cachedModelCatalog = models
            Self.persistCatalog(models)
            rebuildConfigOptions()
            return true
        }
        return false
    }

    /// Tail-first reads only apply once the session is BIG: below the
    /// window a full parse is just as fast and keeps the page complete.
    private static let tailLoadThresholdBytes = 512 * 1024
    private var historyAnchorEntryId: String?
    private var olderLoadInFlight = false

    /// Replay-gate history: the daemon fetches the store file from ITS
    /// machine (remote panes), parsed by the same local parser. Local
    /// reads only as fallback — the daemon-listed path happens to be a
    /// valid local path when GUI and daemon share a filesystem, and the
    /// suffix walk covers a never-listed local session.
    /// TAIL-FIRST (happier coldOpenAtBottom): sessions past the byte
    /// window parse only their recent turn-aligned tail — the open is
    /// O(window), not O(file); the anchor rides back for loadOlder.
    override func readStoredHistory(
            _ sid: String,
            completion: @escaping (StoredSessionHistory?) -> Void) {
        // All blocking I/O below runs off main; state (the history
        // anchor) is written back on main. The daemon handle and the
        // listing cache are captured as immutable inputs up front.
        let daemon = self.daemon
        let daemonPaths = daemonSessionPaths
        AgentSessionExecution.runOffMain(work: { () -> StoredSessionHistory? in
            // Daemon tail first (capability 9, remote panes): a store
            // file can OUTGROW the 16MB frame cap, and then the
            // whole-file reply errors — every fallback reads a
            // different machine's disk and remote history renders
            // empty while the resumed agent's own plan still shows
            // (2026-09-10, host 5090). Local panes keep the direct
            // file read below (no socket hop, unchanged semantics).
            // The windowed parse only wants the tail anyway; an old
            // daemon ignores tail_bytes and answers with the whole
            // file, which the same seam logic handles.
            if daemon.isRemote,
               let tail = daemon.agentStoreFile(
                    sessionId: sid,
                    tailBytes: UInt64(Self.tailLoadThresholdBytes)),
               let text = String(data: tail, encoding: .utf8),
               !text.isEmpty {
                let sliced = OmpSessionStore.daemonTailSlice(text)
                let loaded = OmpSessionStore.parse(sliced.slice)
                let anchor = sliced.firstEntryId
                return StoredSessionHistory(events: loaded.events,
                                            openTools: loaded.openTools,
                                            aborted: loaded.aborted,
                                            firstEntryId: anchor)
            }
            // Local pane (or an unreachable daemon): read the file the
            // GUI can see, tail-first past the byte window.
            guard let raw = Self.storeRaw(sid, daemon: daemon,
                                          daemonPaths: daemonPaths) else { return nil }
            var loaded: OmpSessionStore.Loaded
            if raw.utf8.count > Self.tailLoadThresholdBytes {
                let tail = OmpSessionStore.tailSlice(raw)
                loaded = OmpSessionStore.parse(tail.slice)
                loaded.firstEntryId = tail.firstEntryId
            } else {
                loaded = OmpSessionStore.parse(raw)
            }
            return StoredSessionHistory(events: loaded.events,
                                        openTools: loaded.openTools,
                                        aborted: loaded.aborted,
                                        firstEntryId: loaded.firstEntryId)
        }, completion: { [weak self] history in
            if let anchor = history?.firstEntryId {
                self?.historyAnchorEntryId = anchor
            }
            completion(history)
        })
    }

    /// Prepend pipeline: re-read the full file ONCE and convert the
    /// entries before the anchor. The anchor clears — the next call
    /// (if a new anchor exists after compaction/reload) pages again.
    override func loadOlderHistory(
            completion: @escaping ([AgentSessionEvent]?) -> Void) {
        guard !olderLoadInFlight,
              let sid = sessionId, !sid.isEmpty,
              let anchor = historyAnchorEntryId else {
            completion(nil)
            return
        }
        olderLoadInFlight = true
        let daemon = self.daemon
        let daemonPaths = daemonSessionPaths
        AgentSessionExecution.runOffMain(work: { () -> [AgentSessionEvent]? in
            // Full-file semantics: parseOlder wants everything
            // before the anchor. An over-cap REMOTE file can't
            // cross the wire whole — the fetch misses and the page
            // gets an empty prepend (the sentinel clears; the tail
            // window it already holds is what's reachable).
            Self.storeRaw(sid, daemon: daemon, daemonPaths: daemonPaths).map {
                OmpSessionStore.parseOlder($0, beforeEntryId: anchor).events
            }
        }, completion: { [weak self] events in
            self?.olderLoadInFlight = false
            self?.historyAnchorEntryId = nil
            completion(events)
        })
    }

    /// The session store's raw bytes: the DAEMON's machine first
    /// (remote panes — the GUI's local ~/.omp is a different host),
    /// then the seeded daemon-side path, then the local suffix walk.
    /// Background-queue only (blocking file/socket I/O); takes the
    /// daemon handle and listing cache as immutable inputs so it can
    /// run off the actor.
    private nonisolated static func storeRaw(
        _ sid: String, daemon: SessionDaemon, daemonPaths: [String: String]
    ) -> String? {
        if let data = daemon.agentStoreFile(sessionId: sid) {
            return String(data: data, encoding: .utf8)
        }
        if let path = daemonPaths[sid] {
            return try? String(contentsOfFile: path, encoding: .utf8)
        }
        if let url = OmpSessionStore.fileURL(sessionId: sid) {
            return try? String(contentsOf: url, encoding: .utf8)
        }
        return nil
    }

    /// History from the DAEMON's store (capability 7) — the only right
    /// answer on remote panes, where the GUI's local ~/.omp belongs to
    /// a different machine. Falls back to the local read (old daemon,
    /// round-trip failure); a remote pane on an old daemon surfaces a
    /// one-time notice instead of a silent empty list.
    override func sessionSummaries(
            _ completion: @escaping ([AgentSessionSummary]) -> Void) {
        let daemon = self.daemon
        let cwd = self.cwd
        AgentSessionExecution.runOffMain(work: { () -> (rows: [AgentSessionSummary],
                                                     paths: [String: String]?,
                                                     fallback: [AgentSessionSummary]?) in
            if let (rows, paths) = daemon.agentStoreSummaries(cwd: cwd) {
                return (rows.map { $0.summary }, paths, nil)
            }
            return ([], nil, OmpSessionStore.summaries(cwd: cwd))
        }, completion: { [weak self] result in
            guard let self else { return completion([]) }
            if let paths = result.paths {
                self.daemonSessionPaths.merge(paths) { _, new in new }
                // paths present = the daemon ANSWERED the store RPC. An
                // empty list just means no sessions exist for this cwd —
                // that used to fire the "daemon too old" banner and sent
                // the user chasing a version problem that wasn't there
                // (5090 report 2026-09-16).
                completion(result.rows)
            } else {
                // No reply at all: link stall or a pre-store daemon.
                let summaries = result.fallback ?? []
                self.noteStoreUnreachableIfRemote()
                completion(summaries)
            }
        })
    }
    private func noteStoreUnreachableIfRemote() {
        guard daemon.isRemote, !warnedOldDaemonStore else { return }
        warnedOldDaemonStore = true
        emit([.notice("无法读取该主机的历史记录（连接超时或守护进程无响应，可稍后重试）")])
    }


    // MARK: - ready-frame timeout (pre-ACP panes, rolled rings)

    /// The ready frame never arrived. That is NOT proof the pane is
    /// dead: the 16MB ring rolls the frame off once a session's output
    /// outgrows it, and a live rpc omp mid-turn simply never reprints
    /// it. Killing on this signal alone murdered live processes on
    /// every GUI restart (omp marks the session "previous process
    /// exited before completing the turn"). Probe first: a live v2 omp
    /// answers negotiate_protocol; only silence or a non-v2 answer
    /// falls through to the respawn (dead pane / old ACP protocol).
    private func handleReadyTimeout() {
        guard !handshakeStarted else { return }
        if respawnedForReadyTimeout { return }
        respawnedForReadyTimeout = true
        request("negotiate_protocol", ["protocolVersion": 2]) { [weak self] response in
            DispatchQueue.main.async {
                guard let self, !self.handshakeStarted else { return }
                guard response["success"] as? Bool == true else {
                    self.respawnAfterReadyTimeout()
                    return
                }
                // Alive and speaking v2: the ready frame only fell off
                // the ring. Complete the handshake manually.
                NSLog("GOTY pi-session: ready off-ring — probe answered, completing handshake")
                self.handshake(completion: self.readyCompletion)
            }
        }
    }

    private func respawnAfterReadyTimeout() {
        guard !handshakeStarted, !readyRespawned else { return }
        readyRespawned = true
        NSLog("GOTY pi-session: ready probe unanswered — respawning omp pane")
        pane?.close()
        pane = nil
        // Acknowledged kill, same as load(): an unacknowledged one races
        // the respawn's ATTACH probe and resurrects the dead pane. The
        // reconnect re-enters openPane with the original resume id (the
        // handshake never completed, so lastSessionId is still nil).
        daemon.killPaneAndWait(id: paneId) { [weak self] _ in
            self?.reconnect(completion: self?.readyCompletion)
        }
    }

    // MARK: - command directory (push + cache + probe)

    /// Per-session slash-command cache (~/Library/Application Support/
    /// goty/agent-commands/<sessionId>.json). omp pushes the directory
    /// once per PROCESS; attaches (GUI restart onto a live pane) never
    /// see the frame, so the cache is the reattach's only source.
    private static var commandsCacheDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/goty/agent-commands",
                isDirectory: true)
    }

    override func cacheCommands(_ list: [AgentSlashCommand]) {
        guard !list.isEmpty else { return }
        // Boot-sequence frames ride the ring replay and can beat the
        // handshake; defer until sessionId exists (flushed in
        // handleStateResponse).
        guard let sid = sessionId, !sid.isEmpty else {
            pendingCommandsCache = list
            return
        }
        // omp wire shape (name/description/input.hint) so the loader
        // reuses AgentSlashCommand's parser unchanged.
        let payload: [[String: Any]] = list.map {
            ["name": $0.name,
             "description": $0.description ?? NSNull(),
             "input": ["hint": $0.inputHint ?? NSNull()] as [String: Any]]
        }
        guard let data = try? JSONSerialization.data(
                withJSONObject: ["commands": payload]) else { return }
        let dir = Self.commandsCacheDir
        try? FileManager.default.createDirectory(at: dir,
                                                 withIntermediateDirectories: true)
        try? data.write(to: dir.appendingPathComponent("\(sid).json"))
    }

    /// Cold-start fallback: omp pushes the command directory once per
    /// PROCESS and there is no fetch RPC — when neither the live frame
    /// (fresh spawn), the ring (attach, boot frames still inside), nor
    /// the disk cache (never written for this session) has it, boot a
    /// THROWAWAY omp in the same cwd, intercept its boot-time
    /// available_commands_update, adopt it for THIS session (cache keyed
    /// by our sessionId), and kill the probe. Runs once per attach; the
    /// cache it writes makes every later attach instant.
    private func fetchCommandsViaProbe() {
        guard commandProbe == nil else { return }
        let probe = OmpSession(params: AgentPaneParams(
            paneId: "cmdprobe-" + String(UUID().uuidString.prefix(8)),
            cwd: cwd, environment: environment, daemon: daemon))
        let sink = OmpCommandProbeSink { [weak self] list in
            guard let self else { return }
            self.adoptCommands(list)
            self.cacheCommands(list)
            self.teardownCommandProbe()
        }
        commandProbe = probe
        commandProbeSink = sink
        probe.delegate = sink
        probe.connect { _ in }
        // MCP-slow projects can take a while; give up silently at 15s.
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            self?.teardownCommandProbe()
        }
    }

    private func teardownCommandProbe() {
        commandProbe?.teardownForker()
        commandProbe = nil
        commandProbeSink = nil
    }

    private func loadCachedCommands() {
        guard commands.isEmpty, let sid = sessionId, !sid.isEmpty else { return }
        let url = Self.commandsCacheDir.appendingPathComponent("\(sid).json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data)
                  as? [String: Any],
              let raw = obj["commands"] as? [[String: Any]] else { return }
        let list = AgentSlashCommand.list(raw)
        guard !list.isEmpty else { return }
        adoptCommands(list)
    }

    // MARK: - model catalog (config buttons)
    private func fetchAvailableModels() {
        // A remote omp's first get_available_models can take a while
        // (cold process, MCP probes, shaky link). Without feedback the
        // dropdown just looks dead for tens of seconds — say so at 4s,
        // then still land the catalog whenever the answer arrives.
        let timeoutSentinel = UUID()
        modelsFetchInFlight = timeoutSentinel
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, self.modelsFetchInFlight == timeoutSentinel,
                  self.cachedModelCatalog.isEmpty else { return }
            self.emit([.statusFlash("模型列表仍在加载（远端响应较慢）…")])
        }
        request("get_available_models") { [weak self] response in
            guard let self,
                  response["success"] as? Bool == true,
                  let data = response["data"] as? [String: Any],
                  let models = data["models"] as? [[String: Any]] else {
                self?.modelsFetchInFlight = nil
                return
            }
            self.modelsFetchInFlight = nil
            self.cachedModelCatalog = models
            Self.persistCatalog(models)
            self.rebuildConfigOptions()
        }
    }

    /// Disk cache for the model catalog: the first configChanged of a
    /// fresh OmpSession carries full dropdown choices without waiting
    /// for the (10ms, but render-queued) catalog round-trip. Refreshed
    /// on every successful handshake.
    private static var catalogCacheURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("goty/omp-model-catalog.json")
    }

    private static func loadCachedCatalog() -> [[String: Any]] {
        guard let data = try? Data(contentsOf: catalogCacheURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["v"] as? Int == 1,
              let models = obj["models"] as? [[String: Any]] else { return [] }
        return models
    }

    private static func persistCatalog(_ models: [[String: Any]]) {
        guard let data = try? JSONSerialization.data(
                withJSONObject: ["v": 1, "models": models]) else { return }
        try? data.write(to: catalogCacheURL, options: .atomic)
    }

    /// Rebuild + republish the config options from the cached model
    /// descriptor / thinking level (after get_available_models lands or
    /// a set_model / set_thinking_level response moves a value).
    private func rebuildConfigOptions() {
        var state: [String: Any] = [:]
        if let model = currentModelDescriptor { state["model"] = model }
        if let thinking = thinkingLevelCache { state["thinkingLevel"] = thinking }
        applyState(state, availableModels: cachedModelCatalog)
        if !configOptions.isEmpty {
            emit([.configChanged(configOptions)])
        }
    }

    override func setConfigOption(id: String, value: String) {
        switch id {
        case "model":
            // omp 18.0.11 KILLS the running turn if set_model lands
            // mid-run (probed 2026-09-01: every switch answers ok,
            // streaming stops, no agent_settled, isWorking sticks).
            // Park the pick and apply it when the turn settles.
            guard !isWorking else {
                pendingModelSelector = value
                emit([.notice("⟳ 模型将在本轮结束后切换")])
                return
            }
            applyModelSelector(value)
        case "thinking":
            request("set_thinking_level", ["level": value]) { [weak self] response in
                guard let self, response["success"] as? Bool == true else { return }
                self.thinkingLevelCache = value
                self.rebuildConfigOptions()
            }
        default:
            break
        }
    }

    /// value is the provider/id selector applyState built; set_model
    /// takes it split (verified live). Bare ids pass through.
    private func applyModelSelector(_ value: String) {
        let parts = value.split(separator: "/", maxSplits: 1).map(String.init)
        var extra: [String: Any] = [:]
        if parts.count == 2 {
            extra["provider"] = parts[0]
            extra["modelId"] = parts[1]
        } else {
            extra["modelId"] = value
        }
        request("set_model", extra) { [weak self] response in
            guard let self else { return }
            guard response["success"] as? Bool == true else {
                // A silent swallow left the optimistic chip lying about
                // the active model — surface the refusal instead.
                let reason = (response["error"] as? String) ?? "未知原因"
                self.emit([.notice("⚠︎ 模型切换失败：\(reason)")])
                return
            }
            if let data = response["data"] as? [String: Any] {
                // omp's set_model success carries the model descriptor
                // AS `data` (rpc-mode: success(id, "set_model", model))
                // — there is no data.model wrapper. Reading the wrapper
                // kept the descriptor STALE, so the confirm rebuild
                // pushed the PREVIOUS model and the chip lagged one
                // pick behind (pick B showed A; pick C showed B); the
                // real new value only arrived with the next state
                // frame — one turn too late.
                let fresh = (data["model"] as? [String: Any])
                    ?? ((data["id"] as? String) != nil ? data : nil)
                self.currentModelDescriptor = fresh ?? self.currentModelDescriptor
                if ProcessInfo.processInfo.environment["GOTY_AI_DEBUG"] == "1" {
                    let cur = self.currentModelDescriptor?["id"] as? String ?? "?"
                    FileHandle.standardError.write("SET_MODEL ok data.id=\(data["id"] as? String ?? "nil") descriptor=\(cur)\n".data(using: .utf8)!)
                }
            }
            self.rebuildConfigOptions()
        }
    }

    override func turnSettled() {
        // Base flushes a deferred builtin command FIRST (a /rename may
        // change the context the model switch lands on).
        super.turnSettled()
        if let pending = pendingModelSelector {
            pendingModelSelector = nil
            applyModelSelector(pending)
        }
        scheduleEntryStamp()
    }

    /// Live frames carry no session-tree entry ids (pi-rpc fixture:
    /// message_end has only the provider's responseId), so the 分支
    /// buttons would stay dark until a store replay (pane reopen).
    /// omp writes the turn's tail entries right around settle — the
    /// same 1.5s grace the mid-turn-reattach rebuild uses — then a
    /// store read lights up the just-finished turn's buttons.
    private func scheduleEntryStamp() {
        guard let sid = sessionId, !sid.isEmpty, !entryStampPending else {
            return
        }
        entryStampPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            self.entryStampPending = false
            self.stampEntryMarks(sessionId: sid)
        }
    }

    /// Ship the store's not-yet-marked entries to the page. Newest
    /// first (OmpSessionStore.freshEntryMarks) — the page stamps the
    private func stampEntryMarks(sessionId sid: String) {
        // Main-queue pre-check (sessionId is main-written): a session
        // switch inside the 1.5s window must drop the stale stamp.
        guard sid == sessionId else { return }
        let known = markedEntryIds
        let daemon = self.daemon
        let daemonPaths = daemonSessionPaths
        AgentSessionExecution.runOffMain(work: { () -> [AgentSessionEvent]? in
            // The marks the page still needs live in the file's tail;
            // remote panes fetch the tail by BYTES (over-cap files
            // can't cross the wire whole — same cap as the history
            // load). Falls back to the full local read.
            var slice: String
            if daemon.isRemote,
               let tail = daemon.agentStoreFile(
                    sessionId: sid,
                    tailBytes: UInt64(Self.tailLoadThresholdBytes)),
               let text = String(data: tail, encoding: .utf8), !text.isEmpty {
                slice = OmpSessionStore.daemonTailSlice(text).slice
            } else if let raw = Self.storeRaw(sid, daemon: daemon,
                                              daemonPaths: daemonPaths) {
                slice = raw.utf8.count > Self.tailLoadThresholdBytes
                    ? OmpSessionStore.tailSlice(raw).slice : raw
            } else {
                return nil
            }
            let fresh = OmpSessionStore
                .freshEntryMarks(from: OmpSessionStore.parse(slice),
                                 known: known)
            return fresh.isEmpty ? nil : fresh
        }, completion: { [weak self] fresh in
            if let fresh { self?.emit(fresh) }
        })
    }


    // MARK: - omp capabilities
    override var capabilities: AgentCapabilities {
        Self.declaredCapabilities
    }

    /// Single source of truth for the manifest (agenttest asserts it).
    override class var declaredCapabilities: AgentCapabilities {
        [.steer, .sessions, .fastMode, .fork, .export, .stats]
    }

    override func setFastMode(enabled: Bool) {
        request("set_fast_mode", ["enabled": enabled]) { [weak self] response in
            guard let self else { return }
            guard response["success"] as? Bool == true else {
                // No service-tier family (GLM etc.) — omp rejects the
                // toggle; surface it instead of a dead button.
                let reason = (response["error"] as? String) ?? "当前模型不支持"
                self.emit([.notice("⚡ fast 模式切换失败：\(reason)")])
                return
            }
            self.refreshState()
        }
    }

    override func loginProviders(completion: @escaping ([[String: Any]]) -> Void) {
        request("get_login_providers") { response in
            guard response["success"] as? Bool == true,
                  let data = response["data"] as? [String: Any],
                  let providers = data["providers"] as? [[String: Any]] else {
                completion([])
                return
            }
            completion(providers)
        }
    }

    override func startLogin(providerId: String) {
        request("login", ["providerId": providerId]) { _ in }
    }

    override func exportHTML(completion: @escaping (String?) -> Void) {
        request("export_html") { response in
            guard response["success"] as? Bool == true,
                  let data = response["data"] as? [String: Any] else {
                completion(nil)
                return
            }
            completion((data["path"] as? String) ?? (data["outputPath"] as? String))
        }
    }

    override func sessionStats(completion: @escaping ([String: Any]?) -> Void) {
        request("get_session_stats") { response in
            guard response["success"] as? Bool == true,
                  let data = response["data"] as? [String: Any] else {
                completion(nil)
                return
            }
            completion(data)
        }
    }

    /// Branch from an entry into a new session file: on success the
    /// process switched context — resync state (session id included),
    /// then rebuild the transcript from the new session's store.
    override func branch(entryId: String, completion: @escaping (Bool) -> Void) {
        // Forking swaps this process onto the fork file; a turn in
        // flight would be killed mid-write and pollute the fork. The
        // host refuses while working too — defense in depth.
        guard !isWorking else { return completion(false) }
        request("branch", ["entryId": entryId]) { [weak self] response in
            guard let self, response["success"] as? Bool == true else {
                completion(false)
                return
            }
            self.refreshState { [weak self] _ in
                guard let self else { return }
                self.emit([.ready])
                self.beginReplayGate(sessionId: self.sessionId ?? "")
                completion(true)
            }
        }
    }

    /// Worktree fork: a NEW session file at the entry — this pane's
    /// live process is never touched. FAST PATH is a pure file
    /// operation (~10ms, no process): a hand-made prefix fork omp
    /// resumes cleanly (probed 2026-09-01). The process round-trip
    /// (13.6s boot) remains as the fallback when the file layout
    /// surprises us.
    override func forkToNewSession(entryId: String, completion: @escaping (String?) -> Void) {
        guard let source = sessionId, !source.isEmpty else {
            completion(nil)
            return
        }
        let daemon = self.daemon
        AgentSessionExecution.runOffMain(work: { () -> String? in
            // Local filesystem first (the GUI shares it with a local
            // daemon), then the daemon's store machine (remote panes).
            if let forkId = OmpSessionStore.forkFile(sourceId: source, entryId: entryId) {
                return forkId
            }
            return daemon.agentStoreFork(sourceId: source, entryId: entryId)
        }, completion: { [weak self] forkId in
            guard let self else { return completion(nil) }
            if let forkId {
                completion(forkId)
                return
            }
            self.forkViaProcess(source: source, entryId: entryId, completion: completion)
        })
    }

    /// Fallback: omp's own branch, driven through a throwaway sibling.
    private func forkViaProcess(source: String, entryId: String,
                                completion: @escaping (String?) -> Void) {
        guard let sourcePath = resumePath(for: source) else {
            completion(nil)
            return
        }
        let forker = OmpSession(params: AgentPaneParams(
            paneId: "fork-" + String(UUID().uuidString.prefix(8)),
            cwd: cwd, environment: environment, daemon: daemon,
            restoredSessionId: source))
        // The throwaway forker has no listing cache of its own — seed
        // the source's daemon-side path so its --resume lands right on
        // remote panes too.
        forker.seedResumePath(sourcePath, for: source)
        forker.connect { ok in
            guard ok else {
                forker.teardownForker()
                completion(nil)
                return
            }
            forker.branch(entryId: entryId) { forked in
                let forkId = (forked && forker.sessionId != source)
                    ? forker.sessionId : nil
                forker.teardownForker()
                completion(forkId)
            }
        }
    }
}

/// Delegate for the throwaway command-directory probe: adopts exactly
/// one event kind and ignores the probe's own handshake/ready chatter.
private final class OmpCommandProbeSink: AgentSessionDelegate {
    private let onCommands: ([AgentSlashCommand]) -> Void
    init(onCommands: @escaping ([AgentSlashCommand]) -> Void) {
        self.onCommands = onCommands
    }
    func session(_ session: AgentSessioning, didEmit events: [AgentSessionEvent]) {
        for event in events {
            if case .commandsChanged(let list) = event { onCommands(list) }
        }
    }
    func sessionDidFail(_ session: AgentSessioning, reason: String) {}
    func session(_ session: AgentSessioning, didDisconnectBecause reason: String) {}
}
