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
final class OmpSession: PiSession {
    // ready-frame handshake bookkeeping (spawn-gated)
    private var readyTimeoutScheduled = false
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

    init(params: AgentPaneParams) {
        super.init(params: params, mapperTerminalOnAgentEnd: true)
        // The catalog rides the FIRST configChanged: without it the
        // models dropdown waits on a second emit that queues behind the
        // transcript replay's render — seconds of "empty models" for a
        // command that itself answers in 10ms.
        cachedModelCatalog = Self.loadCachedCatalog()
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
        // continued turn's live chunks race the store read, and only
        // the gate keeps the final transcript free of wipes,
        // duplicates, and lost turn stats (see beginReplayGate).
        if let sessionId, let path = resumePath(for: sessionId) {
            args += ["--resume", path]
            beginReplayGate(sessionId: sessionId)
        }
    }

    override func beginHandshakeAfterSpawn(completion: ((Bool) -> Void)?) {
        handshakeStarted = false
        readyCompletion = completion
        // A pane left over from the pre-migration ACP era speaks a
        // DIFFERENT protocol: its output has no ready frame, so the
        // handshake would never fire and the GUI would stall into
        // the 90s timeout. Attaching to it can't be distinguished
        // from a slow-booting rpc process up front — give the ready
        // frame a short window, then probe (handleReadyTimeout) and
        // respawn with the rpc argv + --resume if needed.
        if !readyTimeoutScheduled {
            readyTimeoutScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                self?.handleReadyTimeout()
            }
        }
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
        // The ready frame of a LIVE pane arrives only inside the ring
        // replay (the process emitted it once at boot); gating the
        // handshake behind suppressReplay would deadlock attach.
        guard frame["type"] as? String == "ready", !handshakeStarted else {
            return false
        }
        handshakeStarted = true
        let completion = readyCompletion
        readyCompletion = nil
        handshake(completion: completion)
        return true
    }

    /// Replay-gate history: the daemon fetches the store file from ITS
    /// machine (remote panes), parsed by the same local parser. Local
    /// reads only as fallback — the daemon-listed path happens to be a
    /// valid local path when GUI and daemon share a filesystem, and the
    /// suffix walk covers a never-listed local session.
    override func readStoredHistory(
            _ sid: String,
            completion: @escaping (StoredSessionHistory?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return completion(nil) }
            var raw = self.daemon.agentStoreFile(sessionId: sid)
                .flatMap { String(data: $0, encoding: .utf8) }
            if raw == nil, let path = self.daemonSessionPaths[sid] {
                raw = try? String(contentsOfFile: path, encoding: .utf8)
            }
            if raw == nil, let url = OmpSessionStore.fileURL(sessionId: sid) {
                raw = try? String(contentsOf: url, encoding: .utf8)
            }
            guard let raw else { return completion(nil) }
            let loaded = OmpSessionStore.parse(raw)
            completion(StoredSessionHistory(events: loaded.events,
                                            openTools: loaded.openTools,
                                            aborted: loaded.aborted))
        }
    }


    /// History from the DAEMON's store (capability 7) — the only right
    /// answer on remote panes, where the GUI's local ~/.omp belongs to
    /// a different machine. Falls back to the local read (old daemon,
    /// round-trip failure); a remote pane on an old daemon surfaces a
    /// one-time notice instead of a silent empty list.
    override func sessionSummaries(
            _ completion: @escaping ([AgentSessionSummary]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return completion([]) }
            if let (rows, paths) = self.daemon.agentStoreSummaries(cwd: self.cwd) {
                self.daemonSessionPaths.merge(paths) { _, new in new }
                let summaries = rows.map { $0.summary }
                self.noteStoreFallbackIfRemote(summaries)
                completion(summaries)
            } else {
                let summaries = OmpSessionStore.summaries(cwd: self.cwd)
                self.noteStoreFallbackIfRemote(summaries)
                completion(summaries)
            }
        }
    }

    private func noteStoreFallbackIfRemote(_ summaries: [AgentSessionSummary]) {
        guard daemon.isRemote, summaries.isEmpty, !warnedOldDaemonStore else { return }
        warnedOldDaemonStore = true
        emit([.notice("远端 sessiond 版本过旧，无法读取该主机上的历史记录（升级远端守护进程后可用）")])
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

    /// The config buttons' dropdown contents. get_state carries
    /// only the CURRENT model; the selectable list comes from
    /// get_available_models (model ids as provider/id selectors — the
    /// same shape set_model takes — and the current model's
    /// thinking.efforts ladder).
    private func fetchAvailableModels() {
        request("get_available_models") { [weak self] response in
            guard let self,
                  response["success"] as? Bool == true,
                  let data = response["data"] as? [String: Any],
                  let models = data["models"] as? [[String: Any]] else { return }
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
            // value is the provider/id selector applyState built; set_model
            // takes it split (verified live). Bare ids pass through.
            let parts = value.split(separator: "/", maxSplits: 1).map(String.init)
            var extra: [String: Any] = [:]
            if parts.count == 2 {
                extra["provider"] = parts[0]
                extra["modelId"] = parts[1]
            } else {
                extra["modelId"] = value
            }
            request("set_model", extra) { [weak self] response in
                guard let self, response["success"] as? Bool == true else { return }
                if let data = response["data"] as? [String: Any] {
                    self.currentModelDescriptor = (data["model"] as? [String: Any])
                        ?? self.currentModelDescriptor
                }
                self.rebuildConfigOptions()
            }
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

    // MARK: - omp capabilities

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
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return completion(nil) }
            // Local filesystem first (the GUI shares it with a local
            // daemon), then the daemon's store machine (remote panes).
            if let forkId = OmpSessionStore.forkFile(sourceId: source, entryId: entryId) {
                completion(forkId)
                return
            }
            if let forkId = self.daemon.agentStoreFork(sourceId: source, entryId: entryId) {
                completion(forkId)
                return
            }
            self.forkViaProcess(source: source, entryId: entryId, completion: completion)
        }
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
