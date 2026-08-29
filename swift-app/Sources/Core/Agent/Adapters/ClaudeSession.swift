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
    /// GOTY_CLAUDE_MODEL debug knob: this machine's default claude model
    /// is misconfigured; tests override it without touching user config.
    private var modelOverride: String? {
        ProcessInfo.processInfo.environment["GOTY_CLAUDE_MODEL"]
    }

    /// Integrity accounting.
    private(set) var framesRouted = 0
    private(set) var unparseableLines = 0

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

    private func argv(resume: String?) -> [String] {
        var args = ["--print", "--input-format", "stream-json",
                    "--output-format", "stream-json", "--verbose"]
        if let modelOverride {
            args += ["--model", modelOverride]
        }
        if let resume {
            args += ["--resume", resume]
        }
        return args
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
        pane = daemon.openPane(
            id: paneId, cwd: cwd, shell: "claude", args: argv(resume: resume),
            environment: environment, grid: grid,
            noEcho: true, ringBytes: 16_777_216,
            onFrame: { [weak self] kind, data in
                self?.handleTransportFrame(kind: kind, data: data)
            },
            onDisconnect: { [weak self] in
                guard let self else { return }
                self.connected = false
                self.processAlive = false
                self.delegate?.sessionDidFail(self, reason: "daemon 连接断开")
            })
        guard pane != nil else {
            connected = false
            delegate?.sessionDidFail(self, reason: "sessiond 不可用")
            completion?(false)
            return
        }
        pane?.start()
        processAlive = true
        completion?(true)
    }

    func send(_ text: String) {
        guard !isWorking else { return }
        isWorking = true
        // --print may have ended the process at the last result: a
        // resumed spawn is the only way onward.
        if !processAlive, let sessionId {
            resumeSessionId = sessionId
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
                self.emit(events + [.configChanged(self.configOptions)])
                self.pane?.close()
                self.pane = nil
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

    private func handleFrame(_ frame: [String: Any]) {
        framesRouted += 1
        // Permission requests ride control_request frames.
        if frame["type"] as? String == "control_request",
           let payload = frame["payload"] as? [String: Any],
           let requestID = frame["request_id"] as? String {
            let title = (payload["tool_name"] as? String)
                ?? (payload["title"] as? String)
                ?? "claude 请求授权"
            let prompt = AgentPermissionPrompt(
                requestID: requestID, toolCallTitle: title,
                options: [ACPOption(optionId: "allow_once", name: "允许", kind: "allow_once"),
                          ACPOption(optionId: "reject_once", name: "拒绝", kind: "reject_once")])
            emit([.permissionRequested(prompt)])
            return
        }
        let events = mapper.map(frame)
        if let sid = mapper.sessionId { sessionId = sid }
        if let model = mapper.model {
            configOptions = [AgentConfigOption(id: "model", name: "模型",
                                               category: nil, currentValue: model,
                                               options: [])]
        }
        // Working state follows the turn: any assistant output means
        // work, result ends it (store.ts already derives it, but the
        // adapter's isWorking gates send()).
        if case .turnEnded = events.last {
            isWorking = false
        } else if events.contains(where: { if case .messageChunk = $0 { return true }; return false }) {
            isWorking = true
        }
        if !events.isEmpty { emit(events) }
    }

    private func emit(_ events: [AgentSessionEvent]) {
        guard !events.isEmpty else { return }
        delegate?.session(self, didEmit: events)
    }
}
