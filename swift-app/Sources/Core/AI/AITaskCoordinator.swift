// goty — see CLAUDE.md for the working principles.
import Foundation

// MARK: - AITaskCoordinator

/// The bounded ReAct loop. Model turns drive tool dispatch through the
/// target's executor; replies STREAM into the card live. Safety is
/// proportionate: read-only probes and ordinary bash run auto-approved
/// in the open (every round is visible); write/edit and DESTRUCTIVE
/// operations (rm, dd, git reset…) gate on the fingerprinted proposal
/// until the user confirms. 25 tool calls per task, +25 on continue.
final class AITaskCoordinator {
    private let model: ModelClient
    private let executorFor: (ExecutionTarget) -> CommandExecutor
    /// All task state lives behind a private serial queue.
    private var tasks: [UUID: AITask] = [:]
    /// Probed host facts per task (AITask.context is let; facts land here).
    private var hostFacts: [UUID: String] = [:]
    /// Wire conversation per task: system + user, then assistant
    /// tool_call / tool-result pairs.
    private var wire: [UUID: [ChatMessage]] = [:]
    /// The tool call behind the pending proposal (replayed on confirm).
    private var pendingCall: [UUID: ToolCall] = [:]
    /// Reasoning the model emitted with its last reply, waiting to be
    /// attached to the round that reply's tool call produces.
    private var pendingReasoning: [UUID: String] = [:]
    /// Live-emit throttle: at most one snapshot per 100ms per task —
    /// markdown re-render per token would stutter the card.
    private var lastLiveEmit: [UUID: Date] = [:]
    /// Cancellation handles for what a task has in flight RIGHT NOW:
    /// the model's stream task and the running exec process. cancel()
    /// tears both down — a cancelled task must stop burning the
    /// network and the target's CPU, not merely ignore late results.
    private var inFlightStream: [UUID: Task<Void, Never>] = [:]
    private var inFlightExec: [UUID: ProcessRunnerHandle] = [:]
    private let queue = DispatchQueue(label: "goty.ai.coord")

    /// Fires on the main queue with a full task snapshot after every
    /// phase/round change.
    var onUpdate: ((AITask) -> Void)?

    init(model: ModelClient, executorFor: @escaping (ExecutionTarget) -> CommandExecutor) {
        self.model = model
        self.executorFor = executorFor
    }

    // MARK: entry points

    func start(context: AIContext) -> UUID {
        let id = UUID()
        aiDebug("start: '\(context.request.prefix(40))' target=\(context.target.displayName) transport=\(context.target.transport)")
        queue.async {
            var task = AITask(id: id, context: context)
            task.advance(to: .thinking)
            self.tasks[id] = task
            self.emit(id)
            // Fact probe: hard-coded, not a model tool call, not
            // budget-charged. Runs through the target's own executor
            // (local targets get a LocalExecutor from the factory).
            let exec = self.executorFor(context.target)
            self.inFlightExec[id] = exec.run("whoami; hostname; uname -srm", cwd: nil, timeout: 15) { [weak self] result in
                self?.queue.async {
                    self?.inFlightExec[id] = nil
                    guard let self, self.tasks[id] != nil else { return }
                    if case .success(let r) = result {
                        self.hostFacts[id] = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                    } else {
                        self.hostFacts[id] = ""
                    }
                    self.step(id)
                }
            }
        }
        return id
    }

    func confirm(taskId: UUID) {
        queue.async {
            guard var task = self.tasks[taskId], task.phase == .awaitingConfirmation,
                  let proposal = task.pendingProposal else { return }
            task.advance(to: .executing)
            self.tasks[taskId] = task
            self.emit(taskId)
            let call = self.pendingCall[taskId]
            switch proposal.op {
            case .bash(let command):
                self.inFlightExec[taskId] = self.executorFor(task.context.target)
                    .run(command, cwd: task.context.target.cwd, timeout: 60) { [weak self] r in
                        self?.queue.async {
                            self?.inFlightExec[taskId] = nil
                            self?.finishConfirmed(taskId, call, Self.describeExec(r))
                        }
                    }
            case .write(let path, let content):
                self.executorFor(task.context.target)
                    .write(path: path, content: content) { [weak self] r in
                        self?.queue.async {
                            self?.finishConfirmed(taskId, call, Self.describeExec(r))
                        }
                    }
            case .edit(let path, let oldText, let newText):
                self.executorFor(task.context.target)
                    .edit(path: path, oldText: oldText, newText: newText) { [weak self] r in
                        self?.queue.async {
                            self?.finishConfirmed(taskId, call, Self.describeExec(r))
                        }
                    }
            }
        }
    }

    /// Replace the pending proposal. The old confirmation was never used;
    /// the new one still requires an explicit confirm before execution.
    func edit(taskId: UUID, to proposal: AIProposal) {
        queue.async {
            guard var task = self.tasks[taskId], task.phase == .awaitingConfirmation else { return }
            task.setPending(proposal)
            self.tasks[taskId] = task
            self.emit(taskId)   // phase stays .awaitingConfirmation
        }
    }

    /// True while the loop can still make progress (close/cancel
    /// should act; terminal phases stay put on a late close click).
    private static func isActive(_ phase: AITaskPhase) -> Bool {
        switch phase {
        case .idle, .thinking, .awaitingConfirmation,
             .executing, .budgetExhausted:
            return true
        case .completed, .failed, .cancelled:
            return false
        }
    }

    func cancel(taskId: UUID) {
        queue.async {
            guard var task = self.tasks[taskId], Self.isActive(task.phase)
            else { return }   // terminal phases stay put (late close click)
            task.advance(to: .cancelled)
            self.tasks[taskId] = task
            // Kill what is RUNNING, not just what it reports: the
            // model stream keeps burning tokens and the exec process
            // keeps burning the target's CPU until they are torn down.
            self.inFlightStream[taskId]?.cancel()
            self.inFlightStream[taskId] = nil
            self.inFlightExec[taskId]?.cancel()
            self.inFlightExec[taskId] = nil
            self.emit(taskId)
        }
    }

    func continueBudget(taskId: UUID) {
        queue.async {
            guard var task = self.tasks[taskId], case .budgetExhausted = task.phase else { return }
            task.grantBudget(25)
            task.advance(to: .thinking)
            self.tasks[taskId] = task
            self.emit(taskId)
            self.step(taskId)
        }
    }

    // MARK: loop

    private func step(_ id: UUID) {
        guard let task = tasks[id], task.phase == .thinking else { return }
        if wire[id] == nil {
            wire[id] = Self.initialMessages(for: task, facts: hostFacts[id] ?? "")
        }
        aiDebug("step: calling model, rounds=\(task.rounds.count)")
        inFlightStream[id] = model.stream(messages: wire[id]!, tools: Self.toolSpecs,
                     onDelta: { [weak self] delta in
                         self?.queue.async { self?.liveDelta(id, delta) }
                     },
                     completion: { [weak self] result in
                         self?.queue.async {
                             self?.inFlightStream[id] = nil
                             self?.handle(id, result)
                         }
                     })
    }

    /// One streamed chunk: grows the task's live text and emits a
    /// throttled snapshot (the resolving turn emits anyway).
    private func liveDelta(_ id: UUID, _ delta: StreamDelta) {
        guard var task = tasks[id], task.phase == .thinking else { return }
        task.appendLive(delta)
        tasks[id] = task
        let now = Date()
        if let last = lastLiveEmit[id], now.timeIntervalSince(last) < 0.1 { return }
        lastLiveEmit[id] = now
        emit(id)
    }

    /// Env-gated trace (GOTY_AI_DEBUG=1): the @ai loop's decision points.
    private func aiDebug(_ msg: String) {
        if ProcessInfo.processInfo.environment["GOTY_AI_DEBUG"] == "1" {
            FileHandle.standardError.write("AICoord \(msg)\n".data(using: .utf8)!)
        }
    }

    private func handle(_ id: UUID, _ result: Result<ModelReply, ModelError>) {
        guard var task = tasks[id], task.phase == .thinking else { return }
        task.clearLive()
        switch result {
        case .failure(let error):
            aiDebug("task failed: \(error)")
            task.advance(to: .failed(String(describing: error)))
            tasks[id] = task
            emit(id)
        case .success(let reply):
            if let r = reply.reasoning, !r.isEmpty {
                pendingReasoning[id] = r
            }
            if let text = reply.text, reply.toolCalls.isEmpty {
                task.advance(to: .completed(summary: text))
                tasks[id] = task
                emit(id)
                return
            }
            guard let call = reply.toolCalls.first else {
                task.advance(to: .failed("empty model reply"))
                tasks[id] = task
                emit(id)
                return
            }
            guard task.spendRound() else {
                task.advance(to: .budgetExhausted(progress: Self.summarize(task.rounds)))
                tasks[id] = task
                emit(id)
                return
            }
            tasks[id] = task
            dispatch(id, call)
        }
    }

    private func dispatch(_ id: UUID, _ call: ToolCall) {
        guard let task = tasks[id] else { return }
        // The assistant turn enters the wire history now; its tool result
        // lands only once execution actually happens (a paused proposal
        // contributes no tool message yet).
        wire[id]?.append(ChatMessage(role: "assistant", content: nil, toolCalls: [call]))
        let exec = executorFor(task.context.target)
        switch call.name {
        case "read":
            exec.read(path: Self.argString(call, "path") ?? "") { [weak self] r in
                self?.queue.async {
                    self?.finishRound(id, call, Self.describeRead(r))
                }
            }
        case "bash":
            let command = Self.argString(call, "command") ?? ""
            let risk = ReadOnlyPolicy.classify(command)
            if risk == .destructive {
                // Only destructive bash gates: reads and ordinary
                // mutations run in the open (every round is visible).
                // write/edit always gate — see their cases above.
                propose(id, call, AIProposal(op: .bash(command), explanation: "",
                                             risk: risk, rollbackHint: nil))
            } else {
                let timeout = Self.argAny(call, "timeout") as? Double ?? 60
                let cwd = Self.argString(call, "cwd") ?? task.context.target.cwd
                inFlightExec[id] = exec.run(command, cwd: cwd, timeout: timeout) { [weak self] r in
                    self?.queue.async {
                        self?.inFlightExec[id] = nil
                        self?.finishRound(id, call, Self.describeExec(r))
                    }
                }
        }
        case "write":
            // File mutations are NEVER silent: the toolSpec promises
            // confirmation and the card's fingerprinted proposal is the
            // gate. The confirm path (below) is the only executor
            // entry for write/edit.
            let path = Self.argString(call, "path") ?? ""
            let content = Self.argString(call, "content") ?? ""
            propose(id, call, AIProposal(
                op: .write(path: path, content: content),
                explanation: "写入 \(path)(\(content.utf8.count) 字节)",
                risk: .mutating, rollbackHint: nil))
        case "edit":
            let path = Self.argString(call, "path") ?? ""
            let oldText = Self.argString(call, "oldText") ?? ""
            let newText = Self.argString(call, "newText") ?? ""
            propose(id, call, AIProposal(
                op: .edit(path: path, oldText: oldText, newText: newText),
                explanation: "编辑 \(path)(替换 \(oldText.utf8.count)→\(newText.utf8.count) 字节)",
                risk: .mutating, rollbackHint: nil))
        case "fetch_content":
            // Web tools run AGENT-SIDE (the Mac), never the target's
            // executor — docs are local even for SSH targets.
            WebAccess.fetch(url: Self.argString(call, "url") ?? "") { [weak self] result in
                self?.queue.async { self?.finishRound(id, call, result) }
            }
        case "web_search":
            WebAccess.search(query: Self.argString(call, "query") ?? "") { [weak self] result in
                self?.queue.async { self?.finishRound(id, call, result) }
            }
        default:
            finishRound(id, call, "unknown tool: \(call.name)")
        }
    }

    private func propose(_ id: UUID, _ call: ToolCall, _ proposal: AIProposal) {
        guard var task = tasks[id], task.phase == .thinking else { return }
        pendingCall[id] = call
        task.setPending(proposal)
        task.advance(to: .awaitingConfirmation)
        tasks[id] = task
        emit(id)
    }

    /// Auto-approved probe completed: record the round + tool message,
    /// then keep stepping.
    private func finishRound(_ id: UUID, _ call: ToolCall, _ result: String) {
        guard var task = tasks[id], task.phase == .thinking else { return }
        task.append(round: AIRound(reasoning: pendingReasoning.removeValue(forKey: id),
                                   toolName: call.name,
                                   toolInput: call.argumentsJSON, toolResult: result))
        wire[id]?.append(ChatMessage(role: "tool", content: result, toolCallId: call.id))
        tasks[id] = task
        emit(id)
        step(id)
    }

    /// Confirmed mutation completed: record the round, clear the gate,
    /// resume the loop (post-exec verification is just the next rounds).
    private func finishConfirmed(_ id: UUID, _ call: ToolCall?, _ result: String) {
        guard var task = tasks[id], task.phase == .executing else { return }
        task.append(round: AIRound(reasoning: pendingReasoning.removeValue(forKey: id),
                                   toolName: call?.name ?? "op",
                                   toolInput: call?.argumentsJSON ?? task.pendingProposal?.fingerprint ?? "",
                                   toolResult: result))
        task.setPending(nil)
        pendingCall[id] = nil
        wire[id]?.append(ChatMessage(role: "tool", content: result,
                                     toolCallId: call?.id ?? "confirmed"))
        task.advance(to: .thinking)
        tasks[id] = task
        emit(id)
        step(id)
    }

    private func emit(_ id: UUID) {
        guard let task = tasks[id] else { return }
        let snapshot = task
        DispatchQueue.main.async { [weak self] in
            self?.onUpdate?(snapshot)
        }
    }

    // MARK: prompts (pure, test-visible surface)

    static let toolSpecs: [ToolSpec] = [
        ToolSpec(name: "read",
                 description: "Read a file's content. Read-only, auto-approved.",
                 parametersJSON: """
                 {"type":"object","properties":{"path":{"type":"string"},\
                 "offset":{"type":"integer"},"limit":{"type":"integer"}},\
                 "required":["path"]}
                 """),
        ToolSpec(name: "write",
                 description: "Create or overwrite a file. Requires user confirmation.",
                 parametersJSON: """
                 {"type":"object","properties":{"path":{"type":"string"},\
                 "content":{"type":"string"}},"required":["path","content"]}
                 """),
        ToolSpec(name: "edit",
                 description: "Replace the first occurrence of oldText with newText in a file. Requires user confirmation.",
                 parametersJSON: """
                 {"type":"object","properties":{"path":{"type":"string"},\
                 "oldText":{"type":"string"},"newText":{"type":"string"}},\
                 "required":["path","oldText","newText"]}
                 """),
        ToolSpec(name: "bash",
                 description: "Run a shell command. Read-only and ordinary commands run automatically; destructive operations (rm, git reset…) require user confirmation.",
                 parametersJSON: """
                 {"type":"object","properties":{"command":{"type":"string"},\
                 "cwd":{"type":"string"},"timeout":{"type":"number"}},\
                 "required":["command"]}
                 """),
        ToolSpec(name: "fetch_content",
                 description: "Fetch an http(s) URL and return readable text (HTML stripped). Runs on the local Mac, not the target host. Use for docs, APIs, changelogs.",
                 parametersJSON: """
                 {"type":"object","properties":{"url":{"type":"string"}},\
                 "required":["url"]}
                 """),
        ToolSpec(name: "web_search",
                 description: "Web search (DuckDuckGo): top results with title, URL and snippet. Follow up with fetch_content on a result URL for the full page.",
                 parametersJSON: """
                 {"type":"object","properties":{"query":{"type":"string"}},\
                 "required":["query"]}
                 """),
    ]

    static func initialMessages(for task: AITask, facts: String) -> [ChatMessage] {
        let target = task.context.target
        var host = "Target: \(target.displayName)"
        if let cwd = target.cwd { host += ", working directory: \(cwd)" }
        let system = """
        You are a terminal task agent working on the user's machine. You have \
        four tools: read, write, edit, bash. Read-only probes and ordinary \
        commands run automatically; write, edit and destructive operations \
        require explicit user confirmation. Prefer read-only probes; produce \
        minimal mutations. \(host). Host facts: \(facts.isEmpty ? "unknown" : facts).
        """
        var user = "Request: \(task.context.request)"
        if !task.context.visibleOutput.isEmpty {
            user += "\n\nRecent terminal output:\n\(task.context.visibleOutput)"
        }
        return [
            ChatMessage(role: "system", content: system),
            ChatMessage(role: "user", content: user),
        ]
    }

    static func summarize(_ rounds: [AIRound]) -> String {
        guard let last = rounds.last else { return "no rounds completed" }
        return "\(rounds.count) tool rounds used; last: \(last.toolName ?? "?")"
    }

    // MARK: helpers

    private static func argAny(_ call: ToolCall, _ key: String) -> Any? {
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(call.argumentsJSON.utf8)))
                as? [String: Any] else { return nil }
        return obj[key]
    }

    private static func argString(_ call: ToolCall, _ key: String) -> String? {
        argAny(call, key) as? String
    }

    private static func describeExec(_ r: Result<ExecResult, ExecFailure>) -> String {
        switch r {
        case .success(let e):
            var out = "exit \(e.exitCode)\n" + String(e.stdout.prefix(2000))
            if !e.stderr.isEmpty { out += "\nstderr: " + String(e.stderr.prefix(500)) }
            return out
        case .failure(let f):
            return "error: \(f)"
        }
    }

    private static func describeRead(_ r: Result<String, ExecFailure>) -> String {
        switch r {
        case .success(let s): return String(s.prefix(4000))
        case .failure(let f): return "error: \(f)"
        }
    }
}
