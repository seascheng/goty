// goty — see CLAUDE.md for the working principles.
import Foundation

/// Claude Code over the stream-json SDK mode — one long-lived pane
/// process fed user frames on stdin (`--print --input-format
/// stream-json` keeps claude reading), frames mapped by
/// ClaudeFrameMapper. `--print` semantics make every result a potential
/// process end; a send() into a dead process respawns with
/// `--resume <session_id>` so the conversation continues.
///
/// History/resume: `~/.claude/projects` jsonl (ClaudeSessionStore);
/// load() replays the file as events, then swaps the pane to a resumed
/// process for live continuation — identical UX to omp's session/load.
final class ClaudeSession: AgentSessioning {
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
    /// The pane (and its store) live on the daemon's machine.
    var runsOnThisMac: Bool { !daemon.isRemote }
    private let channel = LineChannel()
    private let mapper = ClaudeFrameMapper()
    private var pane: PaneSession?
    private var connected = false
    private var processAlive = false
    /// Resume target for the (re)spawn in connect().
    private var resumeSessionId: String?
    /// can_use_tool requests awaiting an answer, keyed by request_id —
    /// the response must echo the input back as updatedInput, so the raw
    /// request is kept verbatim.
    private struct PendingPermission {
        let toolName: String
        let input: [String: Any]
        /// claude's own always-allow rules for this call; echoing them
        /// back is the protocol's way to persist a permission.
        let suggestions: [[String: Any]]
    }
    private var pendingPermissions: [String: PendingPermission] = [:]
    /// Session the pane had open when it was last closed (state.json
    /// via AgentPaneParams). Re-loaded on connect — claude's `--print`
    /// processes are ephemeral; the project store is the durable state.
    private let restoredSessionId: String?
    /// Label for the boot chip re-armed during the settle respawn.
    private static let startingLabel: String =
        AgentRegistry.descriptor(for: "claude")?.label ?? "Claude Code"
    /// Best-effort initial model from ~/.claude/settings.json — the SDK
    /// `init` frame only arrives at the FIRST turn, so without this the
    /// model chip is blank (or stale) for the whole boot.
    private static func settingsModel() -> String? {
        let path = NSString(string: "~/.claude/settings.json").expandingTildeInPath
        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let env = json["env"] as? [String: Any],
              let model = env["ANTHROPIC_MODEL"] as? String, !model.isEmpty else { return nil }
        return model
    }
    /// GOTY_CLAUDE_MODEL debug knob: this machine's default claude model
    /// is misconfigured; tests override it without touching user config.
    private var modelOverride: String? {
        ProcessInfo.processInfo.environment["GOTY_CLAUDE_MODEL"]
    }
    var selfManagesRestore: Bool { true }

    /// Integrity accounting.
    private(set) var framesRouted = 0
    private(set) var unparseableLines = 0

    init(params: AgentPaneParams) {
        self.paneId = params.paneId
        self.cwd = params.cwd
        self.environment = params.environment
        self.daemon = params.daemon
        self.grid = AgentPaneDefaults.grid
        self.restoredSessionId = params.restoredSessionId
        channel.onOutbound = { [weak self] in self?.pane?.sendInput($0) }
        channel.onFrame = { [weak self] frame, replay in
            self?.handleFrame(frame, replay: replay)
        }
        channel.onUnparseable = { line in
            if ProcessInfo.processInfo.environment["GOTY_CLAUDE_DEBUG"] != nil {
                print("CLAUDE_UNPARSEABLE \(line.prefix(300))")
            }
        }
    }

    /// claude refuses TTY stdin under --print ("Input must be provided
    /// through stdin or as a prompt argument" — panes are PTYs). The
    /// bash process substitution feeds claude a PIPE stdin (cat
    /// forwards the PTY), keeping the single-process multi-turn stream
    /// while satisfying the non-TTY check.
    static func shellCommand(model: String?, resume: String?) -> (String, [String]) {
        var cmd = "exec claude --print --input-format stream-json "
            + "--output-format stream-json --verbose "
            // Delta stream: without it claude buffers each message and
            // the reply lands as one block (no live thinking, no
            // progressive text). The interleaved COMPLETE assistant
            // frames are deduped in the mapper by streamed length.
            + "--include-partial-messages "
            // Permission gate: without this flag --print auto-denies any
            // tool not already allowed and NEVER asks the client — the
            // can_use_tool control_request frames in handleFrame (and the
            // permission card) only arrive with it. Verified against
            // claude 2.1.236; matches happier's raw stream-json query.
            + "--permission-prompt-tool stdio"
        if let model, model.allSatisfy({ c in c.isLetter || c.isNumber || ".-_".contains(c) }) {
            cmd += " --model \(model)"
        }
        if let resume, resume.allSatisfy({ $0.isHexDigit || $0 == "-" }) {
            cmd += " --resume \(resume)"
        }
        cmd += " < <(cat)"
        return ("/bin/bash", ["-c", cmd])
    }

    private func argv(resume: String?) -> [String] {
        var args = ["--print", "--input-format", "stream-json",
                    "--output-format", "stream-json", "--verbose",
                    "--include-partial-messages"]
        if let modelOverride {
            args += ["--model", modelOverride]
        }
        if let resume {
            args += ["--resume", resume]
        }
        return args
    }

    func connect(completion: ((Bool) -> Void)? = nil) {
        guard !connected else {
            completion?(true)
            return
        }
        connected = true
        // Seed the model chip before the first turn: the SDK init frame
        // only arrives at turn start, so without this the chip is blank
        // for the whole boot. Ground truth (init) overwrites it later.
        // settings.json is a MAC-side file — remote claude panes wait
        // for the init frame instead of reading the wrong machine's.
        if runsOnThisMac, configOptions.isEmpty, let model = Self.settingsModel() {
            configOptions = [AgentConfigOption(id: "model", name: "模型",
                                               category: nil, currentValue: model,
                                               options: [])]
            emit([.configChanged(configOptions)])
        }
        // Paseo rule: the process is disposable, the project store is
        // the durable state. Attach-to-stale-ring proved fragile (new
        // claude writes no init into the project file, dead processes
        // hold stale env) — so drop any leftover pane and re-load the
        // pane's last session (or the newest for this cwd) from the
        // store, which respawns with --resume and re-reads settings.
        daemon.killPane(id: paneId)
        let restore = restoredSessionId ?? newestStoreSession()
        if let restore {
            load(sessionId: restore, completion: completion)
        } else {
            openPane(resume: nil, completion: completion)
        }
    }

    /// Newest persisted session for this cwd, daemon-side first
    /// (remote panes must consult THEIR host's store).
    private func newestStoreSession() -> String? {
        if let (rows, _) = daemon.agentStoreSummaries(cwd: cwd, store: "claude") {
            return rows.first?.id
        }
        return ClaudeSessionStore.summaries(cwd: cwd).first?.sessionId
    }


    func reconnect(completion: ((Bool) -> Void)? = nil) {
        pane?.close()
        pane = nil
        connected = true
        // claude has no handshake — but a fresh spawn must carry --resume
        // or the conversation context is gone with the old process.
        openPane(resume: lastSessionId ?? resumeSessionId, completion: completion)
    }

    private func openPane(resume: String?, completion: ((Bool) -> Void)?) {
        let (shell, shellArgs) = ClaudeSession.shellCommand(model: modelOverride,
                                                             resume: resume)
        guard let opened = daemon.openPaneWithAttachment(
            id: paneId, cwd: cwd, shell: shell, args: shellArgs,
            environment: environment, grid: grid,
            noEcho: true, ringBytes: 16_777_216,
            onFrame: { [weak self] kind, data in
                self?.handleTransportFrame(kind: kind, data: data)
            },
            onDisconnect: { [weak self] in
                guard let self else { return }
                self.connected = false
                self.processAlive = false
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
        processAlive = true
        // claude has no pre-turn handshake: in SDK --print mode the
        // `init` frame arrives only when the FIRST user turn starts —
        // a fresh process emits nothing but SessionStart hook frames
        // (mapper-ignored noise) while it waits for stdin. Treating
        // init as the only ready signal made every fresh pane sit at
        // "正在启动" until the 90s watchdog fired while claude itself
        // was healthy and waiting for input. Ready = process spawned;
        // the init frame still enriches model/commands on first turn.
        emit([.ready])
        completion?(true)
    }

    func send(_ text: String) {
        guard !isWorking else { return }
        isWorking = true
        // --print may have ended the process at the last result: a
        // resumed spawn is the only way onward.
        if !processAlive, let sessionId {
            resumeSessionId = sessionId
            pane?.close()
            pane = nil
            daemon.killPane(id: paneId)
            openPane(resume: sessionId, completion: nil)
        }
        // claude's live --print stream never echoes the prompt (only the
        // project jsonl does) — emit the asking side locally so the live
        // transcript matches the replayed one.
        emit([.userMessage(text)])
        channel.send(["type": "user",
                      "message": ["role": "user",
                                  "content": [["type": "text", "text": text]]]])
    }

    func cancel() {
        // SDK control protocol interrupt; if claude's build does not
        // honor it the turn still ends at process death (pane kill is
        // the blunt fallback — last resort, history survives on disk).
        let requestID = UUID().uuidString
        channel.send(["type": "control_request",
                      "request_id": requestID,
                      "request": ["subtype": "interrupt"]])
    }

    func respondPermission(requestID: String, optionId: String) {
        // Wire shape (raw stream-json, matches the SDK): {type:
        // "control_response", response:{subtype:"success", request_id,
        // response:<PermissionResult>}}. allow MUST echo the input back
        // as updatedInput; deny carries the reason; always-allow persists
        // claude's own suggestion rules as updatedPermissions.
        let pending = pendingPermissions.removeValue(forKey: requestID)
        var result: [String: Any]
        switch optionId {
        case "allow_always":
            // ponytail: fallback rule shape is SDK-typical — if a build
            // ignores it, always-allow degrades to allow-once.
            var updates: [[String: Any]]
            if let permission = pending, !permission.suggestions.isEmpty {
                updates = permission.suggestions
            } else {
                updates = [["behavior": "allow",
                            "permission": ["type": "tool",
                                           "tool": pending?.toolName ?? ""]]]
            }
            result = ["behavior": "allow",
                      "updatedInput": pending?.input ?? [:],
                      "updatedPermissions": updates]
        case "reject_once":
            result = ["behavior": "deny",
                      "message": "用户拒绝了该工具调用",
                      "interrupt": false]
        default:
            result = ["behavior": "allow",
                      "updatedInput": pending?.input ?? [:]]
        }
        channel.send(["type": "control_response",
                      "response": ["subtype": "success",
                                   "request_id": requestID,
                                   "response": result]])
        // No turnEnded here: after allow the tool RUNS (the turn continues
        // to its result frame); after deny claude reacts and ends the turn
        // itself. The host already moved the phase on the answer — a
        // forced turnEnded stranded live turns at idle.
    }

    func setConfigOption(id: String, value: String) {
        // v1: model switching means a respawn — read-only display for
        // now (configChanged already surfaced the current model).
    }

    func listSessions(completion: @escaping ([AgentSessionSummary]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return completion([]) }
            // Daemon-side store (capability 8) — remote panes list
            // THEIR host's ~/.claude; local read only as fallback.
            var summaries: [AgentSessionSummary]
            if let (rows, _) = self.daemon.agentStoreSummaries(cwd: self.cwd, store: "claude") {
                summaries = rows.map { $0.summary }
            } else {
                summaries = ClaudeSessionStore.summaries(cwd: self.cwd)
            }
            let filtered = summaries.filter { ($0.messageCount ?? 1) > 0 }
            DispatchQueue.main.async {
                completion(filtered)
            }
        }
    }

    func load(sessionId: String, completion: ((Bool) -> Void)? = nil) {
        // 1. Replay the persisted file as events (the asking side
        //    included — userChunk), 2. swap the pane to a resumed
        //    process so send() continues the same conversation.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            var skipped = 0
            // Daemon bytes first (remote panes read THEIR host's store);
            // the local reader only as fallback.
            let frames: [[String: Any]]
            if let data = self.daemon.agentStoreFile(sessionId: sessionId, store: "claude"),
               let text = String(data: data, encoding: .utf8) {
                var parsed: [[String: Any]] = []
                for line in text.split(separator: "\n") {
                    guard let d = line.data(using: .utf8),
                          let json = try? JSONSerialization.jsonObject(with: d)
                              as? [String: Any] else {
                        skipped += 1
                        continue
                    }
                    parsed.append(json)
                }
                frames = parsed
            } else {
                frames = ClaudeSessionStore.history(sessionId: sessionId,
                                                    skippedLines: &skipped)
            }
            var events: [AgentSessionEvent] = []
            let replayMapper = ClaudeFrameMapper()
            for frame in frames {
                events += replayMapper.map(frame)
            }
            if skipped > 0 {
                events.append(.messageChunk("[resume: \(skipped) 行无法解析，已跳过并计数]"))
            }
            DispatchQueue.main.async {
                self.sessionId = sessionId
                self.resumeSessionId = sessionId
                self.commands = []
                // The attach may already have replayed the ring into
                // the transcript — the store file is authoritative, so
                // wipe before replaying it (no double history).
                self.emit([.transcriptReset])
                self.emit(events + [.configChanged(self.configOptions)])
                // The respawn re-reads settings.json (model/env/MCP):
                // surface it as a boot phase — the old starting chip was
                // already consumed by the replayed init's ready.
                self.emit([.starting(agent: Self.startingLabel)])
                self.pane?.close()
                // Pane id is daemon identity (attach-or-spawn): kill the
                // old process or the reopen would ATTACH to it — a fresh
                // --resume spawn never happens.
                self.daemon.killPane(id: self.paneId)
                self.openPane(resume: sessionId, completion: completion)
            }
        }
    }

    func shutdown() {
        pane?.close()
        pane = nil
        connected = false
    }

    // MARK: - frame plumbing

    private func handleTransportFrame(kind: UInt8, data: Data) {
        switch kind {
        case SessionOutputKind.output:
            channel.feed([UInt8](data))
        case SessionOutputKind.snapshot:
            // Ring replay on reattach: claude history is not in the ring
            // (load() reads the store); frame stream replays harmlessly.
            channel.feed([UInt8](data), replay: true)
        case SessionOutputKind.exited:
            processAlive = false
            if isWorking {
                isWorking = false
                emit([.turnEnded(stopReason: nil)])
            }
        default:
            break
        }
    }

    private func handleFrame(_ frame: [String: Any], replay: Bool) {
        let events = mapper.map(frame)
        if let sid = mapper.sessionId { sessionId = sid }
        if let model = mapper.model {
            configOptions = [AgentConfigOption(id: "model", name: "模型",
                                               category: nil, currentValue: model,
                                               options: [])]
        }
        if replay {
            // History rebuilds the transcript only — never the turn
            // state (adapter isWorking stays false for replayed chunks).
            emit(events)
            return
        }
        framesRouted += 1
        if ProcessInfo.processInfo.environment["GOTY_CLAUDE_DEBUG"] != nil {
            let kind = (frame["type"] as? String) ?? "?"
            let sub = (frame["subtype"] as? String) ?? ""
            print("CLAUDE_FRAME \(kind)/\(sub) keys=\(frame.keys.sorted().joined(separator: ","))")
        }
        // Permission requests ride control_request frames. claude → client
        // shape: {type:"control_request", request_id, request:{subtype:
        // "can_use_tool", tool_name, input, suggestions?}} — the SDK's
        // canUseTool callback wraps this same frame over raw stream-json.
        if frame["type"] as? String == "control_request",
           let request = frame["request"] as? [String: Any],
           let requestID = frame["request_id"] as? String,
           request["subtype"] as? String == "can_use_tool" {
            let toolName = request["tool_name"] as? String ?? "工具"
            let input = request["input"] as? [String: Any] ?? [:]
            pendingPermissions[requestID] = PendingPermission(
                toolName: toolName, input: input,
                suggestions: request["suggestions"] as? [[String: Any]] ?? [])
            // Headline argument next to the tool name — the card must
            // show WHAT asks to run, not just that something asks.
            let headline = ClaudeFrameMapper.toolSummary(name: toolName, input: input)
                .first?.text
            let prompt = AgentPermissionPrompt(
                requestID: requestID,
                toolCallTitle: headline.map { "\(toolName)：\($0)" } ?? toolName,
                options: [
                    AgentPermissionOption(optionId: "allow_once", name: "允许", kind: "allow_once"),
                    AgentPermissionOption(optionId: "allow_always", name: "总是允许", kind: "allow_always"),
                    AgentPermissionOption(optionId: "reject_once", name: "拒绝", kind: "reject_once"),
                ])
            emit([.permissionRequested(prompt)])
            return
        }
        // Working state follows the turn: any assistant output means
        // work, result ends it (store.ts already derives it, but the
        // adapter's isWorking gates send()).
        if case .turnEnded = events.last {
            isWorking = false
        } else if events.contains(where: {
            if case .messageChunk = $0 { return true }
            if case .thoughtChunk = $0 { return true }
            return false
        }) {
            isWorking = true
        }
        // Live string user frames are synthetic (command echoes, task
        // receipts): typed text never echoes on the --print stream —
        // send() already bubbled it locally, so the mapper's
        // userMessage here would only double-bubble it.
        let live = events.filter { event in
            if case .userMessage = event { return false }
            return true
        }
        if !live.isEmpty { emit(live) }
    }

    private func emit(_ events: [AgentSessionEvent]) {
        guard !events.isEmpty else { return }
        delegate?.session(self, didEmit: events)
    }
}
