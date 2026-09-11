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
    /// The pane (and its store) live on the daemon's machine.
    var runsOnThisMac: Bool { !daemon.isRemote }
    private let mapper = CodexFrameMapper()
    private var pane: PaneSession?
    private var connected = false
    private var threadId: String?
    /// Live turn id (turn/started) — turn/steer's expectedTurnId. The
    /// steer is fenced to this exact turn; cleared when the turn ends.
    private var activeTurnId: String?
    /// Model the user picked from the models chip (applies to the next
    /// turn/start — monocode passes the model per turn).
    private var selectedModel: String?
    /// Permission/sandbox tier — rides EVERY turn/start (codex has no
    /// mid-session mode RPC; monocode's per-turn resend).
    private var runtimeMode: AgentRuntimeMode = .supervised
    /// Mid-turn sends parked while a turn runs (steer's fallback path).
    private var pendingMidTurn: [(text: String, images: [AgentImage])] = []


    /// The runtimeMode chip's config option (options = all four tiers).
    static func runtimeModeOption(current: AgentRuntimeMode) -> AgentConfigOption {
        RuntimeModeMapping.option(current: current)
    }

    /// turn/start params as a pure function (test seam, monocode's
    /// buildTurnStartParams): text input + picked model + tier knobs.
    static func turnParams(threadId: String, text: String,
                           model: String?, mode: AgentRuntimeMode) -> [String: Any] {
        var params: [String: Any] = [
            "threadId": threadId,
            "input": [["type": "text", "text": text]],
        ]
        if let model { params["model"] = model }
        for (key, value) in RuntimeModeMapping.codexParams(mode) {
            params[key] = value
        }
        return params
    }

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
        self.grid = AgentPaneDefaults.grid
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
        // Attach adoption: the ring re-streams the original thread/start
        // response — the only wire record of the live thread id.
        client.onOrphanResult = { [weak self] result in
            guard let self, self.threadId == nil,
                  let thread = result["thread"] as? [String: Any],
                  let id = thread["id"] as? String else { return }
            self.threadId = id
            self.sessionId = id
        }
    }

    // MARK: - AgentSessioning

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
        if opened.attachedExisting {
            // Live thread on the far side of the ring — adopting, never
            // re-starting (thread/start would fork the conversation).
            emit([.ready])
            completion?(true)
            return
        }
        handshake(completion)
    }

    private func openTransport() -> SessionDaemon.OpenPaneResult? {
        let opened = daemon.openPaneWithAttachment(
            id: paneId, cwd: cwd, shell: "codex", args: ["app-server"],
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
        guard let opened else { return nil }
        // The reader thread was never started here — initialize went
        // out into a pane nobody read (pane was never assigned either),
        // so the handshake hung forever: the pane showed 正在启动 Codex…
        // for every session, ever. Claude and Pi start theirs; codex
        // must too.
        pane = opened.session
        opened.session.start()
        return opened
    }

    private func handshake(_ completion: ((Bool) -> Void)?) {
        client.request("initialize",
                       ["clientInfo": ["name": "goty", "version": "1"]]) { [weak self] result in
            if ProcessInfo.processInfo.environment["GOTY_CODEX_DEBUG"] != nil {
                print("CODEX initialize result: \(result)")
            }
            guard let self else { completion?(false); return }
            guard case .success = result else {
                self.delegate?.sessionDidFail(self, reason: "codex initialize 失败")
                completion?(false)
                return
            }
            self.client.notify("initialized", [:])
            self.startThread(completion: completion)
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
        // Fresh process: re-adopt via thread/resume on the last live id.
        handshake { [weak self] ok in
            guard let self, ok else {
                completion?(ok)
                return
            }
            if let restore = self.lastSessionId {
                self.load(sessionId: restore) { _ in completion?(true) }
            } else {
                completion?(true)
            }
        }
    }


    private func startThread(completion: ((Bool) -> Void)?) {
        var params: [String: Any] = ["cwd": cwd ?? NSHomeDirectory()]
        if let modelOverride { params["model"] = modelOverride }
        for (key, value) in RuntimeModeMapping.codexThreadParams(runtimeMode) {
            params[key] = value
        }
        client.request("thread/start", params) { [weak self] result in
            if ProcessInfo.processInfo.environment["GOTY_CODEX_DEBUG"] != nil {
                print("CODEX thread/start result: \(result)")
            }
            guard let self else { completion?(false); return }
            guard case .success(let value) = result,
                  let thread = value["thread"] as? [String: Any],
                  let id = thread["id"] as? String else {
                self.delegate?.sessionDidFail(self, reason: "codex thread/start 失败")
                completion?(false)
                return
            }
            self.threadId = id
            self.sessionId = id
            if let model = value["model"] as? String {
                self.configOptions = [
                    AgentConfigOption(id: "model", name: "模型",
                                      category: nil,
                                      currentValue: model, options: []),
                    Self.runtimeModeOption(current: self.runtimeMode),
                ]
            } else {
                self.configOptions = [Self.runtimeModeOption(current: self.runtimeMode)]
            }
            // Model catalog (monocode parity): model/list pages the
            // picker's options in after ready — the thread already
            // works with its default while the catalog loads.
            self.loadModelCatalog()
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

    /// `model/list` → the models chip's option list (paged by cursor,
    /// default first — monocode's catalog rules). Failure is silent:
    /// the chip keeps the thread's current model only.
    private func loadModelCatalog() {
        var choices: [AgentConfigChoice] = []
        var defaultValue: String?
        func page(_ cursor: String?) {
            client.request("model/list", cursor.map { ["cursor": $0] } ?? [:]) {
                [weak self] result in
                guard let self, case .success(let value) = result else { return }
                for row in (value["data"] as? [[String: Any]]) ?? [] {
                    guard let id = row["id"] as? String else { continue }
                    if row["isDefault"] as? Bool == true { defaultValue = id }
                    let displayName = (row["displayName"] as? String)
                        ?? (row["name"] as? String) ?? id
                    let source = (row["provider"] as? String)
                        ?? (row["modelProvider"] as? String)
                    choices.append(AgentConfigChoice(value: id, name: displayName,
                                                     description: nil, source: source))
                }
                if let next = value["nextCursor"] as? String, !next.isEmpty {
                    page(next)
                    return
                }
                guard !choices.isEmpty else { return }
                // Default model leads the picker (monocode
                // orderDefaultFirst).
                if let defaultValue,
                   let idx = choices.firstIndex(where: { $0.value == defaultValue }),
                   idx > 0 {
                    choices.swapAt(0, idx)
                }
                let current = self.configOptions.first(where: { $0.id == "model" })?.currentValue
                self.configOptions = [AgentConfigOption(
                    id: "model", name: "模型", category: nil,
                    currentValue: current ?? defaultValue, options: choices)]
                    + [Self.runtimeModeOption(current: self.runtimeMode)]
                self.emit([.configChanged(self.configOptions)])
            }
        }
        page(nil)
    }



    func send(_ text: String, images: [AgentImage]) {
        guard let threadId, !isWorking else { return }
        // Builtin slash handling: app-server takes raw text; /compact
        // is ours to translate.
        if text.trimmingCharacters(in: .whitespacesAndNewlines) == "/compact" {
            client.request("thread/compact/start", ["threadId": threadId]) { _ in }
            return
        }
        isWorking = true
        // turn/start input carries text blocks only (no base64 image
        // block in the app-server dialect we bind to) — tty7's
        // convention instead: stage the bytes next to the agent and
        // name the paths; codex loads readable image paths as images.
        var prompt = text
        for image in images {
            if let path = Self.stageImage(image) {
                prompt += "\n\(path)"
            } else {
                emit([.notice("⚠︎ 一张图片未能保存，已跳过")])
            }
        }
        let turnParams = Self.turnParams(threadId: threadId, text: prompt,
                                          model: selectedModel, mode: runtimeMode)
        client.request("turn/start", turnParams) { [weak self] _ in
            // turn outcome arrives as turn/completed notification; the
            // request result only acknowledges the turn object.
            _ = self
        }
    }

    /// Base64 → temp file the codex process can read (it runs on this
    /// Mac — runsOnThisMac default). tty7 models this exact staging.
    private static func stageImage(_ image: AgentImage) -> String? {
        guard let bytes = Data(base64Encoded: image.data) else { return nil }
        let ext = ["image/png": "png", "image/jpeg": "jpg", "image/gif": "gif",
                   "image/webp": "webp"][image.mimeType] ?? "png"
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("goty-attachments", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("img-\(UUID().uuidString.prefix(8)).\(ext)")
            try bytes.write(to: url)
            return url.path
        } catch {
            return nil
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
        if id == "runtimeMode" {
            guard let mode = AgentRuntimeMode(rawValue: value) else {
                emit([.notice("未知的权限档位：\(value)")])
                return
            }
            runtimeMode = mode
            emit([.configChanged(configOptions + [Self.runtimeModeOption(current: mode)])])
            return
        }
        guard id == "model" else { return }
        // Applies on the NEXT turn/start; the chip's currentValue
        // reflects it immediately.
        selectedModel = value
        var options = configOptions.filter { $0.id != "runtimeMode" }
        if var option = options.first {
            options[0] = AgentConfigOption(id: option.id, name: option.name,
                                           category: option.category,
                                           currentValue: value,
                                           options: option.options)
        }
        options.append(Self.runtimeModeOption(current: runtimeMode))
        configOptions = options
        emit([.configChanged(configOptions)])
    }
    func listSessions(completion: @escaping ([AgentSessionSummary]) -> Void) {
        // Store listing FIRST (daemon capability 7, store:"codex"): the
        // rollout files are the authority and cover sessions created in
        // OTHER processes — the TUI, a previous pane. thread/list only
        // knows THIS app-server's in-memory threads and its preview is
        // the thread's FIRST prompt, so the picker disagreed with the
        // TUI's own history (2026-09-11 5090 basketball_analysis report).
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            if let (rows, _) = self?.daemon.agentStoreSummaries(cwd: self?.cwd,
                                                                store: "codex") {
                let summaries = rows.map { row in
                    AgentSessionSummary(
                        sessionId: row.id, cwd: row.cwd,
                        title: row.title,
                        updatedAt: row.mtimeMs > 0 ? String(row.mtimeMs) : nil,
                        messageCount: nil)
                }
                DispatchQueue.main.async { completion(summaries) }
                return
            }
            // Old daemon: the pane's own thread/list is the only source.
            self?.client.request("thread/list", ["limit": 50]) { result in
                guard case .success(let value) = result else {
                    completion([])
                    return
                }
                let threads = value["data"] as? [[String: Any]] ?? []
                let wanted = self?.cwd
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

    /// Single source of truth for the manifest (agenttest asserts it).
    static let declaredCapabilities: AgentCapabilities = [.steer, .sessions, .runtimeModes]

    var capabilities: AgentCapabilities {
        // .sessions gates the history chip: thread/list + thread/resume
        // + thread/read are implemented — the picker and reload work.
        // .runtimeModes: the 权限 chip — every turn/start re-sends the
        // tier knobs (approvalPolicy/sandboxPolicy/approvalsReviewer).
        Self.declaredCapabilities
    }

    /// Mid-turn steering, codex-native: `turn/steer` fenced to the live
    /// turn (expectedTurnId — monocode/happier parity). Falls back to
    /// the park-and-send queue when the turn id isn't known yet (the
    /// turn hasn't started streaming) or the thread is idle.
    func steer(_ text: String, images: [AgentImage]) {
        guard isWorking, let threadId, let turnId = activeTurnId else {
            enqueueMidTurn(text, images: images)
            return
        }
        var input: [[String: Any]] = [["type": "text", "text": text]]
        for image in images {
            if let path = Self.stageImage(image) {
                input.append(["type": "local_image", "path": path])
            }
        }
        client.request("turn/steer", [
            "threadId": threadId,
            "expectedTurnId": turnId,
            "input": input,
        ]) { _ in }
    }

    private func enqueueMidTurn(_ text: String, images: [AgentImage]) {
        guard isWorking else { return send(text, images: images) }
        pendingMidTurn.append((text, images))
        emit([.notice("⟳ 消息已排队，本轮结束后发送")])
    }

    private func handleNotification(method: String, params: [String: Any]) {
        // Turn lifecycle bookkeeping ahead of the mapper: steer needs
        // the live turn id, and every terminal clears it.
        switch method {
        case "turn/started":
            activeTurnId = (params["turn"] as? [String: Any])?["id"] as? String
        case "turn/completed", "turn/aborted":
            activeTurnId = nil
        default:
            break
        }
        let events = mapper.map(method: method, params: params)
        if case .turnEnded = events.last {
            isWorking = false
            flushMidTurnQueue()
        }
        emit(events)
    }

    private func flushMidTurnQueue() {
        guard !pendingMidTurn.isEmpty else { return }
        let queued = pendingMidTurn
        pendingMidTurn = []
        for item in queued { send(item.text, images: item.images) }
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
        let prompt = AgentPermissionPrompt.allowOrReject(
            requestID: String(id), title: title)
        emit([.permissionRequested(prompt)])
    }

    private func emit(_ events: [AgentSessionEvent]) {
        guard !events.isEmpty else { return }
        delegate?.session(self, didEmit: events)
    }
}
