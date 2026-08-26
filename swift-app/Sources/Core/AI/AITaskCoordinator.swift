// goty — see CLAUDE.md for the working principles.
import Foundation

// MARK: - AITaskCoordinator

/// The bounded ReAct loop. Model turns drive tool dispatch through the
/// target's executor; read-only probes run auto-approved, every mutation
/// becomes an AIProposal gated on explicit confirmation (target + op
/// fingerprint). 25 tool calls per task, +25 on explicit continue.
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
            exec.run("whoami; hostname; uname -srm", cwd: nil, timeout: 15) { [weak self] result in
                self?.queue.async {
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
                self.executorFor(task.context.target)
                    .run(command, cwd: task.context.target.cwd, timeout: 60) { [weak self] r in
                        self?.queue.async {
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

    func cancel(taskId: UUID) {
        queue.async {
            guard var task = self.tasks[taskId] else { return }
            task.advance(to: .cancelled)
            self.tasks[taskId] = task
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
        model.complete(messages: wire[id]!, tools: Self.toolSpecs) { [weak self] result in
            self?.queue.async { self?.handle(id, result) }
        }
    }

    /// Env-gated trace (GOTY_AI_DEBUG=1): the @ai loop's decision points.
    private func aiDebug(_ msg: String) {
        if ProcessInfo.processInfo.environment["GOTY_AI_DEBUG"] == "1" {
            FileHandle.standardError.write("AICoord \(msg)\n".data(using: .utf8)!)
        }
    }

    private func handle(_ id: UUID, _ result: Result<ModelReply, ModelError>) {
        guard var task = tasks[id], task.phase == .thinking else { return }
        switch result {
        case .failure(let error):
            aiDebug("task failed: \(error)")
            task.advance(to: .failed(String(describing: error)))
            tasks[id] = task
            emit(id)
        case .success(let reply):
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
            if ReadOnlyPolicy.autoExecutable(command) {
                let timeout = Self.argAny(call, "timeout") as? Double ?? 60
                let cwd = Self.argString(call, "cwd") ?? task.context.target.cwd
                exec.run(command, cwd: cwd, timeout: timeout) { [weak self] r in
                    self?.queue.async {
                        self?.finishRound(id, call, Self.describeExec(r))
                    }
                }
            } else {
                propose(id, call, AIProposal(op: .bash(command), explanation: "",
                                             risk: ReadOnlyPolicy.classify(command),
                                             rollbackHint: nil))
            }
        case "write":
            propose(id, call, AIProposal(
                op: .write(path: Self.argString(call, "path") ?? "",
                           content: Self.argString(call, "content") ?? ""),
                explanation: "", risk: .mutating, rollbackHint: nil))
        case "edit":
            propose(id, call, AIProposal(
                op: .edit(path: Self.argString(call, "path") ?? "",
                          oldText: Self.argString(call, "oldText") ?? "",
                          newText: Self.argString(call, "newText") ?? ""),
                explanation: "", risk: .mutating, rollbackHint: nil))
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
        task.append(round: AIRound(reasoning: nil, toolName: call.name,
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
        task.append(round: AIRound(reasoning: nil, toolName: call?.name ?? "op",
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
                 description: "Run a shell command. Read-only commands run auto-approved; anything mutating requires user confirmation.",
                 parametersJSON: """
                 {"type":"object","properties":{"command":{"type":"string"},\
                 "cwd":{"type":"string"},"timeout":{"type":"number"}},\
                 "required":["command"]}
                 """),
    ]

    static func initialMessages(for task: AITask, facts: String) -> [ChatMessage] {
        let target = task.context.target
        var host = "Target: \(target.displayName)"
        if let cwd = target.cwd { host += ", working directory: \(cwd)" }
        let system = """
        You are a terminal task agent working on the user's machine. You have \
        four tools: read, write, edit, bash. Read-only probes run automatically; \
        every mutation requires explicit user confirmation. Prefer read-only \
        probes; produce minimal mutations. \(host). Host facts: \(facts.isEmpty ? "unknown" : facts).
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
