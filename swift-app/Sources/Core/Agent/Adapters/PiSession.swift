// goty — see CLAUDE.md for the working principles.
import Foundation

/// pi over `pi --mode rpc` — pi's own JSONL RPC on a LineChannel pane.
/// Commands carry optional ids; responses match by id (a small pending
/// table here — pi's ids live inside payloads, not JSON-RPC envelopes).
/// Events stream as id-less frames; PiFrameMapper shapes them. Resume
/// respawns with `--session <id>` and replays get_messages through the
/// mapper's replay path.
final class PiSession: AgentSessioning {
    weak var delegate: AgentSessionDelegate?

    let cwd: String?
    private(set) var sessionId: String?
    private(set) var isWorking = false
    private(set) var configOptions: [AgentConfigOption] = []
    private(set) var commands: [AgentSlashCommand] = []

    private let paneId: String
    private let environment: [String: String]
    private let daemon: SessionDaemon
    private let grid: SessionGrid
    private let channel = LineChannel()
    private let mapper = PiFrameMapper()
    private var pane: PaneSession?
    private var connected = false
    private var resumeSessionId: String?
    private var nextRequestID = 1
    private let responseLock = NSLock()
    private var pendingResponses: [String: ([String: Any]) -> Void] = [:]

    /// Integrity accounting.
    private(set) var framesRouted = 0

    init(params: AgentPaneParams) {
        self.paneId = params.paneId
        self.cwd = params.cwd
        self.environment = params.environment
        self.daemon = params.daemon
        self.grid = AgentSession.fixedGrid
        channel.onOutbound = { [weak self] in self?.pane?.sendInput($0) }
        channel.onFrame = { [weak self] frame in
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

    private func openPane(resume: String?, completion: ((Bool) -> Void)?) {
        var args = ["--mode", "rpc"]
        if let resume {
            args += ["--session", resume]
        }
        pane = daemon.openPane(
            id: paneId, cwd: cwd, shell: "pi", args: args,
            environment: environment, grid: grid,
            noEcho: true, ringBytes: 16_777_216,
            onFrame: { [weak self] kind, data in
                self?.handleTransportFrame(kind: kind, data: data)
            },
            onDisconnect: { [weak self] in
                guard let self else { return }
                self.connected = false
                self.delegate?.sessionDidFail(self, reason: "daemon 连接断开")
            })
        guard pane != nil else {
            connected = false
            delegate?.sessionDidFail(self, reason: "sessiond 不可用")
            completion?(false)
            return
        }
        pane?.start()
        // Ready = get_state answered: model known, session id captured.
        request("get_state") { [weak self] response in
            guard let self else { return }
            guard response["success"] as? Bool == true,
                  let state = response["data"] as? [String: Any] else {
                self.delegate?.sessionDidFail(self, reason: "pi get_state 失败")
                completion?(false)
                return
            }
            self.sessionId = state["sessionId"] as? String
            self.applyState(state)
            var events: [AgentSessionEvent] = [.ready]
            if !self.configOptions.isEmpty {
                events.append(.configChanged(self.configOptions))
            }
            self.emit(events)
            self.request("get_commands") { [weak self] response in
                guard let self,
                      response["success"] as? Bool == true,
                      let data = response["data"] as? [[String: Any]] else { return }
                let commands: [AgentSlashCommand] = data.compactMap { raw in
                    guard let name = raw["name"] as? String else { return nil }
                    return AgentSlashCommand(name: name,
                                             description: raw["description"] as? String,
                                             inputHint: nil)
                }
                guard !commands.isEmpty else { return }
                self.commands = commands
                self.emit([.commandsChanged(commands)])
            }
            completion?(true)
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
        // pi rpc auto-approves per its config in v1; no permission
        // requests are mapped, so an answer here is a no-op.
    }

    func setConfigOption(id: String, value: String) {
        // v1: display-only (configChanged reports model + thinking level).
    }

    func listSessions(completion: @escaping ([AgentSessionSummary]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let summaries = PiSessionStore.summaries(cwd: self.cwd)
            DispatchQueue.main.async {
                completion(summaries)
            }
        }
    }

    func load(sessionId: String, completion: ((Bool) -> Void)? = nil) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let found = PiSessionStore.find(sessionId: sessionId) != nil
            DispatchQueue.main.async {
                guard found else {
                    completion?(false)
                    return
                }
                self.sessionId = sessionId
                self.resumeSessionId = sessionId
                // Swap the pane to the resumed session, then replay its
                // messages through the mapper once the new process answers.
                self.pane?.close()
                self.pane = nil
                self.openPane(resume: sessionId) { [weak self] ok in
                    guard let self, ok else {
                        completion?(false)
                        return
                    }
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
        case SessionOutputKind.output, SessionOutputKind.snapshot:
            channel.feed([UInt8](data), replay: true)
        case SessionOutputKind.exited:
            if isWorking {
                isWorking = false
                emit([.turnEnded(stopReason: nil)])
            }
            delegate?.sessionDidFail(self, reason: "pi 进程已退出")
        default:
            break
        }
    }

    private func handleFrame(_ frame: [String: Any]) {
        framesRouted += 1
        if frame["type"] as? String == "response",
           let id = frame["id"] as? String {
            responseLock.lock()
            let completion = pendingResponses.removeValue(forKey: id)
            responseLock.unlock()
            completion?(frame)
            return
        }
        let events = mapper.map(frame)
        if case .turnEnded = events.last {
            isWorking = false
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

    /// pi command with id-matched response completion. The pending entry
    /// registers BEFORE the frame hits the wire (same invariant as
    /// JSONRPCChannel).
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
