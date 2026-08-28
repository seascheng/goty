// goty — see CLAUDE.md for the working principles.
import Foundation

/// One GUI agent session: an ACP-speaking agent process hosted by
/// sessiond (attach-or-spawn), driven over the shared frame channel.
/// State machine: disconnected → connecting → ready ⇄ working /
/// awaitingPermission; death surfaces as the daemon's EXITED frame.
final class AgentSession {
    weak var delegate: AgentSessionDelegate?

    private let paneId: String
    private let cwd: String?
    private let environment: [String: String]
    private let launch: AgentManifests.ACPLaunch
    private let daemon: SessionDaemon
    private let grid: SessionGrid
    private var pane: PaneSession?
    private let client = ACPClient()
    private(set) var sessionId: String?
    private(set) var isWorking = false
    private var connected = false

    init(paneId: String, cwd: String?, grid: SessionGrid,
         environment: [String: String],
         launch: AgentManifests.ACPLaunch, daemon: SessionDaemon,
         delegate: AgentSessionDelegate? = nil) {
        self.paneId = paneId
        self.cwd = cwd
        self.grid = grid
        self.environment = environment
        self.launch = launch
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
    }

    /// Agent panes are line-agnostic; the grid only exists because the
    /// daemon sizes every PTY. Fixed sane defaults; resize is never sent.
    static let fixedGrid = SessionGrid(columns: 120, rows: 40, cellWidth: 8, cellHeight: 16)

    func connect(completion: ((Bool) -> Void)? = nil) {
        guard !connected else {
            completion?(true)
            return
        }
        connected = true
        pane = daemon.openPane(
            id: paneId, cwd: cwd, shell: launch.command, args: launch.args,
            environment: environment, grid: grid,
            noEcho: true, ringBytes: launch.ringBytes,
            onFrame: { [weak self] kind, data in
                self?.handleFrame(kind: kind, data: data)
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
        client.request("initialize", [
            "protocolVersion": 1,
            "clientCapabilities": ["fs": ["readTextFile": false, "writeTextFile": false]],
        ]) { [weak self] result in
            guard let self, case .success = result else {
                self?.delegate?.sessionDidFail(self!, reason: "initialize 失败")
                completion?(false)
                return
            }
            self.client.request("session/new", [
                "cwd": self.cwd ?? NSNull(), "mcpServers": [],
            ]) { [weak self] result in
                guard let self, case .success(let value) = result,
                      let sessionId = value["sessionId"] as? String else {
                    self?.delegate?.sessionDidFail(self!, reason: "session/new 失败")
                    completion?(false)
                    return
                }
                self.sessionId = sessionId
                self.emit([.ready])
                completion?(true)
            }
        }
    }

    private func handleFrame(kind: UInt8, data: Data) {
        guard kind == SessionOutputKind.output else { return } // SIZE/SNAPSHOT 已进 ring，无需解析
        client.feed([UInt8](data))
    }

    func send(_ text: String) {
        guard let sessionId, !isWorking else { return }
        isWorking = true
        client.request("session/prompt", [
            "sessionId": sessionId,
            "content": [["type": "text", "text": text]],
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

    func respondPermission(requestID: Int, optionId: String) {
        client.respond(id: requestID,
                       result: ["outcome": ["outcome": "selected", "optionId": optionId]])
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
                    .compactMap { ACPOption(raw: $0) }
                let title = (params["toolCall"] as? [String: Any])?["title"] as? String
                events.append(.permissionRequested(
                    ACPPermissionPrompt(requestID: id, toolCallTitle: title, options: options)))
            }
            emit(events)
            return events
        }
        switch kind {
        case "agent_message_chunk":
            if let content = (update["content"] as? [String: Any]).flatMap(ACPContent.init),
               let text = content.text {
                events.append(.messageChunk(text))
            }
        case "agent_thought_chunk":
            if let content = (update["content"] as? [String: Any]).flatMap(ACPContent.init),
               let text = content.text {
                events.append(.thoughtChunk(text))
            }
        case "tool_call", "tool_call_update":
            if let id = update["toolCallId"] as? String {
                let content = ((update["content"] as? [[String: Any]]) ?? []).compactMap(ACPContent.init)
                events.append(.toolCallUpdate(id: id,
                                              title: update["title"] as? String,
                                              kind: update["kind"] as? String,
                                              status: update["status"] as? String,
                                              content: content))
            }
        case "plan":
            let entries = ((update["entries"] as? [[String: Any]]) ?? []).compactMap(ACPPlanEntry.init)
            if !entries.isEmpty {
                events.append(.plan(entries))
            }
        default:
            break
        }
        emit(events)
        return events
    }

    private func emit(_ events: [AgentSessionEvent]) {
        guard !events.isEmpty else { return }
        delegate?.session(self, didEmit: events)
    }
}
