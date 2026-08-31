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
        // omp: the handshake rides the daemon's spawn prewrite — omp's
        // Bun stdin only processes input buffered at boot (post-startup
        // writes are never surfaced by its event loop, probed
        // 2026-08-31), so negotiate+get_state must already be in the PTY
        // when the process starts. The responses arrive through the
        // channel as ordinary id-matched frames; register their pending
        // completions BEFORE the spawn so nothing races.
        var prewrite: String?
        if harness == .omp {
            prewrite = bootHandshakePrewrite(completion: completion)
        }
        guard let opened = daemon.openPaneWithAttachment(
            id: paneId, cwd: cwd, shell: harness.shell, args: args,
            environment: environment, grid: grid,
            noEcho: true, ringBytes: 16_777_216,
            prewrite: prewrite,
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
        // pi answers get_state immediately after spawn. omp's handshake
        // already rode the spawn prewrite; the ready frame stays as a
        // fallback trigger for environments where the prewrite was
        // eaten by the pane wrapper.
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

    /// omp's spawn prewrite: negotiate + get_state as two JSONL lines.
    /// The ids are registered in `pendingResponses` first (see openPane)
    /// so the daemon-pre-written responses route like any other.

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
        daemon.killPane(id: paneId)
        openPane(resume: resumeSessionId, completion: readyCompletion)
    }

    /// Shared get_state handler: the pi immediate handshake and the omp
    /// spawn-prewrite response both land here.
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
        }
        completion?(true)
    }

    /// omp's spawn prewrite: negotiate + get_state as two JSONL lines.
    /// Their pending completions are registered BEFORE the spawn (see
    /// openPane) so the daemon-pre-written responses route like any
    /// other id-matched frame.
    private func bootHandshakePrewrite(completion: ((Bool) -> Void)?) -> String {
        let negotiate = ["id": "boot-1", "type": "negotiate_protocol",
                         "protocolVersion": 2] as [String: Any]
        let state = ["id": "boot-2", "type": "get_state"] as [String: Any]
        responseLock.lock()
        pendingResponses["boot-1"] = { [weak self] response in
            guard let self else { return }
            if response["success"] as? Bool != true {
                self.delegate?.sessionDidFail(self, reason: "omp 不支持 RPC v2，请升级 CLI")
                completion?(false)
            }
        }
        pendingResponses["boot-2"] = { [weak self] response in
            guard let self else { return }
            self.handleStateResponse(response, completion: completion)
        }
        responseLock.unlock()
        func line(_ obj: [String: Any]) -> String {
            (try? JSONSerialization.data(withJSONObject: obj)).flatMap {
                String(data: $0, encoding: .utf8)
            } ?? ""
        }
        return line(negotiate) + "\n" + line(state) + "\n"
    }

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
        request("get_state") { [weak self] response in
            guard let self else { return }
            self.handleStateResponse(response, completion: finish)
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

    func respondPermission(requestID: String, optionId: String) {
        // rpc mode auto-approves per the agent's own config in v1; no
        // permission requests are mapped, so an answer here is a no-op.
    }

    func setConfigOption(id: String, value: String) {
        // v1: display-only (configChanged reports model + thinking level).
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
        // store, pi from get_messages.
        resumeSessionId = sessionId
        self.sessionId = sessionId
        pane?.close()
        pane = nil
        daemon.killPane(id: paneId)
        openPane(resume: sessionId) { [weak self] ok in
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
        if suppressReplay { return }
        if frame["type"] as? String == "ready",
           harness == .omp, !handshakeStarted {
            handshakeStarted = true
            let completion = readyCompletion
            readyCompletion = nil
            handshake(completion: completion)
            return
        }

        if suppressReplay { return }
        if frame["type"] as? String == "response",
           let id = frame["id"] as? String {
            responseLock.lock()
            let completion = pendingResponses.removeValue(forKey: id)
            responseLock.unlock()
            completion?(frame)
            return
        }
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

    private func applyState(_ state: [String: Any]) {
        var options: [AgentConfigOption] = []
        if let model = state["model"] as? [String: Any] {
            let name = (model["name"] as? String)
                ?? (model["id"] as? String) ?? ""
            options.append(AgentConfigOption(id: "model", name: "模型", category: nil,
                                             currentValue: name, options: []))
        }
        if let thinking = state["thinkingLevel"] as? String {
            options.append(AgentConfigOption(id: "thinking", name: "思考", category: nil,
                                             currentValue: thinking, options: []))
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

    private func emit(_ events: [AgentSessionEvent]) {
        guard !events.isEmpty else { return }
        delegate?.session(self, didEmit: events)
    }
}
