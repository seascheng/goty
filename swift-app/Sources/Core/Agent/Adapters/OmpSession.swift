// goty — see CLAUDE.md for the working principles.
import Foundation

/// omp adapter — ACP over the daemon-hosted pane (attach-or-spawn).
/// State machine: disconnected → connecting → ready ⇄ working /
/// awaitingPermission; death surfaces as the daemon's EXITED frame.
final class OmpSession: AgentSessioning {
    weak var delegate: AgentSessionDelegate?

    let cwd: String?
    private let paneId: String
    private let environment: [String: String]
    private let spawn: AgentSpawn
    private let daemon: SessionDaemon
    private let grid: SessionGrid
    private var pane: PaneSession?
    private let client = JSONRPCChannel()
    private(set) var sessionId: String?
    private(set) var isWorking = false
    private(set) var configOptions: [AgentConfigOption] = []
    private(set) var commands: [AgentSlashCommand] = []
    private var connected = false

    init(paneId: String, cwd: String?, grid: SessionGrid,
         environment: [String: String],
         spawn: AgentSpawn, daemon: SessionDaemon,
         delegate: AgentSessionDelegate? = nil) {
        self.paneId = paneId
        self.cwd = cwd
        self.grid = grid
        self.environment = environment
        self.spawn = spawn
        self.daemon = daemon
        self.delegate = delegate
        client.onOutbound = { [weak self] in self?.pane?.sendInput($0) }
        client.onNotification = { [weak self] method, params in
            self?.interpret(["method": method, "params": params])
        }
        client.onRequest = { [weak self] id, method, params in
            guard method == "session/request_permission" else { return }
            self?.interpret(["id": id, "method": method, "params": params])
        }
        // Attach adoption: the ring re-streams the pane's original
        // session/new response; that orphan result is where the live
        // sessionId lives (the process owns it — we never re-handshake).
        client.onOrphanResult = { [weak self] result in
            guard let self, self.sessionId == nil,
                  let id = result["sessionId"] as? String else { return }
            self.sessionId = id
        }
    }

    func connect(completion: ((Bool) -> Void)? = nil) {
        guard !connected else {
            completion?(true)
            return
        }
        connected = true
        guard let opened = openTransport() else {
            connected = false
            delegate?.sessionDidFail(self, reason: "sessiond 不可用")
            completion?(false)
            return
        }
        if debugFramesEnabled {
            print("GOTY_DEBUG omp openTransport attached=\(opened.attachedExisting)")
        }
        if opened.attachedExisting {
            // The pane's process already owns a session; its ring replay
            // rebuilds the transcript and the orphan-result hook re-learns
            // the sessionId. A fresh handshake here would create a SECOND
            // omp session and orphan the live turn.
            emit([.ready])
            completion?(true)
            return
        }
        handshake(completion)
    }

    private func openTransport() -> SessionDaemon.OpenPaneResult? {
        guard let opened = daemon.openPaneWithAttachment(
            id: paneId, cwd: cwd, shell: spawn.command, args: spawn.args,
            environment: environment, grid: grid,
            noEcho: true, ringBytes: spawn.ringBytes,
            onFrame: { [weak self] kind, data in
                self?.handleFrame(kind: kind, data: data)
            },
            onDisconnect: { [weak self] in
                guard let self else { return }
                self.connected = false
                self.delegate?.session(self, didDisconnectBecause: "daemon 连接断开")
            })
        else { return nil }
        // onOutbound writes through this property — a nil pane silently
        // eats every request (initialize included).
        pane = opened.session
        // The reader thread pumps attach replies, ring replay and live
        // frames — without it the handshake hangs forever.
        opened.session.start()
        return opened
    }

    private func handshake(_ completion: ((Bool) -> Void)?) {
        if debugFramesEnabled {
            print("GOTY_DEBUG omp handshake: sending initialize")
        }
        client.request("initialize", [
            "protocolVersion": 1,
            "clientCapabilities": ["fs": ["readTextFile": false, "writeTextFile": false]],
        ]) { [weak self] result in
            guard let self, case .success = result else {
                self?.failHandshake("initialize 失败", completion)
                return
            }
            self.client.request("session/new", [
                "cwd": self.cwd ?? NSNull(), "mcpServers": [],
            ]) { [weak self] result in
                guard let self, case .success(let value) = result,
                      let sessionId = value["sessionId"] as? String else {
                    self?.failHandshake("session/new 失败", completion)
                    return
                }
                self.sessionId = sessionId
                let configs = AgentConfigOption.list(value["configOptions"])
                self.configOptions = configs
                self.emit(configs.isEmpty ? [.ready] : [.configChanged(configs), .ready])
                completion?(true)
            }
        }
    }

    func reconnect(completion: ((Bool) -> Void)? = nil) {
        pane?.close()
        pane = nil
        connected = true
        guard let opened = openTransport() else {
            connected = false
            completion?(false)
            return
        }
        if opened.attachedExisting {
            emit([.ready])
            completion?(true)
            return
        }
        // Fresh process: the old session id is gone from the wire; the
        // caller restores the conversation via load(lastSessionId).
        handshake { [weak self] ok in
            guard let self, ok, let restore = self.lastSessionId else {
                completion?(ok)
                return
            }
            self.load(sessionId: restore) { _ in completion?(true) }
        }
    }

    /// Handshake failure path: report and settle the connect completion.
    /// (The old `sessionDidFail(self!)` crashed when the weak self had
    /// already gone — argument evaluation runs before optional chaining.)
    private func failHandshake(_ reason: String, _ completion: ((Bool) -> Void)?) {
        delegate?.sessionDidFail(self, reason: reason)
        completion?(false)
    }

    private func handleFrame(kind: UInt8, data: Data) {
        bytesFed += data.count
        if debugFramesEnabled {
            if loadDebugBytes == 0 { loadDebugStart = Date() }
            loadDebugBytes += data.count
            loadDebugFrames += 1
            if loadDebugBytes / 262_144 != (loadDebugBytes - data.count) / 262_144 {
                print("GOTY_DEBUG: replay \(loadDebugBytes)B in \(Date().timeIntervalSince(loadDebugStart))s frames=\(loadDebugFrames)")
            }
        }
        switch kind {
        case SessionOutputKind.output:
            if debugFramesEnabled { print("GOTY_DEBUG omp frame OUTPUT \(data.count)B: \(String(decoding: data.prefix(120), as: UTF8.self))") }
            client.feed([UInt8](data))
        case SessionOutputKind.snapshot:
            if debugFramesEnabled { print("GOTY_DEBUG omp frame SNAPSHOT \(data.count)B") }
            // Ring replay (reattach to a live pane): the history bytes ARE
            // the transcript. Replayed responses never complete the fresh
            // handshake — ACPClient drops those in replay mode — while the
            // session/update notifications rebuild the transcript.
            client.feed([UInt8](data), replay: true)
        case SessionOutputKind.exited:
            delegate?.sessionDidFail(self, reason: "agent 进程已退出")
        default:
            break // SIZE/ATTACHED/ERROR: transport markers, not transcript
        }
    }

    /// Replay bursts arrive as thousands of single-event emits; hopping
    /// each onto the main queue individually stalls the replay pipeline
    /// (a multi-second session/load). Deliver at most one batched
    /// delegate call per main-queue turn — ordering preserved, connect-
    /// time ready/config events can never strand in the buffer.
    private func emit(_ events: [AgentSessionEvent]) {
        guard !events.isEmpty else { return }
        eventsEmitted += events.count
        pendingLock.lock()
        pendingEvents.append(contentsOf: events)
        let needsSchedule = !pendingFlushScheduled
        pendingFlushScheduled = true
        pendingLock.unlock()
        if needsSchedule {
            DispatchQueue.main.async { [weak self] in self?.flushPendingEvents() }
        }
    }

    private func flushPendingEvents() {
        pendingLock.lock()
        defer { pendingFlushScheduled = false }
        let events = pendingEvents
        pendingEvents = []
        pendingLock.unlock()
        if events.isEmpty { return }
        delegate?.session(self, didEmit: events)
        pendingLock.lock()
        let again = !pendingEvents.isEmpty
        if again { pendingFlushScheduled = true }
        pendingLock.unlock()
        if again {
            DispatchQueue.main.async { [weak self] in self?.flushPendingEvents() }
        }
    }
    private var pendingEvents: [AgentSessionEvent] = []
    private var pendingFlushScheduled = false
    private let pendingLock = NSLock()
    /// Hoisted out of handleFrame: ProcessInfo.environment copies the whole
    /// environment dictionary on every access — per frame that dominated
    /// the replay pipeline.
    private var loadDebugBytes = 0
    private var loadDebugFrames = 0
    private var loadDebugStart = Date()
    private let debugFramesEnabled = ProcessInfo.processInfo.environment["GOTY_AUTOLOAD_SESSION"] != nil
    var debugReplayBytes: Int { loadDebugBytes }
    var debugReplayFrames: Int { loadDebugFrames }

    // MARK: - Integrity accounting

    /// Resume audits compare these per layer — bytes in, ACP messages
    /// routed, events emitted; any mismatch localizes the first lossy
    /// boundary. Integer bumps, always on.
    private(set) var bytesFed = 0
    private(set) var eventsEmitted = 0
    var messagesRouted: Int { client.messagesRouted }
    var unparseableLines: Int { client.unparseableLines }

    func send(_ text: String) {
        if debugFramesEnabled {
            print("GOTY_DEBUG omp send: sessionId=\(sessionId ?? "nil") working=\(isWorking) pane=\(pane != nil)")
        }
        guard let sessionId, !isWorking else { return }
        isWorking = true
        // omp 18.0.8 names the field `prompt` (spec drift: ACP v1 says
        // `content`); M3 adapters translate back per agent.
        client.request("session/prompt", [
            "sessionId": sessionId,
            "prompt": [["type": "text", "text": text]],
        ]) { [weak self] result in
            guard let self else { return }
            self.isWorking = false
            if case .success(let value) = result {
                self.emit([.turnEnded(stopReason: value["stopReason"] as? String)])
            } else {
                self.emit([.turnEnded(stopReason: nil)])
            }
        }
    }

    func cancel() {
        guard let sessionId else { return }
        client.notify("session/cancel", ["sessionId": sessionId])
    }

    func respondPermission(requestID: String, optionId: String) {
        guard let id = Int(requestID) else { return }
        client.respond(id: id,
                       result: ["outcome": ["outcome": "selected", "optionId": optionId]])
    }

    /// Persisted-session directory (session/list) filtered to the pane cwd.
    /// Zero-message entries are creation placeholders — drop them; newest
    /// activity sorts first.
    func listSessions(completion: @escaping ([AgentSessionSummary]) -> Void) {
        var params: [String: Any] = [:]
        if let cwd { params["cwd"] = cwd }
        client.request("session/list", params) { result in
            guard case .success(let value) = result else {
                completion([])
                return
            }
            let summaries = AgentSessionSummary.list(value["sessions"])
                .filter { ($0.messageCount ?? 0) > 0 }
                .sorted { ($0.updatedAt ?? "") > ($1.updatedAt ?? "") }
            completion(summaries)
        }
    }

    /// Flip one config knob (mode / model / thinking …). The OK response
    /// carries the full updated knob list — that is the new state, apply
    /// it wholesale.
    func setConfigOption(id: String, value: String) {
        guard let sessionId else { return }
        client.request("session/set_config_option", [
            "sessionId": sessionId, "configId": id, "value": value,
        ]) { [weak self] result in
            guard let self, case .success(let response) = result else { return }
            let configs = AgentConfigOption.list(response["configOptions"])
            guard !configs.isEmpty else { return }
            self.configOptions = configs
            self.emit([.configChanged(configs)])
        }
    }

    /// Resume a persisted agent session on this connection; replayed
    /// history arrives as normal session/update events.
    func load(sessionId id: String, completion: ((Bool) -> Void)? = nil) {
        // omp REQUIRES a string cwd ("path must be of type string" on
        // null/missing) — fall back to the process cwd for panes whose
        // workspace never tracked one.
        let params: [String: Any] = [
            "sessionId": id,
            "cwd": cwd ?? FileManager.default.currentDirectoryPath,
            "mcpServers": [],
        ]
        client.request("session/load", params) { [weak self] result in
            guard let self, case .success(let value) = result else {
                completion?(false)
                return
            }
            self.sessionId = id
            self.isWorking = false
            let configs = AgentConfigOption.list(value["configOptions"])
            self.configOptions = configs
            var events: [AgentSessionEvent] = []
            if !configs.isEmpty { events.append(.configChanged(configs)) }
            events.append(.ready)
            self.emit(events)
            completion?(true)
        }
    }

    func shutdown() {
        pane?.close()
        pane = nil
        sessionId = nil
        connected = false
    }

    // MARK: - Inbound interpretation (internal for agenttest)

    /// Returns the decoded events so tests can collect them with a nil
    /// delegate; production callers consume via the delegate only.
    @discardableResult
    func interpret(_ message: [String: Any]) -> [AgentSessionEvent] {
        var events: [AgentSessionEvent] = []
        guard message["method"] as? String == "session/update",
              let params = message["params"] as? [String: Any],
              let update = params["update"] as? [String: Any],
              let kind = update["sessionUpdate"] as? String else {
            if message["method"] as? String == "session/request_permission",
               let id = message["id"] as? Int,
               let params = message["params"] as? [String: Any] {
                let options = (params["options"] as? [[String: Any]] ?? [])
                    .compactMap { AgentPermissionOption(raw: $0) }
                let title = (params["toolCall"] as? [String: Any])?["title"] as? String
                events.append(.permissionRequested(
                    AgentPermissionPrompt(requestID: String(id), toolCallTitle: title, options: options)))
            }
            emit(events)
            return events
        }
        switch kind {
        case "user_message_chunk":
            if let content = (update["content"] as? [String: Any]).flatMap(AgentContent.init),
               let text = content.text {
                events.append(.userChunk(text))
            }
        case "agent_message_chunk":
            if let content = (update["content"] as? [String: Any]).flatMap(AgentContent.init),
               let text = content.text {
                events.append(.messageChunk(text))
            }
        case "agent_thought_chunk":
            if let content = (update["content"] as? [String: Any]).flatMap(AgentContent.init),
               let text = content.text {
                events.append(.thoughtChunk(text))
            }
        case "tool_call", "tool_call_update":
            if let id = update["toolCallId"] as? String {
                // Full fidelity, both wire shapes: nested `content` wrappers
                // and `rawOutput` tool results. The flat-only reader plus a
                // 64 KiB cap silently dropped most tool output on resume —
                // the long-session content loss. No truncation here: the
                // render layer windows, the bridge is structured transport.
                let content = ACPContentNormalizer.flatten(update["content"] as? [[String: Any]])
                let output = ACPContentNormalizer.resultItems(rawOutput: update["rawOutput"])
                // Edit-like calls carry rawInput {path, content}: snapshot the
                // on-disk file NOW (before the write lands) so the UI can
                // render a real old↔new diff. Local panes only; 256 KiB cap.
                var oldText: String?
                let toolStatus = update["status"] as? String
                if toolStatus == "pending", let rawInput = update["rawInput"] as? [String: Any],
                   let path = rawInput["path"] as? String,
                   let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                   let size = attrs[.size] as? Int, size <= 256 * 1024,
                   let data = FileManager.default.contents(atPath: path) {
                    oldText = String(data: data, encoding: .utf8)
                }
                events.append(.toolCallUpdate(id: id,
                                              title: update["title"] as? String,
                                              kind: update["kind"] as? String,
                                              status: toolStatus,
                                              content: content,
                                              output: output,
                                              rawInput: update["rawInput"] as? [String: Any],
                                              oldText: oldText))
            }
        case "plan":
            let entries = ((update["entries"] as? [[String: Any]]) ?? []).compactMap(AgentPlanEntry.init)
            if !entries.isEmpty {
                events.append(.plan(entries))
            }
        case "available_commands_update":
            let list = AgentSlashCommand.list(update["availableCommands"])
            commands = list
            events.append(.commandsChanged(list))
        case "usage_update":
            let cost = update["cost"] as? [String: Any]
            events.append(.usageUpdate(used: update["used"] as? Int,
                                       size: update["size"] as? Int,
                                       input: (update["input"] as? Int)
                                           ?? (update["tokensIn"] as? Int),
                                       output: (update["output"] as? Int)
                                           ?? (update["tokensOut"] as? Int),
                                       costAmount: cost?["amount"] as? Double,
                                       costCurrency: cost?["currency"] as? String))
        default:
            break
        }
        emit(events)
        return events
    }

}
