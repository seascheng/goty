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
    /// PaneState.agentSessionId at GUI start: the thread to re-open on
    /// both the attach (thread/read) and respawn (thread/resume) paths.
    private let restoredSessionId: String?
    private(set) var isWorking = false
    private(set) var configOptions: [AgentConfigOption] = []
    private(set) var commands: [AgentSlashCommand] = []
    /// The agent's declared skills (skills/list) — invoked with `$name`
    /// mentions, never listed flat in the / menu.
    private var skillCommands: [AgentSlashCommand] = []

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

    /// The command directory = the TUI's OWN slash menu, verbatim from
    /// codex-rs tui/src/slash_command.rs (release-visible set, enum
    /// order = popup order). Skills are NOT flattened in — the TUI
    /// lists them under `/skills` and invokes them with a `$name`
    /// mention; custom prompts (`~/.codex/prompts/*.md`) ride after
    /// the builtins (paseo's listCodexCustomPrompts).
    static func tuiCommands() -> [AgentSlashCommand] {
        let table: [(String, String, String?)] = [
            ("model", "choose what model and reasoning effort to use", nil),
            ("ide", "include current selection, open files, and other context from your IDE", nil),
            ("permissions", "choose what Codex is allowed to do", nil),
            ("keymap", "remap TUI shortcuts", nil),
            ("vim", "toggle Vim mode for the composer", nil),
            ("setup-default-sandbox", "set up elevated agent sandbox", nil),
            ("experimental", "toggle experimental features", nil),
            ("approve", "approve one retry of a recent auto-review denial", nil),
            ("memories", "configure memory use and generation", nil),
            ("skills", "use skills to improve how Codex performs specific tasks", "$name"),
            ("import", "import setup, this project, and recent chats from Claude Code", nil),
            ("hooks", "view and manage lifecycle hooks", nil),
            ("review", "review my current changes and find issues", nil),
            ("rename", "rename the current thread", "<title>"),
            ("new", "start a new chat during a conversation", nil),
            ("archive", "archive this session", nil),
            ("delete", "permanently delete this session", nil),
            ("resume", "resume a saved chat", nil),
            ("fork", "fork the current chat", nil),
            ("worktree", "start or continue a conversation in a new worktree", nil),
            ("app", "continue this session in the Desktop app", nil),
            ("init", "create an AGENTS.md file with instructions for Codex", nil),
            ("compact", "summarize conversation to prevent hitting the context limit", nil),
            ("recap", "summarize the current conversation now", nil),
            ("plan", "switch to Plan mode", nil),
            ("voice", "start or stop voice; use /voice settings to choose a voice", nil),
            ("goal", "set or view the goal for a long-running task", "<objective>|pause|resume|clear"),
            ("agents", "view and switch between all active agent sessions", nil),
            ("side", "start a side conversation in an ephemeral fork", nil),
            ("btw", "start a side conversation in an ephemeral fork", nil),
            ("copy", "copy the last response or part of it", nil),
            ("export", "export the conversation as markdown", nil),
            ("raw", "toggle raw scrollback mode for copy-friendly terminal selection", nil),
            ("diff", "show git diff (including untracked files)", nil),
            ("mention", "mention a file", nil),
            ("status", "show current session configuration and token usage", nil),
            ("cd", "change the current working directory", "<dir>"),
            ("pwd", "show the current working directory", nil),
            ("usage", "view account usage or use a usage limit reset", nil),
            ("debug-config", "show config layers and requirement sources for debugging", nil),
            ("title", "configure which items appear in the terminal title", nil),
            ("statusline", "configure which items appear in the status line", nil),
            ("theme", "choose a syntax highlighting theme", nil),
            ("pets", "choose or hide the terminal pet", nil),
            ("mcp", "list configured MCP tools; use /mcp verbose for details", nil),
            ("apps", "manage apps", nil),
            ("plugins", "browse plugins", nil),
            ("logout", "log out of Codex", nil),
            ("quit", "exit Codex", nil),
            ("exit", "exit Codex", nil),
            ("feedback", "send logs to maintainers", nil),
            ("ps", "list background terminals", nil),
            ("stop", "stop all background terminals", nil),
            ("clear", "clear the terminal and start a new chat", nil),
            ("personality", "choose a communication style for Codex", nil),
            ("subagents", "switch between this session's subagents", nil),
        ]
        return table.map {
            AgentSlashCommand(name: $0.0, description: $0.1, inputHint: $0.2)
        }
    }

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

    /// `~/.codex/prompts/*.md` — codex's custom-prompt mechanism (the
    /// GUI machine's home; a remote pane's app-server lives on its own
    /// host, where this scan simply finds nothing). Name prefixed
    /// `prompts:` so it never shadows a skill. Local-only read: this
    /// is the agent's own directory, not a host fabrication.
    static func scanCustomPrompts(codexHome: String) -> [AgentSlashCommand] {
        let dir = (codexHome as NSString).appendingPathComponent("prompts")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        return files.compactMap { file -> AgentSlashCommand? in
            guard file.hasSuffix(".md") else { return nil }
            let name = String(file.dropLast(3))
            guard !name.isEmpty else { return nil }
            let path = (dir as NSString).appendingPathComponent(file)
            guard let raw = try? String(contentsOfFile: path, encoding: .utf8)
                else { return nil }
            let meta = parseFrontMatter(raw)
            return AgentSlashCommand(
                name: "prompts:\(name)",
                description: meta["description"] ?? "Custom prompt",
                inputHint: meta["argument-hint"] ?? meta["argument_hint"],
                promptPath: path)
        }
    }

    /// Frontmatter `key: value` pairs from a prompt/skill markdown
    /// file (paseo's parseFrontMatter: simple line scan, quotes
    /// stripped). Empty when the file has no `---` fence.
    static func parseFrontMatter(_ raw: String) -> [String: String] {
        var lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return [:] }
        lines.removeFirst()
        var out: [String: String] = [:]
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" { break }
            guard let idx = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[..<idx]).trimmingCharacters(in: .whitespaces)
            var value = String(trimmed[trimmed.index(after: idx)...])
                .trimmingCharacters(in: .whitespaces)
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if !key.isEmpty, !value.isEmpty {
                out[key] = value
            }
        }
        return out
    }

    private func loadCommands() {
        var params: [String: Any] = [:]
        if let cwd { params["cwds"] = [cwd] }
        client.request("skills/list", params) { [weak self] result in
            guard let self else { return }
            let groups = (try? result.get())?["data"] as? [[String: Any]] ?? []
            // Skills live OUTSIDE the / menu (the TUI shows them under
            // /skills and invokes via $name mentions); keep the list
            // for the $ trigger.
            self.skillCommands = Self.parseSkillCatalog(groups: groups)
            let prompts = Self.scanCustomPrompts(
                codexHome: NSHomeDirectory() + "/.codex")
            self.commands = Self.tuiCommands() + prompts
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
        // The thread the user last had here (PaneState.agentSessionId) —
        // claude/pi consume the same param; without it a restart either
        // starts a blank thread or gambles on discovery.
        self.restoredSessionId = params.restoredSessionId
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
            // picker in over the live app-server). The thread to open is
            // the one the user left here (restoredSessionId — the exact
            // claude/pi restore param); without one, fall back to the
            // app-server's own live-thread report (thread/loaded/list).
            // The ring replay's orphaned thread/start result only
            // survives inside the 16MB window, so it can't be the
            // primary source.
            configOptions = assembleOptions()
            loadModelCatalog()
            adoptRebuild = true
            commands = []
            loadCommands()
            if let restore = restoredSessionId {
                if ProcessInfo.processInfo.environment["GOTY_CODEX_DEBUG"] != nil {
                    print("CODEX_ATTACH restore=\(restore)")
                }
                adoptRebuild = false
                threadId = restore
                sessionId = restore
                rebuildAdoptedThread(restore)
            } else {
                client.request("thread/loaded/list", [:]) { [weak self] result in
                    guard let self, self.adoptRebuild else { return }
                    guard let value = try? result.get() else {
                        if ProcessInfo.processInfo.environment["GOTY_CODEX_DEBUG"] != nil {
                            print("CODEX_LOADED_LIST failed")
                        }
                        return
                    }
                    if ProcessInfo.processInfo.environment["GOTY_CODEX_DEBUG"] != nil {
                        print("CODEX_LOADED_LIST value=\(value)")
                    }
                    guard let id = Self.pickLoadedThreadId(value) else { return }
                    self.adoptRebuild = false
                    self.threadId = id
                    self.sessionId = id
                    self.rebuildAdoptedThread(id)
                }
            }
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
            // A restarted GUI with a remembered thread re-opens IT
            // (thread/resume); thread/start would fork a new one.
            if let restore = self.restoredSessionId {
                self.load(sessionId: restore) { _ in completion?(true) }
            } else {
                self.startThread(completion: completion)
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
        // Fresh process: handshake re-opens the remembered thread
        // (restoredSessionId / lastSessionId) itself via thread/resume.
        handshake(completion)
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
            // Command directory = builtin translations + the agent's
            // skills/list + codex custom prompts (paseo's union).
            self.loadCommands()
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
        // Slash = the TUI's command table. Host-translated RPCs run
        // out of band (compact, goal); commands the GUI carries as
        // chips say so; the rest admit they're not wired. Skills are
        // NOT slash commands — a `$name` mention rides the structured
        // input entry (the agent reads SKILL.md itself). Custom
        // prompts expand per codex's placeholder rules.
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("/") {
            if let m = Self.matchCommand(trimmed, commands: Self.tuiCommands()) {
                executeTuiCommand(m.command.name, args: m.rest, threadId: threadId)
                return
            }
        }
        var prompt = text
        var skill: (name: String, path: String)?
        if trimmed.hasPrefix("/") {
            if let match = Self.matchPrompt(trimmed, commands: commands) {
                prompt = Self.expandCustomPrompt(template: match.body, args: match.rest)
            }
        } else if trimmed.hasPrefix("$"),
                  let match = Self.matchSkill(trimmed, commands: skillCommands) {
            skill = (name: match.command.name, path: match.command.skillPath ?? "")
            prompt = trimmed
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

    /// Host-translated TUI commands (RPC evidence from paseo's
    /// executeCompactCommand / executeGoalSubcommand). Commands whose
    /// TUI surface is a GUI chip here say so; the rest are honestly
    /// reported as not wired rather than faked.
    private func executeTuiCommand(_ name: String, args: String, threadId: String) {
        switch name {
        case "compact":
            client.request("thread/compact/start", ["threadId": threadId]) { _ in }
        case "goal":
            let goal = Self.goalParams(threadId: threadId, args: args)
            if let goal {
                client.request(goal.method, goal.params) { _ in }
            } else {
                emit([.notice("用法：/goal <objective>|pause|resume|clear")])
            }
        case "model":
            emit([.notice("模型与推理力度由底部「模型 / 思考」chip 承载")])
        case "permissions":
            emit([.notice("权限由底部「权限」chip 承载")])
        case "skills":
            let count = skillCommands.count
            emit([.notice(count > 0
                  ? "技能以 $ 前缀调用：输入 $ 加技能名（\(count) 个可用）"
                  : "当前无可用技能")])
        default:
            emit([.notice("「/\(name)」暂未接入此 GUI")])
        }
    }

    /// `/goal` subcommand → RPC frame (paseo's GoalSubcommand mapping):
    /// set → thread/goal/set {threadId, objective, status:active};
    /// pause/resume → status only; clear → thread/goal/clear.
    /// nil = bare /goal (usage notice).
    static func goalParams(threadId: String, args: String)
        -> (method: String, params: [String: Any])? {
        let rest = args.trimmingCharacters(in: .whitespacesAndNewlines)
        switch rest {
        case "":
            return nil
        case "pause":
            return ("thread/goal/set", ["threadId": threadId, "status": "paused"])
        case "resume":
            return ("thread/goal/set", ["threadId": threadId, "status": "active"])
        case "clear":
            return ("thread/goal/clear", ["threadId": threadId])
        default:
            return ("thread/goal/set",
                    ["threadId": threadId, "objective": rest, "status": "active"])
        }
    }

    /// `/name rest…` against a command directory.
    static func matchCommand(_ text: String, commands: [AgentSlashCommand])
        -> (command: AgentSlashCommand, rest: String)? {
        guard text.hasPrefix("/") else { return nil }
        let (name, rest) = Self.splitSlash(text.dropFirst())
        guard let command = commands.first(where: { $0.name == name }) else { return nil }
        return (command, rest)
    }

    /// `$name rest…` against the agent's declared skills (the TUI's
    /// mention syntax — paseo/happier send the same token in the turn
    /// text alongside the structured entry).
    static func matchSkill(_ text: String, commands: [AgentSlashCommand])
        -> (command: AgentSlashCommand, rest: String)? {
        guard text.hasPrefix("$") else { return nil }
        let (name, rest) = Self.splitSlash(text.dropFirst())
        guard let command = commands.first(where: {
            $0.name == name && $0.skillPath != nil
        }) else { return nil }
        return (command, rest)
    }

    /// `/name rest…` against the custom-prompt directory: reads the
    /// file (execution-time read — the file may change after listing)
    /// and strips frontmatter, leaving the body template.
    static func matchPrompt(_ text: String, commands: [AgentSlashCommand])
        -> (command: AgentSlashCommand, body: String, rest: String)? {
        guard text.hasPrefix("/") else { return nil }
        let (name, rest) = Self.splitSlash(text.dropFirst())
        guard let command = commands.first(where: {
            $0.name == name && $0.promptPath != nil
        }), let raw = try? String(contentsOfFile: command.promptPath!,
                                  encoding: .utf8)
            else { return nil }
        return (command, Self.stripFrontMatter(raw), rest)
    }

    /// `/name` and the trailing args (shared splitter).
    private static func splitSlash(_ body: Substring) -> (String, String) {
        if let space = body.firstIndex(where: { $0 == " " || $0 == "\n" }) {
            return (String(body[..<space]),
                    String(body[body.index(after: space)...])
                        .trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return (String(body), "")
    }

    /// The markdown body after a `---` frontmatter fence (empty fence
    /// or none → the whole raw string).
    static func stripFrontMatter(_ raw: String) -> String {
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return raw }
        for (offset, line) in lines.enumerated() where offset > 0 {
            if line.trimmingCharacters(in: .whitespaces) == "---" {
                return lines[(offset + 1)...].joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return raw
    }

    /// Codex custom-prompt placeholder expansion (paseo's
    /// expandCodexCustomPrompt): `$$` escapes a literal `$`;
    /// `$ARGUMENTS` = all args; `$1`..`$9` = positional tokens;
    /// `key=value` args substitute `$key` (longest keys first).
    static func expandCustomPrompt(template: String, args: String) -> String {
        let trimmedArgs = args.trimmingCharacters(in: .whitespacesAndNewlines)
        var named: [String: String] = [:]
        var positional: [String] = []
        for token in trimmedArgs.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
            if let idx = token.firstIndex(of: "="), idx > token.startIndex {
                named[String(token[..<idx])] = String(token[token.index(after: idx)...])
            } else {
                positional.append(String(token))
            }
        }
        let dollar = "\u{0}DOLLAR\u{0}"
        var out = template.replacingOccurrences(of: "$$", with: dollar)
        out = out.replacingOccurrences(of: "$ARGUMENTS", with: trimmedArgs)
        for i in 1...9 {
            out = out.replacingOccurrences(
                of: "$\(i)",
                with: positional.count >= i ? positional[i - 1] : "")
        }
        for key in named.keys.sorted(by: { $0.count > $1.count }) {
            out = out.replacingOccurrences(of: "$\(key)", with: named[key] ?? "")
        }
        return out.replacingOccurrences(of: dollar, with: "$")
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
        // The TUI's OWN picker reads app-server thread/list (tui
        // resume_picker: archived=false, sort_key, id-dedupe across
        // fork rows) — the GUI uses the SAME API on its live
        // app-server so the two lists agree (2026-09-11: the daemon's
        // sqlite+rollout scan listed fork dupes and raw titles the TUI
        // never shows). Daemon scan stays as the fallback for an
        // unresponsive app-server.
        self.client.request(
            "thread/list",
            ["archived": false, "sort_key": "updated_at", "limit": 50]
        ) { [weak self] result in
            guard let self else { return }
            if case .success(let value) = result,
               let threads = value["data"] as? [[String: Any]], !threads.isEmpty {
                let wanted = self.cwd
                var seen = Set<String>()
                var summaries: [AgentSessionSummary] = []
                for thread in threads {
                    guard let id = thread["id"] as? String,
                          !seen.contains(id) else { continue }
                    seen.insert(id)
                    let threadCwd = thread["cwd"] as? String
                    if let wanted, let threadCwd,
                       !threadCwd.hasPrefix(wanted) { continue }
                    let name = (thread["name"] as? String) ?? ""
                    let title = !name.isEmpty
                        ? name
                        : (thread["preview"] as? String ?? "")
                    let updated = (thread["updatedAt"] as? Int)
                        ?? (thread["recencyAt"] as? Int)
                    summaries.append(AgentSessionSummary(
                        sessionId: id, cwd: threadCwd,
                        title: DaemonSessionRow.clampedTitle(title),
                        updatedAt: updated.map { String($0) },
                        messageCount: nil))
                }
                completion(summaries)
                return
            }
            // Fallback: the daemon's sqlite/rollout scan.
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else {
                    completion([])
                    return
                }
                if let (rows, _) = self.daemon.agentStoreSummaries(cwd: self.cwd,
                                                                    store: "codex") {
                    let summaries = rows.map { row in
                        AgentSessionSummary(
                            sessionId: row.id, cwd: row.cwd,
                            title: DaemonSessionRow.clampedTitle(row.title),
                            updatedAt: row.mtimeMs > 0 ? String(row.mtimeMs) : nil,
                            messageCount: nil)
                    }
                    DispatchQueue.main.async { completion(summaries) }
                    return
                }
                completion([])
            }
        }
    }

    /// thread/loaded/list reply → the live thread of this pane's own
    /// app-server process (one codex process per pane, so the first
    /// entry is ours; paseo's fake pins the same `{data: [id]}` shape).
    static func pickLoadedThreadId(_ value: [String: Any]) -> String? {
        (value["data"] as? [String])?.first { !$0.isEmpty }
    }

    /// Attach-adoption rebuild: swap the page for the thread's
    /// authoritative history, like omp's attach store re-read. A GUI
    /// restart lands here with an EMPTY page, so the reset is lossless;
    /// an in-flight turn keeps streaming — its remaining items arrive on
    /// the live notification flow after the settled turns replay.
    private func rebuildAdoptedThread(_ id: String) {
        replayThreadHistory(id) { [weak self] events in
            self?.emit(events)
        }
    }

    /// Paginated history (0.153+ deprecated includeTurns — a paginated
    /// thread answers turns:[] to the old flag, probed 2026-09-11 on
    /// host 5090: 12 turns came back as zero): thread/read for the
    /// thread metadata (model/effort adoption), then thread/turns/list
    /// pages — {data:[turn] (oldest→newest), nextCursor} until the
    /// cursor runs dry. Same mapper as the live flow replays each item.
    private func replayThreadHistory(_ id: String,
                                     done: @escaping ([AgentSessionEvent]) -> Void) {
        // A FRESH mapper: the live instance's dedupe sets already hold
        // every ring-replayed item id, so replaying through it drops
        // every message as a duplicate and only the (ungated) turn
        // error lines survive — the "only error messages, no body"
        // history bug. The replay owns its own dedupe state.
        let mapper = CodexFrameMapper()
        client.request("thread/read", ["threadId": id]) { [weak self] result in
            guard let self else { return }
            let box = Box()
            box.events = [.transcriptReset]
            box.turnCount = 0
            if case .success(let value) = result,
               let thread = value["thread"] as? [String: Any] {
                if let model = thread["model"] as? String {
                    self.modelCurrent = model
                }
                if let effort = thread["reasoningEffort"] as? String,
                   ["minimal", "low", "medium", "high", "xhigh"].contains(effort) {
                    self.reasoningEffort = effort
                }
            }
            self.collectTurns(threadId: id, cursor: nil, box: box,
                              mapper: mapper) {
                if ProcessInfo.processInfo.environment["GOTY_CODEX_DEBUG"] != nil {
                    print("CODEX_REPLAY id=\(id.prefix(8)) turns=\(box.turnCount) events=\(box.events.count)")
                }
                done(box.events)
            }
        }
    }

    private func collectTurns(threadId: String, cursor: String?,
                              box: Box, mapper: CodexFrameMapper,
                              done: @escaping () -> Void) {
        var params: [String: Any] = ["threadId": threadId]
        if let cursor { params["cursor"] = cursor }
        client.request("thread/turns/list", params) { [weak self] result in
            guard let self else { return }
            guard case .success(let value) = result else {
                done()
                return
            }
            for turn in value["data"] as? [[String: Any]] ?? [] {
                box.turnCount += 1
                for item in turn["items"] as? [[String: Any]] ?? [] {
                    box.events += mapper.map(
                        method: "item/completed",
                        params: ["item": item, "threadId": threadId])
                }
                box.events += mapper.map(method: "turn/completed",
                                         params: ["turn": turn])
            }
            if let next = value["nextCursor"] as? String, !next.isEmpty {
                self.collectTurns(threadId: threadId, cursor: next,
                                  box: box, mapper: mapper, done: done)
            } else {
                done()
            }
        }
    }

    func load(sessionId: String, completion: ((Bool) -> Void)? = nil) {
        // thread/resume reattaches the server-side thread; the paginated
        // replay then swaps the page for its authoritative history. A
        // carried model override can poison the resume on a host whose
        // config lacks that provider ("Model provider `fox` not found",
        // probed 2026-09-11) — one bare retry keeps the history flowing;
        // the thread keeps its own model.
        var resumeParams: [String: Any] = ["threadId": sessionId]
        if let modelOverride { resumeParams["model"] = modelOverride }
        func resume(bare: Bool) {
            let params: [String: Any] = bare
                ? ["threadId": sessionId] : resumeParams
            client.request("thread/resume", params) { [weak self] result in
                guard let self else { return }
                if case .failure = result, !bare {
                    resume(bare: true)
                    return
                }
                self.threadId = sessionId
                self.sessionId = sessionId
                self.replayThreadHistory(sessionId) { [weak self] events in
                    self?.emit(events + [.configChanged(self?.assembleOptions() ?? []),
                                         .ready])
                    completion?(true)
                }
            }
        }
        resume(bare: false)
    }

    /// Accumulator for the paginated replay (async pages can't share an
    /// inout across escaping closures).
    private final class Box {
        var events: [AgentSessionEvent] = []
        var turnCount = 0
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
