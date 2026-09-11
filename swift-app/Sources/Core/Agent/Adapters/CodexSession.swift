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
    /// Model chip state: the live thread model + the paged catalog.
    private var modelCurrent: String?
    private var modelChoices: [AgentConfigChoice] = []
    /// Reasoning effort picked in the thinking chip; nil = codex's own
    /// default (turn/start omits the field).
    private var reasoningEffort: String?
    /// Mid-turn sends parked while a turn runs (steer's fallback path).
    private var pendingMidTurn: [(text: String, images: [AgentImage])] = []
    /// Speed tier (TUI /fast /ultrafast → serviceTier on turn/start).
    private var serviceTier: String?

    /// The runtimeMode chip's config option (options = all four tiers).
    static func runtimeModeOption(current: AgentRuntimeMode) -> AgentConfigOption {
        RuntimeModeMapping.option(current: current)
    }

    /// Every configOptions emission rebuilds from this one assembly
    /// point — start/attach/catalog/switch paths cannot drift.
    private func assembleOptions() -> [AgentConfigOption] {
        [
            AgentConfigOption(id: "model", name: "模型", category: nil,
                              currentValue: modelCurrent, options: modelChoices),
            Self.speedOption(current: serviceTier),
            Self.thinkingOption(current: reasoningEffort ?? "medium"),
            Self.runtimeModeOption(current: runtimeMode),
        ]
    }


    /// turn/start params as a pure function (test seam): paseo's exact
    /// shape — a slash skill becomes a STRUCTURED `{type:"skill", name,
    /// path}` input entry plus the text rewritten as a `$name` mention;
    /// the app-server reads the SKILL.md itself, the host injects
    /// nothing. Scalar knobs (model/effort/tier/mode) ride the params.
    static func turnParams(threadId: String, text: String,
                           model: String?, mode: AgentRuntimeMode,
                           effort: String?, serviceTier: String?,
                           skill: (name: String, path: String)? = nil)
        -> [String: Any] {
        var input: [[String: Any]] = []
        if let skill {
            input.append(["type": "skill", "name": skill.name,
                          "path": skill.path])
        }
        input.append(["type": "text", "text": text, "text_elements": []])
        var params: [String: Any] = [
            "threadId": threadId,
            "input": input,
        ]
        if let model { params["model"] = model }
        if let effort { params["effort"] = effort }
        if let serviceTier { params["serviceTier"] = serviceTier }
        for (key, value) in RuntimeModeMapping.codexParams(mode) {
            params[key] = value
        }
        return params
    }

    /// The speed chip (TUI /fast /ultrafast): serviceTier values from
    /// the agent's own tier catalog; nil = model default.
    static func speedOption(current: String?) -> AgentConfigOption {
        AgentConfigOption(
            id: "speed", name: "速度", category: nil,
            currentValue: current ?? "default",
            options: [
                AgentConfigChoice(value: "default", name: "默认",
                                  description: "标准吞吐", source: nil),
                AgentConfigChoice(value: "fast", name: "fast",
                                  description: "1.5x 速度，用量增加", source: nil),
                AgentConfigChoice(value: "ultrafast", name: "ultrafast",
                                  description: "最低延迟（部分模型）", source: nil),
            ])
    }

    /// The command directory: `skills/list` — the agent's OWN
    /// declaration, exactly what the TUI's / menu shows (paseo's
    /// loadSkills + enabledCodexSkills, happier's pluginAndSkillCatalog):
    /// names, descriptions, paths; disabled skills never list; multiple
    /// skill roots dedupe by name. The host invents no entries and
    /// never reads SKILL.md bodies — execution rides the structured
    /// input entry. Older app-servers without the method degrade to an
    /// empty directory.
    static func parseSkillCatalog(groups: [[String: Any]]) -> [AgentSlashCommand] {
        var byName: [String: AgentSlashCommand] = [:]
        var order: [String] = []
        for group in groups {
            for raw in group["skills"] as? [[String: Any]] ?? [] {
                guard let name = raw["name"] as? String, !name.isEmpty,
                      let path = raw["path"] as? String, !path.isEmpty,
                      raw["enabled"] as? Bool != false,
                      byName[name] == nil else { continue }
                byName[name] = AgentSlashCommand(
                    name: name,
                    description: raw["description"] as? String,
                    inputHint: nil,
                    skillPath: path)
                order.append(name)
            }
        }
        return order.compactMap { byName[$0] }
    }

    private func loadSkillCommands() {
        var params: [String: Any] = [:]
        if let cwd { params["cwds"] = [cwd] }
        client.request("skills/list", params) { [weak self] result in
            guard let self else { return }
            let groups = (try? result.get())?["data"] as? [[String: Any]] ?? []
            self.commands = Self.parseSkillCatalog(groups: groups)
            self.emit([.commandsChanged(self.commands)])
        }
    }

    /// The thinking chip's config option (id "thinking" — the web
    /// renders it with the omp thinking knob's icon and order).
    static func thinkingOption(current: String?) -> AgentConfigOption {
        AgentConfigOption(
            id: "thinking", name: "思考", category: nil,
            currentValue: current,
            options: [
                AgentConfigChoice(value: "minimal", name: "极简",
                                  description: "几乎不思考，最快", source: nil),
                AgentConfigChoice(value: "low", name: "低",
                                  description: "轻量推理", source: nil),
                AgentConfigChoice(value: "medium", name: "中",
                                  description: "默认平衡档", source: nil),
                AgentConfigChoice(value: "high", name: "高",
                                  description: "更深的推理", source: nil),
                AgentConfigChoice(value: "xhigh", name: "极高",
                                  description: "最大推理深度（部分模型）", source: nil),
            ])
    }

    /// GOTY_CODEX_MODEL debug knob: this machine's relay default model
    /// is unusable for text; tests override without config surgery.
    private var modelOverride: String? {
        ProcessInfo.processInfo.environment["GOTY_CODEX_MODEL"]
    }

    /// Attach-adoption transcript rebuild pending: the ring will
    /// re-stream the thread/start response; when its id lands, re-read
    /// the thread (the authoritative history — the ring alone is not a
    /// rebuild source for codex).
    private var adoptRebuild = false

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
        client.onOrphanResult = { [weak self] result in
            guard let self, self.threadId == nil,
                  let thread = result["thread"] as? [String: Any],
                  let id = thread["id"] as? String else { return }
            self.threadId = id
            self.sessionId = id
            guard self.adoptRebuild else { return }
            self.adoptRebuild = false
            self.rebuildAdoptedThread(id)
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
            // The chips and transcript still have to come from
            // somewhere: emit the knobs now (model/list pages the
            // picker in over the live app-server) and rebuild the
            // transcript once the ring re-streams the thread id.
            configOptions = assembleOptions()
            loadModelCatalog()
            adoptRebuild = true
            commands = []
            loadSkillCommands()
            emit([.configChanged(configOptions), .ready])
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
            // The thread object carries the live model + reasoning
            // effort (probe: thread/start has NO top-level model field
            // — reading it left the model chip blank).
            self.modelCurrent = thread["model"] as? String
            self.modelChoices = []
            if let effort = thread["reasoningEffort"] as? String,
               ["minimal", "low", "medium", "high", "xhigh"].contains(effort) {
                self.reasoningEffort = effort
            }
            self.configOptions = self.assembleOptions()
            // Model catalog (monocode parity): model/list pages the
            // picker's options in after ready — the thread already
            // works with its default while the catalog loads.
            self.loadModelCatalog()
            var readyEvents: [AgentSessionEvent] = [.configChanged(self.configOptions), .ready]
            // Command directory = the agent's own skills/list
            // declaration (codex has no separate command RPC).
            self.loadSkillCommands()
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
                self.modelChoices = choices
                self.modelCurrent = self.modelCurrent ?? defaultValue
                self.configOptions = self.assembleOptions()
                self.emit([.configChanged(self.configOptions)])
            }
        }
        page(nil)
    }

    func send(_ text: String, images: [AgentImage]) {
        guard let threadId, !isWorking else { return }
        // /compact is the one host translation (an app-server turn the
        // TUI owns as a command). Everything else passes through: slash
        // skills ride the structured input entry, native tokens reach
        // the agent verbatim.
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "/compact" {
            client.request("thread/compact/start", ["threadId": threadId]) { _ in }
            return
        }
        var prompt = text
        var skill: (name: String, path: String)?
        if trimmed.hasPrefix("/"),
           let match = Self.matchSkill(trimmed, commands: commands) {
            skill = (name: match.command.name, path: match.command.skillPath ?? "")
            prompt = match.rest.isEmpty
                ? "$\(match.command.name)"
                : "$\(match.command.name) \(match.rest)"
        }
        for image in images {
            if let path = Self.stageImage(image) {
                prompt += "\n\(path)"
            } else {
                emit([.notice("⚠︎ 一张图片未能保存，已跳过")])
            }
        }
        let params = Self.turnParams(threadId: threadId, text: prompt,
                                     model: selectedModel, mode: runtimeMode,
                                     effort: reasoningEffort,
                                     serviceTier: serviceTier,
                                     skill: skill.flatMap {
                                         $0.path.isEmpty ? nil : $0
                                     })
        client.request("turn/start", params) { [weak self] _ in
            // turn outcome arrives as turn/completed notification; the
            // request result only acknowledges the turn object.
            _ = self
        }
    }

    /// `/name rest…` against the directory (pure, test seam): returns
    /// the matching skill command and the trailing args.
    static func matchSkill(_ text: String,
                           commands: [AgentSlashCommand])
        -> (command: AgentSlashCommand, rest: String)? {
        let body = text.dropFirst()
        let (name, rest) = if let space = body.firstIndex(where: { $0 == " " || $0 == "\n" }) {
            (String(body[..<space]),
             String(body[body.index(after: space)...])
                 .trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            (String(body), "")
        }
        guard let command = commands.first(where: {
            $0.name == name && $0.skillPath != nil
        }) else { return nil }
        return (command, rest)
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
        switch id {
        case "runtimeMode":
            guard let mode = AgentRuntimeMode(rawValue: value) else {
                emit([.notice("未知的权限档位：\(value)")])
                return
            }
            runtimeMode = mode
        case "thinking":
            guard ["minimal", "low", "medium", "high", "xhigh"].contains(value) else {
                emit([.notice("未知的思考档位：\(value)")])
                return
            }
            reasoningEffort = value
        case "speed":
            // TUI /fast /ultrafast parity: serviceTier on turn/start;
            // "default" clears back to the model's own tier.
            guard ["default", "fast", "ultrafast"].contains(value) else {
                emit([.notice("未知的速度档位：\(value)")])
                return
            }
            serviceTier = value == "default" ? nil : value
        case "model":
            // Applies on the NEXT turn/start; the chip's currentValue
            // reflects it immediately.
            selectedModel = value
            modelCurrent = value
        default:
            return
        }
        // One assembly point — REPLACE semantics keep each knob single.
        configOptions = assembleOptions()
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

    /// Attach-adoption rebuild: swap the page for the thread's
    /// authoritative history (thread/read), like omp's attach store
    /// re-read. Mid-turn adopts keep the live stream instead — the
    /// read only covers settled turns.
    private func rebuildAdoptedThread(_ id: String) {
        guard !isWorking else { return }
        client.request("thread/read",
                       ["threadId": id, "includeTurns": true]) { [weak self] result in
            guard let self else { return }
            var events: [AgentSessionEvent] = [.transcriptReset]
            if case .success(let value) = result,
               let thread = value["thread"] as? [String: Any] {
                if let model = thread["model"] as? String {
                    self.modelCurrent = model
                }
                if let effort = thread["reasoningEffort"] as? String,
                   ["minimal", "low", "medium", "high", "xhigh"].contains(effort) {
                    self.reasoningEffort = effort
                }
                if let turns = thread["turns"] as? [[String: Any]] {
                    for turn in turns {
                        guard let items = turn["items"] as? [[String: Any]] else { continue }
                        for item in items {
                            events += self.mapper.map(
                                method: "item/completed",
                                params: ["item": item, "threadId": id])
                        }
                        events += self.mapper.map(method: "turn/completed",
                                                  params: ["turn": turn])
                    }
                }
            }
            self.emit(events)
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
                   let thread = value["thread"] as? [String: Any] {
                    if let model = thread["model"] as? String {
                        self.modelCurrent = model
                    }
                    if let effort = thread["reasoningEffort"] as? String,
                       ["minimal", "low", "medium", "high", "xhigh"].contains(effort) {
                        self.reasoningEffort = effort
                    }
                    if let turns = thread["turns"] as? [[String: Any]] {
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
                }
                self.emit(events + [.configChanged(self.assembleOptions()), .ready])
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
