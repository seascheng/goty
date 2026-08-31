// goty — see CLAUDE.md for the working principles.
import Foundation

/// omp adapter — ACP over the daemon-hosted pane (attach-or-spawn).
/// State machine: disconnected → connecting → ready ⇄ working /
/// awaitingPermission; death surfaces as the daemon's EXITED frame.
final class OmpSession: AgentSessioning {
    weak var delegate: AgentSessionDelegate?

    let cwd: String?
    private let paneId: String
    private let environment: [String: String]
    private let spawn: AgentSpawn
    private let daemon: SessionDaemon
    private let grid: SessionGrid
    private var pane: PaneSession?
    private let client = JSONRPCChannel()
    private(set) var sessionId: String?
    private(set) var isWorking = false
    private(set) var configOptions: [AgentConfigOption] = []
    private(set) var commands: [AgentSlashCommand] = []
    private var connected = false
    /// Attach-first restore state. `attachedLive`: the current transport
    /// attached to a pane whose agent process is the one that owns the
    /// conversation (never killed by us). `paneDead`: that process died;
    /// the next connect must spawn, never attach the frozen ring again.
    /// `healing`: an auto-respawn after that death is in flight.
    private var attachedLive = false
    private var paneDead = false
    private var healing = false
    private var inReplayFeed = false
    /// Ring replay is SIGNAL-ONLY (prompt counting, session id adoption):
    /// its request/notification callbacks do not preserve chronological
    /// order, so rendering from it scrambled user prompts after model
    /// output (2026-08-31). The transcript renders from the session
    /// store alone — append-only jsonl, TUI-grade order.
    private var suppressReplayRender = false
    /// session/load issued ONLY to fetch configOptions on attach: the
    /// replayed history is already on the page (ring/store) — its event
    /// stream is dropped, the response's configOptions kept.
    private var suppressLoadReplay = false
    /// Healing reload: the fresh process's history replay is BUFFERED
    /// (never rendered) and swaps in atomically on completion — the page
    /// keeps showing the old picture until the authoritative history is
    /// complete. Blank-screen waiting was the 2026-08-31 report.
    private var suppressUpdates = false
    private var bufferedReload: [AgentSessionEvent] = []
    /// Model-output chunks seen since connect — the stall watchdog's
    /// liveness signal (raw bytes lie: omp emits stray log lines while a
    /// turn is dead; chunks mean the MODEL is actually producing).
    private(set) var chunkCount = 0
    private var stallChunkBaseline = 0
    /// Ring accounting for mid-turn detection on attach: a prompt
    /// request without a matching result in the ring means the turn is
    /// still running and the reattached page must stay in working state.
    private var replayPromptRequests = 0
    private var replayPromptResults = 0
    /// The session the user last had loaded here (persisted per pane in
    /// state.json). A fresh process reloads it via session/load; a live
    /// attach adopts the process's own id from the ring instead.
    private let restoredSessionId: String?

    init(paneId: String, cwd: String?, grid: SessionGrid,
         environment: [String: String],
         spawn: AgentSpawn, daemon: SessionDaemon,
         restoredSessionId: String? = nil,
         delegate: AgentSessionDelegate? = nil) {
        self.paneId = paneId
        self.cwd = cwd
        self.grid = grid
        self.environment = environment
        self.spawn = spawn
        self.daemon = daemon
        self.restoredSessionId = restoredSessionId
        self.delegate = delegate
        client.onOutbound = { [weak self] in self?.pane?.sendInput($0) }
        client.onNotification = { [weak self] method, params in
            self?.interpret(["method": method, "params": params])
        }
        client.onRequest = { [weak self] id, method, params in
            guard method == "session/request_permission" else { return }
            self?.interpret(["id": id, "method": method, "params": params])
        }
        // Attach adoption: the ring re-streams the pane's original
        // session/new response; that orphan result is where the live
        // sessionId lives (the process owns it — we never re-handshake).
        // Prompt RESULTS (stopReason) are tracked too: during replay
        // they answer "was the turn already over", and one arriving LIVE
        // after a reattach is the in-flight turn finishing with nobody
        // waiting on it — close the page's working state right there.
        client.onOrphanResult = { [weak self] result in
            guard let self else { return }
            if self.sessionId == nil, let id = result["sessionId"] as? String {
                self.sessionId = id
                // The same orphan carries the handshake's configOptions
                // (model / thinking knobs) — on attach this is the ONLY
                // place they exist, and the composer renders its toolbar
                // from them. Without adoption a reattached pane shows a
                // bare composer: icon + history, no knobs.
                let configs = AgentConfigOption.list(result["configOptions"])
                if !configs.isEmpty {
                    self.configOptions = configs
                    self.emit([.configChanged(configs)])
                }
            }
            guard let stopReason = result["stopReason"] as? String else { return }
            if self.inReplayFeed {
                self.replayPromptResults += 1
            } else if self.attachedLive {
                // The in-flight turn finished with nobody waiting on its
                // response. Idempotent: emitting from a non-working state
                // just re-lands idle (the turnEnded path also re-persists
                // the session id and refreshes the title).
                self.isWorking = false
                self.emit([.turnEnded(stopReason: stopReason)])
            }
        }
        // Ring_input panes re-stream the user's own session/prompt
        // requests — the only wire record of the user's side of the
        // conversation. Replayed into the transcript in ring order.
        client.onReplayRequest = { [weak self] _, method, params in
            guard let self, self.attachedLive,
                  method == "session/prompt" else { return }
            self.replayPromptRequests += 1
            let blocks = (params["prompt"] as? [[String: Any]])
                ?? (params["content"] as? [[String: Any]]) ?? []
            let text = blocks.compactMap { $0["text"] as? String }.joined()
            if !text.isEmpty {
                self.emit([.userChunk(text)])
            }
        }
    }

    /// Override — omp restores inside connect/resume itself (attach
    /// adoption or session/load on the fresh process). The host must NOT
    /// fire its compensating load afterwards: session/load on a process
    /// that just loaded replays the whole history a second time.
    var selfManagesRestore: Bool { true }

    func connect(completion: ((Bool) -> Void)? = nil) {
        guard !connected else {
            completion?(true)
            return
        }
        connected = true
        resume(completion)
    }

    /// Restore-or-KEEP: attach to the daemon-hosted pane first — the
    /// agent process survives GUI restarts and transport blips, so an
    /// in-flight model call must never be killed just because the client
    /// went away (the 2026-08-31 keep/recover report: reopen used to
    /// murder the running task, then mint an empty session). The attach
    /// replay rebuilds the transcript — user prompts included, they ride
    /// the ring via ring_input — and the live stream continues. Only a
    /// genuinely absent pane spawns a fresh process, which then reloads
    /// the persisted conversation from omp's store (restoredSessionId).
    private func resume(_ completion: ((Bool) -> Void)?) {
        // Close the old client transport first. Its reader must not
        // receive the new pane's frames mixed with the old stream.
        pane?.close()
        pane = nil
        if !paneDead, let opened = openTransport() {
            if opened.attachedExisting {
                // The live pane answered: adoption + turn-state settle
                // happen on the reader thread as the ring replays.
                attachedLive = true
                completion?(true)
                return
            }
            // Fresh spawn (no pane existed): brand-new process, empty
            // in-memory session — reload the persisted conversation
            // instead of minting an empty zombie via session/new.
            handshake(completion)
            return
        }
        if !paneDead {
            connected = false
            delegate?.sessionDidFail(self, reason: "sessiond 不可用")
            completion?(false)
            return
        }
        // The previously adopted pane died: clear the remnant so the
        // spawn is clean (an attach of a dead pane would replay a frozen
        // ring and exit again — a retry loop).
        daemon.killPaneAndWait(id: paneId) { [weak self] killed in
            guard let self, killed else {
                completion?(false)
                return
            }
            guard self.openTransport() != nil else {
                self.connected = false
                self.delegate?.sessionDidFail(self, reason: "sessiond 不可用")
                completion?(false)
                return
            }
            self.paneDead = false
            self.handshake(completion)
        }
    }

    private func openTransport() -> SessionDaemon.OpenPaneResult? {
        guard let opened = daemon.openPaneWithAttachment(
            id: paneId, cwd: cwd, shell: spawn.command, args: spawn.args,
            environment: environment, grid: grid,
            noEcho: true, ringBytes: spawn.ringBytes, ringInput: true,
            onFrame: { [weak self] kind, data in
                self?.handleFrame(kind: kind, data: data)
            },
            onDisconnect: { [weak self] in
                guard let self else { return }
                self.connected = false
                self.delegate?.session(self, didDisconnectBecause: "daemon 连接断开")
            })
        else { return nil }
        // onOutbound writes through this property — a nil pane silently
        // eats every request (initialize included).
        pane = opened.session
        // The reader thread pumps attach replies, ring replay and live
        // frames — without it the handshake hangs forever.
        opened.session.start()
        return opened
    }

    /// The adopted pane died while we were away: tear the remnant down
    /// and bring a fresh process up, reloading the persisted session.
    /// Entry is on the pane's reader thread; killPaneAndWait hops to a
    /// utility queue and hops back to main, where the rest of this
    /// class's transport work already runs.
    private func respawnAfterDeath() {
        paneDead = true
        pane?.close()
        pane = nil
        daemon.killPaneAndWait(id: paneId) { [weak self] killed in
            guard let self else { return }
            // killed=false is fine: a pane that already vanished (daemon
            // restart) left the socket free — spawning directly is the
            // recovery. Only a failed spawn/transport is a real failure.
            guard self.openTransport() != nil else {
                self.healing = false
                self.suppressUpdates = false
                self.delegate?.sessionDidFail(self, reason: "agent 进程已退出，自动恢复失败")
                return
            }
            self.paneDead = false
            self.handshake { [weak self] ok in
                guard let self else { return }
                self.healing = false
                self.suppressUpdates = false
                // Atomic swap: drop the stale picture, land the
                // authoritative history buffered during the reload.
                let buffered = self.bufferedReload
                self.bufferedReload = []
                if ok {
                    self.emit([.transcriptReset] + buffered + [.ready])
                } else {
                    self.emit([.transcriptReset])
                    self.delegate?.sessionDidFail(self, reason: "agent 进程已退出，自动恢复失败")
                }
            }
        }
    }

    private func handshake(_ completion: ((Bool) -> Void)?) {
        if debugFramesEnabled {
            print("GOTY_DEBUG omp handshake: sending initialize")
        }
        client.request("initialize", [
            "protocolVersion": 1,
            "clientCapabilities": ["fs": ["readTextFile": false, "writeTextFile": false]],
        ]) { [weak self] result in
            guard let self, case .success = result else {
                self?.failHandshake("initialize 失败", completion)
                return
            }
            // A persisted/live session resumes INSTEAD of session/new —
            // session/new here would mint an empty zombie session per
            // restore. Prefer the pane's persisted id; if the load fails
            // (session purged upstream), fall back to a fresh session so
            // the pane stays usable.
            if let restore = restoredSessionId ?? lastSessionId {
                load(sessionId: restore) { ok in
                    if ok { completion?(true) }
                    else { self.sessionNew(completion) }
                }
            } else {
                self.sessionNew(completion)
            }
        }
    }

    private func sessionNew(_ completion: ((Bool) -> Void)?) {
        client.request("session/new", [
            "cwd": cwd ?? NSNull(), "mcpServers": [],
        ]) { [weak self] result in
            guard let self, case .success(let value) = result,
                  let sessionId = value["sessionId"] as? String else {
                self?.failHandshake("session/new 失败", completion)
                return
            }
            self.sessionId = sessionId
            let configs = AgentConfigOption.list(value["configOptions"])
            self.configOptions = configs
            self.emit(configs.isEmpty ? [.ready] : [.configChanged(configs), .ready])
            completion?(true)
        }
    }

    func reconnect(completion: ((Bool) -> Void)? = nil) {
        connected = true
        resume(completion)
    }

    /// Handshake failure path: report and settle the connect completion.
    /// (The old `sessionDidFail(self!)` crashed when the weak self had
    /// already gone — argument evaluation runs before optional chaining.)
    private func failHandshake(_ reason: String, _ completion: ((Bool) -> Void)?) {
        delegate?.sessionDidFail(self, reason: reason)
        completion?(false)
    }

    private func handleFrame(kind: UInt8, data: Data) {
        bytesFed += data.count
        if debugFramesEnabled {
            if loadDebugBytes == 0 { loadDebugStart = Date() }
            loadDebugBytes += data.count
            loadDebugFrames += 1
            if loadDebugBytes / 262_144 != (loadDebugBytes - data.count) / 262_144 {
                print("GOTY_DEBUG: replay \(loadDebugBytes)B in \(Date().timeIntervalSince(loadDebugStart))s frames=\(loadDebugFrames)")
            }
        }
        switch kind {
        case SessionOutputKind.output:
            if debugFramesEnabled { print("GOTY_DEBUG omp frame OUTPUT \(data.count)B: \(String(decoding: data.prefix(120), as: UTF8.self))") }
            client.feed([UInt8](data))
        case SessionOutputKind.snapshot:
            if debugFramesEnabled { print("GOTY_DEBUG omp frame SNAPSHOT \(data.count)B") }
            // Ring replay (reattach to a LIVE pane) is SIGNAL-ONLY:
            // prompt counting + live session id adoption. Its request and
            // notification callbacks do not preserve chronological order,
            // so rendering from it put user prompts AFTER model output and
            // glued consecutive prompts into one bubble (2026-08-31). The
            // transcript renders from the SESSION STORE alone — the same
            // append-only jsonl the omp TUI reads: user side included,
            // aborted turns marked with their persisted stopReason.
            inReplayFeed = true
            suppressReplayRender = true
            client.feed([UInt8](data), replay: true)
            suppressReplayRender = false
            inReplayFeed = false
            if sessionId == nil { sessionId = restoredSessionId }
            let stored = sessionId.flatMap { OmpSessionStore.load(sessionId: $0) }
            NSLog("GOTY attach settle: sid=%@ restored=%@ storedEvents=%ld aborted=%@ req=%ld res=%ld",
                  sessionId ?? "nil", restoredSessionId ?? "nil",
                  stored?.events.count ?? -1,
                  stored?.aborted.description ?? "nil",
                  replayPromptRequests, replayPromptResults)
            // Turn verdict: omp's persisted stopReason is authoritative
            // for dead turns (they never deliver a wire result — the fake
            // "working" no stop could clear); an unanswered prompt request
            // means the turn is genuinely live.
            isWorking = stored?.aborted != true
                && replayPromptRequests > replayPromptResults
            var events: [AgentSessionEvent] = []
            if let stored, !stored.events.isEmpty {
                events.append(.transcriptReset)
                events.append(contentsOf: stored.events)
            }
            events.append(.ready)   // host lands idle or thinking from isWorking
            emit(events)
            if isWorking {
                stallChunkBaseline = chunkCount
                DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
                    self?.settleStalledAttach()
                }
            }
            // ACP ships the composer's configOptions (model / thinking
            // knobs) only on session/new|load responses. An attach sends
            // neither — the ring's new-session orphan rotated away long
            // ago — so a reattached pane rendered a bare composer
            // (history button only). One no-op load against the live
            // process carries them; the replayed history stream drops
            // (the page is already authoritative) and the response's
            // configOptions land on the composer.
            if let sid = sessionId, configOptions.isEmpty {
                suppressLoadReplay = true
                client.request("session/load", [
                    "sessionId": sid,
                    "cwd": cwd ?? FileManager.default.currentDirectoryPath,
                    "mcpServers": [],
                ]) { [weak self] result in
                    guard let self else { return }
                    self.suppressLoadReplay = false
                    guard case .success(let value) = result else { return }
                    let configs = AgentConfigOption.list(value["configOptions"])
                    guard !configs.isEmpty else { return }
                    self.configOptions = configs
                    self.emit([.configChanged(configs)])
                }
            }
        default:
            break // SIZE/ATTACHED/ERROR: transport markers, not transcript
        }
    }


    /// 30s after an attach that settled mid-turn: no new bytes means the
    /// turn died without a result. Land idle (the history stays on the
    /// page); the user can re-prompt to continue the task.
    private func settleStalledAttach() {
        guard attachedLive, isWorking, chunkCount == stallChunkBaseline else { return }
        isWorking = false
        emit([.turnEnded(stopReason: nil)])
    }

    /// Replay bursts arrive as thousands of single-event emits; hopping
    /// each onto the main queue individually stalls the replay pipeline
    private func emit(_ events: [AgentSessionEvent]) {
        guard !events.isEmpty else { return }
        if suppressReplayRender { return }
        if suppressLoadReplay { return }
        if suppressUpdates {
            // Healing reload in flight: buffer the authoritative replay,
            // render nothing until it swaps in atomically.
            bufferedReload.append(contentsOf: events)
            return
        }
        eventsEmitted += events.count
        pendingLock.lock()
        pendingEvents.append(contentsOf: events)
        let needsSchedule = !pendingFlushScheduled
        pendingFlushScheduled = true
        pendingLock.unlock()
        if needsSchedule {
            DispatchQueue.main.async { [weak self] in self?.flushPendingEvents() }
        }
    }

    private func flushPendingEvents() {
        pendingLock.lock()
        defer { pendingFlushScheduled = false }
        let events = pendingEvents
        pendingEvents = []
        pendingLock.unlock()
        if events.isEmpty { return }
        delegate?.session(self, didEmit: events)
        pendingLock.lock()
        let again = !pendingEvents.isEmpty
        if again { pendingFlushScheduled = true }
        pendingLock.unlock()
        if again {
            DispatchQueue.main.async { [weak self] in self?.flushPendingEvents() }
        }
    }
    private var pendingEvents: [AgentSessionEvent] = []
    private var pendingFlushScheduled = false
    private let pendingLock = NSLock()
    /// Hoisted out of handleFrame: ProcessInfo.environment copies the whole
    /// environment dictionary on every access — per frame that dominated
    /// the replay pipeline.
    private var loadDebugBytes = 0
    private var loadDebugFrames = 0
    private var loadDebugStart = Date()
    private let debugFramesEnabled = ProcessInfo.processInfo.environment["GOTY_AUTOLOAD_SESSION"] != nil
    var debugReplayBytes: Int { loadDebugBytes }
    var debugReplayFrames: Int { loadDebugFrames }

    // MARK: - Integrity accounting

    /// Resume audits compare these per layer — bytes in, ACP messages
    /// routed, events emitted; any mismatch localizes the first lossy
    /// boundary. Integer bumps, always on.
    private(set) var bytesFed = 0
    private(set) var eventsEmitted = 0
    var messagesRouted: Int { client.messagesRouted }
    var unparseableLines: Int { client.unparseableLines }

    func send(_ text: String) {
        if debugFramesEnabled {
            print("GOTY_DEBUG omp send: sessionId=\(sessionId ?? "nil") working=\(isWorking) pane=\(pane != nil)")
        }
        guard let sessionId, !isWorking else { return }
        isWorking = true
        // omp 18.0.8 names the field `prompt` (spec drift: ACP v1 says
        // `content`); M3 adapters translate back per agent.
        client.request("session/prompt", [
            "sessionId": sessionId,
            "prompt": [["type": "text", "text": text]],
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

    /// The working switch is owned by the daemon's extension report (the
    /// tab badge reads the same value); cancel here is the REQUEST to
    /// stop. First press: notify the agent and wait for its own
    /// cancelled result — the transcript stays untouched. A second
    /// press within 10s means the agent ignored it: kill the pane and
    /// heal back onto the persisted conversation (a clear + reload is
    /// then the user's explicit choice, never a surprise). The heal
    /// keeps the old transcript on the page and swaps the authoritative
    /// history in atomically when the reload completes.
    func cancel() {
        guard let id = sessionId ?? restoredSessionId else { return }
        client.notify("session/cancel", ["sessionId": id])
        let now = Date()
        cancelCount = now.timeIntervalSince(lastCancelAt) < 10 ? cancelCount + 1 : 1
        lastCancelAt = now
        if cancelCount >= 2, attachedLive, !healing {
            healing = true
            attachedLive = false
            isWorking = false
            emit([.starting(agent: "omp")])
            suppressUpdates = true
            respawnAfterDeath()
            return
        }
        // Single cancel: the agent may abort silently (no result line —
        // omp's aborted turns are exactly that). Schedule the same stall
        // verdict: 30s without new model output lands the pane idle.
        if isWorking {
            stallChunkBaseline = chunkCount
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
                self?.settleStalledAttach()
            }
        }
    }
    private var cancelCount = 0
    private var lastCancelAt = Date.distantPast

    func respondPermission(requestID: String, optionId: String) {
        guard let id = Int(requestID) else { return }
        client.respond(id: id,
                       result: ["outcome": ["outcome": "selected", "optionId": optionId]])
    }

    /// Persisted-session directory (session/list) filtered to the pane cwd.
    /// Zero-message entries are creation placeholders — drop them; newest
    /// activity sorts first.
    func listSessions(completion: @escaping ([AgentSessionSummary]) -> Void) {
        var params: [String: Any] = [:]
        if let cwd { params["cwd"] = cwd }
        client.request("session/list", params) { result in
            guard case .success(let value) = result else {
                completion([])
                return
            }
            let summaries = AgentSessionSummary.list(value["sessions"])
                .filter { ($0.messageCount ?? 0) > 0 }
                .sorted { ($0.updatedAt ?? "") > ($1.updatedAt ?? "") }
            completion(summaries)
        }
    }

    /// Flip one config knob (mode / model / thinking …). The OK response
    /// carries the full updated knob list — that is the new state, apply
    /// it wholesale.
    func setConfigOption(id: String, value: String) {
        guard let sessionId else { return }
        client.request("session/set_config_option", [
            "sessionId": sessionId, "configId": id, "value": value,
        ]) { [weak self] result in
            guard let self, case .success(let response) = result else { return }
            let configs = AgentConfigOption.list(response["configOptions"])
            guard !configs.isEmpty else { return }
            self.configOptions = configs
            self.emit([.configChanged(configs)])
        }
    }

    /// Resume a persisted agent session on this connection; replayed
    /// history arrives as normal session/update events.
    func load(sessionId id: String, completion: ((Bool) -> Void)? = nil) {
        // omp REQUIRES a string cwd ("path must be of type string" on
        // null/missing) — fall back to the process cwd for panes whose
        // workspace never tracked one.
        let params: [String: Any] = [
            "sessionId": id,
            "cwd": cwd ?? FileManager.default.currentDirectoryPath,
            "mcpServers": [],
        ]
        // Large sessions replay for a long time (history events stream
        // through as normal updates — the page fills progressively). But
        // a reply that NEVER arrives used to strand the pane blank on
        // "思考中" forever: report the stall instead of hanging silent.
        var finished = false
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, !finished else { return }
            finished = true
            self.isWorking = false
            self.delegate?.sessionDidFail(self,
                reason: "会话恢复超时（45s 无响应）。点重试再试一次。")
            completion?(false)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 45, execute: timeout)
        client.request("session/load", params) { [weak self, timeout] result in
            timeout.cancel()
            guard let self, !finished, case .success(let value) = result else {
                if !finished { finished = true; completion?(false) }
                return
            }
            finished = true
            self.sessionId = id
            self.isWorking = false
            let configs = AgentConfigOption.list(value["configOptions"])
            self.configOptions = configs
            var events: [AgentSessionEvent] = []
            if !configs.isEmpty { events.append(.configChanged(configs)) }
            events.append(.ready)
            self.emit(events)
            completion?(true)
        }
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
                    .compactMap { AgentPermissionOption(raw: $0) }
                let title = (params["toolCall"] as? [String: Any])?["title"] as? String
                events.append(.permissionRequested(
                    AgentPermissionPrompt(requestID: String(id), toolCallTitle: title, options: options)))
            }
            emit(events)
            return events
        }
        switch kind {
        case "user_message_chunk":
            if let content = (update["content"] as? [String: Any]).flatMap(AgentContent.init),
               let text = content.text {
                events.append(.userChunk(text))
            }
        case "agent_message_chunk":
            // A LIVE chunk is PROOF the turn is alive — it overrides
            // the stall watchdog's 30s guess, which mis-killed turns
            // that pause between sparse outputs (MCP tools, long
            // thinking) and left the composer idle with no stop button
            // on a turn that was genuinely still running (2026-08-31).
            if !inReplayFeed {
                isWorking = true
            }
            chunkCount += 1
            if let content = (update["content"] as? [String: Any]).flatMap(AgentContent.init),
               let text = content.text {
                events.append(.messageChunk(text))
            }
        case "agent_thought_chunk":
            if let content = (update["content"] as? [String: Any]).flatMap(AgentContent.init),
               let text = content.text {
                events.append(.thoughtChunk(text))
            }
        case "tool_call", "tool_call_update":
            if let id = update["toolCallId"] as? String {
                // Full fidelity, both wire shapes: nested `content` wrappers
                // and `rawOutput` tool results. The flat-only reader plus a
                // 64 KiB cap silently dropped most tool output on resume —
                // the long-session content loss. No truncation here: the
                // render layer windows, the bridge is structured transport.
                let content = ACPContentNormalizer.flatten(update["content"] as? [[String: Any]])
                let output = ACPContentNormalizer.resultItems(rawOutput: update["rawOutput"])
                // Edit-like calls carry rawInput {path, content}: snapshot the
                // on-disk file NOW (before the write lands) so the UI can
                // render a real old↔new diff. Local panes only; 256 KiB cap.
                var oldText: String?
                let toolStatus = update["status"] as? String
                if toolStatus == "pending", let rawInput = update["rawInput"] as? [String: Any],
                   let path = rawInput["path"] as? String,
                   let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                   let size = attrs[.size] as? Int, size <= 256 * 1024,
                   let data = FileManager.default.contents(atPath: path) {
                    oldText = String(data: data, encoding: .utf8)
                }
                events.append(.toolCallUpdate(id: id,
                                              title: update["title"] as? String,
                                              kind: update["kind"] as? String,
                                              status: toolStatus,
                                              content: content,
                                              output: output,
                                              rawInput: update["rawInput"] as? [String: Any],
                                              oldText: oldText))
            }
        case "plan":
            let entries = ((update["entries"] as? [[String: Any]]) ?? []).compactMap(AgentPlanEntry.init)
            if !entries.isEmpty {
                events.append(.plan(entries))
            }
        case "available_commands_update":
            let list = AgentSlashCommand.list(update["availableCommands"])
            commands = list
            events.append(.commandsChanged(list))
        case "usage_update":
            let cost = update["cost"] as? [String: Any]
            events.append(.usageUpdate(used: update["used"] as? Int,
                                       size: update["size"] as? Int,
                                       input: (update["input"] as? Int)
                                           ?? (update["tokensIn"] as? Int),
                                       output: (update["output"] as? Int)
                                           ?? (update["tokensOut"] as? Int),
                                       costAmount: cost?["amount"] as? Double,
                                       costCurrency: cost?["currency"] as? String))
        default:
            break
        }
        emit(events)
        return events
    }

}
