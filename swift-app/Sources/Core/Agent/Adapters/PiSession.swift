// goty - see CLAUDE.md for the working principles.
import Foundation

/// Which pi-mono harness a session drives. Both speak the same JSONL
/// RPC runtime (`--mode rpc`); the differences stop at this enum:
///
/// - argv: omp takes `--cwd <dir>` (and `--resume <file>`); pi has no
///   --cwd (the pane's cwd buckets its sessions) and resumes via
///   `--session`;
/// - handshake: omp negotiates protocol v2 and may send base64
///   `rpc_chunk` frames that reassemble into one logical frame; pi has
///   neither;
/// - events: omp streams tool lifecycle as tool_execution_* frames and
///   terminates runs with agent_end (pi settles via agent_settled and
///   carries tools as content blocks);
/// - recovery: omp renders its transcript from the session store (the
///   same jsonl the omp TUI reads); pi replays get_messages.
///
/// Probed live on omp 18.0.10 / pinned by fixtures for pi 0.84.3.
enum PiMonoHarness {
    case pi
    case omp

    var shell: String { self == .omp ? "omp" : "pi" }
}

/// One harness of the pi-mono family over `--mode rpc` — JSONL frames
/// on a LineChannel pane. Commands carry optional ids; responses match
/// by id. Events stream as id-less frames; PiFrameMapper shapes them.
final class PiSession: AgentSessioning {
    weak var delegate: AgentSessionDelegate?

    let cwd: String?
    private(set) var sessionId: String?
    private(set) var isWorking = false
    private(set) var configOptions: [AgentConfigOption] = []
    private(set) var commands: [AgentSlashCommand] = []

    private let harness: PiMonoHarness
    private let paneId: String
    private let environment: [String: String]
    private let daemon: SessionDaemon
    private let grid: SessionGrid
    private let channel = LineChannel()

    /// get_state's model descriptor — the thinking-level ladder is
    /// model-specific (thinking.efforts), so applyState needs it when
    /// get_available_models lands.
    private var currentModelDescriptor: [String: Any]?
    private var thinkingLevelCache: String?
    private var cachedModelCatalog: [[String: Any]] = []
    private let mapper: PiFrameMapper
    private var pane: PaneSession?
    /// omp handshake gate: the ready frame (not spawn) starts
    /// negotiate+get_state — see openPane.
    private var handshakeStarted = false
    private var readyCompletion: ((Bool) -> Void)?
    private var readyTimeoutScheduled = false
    private var respawnedForReadyTimeout = false

    private var connected = false
    private var resumeSessionId: String?
    private var nextRequestID = 1
    private let responseLock = NSLock()
    private var pendingResponses: [String: ([String: Any]) -> Void] = [:]

    /// omp attach: ring frames are SIGNAL-ONLY while the authoritative
    /// transcript is read from the session store (the ring's callback
    /// order is not chronological; rendering it scrambled transcripts).
    private var suppressReplay = false

    /// v2 chunked frames: base64 rpc_chunk sequences reassembled per
    /// chunkId (≤64 MiB, ≤4096 parts — omp's ready-frame caps).
    private struct ChunkAssembly {
        var count: Int
        var parts: [Int: Data]
        var bytes: Int
    }
    private var chunkAssemblies: [String: ChunkAssembly] = [:]

    /// Integrity accounting.
    private(set) var framesRouted = 0

    init(params: AgentPaneParams, harness: PiMonoHarness = .pi) {
        self.harness = harness
        self.paneId = params.paneId
        self.cwd = params.cwd
        self.environment = params.environment
        self.daemon = params.daemon
        self.grid = AgentPaneDefaults.grid
        self.mapper = PiFrameMapper(terminalOnAgentEnd: harness == .omp)
        self.resumeSessionId = params.restoredSessionId
        // The catalog rides the FIRST configChanged: without it the
        // models dropdown waits on a second emit that queues behind the
        // transcript replay's render — seconds of "empty models" for a
        // command that itself answers in 10ms.
        self.cachedModelCatalog = Self.loadCachedCatalog()
        channel.onOutbound = { [weak self] in self?.pane?.sendInput($0) }
        channel.onFrame = { [weak self] frame, _ in
            self?.handleFrame(frame)
        }
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
        var args = ["--mode", "rpc"]
        switch harness {
        case .omp:
            // omp buckets its sessions by --cwd; the pane cwd alone is
            // not enough for a fresh spawn from a Finder-launched GUI.
            if let cwd, !cwd.isEmpty { args += ["--cwd", cwd] }
            // omp's --resume wants the exact session file path.
            if let sessionId,
               let url = OmpSessionStore.fileURL(sessionId: sessionId) {
                args += ["--resume", url.path]
            }
        case .pi:
            if let sessionId { args += ["--session", sessionId] }
        }
        // omp: the handshake is gated on the ready frame (see
        // handleFrame) — the process answers stdin normally once its
        // RPC loop is up; a burst written before that strands all but
        // the first line (PTY line discipline, probed 2026-08-31).
        // A pane left over from the pre-migration ACP era speaks a
        // DIFFERENT protocol: its output has no ready frame, so the
        // handshake would never fire — handleReadyTimeout respawns
        // with the rpc argv and --resume below.
        guard let opened = daemon.openPaneWithAttachment(
            id: paneId, cwd: cwd, shell: harness.shell, args: args,
            environment: environment, grid: grid,
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
            connected = false
            delegate?.sessionDidFail(self, reason: "sessiond 不可用")
            completion?(false)
            return
        }
        opened.session.start()
        pane = opened.session
        // pi answers the handshake immediately after spawn (its node
        // runtime has no PTY first-line stranding); omp waits for the
        // ready frame — live on a fresh spawn, or inside the ring
        // replay when attaching to a live pane.
        if harness == .omp {
            handshakeStarted = false
            readyCompletion = completion
            // A pane left over from the pre-migration ACP era speaks a
            // DIFFERENT protocol: its output has no ready frame, so the
            // handshake would never fire and the GUI would stall into
            // the 90s timeout. Attaching to it can't be distinguished
            // from a slow-booting rpc process up front — give the ready
            // frame a short window, then respawn with the rpc argv and
            // --resume (the session itself lives in the store file).
            if !readyTimeoutScheduled {
                readyTimeoutScheduled = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                    self?.handleReadyTimeout()
                }
            }
        } else {
            handshake(completion: completion)
        }
    }

    /// The ready frame never arrived: the pane is either an old ACP
    /// process or a dead process the daemon still lists. Respawn once
    /// with the current harness argv; the next openPane's ready frame
    /// (or the pane's exit) resolves the situation.
    private func handleReadyTimeout() {
        guard harness == .omp, !handshakeStarted else { return }
        if respawnedForReadyTimeout { return }
        respawnedForReadyTimeout = true
        NSLog("GOTY pi-session: ready timeout — respawning %@ pane", harness.shell)
        pane?.close()
        pane = nil
        // Acknowledged kill, same as load(): an unacknowledged one races
        // the respawn's ATTACH probe and resurrects the dead pane.
        daemon.killPaneAndWait(id: paneId) { [weak self] _ in
            self?.openPane(resume: self?.resumeSessionId, completion: self?.readyCompletion)
        }
    }

    /// Shared get_state handler: the pi immediate handshake and the omp
    /// ready-gated handshake both land here.
    private func handleStateResponse(_ response: [String: Any],
                                     completion: ((Bool) -> Void)?) {
        guard response["success"] as? Bool == true,
              let state = response["data"] as? [String: Any] else {
            delegate?.sessionDidFail(self, reason: "\(harness.shell) get_state 失败")
            completion?(false)
            return
        }
        handshakeStarted = true
        sessionId = state["sessionId"] as? String ?? sessionId
        currentModelDescriptor = state["model"] as? [String: Any]
        thinkingLevelCache = state["thinkingLevel"] as? String
        applyState(state)
        // omp: the ring is signal-only; the authoritative transcript
        // comes from the session store (user side included, aborted
        // turns settled). pi: the ring replay already rendered through
        // the mapper (replaying mode emits the user echo).
        if harness == .omp {
            isWorking = state["isStreaming"] as? Bool ?? false
            ompStoreReplay()
        }
        var events: [AgentSessionEvent] = [.ready]
        if !configOptions.isEmpty {
            events.append(.configChanged(configOptions))
        }
        emit(events)
        if harness == .pi {
            fetchCommands()
        } else {
            fetchAvailableModels()
        }
        completion?(true)
    }

    /// omp: the config buttons' dropdown contents. get_state carries
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
    /// fresh PiSession carries full dropdown choices without waiting
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

    /// ready-gated handshake, one command in flight at a time. omp's
    /// PTY delivers ONE line per read until its reader loop spins up,
    /// so a two-line burst written at once can strand the second line
    /// forever (probed 2026-08-31: prewrite boots answered negotiate
    /// but never get_state). Sequential request→response→request is
    /// also the shape gooey-pi's runtime uses against the same
    /// protocol.
    private func handshake(completion: ((Bool) -> Void)?) {
        // The host's 90s watchdog is disarmed by our early .ready (the
        // session-name render); a genuinely broken handshake must still
        // fail loudly — 20s ceiling here.
        var finished = false
        let failAfter = DispatchWorkItem { [weak self] in
            guard let self, !finished else { return }
            finished = true
            self.delegate?.sessionDidFail(self, reason: "\(self.harness.shell) 握手超时")
            completion?(false)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: failAfter)
        func finish(_ ok: Bool) {
            guard !finished else { return }
            finished = true
            failAfter.cancel()
            completion?(ok)
        }
        // negotiate_protocol is an omp extension (v2 chunked frames);
        // base pi 0.8x answers it success=false and would fail the
        // whole handshake (2026-08-31: every pi panel showed 连接失败).
        // pi goes straight to get_state.
        if harness == .omp {
            request("negotiate_protocol", ["protocolVersion": 2]) { [weak self] response in
                guard let self else { return }
                guard response["success"] as? Bool == true else {
                    self.delegate?.sessionDidFail(self, reason: "omp 不支持 RPC v2，请升级 CLI")
                    finish(false)
                    return
                }
                request("get_state") { [weak self] response in
                    self?.handleStateResponse(response, completion: finish)
                }
            }
        } else {
            request("get_state") { [weak self] response in
                self?.handleStateResponse(response, completion: finish)
            }
        }
    }

    private func fetchCommands() {
        request("get_commands") { [weak self] response in
            guard let self, response["success"] as? Bool == true else { return }
            // Response wraps the list: {"commands":[…]} (verified
            // live); a bare array is tolerated for forward compat.
            let payload = response["data"] as? [String: Any]
            let data = (payload?["commands"] as? [[String: Any]])
                ?? (response["data"] as? [[String: Any]]) ?? []
            self.applyCommands(data)
        }
    }

    private func applyCommands(_ data: [[String: Any]]) {
        let commands: [AgentSlashCommand] = data.compactMap { raw in
            guard let name = raw["name"] as? String else { return nil }
            return AgentSlashCommand(name: name,
                                     description: raw["description"] as? String,
                                     inputHint: (raw["input"] as? [String: Any])?["hint"] as? String)
        }
        guard !commands.isEmpty else { return }
        self.commands = commands
        emit([.commandsChanged(commands)])
    }

    private func ompStoreReplay() {
        guard let sid = sessionId else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let stored = OmpSessionStore.load(sessionId: sid)
            DispatchQueue.main.async {
                guard let self, !stored.events.isEmpty else { return }
                self.emit([.transcriptReset] + stored.events)
            }
        }
    }

    func send(_ text: String) {
        guard !isWorking else { return }
        isWorking = true
        channel.send(["id": "u\(nextRequestID)", "type": "prompt", "message": text])
        nextRequestID += 1
    }

    func cancel() {
        channel.send(["type": "abort"])
    }

    func setConfigOption(id: String, value: String) {
        guard harness == .omp else { return }
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

    func respondPermission(requestID: String, optionId: String) {
        // rpc mode auto-approves per the agent's own config in v1; no
        // permission requests are mapped, so an answer here is a no-op.
    }


    func listSessions(completion: @escaping ([AgentSessionSummary]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let summaries = self.harness == .omp
                ? OmpSessionStore.summaries(cwd: self.cwd)
                : PiSessionStore.summaries(cwd: self.cwd)
            DispatchQueue.main.async {
                completion(summaries)
            }
        }
    }

    func load(sessionId: String, completion: ((Bool) -> Void)? = nil) {
        // Both harnesses swap sessions the same way: kill the pane (or
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
            self?.openPane(resume: sessionId) { [weak self] ok in
                guard let self, ok else {
                    completion?(false)
                    return
                }
                if self.harness == .pi {
                    self.request("get_messages") { [weak self] response in
                        guard let self,
                              response["success"] as? Bool == true,
                              let data = response["data"] as? [String: Any],
                              let messages = data["messages"] as? [[String: Any]] else {
                            completion?(false)
                            return
                        }
                        let replayMapper = PiFrameMapper()
                        var events: [AgentSessionEvent] = []
                        for message in messages {
                            events += replayMapper.mapReplayedMessage(message)
                        }
                        self.emit(events)
                        completion?(true)
                    }
                } else {
                    completion?(true)
                }
            }
        }
    }

    func shutdown() {
        pane?.close()
        pane = nil
        connected = false
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
            if harness == .omp { suppressReplay = true }
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
            delegate?.sessionDidFail(self, reason: "\(harness.shell) 进程已退出")
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
        // Protocol plumbing is exempt from replay suppression: the
        // ready frame of a LIVE pane arrives only inside the ring
        // replay (the process emitted it once at boot), so gating the
        // handshake behind suppressReplay deadlocks attach. Stale
        // replayed responses simply match no pending id and drop.
        if frame["type"] as? String == "ready",
           harness == .omp, !handshakeStarted {
            handshakeStarted = true
            let completion = readyCompletion
            readyCompletion = nil
            handshake(completion: completion)
            return
        }
        if frame["type"] as? String == "response",
           let id = frame["id"] as? String {
            responseLock.lock()
            let completion = pendingResponses.removeValue(forKey: id)
            responseLock.unlock()
            completion?(frame)
            return
        }
        // Transcript frames from the ring replay stay suppressed for
        // omp: the session store is the authoritative transcript.
        if suppressReplay { return }
        let events = mapper.map(frame)
        for event in events {
            if case .commandsChanged(let list) = event {
                commands = list
            }
            if case .turnEnded = event {
                isWorking = false
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

    private func applyState(_ state: [String: Any],
                            availableModels: [[String: Any]] = []) {
        var options: [AgentConfigOption] = []
        let modelChoices: [AgentConfigChoice] = availableModels.compactMap { raw in
            guard let id = raw["id"] as? String else { return nil }
            let value = (raw["provider"] as? String).map { "\($0)/\(id)" } ?? id
            return AgentConfigChoice(value: value,
                                     name: (raw["name"] as? String) ?? id,
                                     description: nil)
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
    private func request(_ command: String, _ extra: [String: Any] = [:],
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

    /// Restore is self-managed: connect() spawns with the resume flag
    /// and the handshake replays the store, so the host must NOT issue
    /// a second load() on top (it would kill and respawn the pane the
    /// handshake is running on).
    var selfManagesRestore: Bool { true }

    private func emit(_ events: [AgentSessionEvent]) {
        guard !events.isEmpty else { return }
        delegate?.session(self, didEmit: events)
    }
}
