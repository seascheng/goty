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
    private let channel = LineChannel()
    private let mapper = ClaudeFrameMapper()
    private var pane: PaneSession?
    private var connected = false
    private var processAlive = false
    /// Resume target for the (re)spawn in connect().
    private var resumeSessionId: String?
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
            + "--include-partial-messages"
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
        if configOptions.isEmpty, let model = Self.settingsModel() {
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
        if let restore = restoredSessionId ?? ClaudeSessionStore.summaries(cwd: cwd).first?.sessionId {
            load(sessionId: restore, completion: completion)
        } else {
            openPane(resume: nil, completion: completion)
        }
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
                      "payload": ["type": "interrupt"]])
    }

    func respondPermission(requestID: String, optionId: String) {
        let behavior = optionId.hasPrefix("allow") ? "allow" : "deny"
        channel.send(["type": "control_response",
                      "response_id": requestID,
                      "payload": ["behavior": behavior]])
        emit([.turnEnded(stopReason: nil)])
    }

    func setConfigOption(id: String, value: String) {
        // v1: model switching means a respawn — read-only display for
        // now (configChanged already surfaced the current model).
    }

    func listSessions(completion: @escaping ([AgentSessionSummary]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let summaries = ClaudeSessionStore.summaries(cwd: self.cwd)
            DispatchQueue.main.async {
                completion(summaries.filter { ($0.messageCount ?? 1) > 0 })
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
            let frames = ClaudeSessionStore.history(sessionId: sessionId,
                                                    skippedLines: &skipped)
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
        // Permission requests ride control_request frames.
        if frame["type"] as? String == "control_request",
           let payload = frame["payload"] as? [String: Any],
           let requestID = frame["request_id"] as? String {
            let title = (payload["tool_name"] as? String)
                ?? (payload["title"] as? String)
                ?? "claude 请求授权"
            let prompt = AgentPermissionPrompt.allowOrReject(
                requestID: requestID, title: title)
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
        if !events.isEmpty { emit(events) }
    }

    private func emit(_ events: [AgentSessionEvent]) {
        guard !events.isEmpty else { return }
        delegate?.session(self, didEmit: events)
    }
}
