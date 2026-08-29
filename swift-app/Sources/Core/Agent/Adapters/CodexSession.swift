// goty — see CLAUDE.md for the working principles.
import Foundation

/// codex over `codex app-server` — JSON-RPC 2.0 over the pane (the
/// JSONRPCChannel core omp uses, replay suppression included). Flow:
/// initialize → thread/start(cwd) → ready; one turn/start per send;
/// `turn/interrupt` cancels; approvals are server→client requests
/// answered with {decision: accept|decline}. Resume rides the server's
/// own model: thread/list {cwd} → thread/resume + thread/read
/// {includeTurns} → the same mapper replays items as events.
final class CodexSession: AgentSessioning {
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
    private let client = JSONRPCChannel()
    private let mapper = CodexFrameMapper()
    private var pane: PaneSession?
    private var connected = false
    private var threadId: String?
    /// GOTY_CODEX_MODEL debug knob: this machine's relay default model
    /// is unusable for text; tests override without config surgery.
    private var modelOverride: String? {
        ProcessInfo.processInfo.environment["GOTY_CODEX_MODEL"]
    }

    init(params: AgentPaneParams) {
        self.paneId = params.paneId
        self.cwd = params.cwd
        self.environment = params.environment
        self.daemon = params.daemon
        self.grid = AgentSession.fixedGrid
        client.onOutbound = { [weak self] in self?.pane?.sendInput($0) }
        client.onUnparseable = { line in
            if ProcessInfo.processInfo.environment["GOTY_CODEX_DEBUG"] != nil {
                print("CODEX_UNPARSEABLE \(line.prefix(300))")
            }
        }
        client.onNotification = { [weak self] method, params in
            if ProcessInfo.processInfo.environment["GOTY_CODEX_DEBUG"] != nil {
                print("CODEX_NOTIF \(method)")
            }
            self?.handleNotification(method: method, params: params)
        }
        client.onRequest = { [weak self] id, method, params in
            self?.handleServerRequest(id: id, method: method, params: params)
        }
    }

    // MARK: - AgentSessioning

    func connect(completion: ((Bool) -> Void)? = nil) {
        guard !connected else {
            completion?(true)
            return
        }
        connected = true
        pane = daemon.openPane(
            id: paneId, cwd: cwd, shell: "codex", args: ["app-server"],
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
        client.request("initialize",
                       ["clientInfo": ["name": "goty", "version": "1"]]) { [weak self] result in
            if ProcessInfo.processInfo.environment["GOTY_CODEX_DEBUG"] != nil {
                print("CODEX initialize result: \(result)")
            }
            guard let self, case .success = result else {
                self?.delegate?.sessionDidFail(self!, reason: "codex initialize 失败")
                completion?(false)
                return
            }
            self.client.notify("initialized", [:])
            self.startThread(completion: completion)
        }
    }

    private func startThread(completion: ((Bool) -> Void)?) {
        var params: [String: Any] = ["cwd": cwd ?? NSHomeDirectory()]
        if let modelOverride { params["model"] = modelOverride }
        client.request("thread/start", params) { [weak self] result in
            if ProcessInfo.processInfo.environment["GOTY_CODEX_DEBUG"] != nil {
                print("CODEX thread/start result: \(result)")
            }
            guard let self, case .success(let value) = result,
                  let thread = value["thread"] as? [String: Any],
                  let id = thread["id"] as? String else {
                self?.delegate?.sessionDidFail(self!, reason: "codex thread/start 失败")
                completion?(false)
                return
            }
            self.threadId = id
            self.sessionId = id
            if let model = value["model"] as? String {
                self.configOptions = [AgentConfigOption(id: "model", name: "模型",
                                                        category: nil,
                                                        currentValue: model, options: [])]
            }
            var readyEvents: [AgentSessionEvent] = [.configChanged(self.configOptions), .ready]
            // v1 command directory: /compact maps to thread/compact/start
            // (codex exposes no command-list RPC; skills arrive later).
            let compact = AgentSlashCommand(
                name: "compact",
                description: "压缩对话以释放上下文",
                inputHint: nil)
            self.commands = [compact]
            readyEvents.append(.commandsChanged([compact]))
            self.emit(readyEvents)
            completion?(true)
        }
    }

    func send(_ text: String) {
        guard let threadId, !isWorking else { return }
        // Builtin slash handling: app-server takes raw text; /compact
        // is ours to translate.
        if text.trimmingCharacters(in: .whitespacesAndNewlines) == "/compact" {
            client.request("thread/compact/start", ["threadId": threadId]) { _ in }
            return
        }
        isWorking = true
        client.request("turn/start", [
            "threadId": threadId,
            "input": [["type": "text", "text": text]],
        ]) { [weak self] _ in
            // turn outcome arrives as turn/completed notification; the
            // request result only acknowledges the turn object.
            _ = self
        }
    }

    func cancel() {
        guard let threadId else { return }
        client.notify("turn/interrupt", ["threadId": threadId])
    }

    func respondPermission(requestID: String, optionId: String) {
        guard let id = Int(requestID) else { return }
        let decision = optionId.hasPrefix("allow") ? "accept" : "decline"
        client.respond(id: id, result: ["decision": decision])
    }

    func setConfigOption(id: String, value: String) {
        // v1: display-only (configChanged reports the active model).
    }

    func listSessions(completion: @escaping ([AgentSessionSummary]) -> Void) {
        client.request("thread/list", ["limit": 50]) { [weak self] result in
            guard let self, case .success(let value) = result else {
                completion([])
                return
            }
            let threads = value["data"] as? [[String: Any]] ?? []
            let wanted = self.cwd
            let summaries = threads.compactMap { thread -> AgentSessionSummary? in
                guard let id = thread["id"] as? String else { return nil }
                let threadCwd = thread["cwd"] as? String
                if let wanted, let threadCwd, !threadCwd.hasPrefix(wanted) { return nil }
                let updated = thread["updatedAt"] as? Int
                return AgentSessionSummary(
                    sessionId: id, cwd: threadCwd,
                    title: (thread["preview"] as? String).map { String($0.prefix(80)) },
                    updatedAt: updated.map { String($0) },
                    messageCount: nil)
            }
            completion(summaries.sorted {
                (Int($0.updatedAt ?? "") ?? 0) > (Int($1.updatedAt ?? "") ?? 0)
            })
        }
    }

    func load(sessionId: String, completion: ((Bool) -> Void)? = nil) {
        // thread/resume reattaches the server-side thread; thread/read
        // with turns replays items through the same mapper.
        var resumeParams: [String: Any] = ["threadId": sessionId]
        if let modelOverride { resumeParams["model"] = modelOverride }
        client.request("thread/resume", resumeParams) { [weak self] result in
            guard let self else { return }
            self.threadId = sessionId
            self.sessionId = sessionId
            _ = result
            self.client.request("thread/read",
                                ["threadId": sessionId, "includeTurns": true]) { [weak self] result in
                guard let self else { return }
                var events: [AgentSessionEvent] = []
                if case .success(let value) = result,
                   let thread = value["thread"] as? [String: Any],
                   let turns = thread["turns"] as? [[String: Any]] {
                    for turn in turns {
                        guard let items = turn["items"] as? [[String: Any]] else { continue }
                        for item in items {
                            events += self.mapper.map(
                                method: "item/completed",
                                params: ["item": item, "threadId": sessionId])
                        }
                        events += self.mapper.map(method: "turn/completed",
                                                  params: ["turn": turn])
                    }
                }
                self.emit(events + [.ready])
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
        if ProcessInfo.processInfo.environment["GOTY_CODEX_DEBUG"] != nil,
           kind == SessionOutputKind.output {
            print("CODEX_RAW \(String(decoding: data.prefix(200), as: UTF8.self))")
        }
        switch kind {
        case SessionOutputKind.output:
            client.feed([UInt8](data))
        case SessionOutputKind.snapshot:
            client.feed([UInt8](data), replay: true)
        case SessionOutputKind.exited:
            if isWorking {
                isWorking = false
                emit([.turnEnded(stopReason: nil)])
            }
            delegate?.sessionDidFail(self, reason: "codex 进程已退出")
        default:
            break
        }
    }

    private func handleNotification(method: String, params: [String: Any]) {
        let events = mapper.map(method: method, params: params)
        if case .turnEnded = events.last {
            isWorking = false
        }
        emit(events)
    }

    private func handleServerRequest(id: Int, method: String, params: [String: Any]) {
        // Echo artifacts: these are methods WE initiate — a frame with
        // one of them plus an id is our own request bouncing back past
        // the echo ring, never a codex request. Answering it would
        // complete our own pending handshake with an empty result.
        let clientMethods: Set<String> = ["initialize", "initialized", "thread/start",
                                          "thread/resume", "thread/read", "thread/list",
                                          "turn/start", "turn/interrupt", "model/list"]
        guard !clientMethods.contains(method) else { return }
        guard method.hasSuffix("requestApproval") || method.hasSuffix("requestUserInput") else {
            client.respond(id: id, result: [:])
            return
        }
        let title: String
        if let item = params["item"] as? [String: Any] {
            let command = (item["command"] as? [String: Any])?["command"] as? String
                ?? (item["command"] as? String)
            let path = item["path"] as? String
            title = command ?? path ?? "codex 请求授权"
        } else {
            title = (params["title"] as? String) ?? "codex 请求授权"
        }
        let prompt = AgentPermissionPrompt(
            requestID: String(id), toolCallTitle: title,
            options: [ACPOption(optionId: "allow_once", name: "允许", kind: "allow_once"),
                      ACPOption(optionId: "reject_once", name: "拒绝", kind: "reject_once")])
        emit([.permissionRequested(prompt)])
    }

    private func emit(_ events: [AgentSessionEvent]) {
        guard !events.isEmpty else { return }
        delegate?.session(self, didEmit: events)
    }
}
