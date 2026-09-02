// goty - see CLAUDE.md for the working principles.
import Foundation

/// The pi 0.8x dialect of the pi-mono family: immediate get_state
/// handshake (no protocol negotiation), history via get_messages,
/// sessions in PiSessionStore, command directory via get_commands.
/// Attaches omp-style (the 2026-09-02 double-reload report): ring
/// replay suppressed, transcript rebuilt from the live process.
final class PiLegacySession: PiSession {
    override func appendSpawnArgs(_ args: inout [String], resume sessionId: String?) {
        // pi EXITS when --session names an id its store no longer
        // has ("No session found matching '…'" → EXITED → the
        // pane reported 进程已退出 forever). Only resume ids the
        // store can still find; a missing one boots fresh.
        if let sessionId, PiSessionStore.find(sessionId: sessionId) != nil {
            args += ["--session", sessionId]
        }
    }

    /// pi used to re-stream its whole ring into the page on every
    /// attach, then the host's restore `load()` killed the live
    /// process, respawned it and re-rendered via get_messages — each
    /// GUI restart showed all data loading TWICE and rebooted a
    /// healthy agent. omp's model instead: suppress the ring, rebuild
    /// the transcript from the process's own history.
    override var suppressesRingReplay: Bool { true }
    /// The restore runs inside connect (history rebuild via the replay
    /// gate) — the host must NOT follow up with its kill-and-respawn
    /// `load()`.
    var selfManagesRestore: Bool { true }

    /// Every completed handshake (attach, reconnect, resume respawn)
    /// rebuilds the transcript through the replay gate: history
    /// first, live frames after — omp's store rebuild ordering.
    /// Mid-turn parity with omp: isStreaming adopts as working state
    /// and reattachedMidTurn triggers the settle rebuild — get_messages
    /// does NOT include the in-flight message (probed 2026-09-02:
    /// mid-turn it returns only completed messages), so the
    /// in-flight message's pre-attach deltas heal through the
    /// full-history rebuild at the turn's end.
    override func adoptAttachedState(_ state: [String: Any]) {
        let streaming = state["isStreaming"] as? Bool ?? false
        isWorking = streaming
        reattachedMidTurn = streaming
        if let sid = state["sessionId"] as? String, !sid.isEmpty {
            DispatchQueue.main.async { [weak self] in
                self?.beginReplayGate(sessionId: sid)
            }
        }
    }

    /// pi's history source is the LIVE process: get_messages answers
    /// the resumed session. File-based sources don't exist for the
    /// GUI when the pane runs on a remote daemon.
    override func readStoredHistory(
            _ sid: String,
            completion: @escaping (StoredSessionHistory?) -> Void) {
        request("get_messages") { response in
            guard response["success"] as? Bool == true,
                  let data = response["data"] as? [String: Any],
                  let messages = data["messages"] as? [[String: Any]] else {
                completion(nil)
                return
            }
            let mapper = PiFrameMapper()
            var events: [AgentSessionEvent] = []
            for message in messages {
                events += mapper.mapReplayedMessage(message)
            }
            if let assistant = messages.last(where: { $0["role"] as? String == "assistant" }),
               assistant["stopReason"] as? String == "error",
               let text = AgentSessionEvent.providerErrorText(from: assistant) {
                events.append(.error(text: text))
            }
            completion(StoredSessionHistory(events: events, openTools: 0, aborted: false))
        }
    }

    /// The replay gate (adoptAttachedState) already renders history
    /// exactly once; `load()` only needs the success verdict —
    /// re-fetching here would duplicate every block.
    override func completeSessionLoad(_ completion: @escaping (Bool) -> Void) {
        completion(true)
    }

    /// pi's BUILT-IN slash commands, verbatim from pi 0.8x's own
    /// registry (core/slash-commands.js, extracted from 0.84.3). The
    /// get_commands RPC only lists EXTENSION commands — builtins
    /// still parse on the prompt path but never appear in the
    /// directory, so the / popup would silently omit /compact & co.
    /// (the missing-/compact report). Supplement, never replace: an
    /// RPC-reported command wins if pi starts listing builtins
    /// itself.
    static let builtinCommands: [AgentSlashCommand] = [
        AgentSlashCommand(name: "settings", description: "Open settings menu", inputHint: nil),
        AgentSlashCommand(name: "model", description: "Select model (opens selector UI)", inputHint: nil),
        AgentSlashCommand(name: "tree", description: "Navigate session tree (switch branches)", inputHint: nil),
        AgentSlashCommand(name: "thinking", description: "Set thinking level", inputHint: nil),
        AgentSlashCommand(name: "scoped-models", description: "Enable/disable models for Ctrl+P cycling", inputHint: nil),
        AgentSlashCommand(name: "export", description: "Export session (HTML default, or specify path: .html/.jsonl)", inputHint: nil),
        AgentSlashCommand(name: "import", description: "Import and resume a session from a JSONL file", inputHint: nil),
        AgentSlashCommand(name: "share", description: "Share session as a secret GitHub gist", inputHint: nil),
        AgentSlashCommand(name: "copy", description: "Copy last agent message to clipboard", inputHint: nil),
        AgentSlashCommand(name: "name", description: "Set session display name", inputHint: nil),
        AgentSlashCommand(name: "session", description: "Show session info and stats", inputHint: nil),
        AgentSlashCommand(name: "changelog", description: "Show changelog entries", inputHint: nil),
        AgentSlashCommand(name: "hotkeys", description: "Show all keyboard shortcuts", inputHint: nil),
        AgentSlashCommand(name: "fork", description: "Create a new fork from a previous user message", inputHint: nil),
        AgentSlashCommand(name: "clone", description: "Duplicate the current session at the current position", inputHint: nil),
        AgentSlashCommand(name: "trust", description: "Save project trust decision for future sessions", inputHint: nil),
        AgentSlashCommand(name: "login", description: "Configure provider authentication", inputHint: nil),
        AgentSlashCommand(name: "logout", description: "Remove provider authentication", inputHint: nil),
        AgentSlashCommand(name: "new", description: "Start a new session", inputHint: nil),
        AgentSlashCommand(name: "compact", description: "Manually compact the session context", inputHint: nil),
        AgentSlashCommand(name: "resume", description: "Resume a different session", inputHint: nil),
        AgentSlashCommand(name: "reload", description: "Reload keybindings, extensions, skills, prompts, themes, and context files", inputHint: nil),
        AgentSlashCommand(name: "quit", description: "Quit pi", inputHint: nil),
    ]

    override func loadCommandsAfterHandshake() {
        request("get_commands") { [weak self] response in
            guard let self, response["success"] as? Bool == true else { return }
            // Response wraps the list: {"commands":[…]} (verified
            // live); a bare array is tolerated for forward compat.
            let raw = (response["data"] as? [String: Any])?["commands"]
                as? [[String: Any]]
                ?? (response["commands"] as? [[String: Any]])
                ?? []
            let fetched = raw.compactMap { (item: [String: Any]) -> AgentSlashCommand? in
                guard let name = item["name"] as? String else { return nil }
                return AgentSlashCommand(
                    name: name,
                    description: item["description"] as? String,
                    inputHint: (item["input"] as? [String: Any])?["hint"] as? String)
            }
            var seen = Set(fetched.map(\.name))
            let builtins = Self.builtinCommands.filter { seen.insert($0.name).inserted }
            self.adoptCommands(builtins + fetched)
        }
    }

    override func sessionSummaries(
            _ completion: @escaping ([AgentSessionSummary]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return completion([]) }
            // Daemon-side store (capability 8): remote panes must read
            // THEIR host's ~/.pi, not the GUI's. Local fallback keeps
            // old daemons identical.
            if let (rows, _) = self.daemon.agentStoreSummaries(cwd: self.cwd, store: "pi") {
                completion(rows.map { $0.summary })
            } else {
                completion(PiSessionStore.summaries(cwd: self.cwd))
            }
        }
    }
}
